// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MathHarness} from "../utils/MathHarness.sol";
import {Leg, OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice Solidity vs the independent exact-rational Python model (TESTING.md sections 19-22, 108-109; RSK-020,
///         FIX-015, FIX-017, MTH-010). Expected values never come from Solidity.
contract DifferentialTest is Test {
    uint256 constant W = 1e18;
    MathHarness m;
    string constant REF = "../test-vectors/optara_ref.py";

    function setUp() public {
        m = new MathHarness();
    }

    // ------------------------------------------------------------------ FFI differential fuzzing

    function _legArgs(Leg[] memory legs) internal pure returns (string[] memory out) {
        out = new string[](1 + 6 * legs.length);
        out[0] = vm.toString(legs.length);
        for (uint256 i = 0; i < legs.length; ++i) {
            out[1 + 6 * i] = legs[i].optionType == OptionType.CALL ? "0" : "1";
            out[2 + 6 * i] = vm.toString(legs[i].strikeWad);
            out[3 + 6 * i] = vm.toString(legs[i].capWad);
            out[4 + 6 * i] = vm.toString(legs[i].contractSizeWad);
            out[5 + 6 * i] = vm.toString(legs[i].shortQty);
            out[6 + 6 * i] = vm.toString(legs[i].lockedQty);
        }
    }

    function _ffi(string[] memory head, string[] memory legArgs) internal returns (bytes memory) {
        string[] memory cmd = new string[](head.length + legArgs.length + 2);
        cmd[0] = "python3";
        cmd[1] = REF;
        for (uint256 i = 0; i < head.length; ++i) {
            cmd[2 + i] = head[i];
        }
        for (uint256 i = 0; i < legArgs.length; ++i) {
            cmd[2 + head.length + i] = legArgs[i];
        }
        return vm.ffi(cmd);
    }

    /// RSK-020: exact worst-case numerator and native margin equal the reference for random portfolios.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_RSK_020_marginMatchesReference(uint256 seed, uint8 d) public {
        d = uint8(bound(d, 0, 18));
        Leg[] memory legs = _randomLegs(seed);
        string[] memory head = new string[](4);
        head[0] = "margin";
        head[1] = vm.toString(uint256(d));
        head[2] = "0";
        head[3] = "0";
        (uint256 refWorst, uint256 refMargin) = abi.decode(_ffi(head, _legArgs(legs)), (uint256, uint256));
        assertEq(m.worstCaseLossNumerator(legs), refWorst, "worst numerator");
        assertEq(m.marginNative(legs, d), refMargin, "native margin");
    }

    /// Settlement numerators and the single-rounded net delta equal the reference at any price.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_settlementMatchesReference(uint256 seed, uint256 price, uint8 d) public {
        d = uint8(bound(d, 0, 18));
        price = bound(price, 0, 80 * W);
        Leg[] memory legs = _randomLegs(seed);
        string[] memory head = new string[](3);
        head[0] = "settle";
        head[1] = vm.toString(uint256(d));
        head[2] = vm.toString(price);
        (uint256 refShort, uint256 refLong, uint256 isDebit, uint256 deltaAbs) =
            abi.decode(_ffi(head, _legArgs(legs)), (uint256, uint256, uint256, uint256));
        (uint256 s, uint256 l) = m.numeratorsAt(legs, price);
        assertEq(s, refShort);
        assertEq(l, refLong);
        uint256 den = m.nativeDenominator(d);
        if (s > l) {
            assertEq(isDebit, 1);
            assertEq(m.ceilDiv(s - l, den), deltaAbs);
        } else if (s == l) {
            assertEq(isDebit, 0);
            assertEq(deltaAbs, 0);
        } else {
            assertEq(isDebit, 0);
            assertEq((l - s) / den, deltaAbs);
        }
    }

    /// FIX-017 / INV-ROUND-06: at ANY price (interior included) the single-rounded net debit never exceeds the
    /// pre-funded native margin computed at critical points only.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_FIX_017_interiorDebitBoundedByMargin(uint256 seed, uint256 price, uint8 d) public {
        d = uint8(bound(d, 0, 18));
        price = bound(price, 0, 80 * W);
        Leg[] memory legs = _randomLegs(seed);
        uint256 margin = m.marginNative(legs, d);
        string[] memory head = new string[](3);
        head[0] = "lossat";
        head[1] = vm.toString(uint256(d));
        head[2] = vm.toString(price);
        uint256 refLossCeil = abi.decode(_ffi(head, _legArgs(legs)), (uint256));
        assertLe(refLossCeil, margin);
        uint256 loss = m.lossNumeratorAt(legs, price);
        assertLe(m.ceilDiv(loss, m.nativeDenominator(d)), margin);
    }

    // ------------------------------------------------------------------ Shared JSON vectors (MTH-010)

    function test_MTH_010_riskVectors() public view {
        string memory json = vm.readFile("../test-vectors/vectors/risk.json");
        uint256 n = vm.parseJsonUint(json, ".count");
        assertGt(n, 100);
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".vectors[", vm.toString(i), "]");
            Leg[] memory legs = abi.decode(vm.parseJsonBytes(json, string.concat(p, ".legsAbi")), (Leg[]));
            uint8 d = uint8(vm.parseJsonUint(json, string.concat(p, ".decimals")));
            assertEq(
                m.worstCaseLossNumerator(legs), vm.parseJsonUint(json, string.concat(p, ".worstNumerator")), "worst"
            );
            assertEq(m.marginNative(legs, d), vm.parseJsonUint(json, string.concat(p, ".marginNative")), "margin");
        }
    }

    function test_MTH_010_settlementVectors() public view {
        string memory json = vm.readFile("../test-vectors/vectors/settlement.json");
        uint256 n = vm.parseJsonUint(json, ".count");
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".vectors[", vm.toString(i), "]");
            Leg[] memory legs = abi.decode(vm.parseJsonBytes(json, string.concat(p, ".legsAbi")), (Leg[]));
            uint8 d = uint8(vm.parseJsonUint(json, string.concat(p, ".decimals")));
            uint256 price = vm.parseJsonUint(json, string.concat(p, ".priceWad"));
            (uint256 s, uint256 l) = m.numeratorsAt(legs, price);
            assertEq(s, vm.parseJsonUint(json, string.concat(p, ".shortNumerator")));
            assertEq(l, vm.parseJsonUint(json, string.concat(p, ".longNumerator")));
            uint256 den = m.nativeDenominator(d);
            bool isDebit = vm.parseJsonBool(json, string.concat(p, ".isDebit"));
            uint256 expected = vm.parseJsonUint(json, string.concat(p, ".deltaAbs"));
            assertEq(isDebit, s > l);
            assertEq(s >= l ? m.ceilDiv(s - l, den) : (l - s) / den, expected);
        }
    }

    function test_MTH_010_payoffAndRedeemVectors() public view {
        string memory json = vm.readFile("../test-vectors/vectors/payoff.json");
        uint256 n = vm.parseJsonUint(json, ".phiCount");
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".phi[", vm.toString(i), "]");
            OptionType t = keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".optionType"))))
                == keccak256("CALL")
                ? OptionType.CALL
                : OptionType.PUT;
            assertEq(
                m.phi(
                    t,
                    vm.parseJsonUint(json, string.concat(p, ".strikeWad")),
                    vm.parseJsonUint(json, string.concat(p, ".capWad")),
                    vm.parseJsonUint(json, string.concat(p, ".priceWad"))
                ),
                vm.parseJsonUint(json, string.concat(p, ".phiWad"))
            );
        }
        n = vm.parseJsonUint(json, ".redeemCount");
        for (uint256 i = 0; i < n; ++i) {
            string memory p = string.concat(".redeem[", vm.toString(i), "]");
            OptionType t = keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".optionType"))))
                == keccak256("CALL")
                ? OptionType.CALL
                : OptionType.PUT;
            uint256 num = m.payoffNumerator(
                t,
                vm.parseJsonUint(json, string.concat(p, ".strikeWad")),
                vm.parseJsonUint(json, string.concat(p, ".capWad")),
                vm.parseJsonUint(json, string.concat(p, ".contractSizeWad")),
                vm.parseJsonUint(json, string.concat(p, ".priceWad")),
                vm.parseJsonUint(json, string.concat(p, ".quantity"))
            );
            uint8 d = uint8(vm.parseJsonUint(json, string.concat(p, ".decimals")));
            assertEq(num / m.nativeDenominator(d), vm.parseJsonUint(json, string.concat(p, ".payoutNative")));
        }
    }

    // ------------------------------------------------------------------ FIX-015 fragmentation

    /// FIX-015: 18-decimal asset, per-whole payoff WAD + 1, two half-option writers and one whole redeemer.
    /// Rounded writer debits (ceil each) cover the floored redemption; the surplus is exactly the rounding residual.
    function test_FIX_015_fragmentedWritersFundAggregatedLong() public view {
        // price = K + phi with phi = 1e18 + 1 wei per underlying
        uint256 k = 10 * W;
        uint256 price = k + W + 1;
        uint256 den = m.nativeDenominator(18);
        uint256 half = m.payoffNumerator(OptionType.CALL, k, 5 * W, W, price, W / 2);
        uint256 whole = m.payoffNumerator(OptionType.CALL, k, 5 * W, W, price, W);
        uint256 debits = 2 * m.ceilDiv(half, den);
        uint256 payout = whole / den;
        assertGe(debits, payout);
        assertEq(debits - payout, 1);
        // residual = 2 * (ceil(half) - half) + (whole - floor(whole)), exactly
        assertEq((debits * den) - whole + (whole - payout * den), (debits - payout) * den);
    }

    function _randomLegs(uint256 seed) internal pure returns (Leg[] memory legs) {
        uint256 n = 1 + seed % 8;
        legs = new Leg[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "diff")));
            OptionType t = r % 2 == 0 ? OptionType.CALL : OptionType.PUT;
            uint256 k = (1 + (r >> 8) % 40) * W / 2 + (r >> 16) % 1000;
            uint256 c = (1 + (r >> 24) % 20) * W / 4 + (r >> 32) % 1000;
            if (t == OptionType.PUT && c > k) c = k;
            uint256 cs = [W, W / 10, W / 4, 3 * W / 2, W + 7][(r >> 40) % 5];
            uint256 sh = (r >> 48) % 3 == 0 ? 0 : 1 + (r >> 56) % (10 * W);
            uint256 lo = (r >> 120) % 2 == 0 ? 0 : 1 + (r >> 128) % (10 * W);
            if (sh == 0 && lo == 0) sh = W;
            legs[i] = Leg(t, k, c, cs, sh, lo);
        }
    }
}
