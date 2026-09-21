// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionMath} from "../src/libraries/OptionMath.sol";
import {OptionType} from "../src/Types.sol";
import {InvalidDecimals} from "../src/Errors.sol";

/// Exposes the internal library so reverts can be asserted.
contract OptionMathHarness {
    function optionScale(uint8 d) external pure returns (uint256) {
        return OptionMath.optionScale(d);
    }

    function uqScale(uint8 u, uint8 q) external pure returns (uint256) {
        return OptionMath.uqScale(u, q);
    }

    function buyerPayoutRate(OptionType t, uint256 c, uint256 k, uint256 s, uint256 uq) external pure returns (uint256) {
        return OptionMath.buyerPayoutRate(t, c, k, s, uq);
    }
}

/// The six normative vectors from simple-workflow/math.md are asserted bit for bit, including every
/// intermediate value, then the invariants are fuzzed.
contract OptionMathTest is Test {
    OptionMathHarness h = new OptionMathHarness();

    // ---------------------------------------------------------------- scales

    function test_uqScale_allDecimalPairsAreExact() public pure {
        assertEq(OptionMath.uqScale(18, 6), 1e30);
        assertEq(OptionMath.uqScale(6, 18), 1e6);
        assertEq(OptionMath.uqScale(8, 6), 1e20);
        assertEq(OptionMath.uqScale(18, 18), 1e18);
        assertEq(OptionMath.uqScale(0, 18), 1);
        assertEq(OptionMath.uqScale(18, 0), 1e36);
        assertEq(OptionMath.uqScale(6, 6), 1e18);
    }

    function testFuzz_uqScale_matchesDefinitionAndIsAtLeastOne(uint8 u, uint8 q) public pure {
        u = uint8(bound(u, 0, 18));
        q = uint8(bound(q, 0, 18));
        uint256 uq = OptionMath.uqScale(u, q);
        assertGe(uq, 1);
        // 1e18 * 10**u == uq * 10**q exactly (no rounding anywhere)
        assertEq(1e18 * (10 ** uint256(u)), uq * (10 ** uint256(q)));
    }

    function test_decimalsAbove18Revert() public {
        vm.expectRevert(InvalidDecimals.selector);
        h.uqScale(19, 6);
        vm.expectRevert(InvalidDecimals.selector);
        h.uqScale(6, 19);
        vm.expectRevert(InvalidDecimals.selector);
        h.optionScale(19);
    }

    /// Sanity checks from math.md: quoteRaw(underlyingRaw, price) = underlyingRaw * price / UQ_SCALE.
    function test_quoteRawSanity() public pure {
        // MON (18 dp) against USDC (6 dp) at 5.25 -> 5.25 USDC
        assertEq(Math.mulDiv(1e18, 5.25e18, OptionMath.uqScale(18, 6)), 5.25e6);
        // underlying 6 dp against quote 18 dp -> 5.25 whole quote
        assertEq(Math.mulDiv(1e6, 5.25e18, OptionMath.uqScale(6, 18)), 5.25e18);
    }

    // ---------------------------------------------------------------- Vector 1

    function test_vector1_call_18_6_exact() public pure {
        uint256 os = OptionMath.optionScale(18);
        uint256 uq = OptionMath.uqScale(18, 6);
        assertEq(os, 1e18);
        assertEq(uq, 1e30);

        uint256 c = 1e18;
        uint256 k = 10e18;
        uint256 s = 12.5e18;

        uint256 cpo = OptionMath.collateralPerOption(OptionType.CALL, c, k, uq);
        assertEq(cpo, 1e18);
        assertEq(OptionMath.requiredCollateral(5e18, cpo, os), 5e18);

        uint256 rb = OptionMath.buyerPayoutRate(OptionType.CALL, c, k, s, uq);
        uint256 rw = OptionMath.residualRate(cpo, rb);
        assertEq(rb, 2e17);
        assertEq(rw, 8e17);

        assertEq(OptionMath.grossClaim(5e18, rb, os), 1e18);
        assertEq(OptionMath.grossClaim(5e18, rw, os), 4e18);
        assertEq(OptionMath.grossClaim(5e18, rb, os) + OptionMath.grossClaim(5e18, rw, os), 5e18);
    }

    // ---------------------------------------------------------------- Vector 2

    function test_vector2_put_8_6() public pure {
        uint256 os = OptionMath.optionScale(18);
        uint256 uq = OptionMath.uqScale(8, 6);
        assertEq(uq, 1e20);

        uint256 c = 1e6;
        uint256 k = 60000e18;
        uint256 s = 55000e18;

        uint256 cpo = OptionMath.collateralPerOption(OptionType.PUT, c, k, uq);
        assertEq(cpo, 6e8);
        assertEq(OptionMath.requiredCollateral(3e18, cpo, os), 1.8e9);

        uint256 rb = OptionMath.buyerPayoutRate(OptionType.PUT, c, k, s, uq);
        uint256 rw = OptionMath.residualRate(cpo, rb);
        assertEq(rb, 5e7);
        assertEq(rw, 5.5e8);

        assertEq(OptionMath.grossClaim(3e18, rb, os), 1.5e8);
        assertEq(OptionMath.grossClaim(3e18, rw, os), 1.65e9);
        assertEq(OptionMath.grossClaim(3e18, rb, os) + OptionMath.grossClaim(3e18, rw, os), 1.8e9);
    }

    // ---------------------------------------------------------------- Vector 3

    function test_vector3_call_nonTerminating_dustAppears() public pure {
        uint256 os = 1e18;
        uint256 uq = OptionMath.uqScale(18, 6);
        uint256 c = 1e18;
        uint256 k = 3e18;
        uint256 s = 7e18;

        uint256 cpo = OptionMath.collateralPerOption(OptionType.CALL, c, k, uq);
        assertEq(cpo, 1e18);

        uint256 rb = OptionMath.buyerPayoutRate(OptionType.CALL, c, k, s, uq);
        uint256 rw = OptionMath.residualRate(cpo, rb);
        assertEq(rb, 571428571428571428);
        assertEq(rw, 428571428571428572);

        assertEq(OptionMath.requiredCollateral(1e18, cpo, os), 1e18);
        uint256 holder = OptionMath.grossClaim(1e18 - 1, rb, os);
        uint256 writer = OptionMath.grossClaim(1e18, rw, os);
        assertEq(holder, 571428571428571427);
        assertEq(writer, 428571428571428572);
        assertEq(holder + writer, 999999999999999999);
        assertEq(1e18 - (holder + writer), 1); // 1 wei of dust, never negative
    }

    // ---------------------------------------------------------------- Vector 4

    function test_vector4_outOfTheMoney_bothTypes() public pure {
        uint256 uq = OptionMath.uqScale(18, 6);
        uint256 c = 1e18;
        uint256 k = 10e18;

        // CALL with S <= K
        uint256 cpoC = OptionMath.collateralPerOption(OptionType.CALL, c, k, uq);
        assertEq(OptionMath.buyerPayoutRate(OptionType.CALL, c, k, 10e18, uq), 0); // S == K
        assertEq(OptionMath.buyerPayoutRate(OptionType.CALL, c, k, 9e18, uq), 0); // S < K
        assertEq(OptionMath.residualRate(cpoC, 0), cpoC);

        // PUT with S >= K
        uint256 cpoP = OptionMath.collateralPerOption(OptionType.PUT, c, k, uq);
        assertEq(OptionMath.buyerPayoutRate(OptionType.PUT, c, k, 10e18, uq), 0); // S == K
        assertEq(OptionMath.buyerPayoutRate(OptionType.PUT, c, k, 11e18, uq), 0); // S > K
        assertEq(OptionMath.residualRate(cpoP, 0), cpoP);
    }

    // ---------------------------------------------------------------- Vector 5

    function test_vector5_fees() public pure {
        // continue vector 1, mintFeeBps = 10, exerciseFeeBps = 25
        assertEq(OptionMath.mintFee(5e18, 10), 5e15);
        // gross payout 1e18
        assertEq(OptionMath.exerciseFee(1e18, 25), 2.5e15);
        assertEq(uint256(1e18) - OptionMath.exerciseFee(1e18, 25), 9.975e17);
    }

    function test_fees_roundingDirection() public pure {
        // mint fee rounds UP, exercise fee rounds DOWN
        assertEq(OptionMath.mintFee(1, 1), 1); // ceil(1 * 1 / 10000) = 1
        assertEq(OptionMath.exerciseFee(1, 1), 0); // floor(1 * 1 / 10000) = 0
        assertEq(OptionMath.mintFee(10_000, 1), 1); // exact
        assertEq(OptionMath.mintFee(10_001, 1), 2); // 1.0001 -> 2
        assertEq(OptionMath.exerciseFee(10_001, 1), 1); // 1.0001 -> 1
    }

    function test_zeroFeesAreZero() public pure {
        assertEq(OptionMath.mintFee(123456789, 0), 0);
        assertEq(OptionMath.exerciseFee(123456789, 0), 0);
    }

    // ---------------------------------------------------------------- Vector 6

    function test_vector6_put_factoryFixedContractSize() public pure {
        uint256 os = OptionMath.optionScale(18);
        uint256 uq = OptionMath.uqScale(8, 6);
        uint256 c = 1e8; // one whole BTC
        uint256 k = 60000e18;
        uint256 s = 55000e18;

        uint256 cpo = OptionMath.collateralPerOption(OptionType.PUT, c, k, uq);
        assertEq(cpo, 6e10);
        assertEq(OptionMath.requiredCollateral(3e18, cpo, os), 1.8e11);

        uint256 rb = OptionMath.buyerPayoutRate(OptionType.PUT, c, k, s, uq);
        uint256 rw = OptionMath.residualRate(cpo, rb);
        assertEq(rb, 5e9);
        assertEq(rw, 5.5e10);

        assertEq(OptionMath.grossClaim(3e18, rb, os), 1.5e10);
        assertEq(OptionMath.grossClaim(3e18, rw, os), 1.65e11);
        assertEq(OptionMath.grossClaim(3e18, rb, os) + OptionMath.grossClaim(3e18, rw, os), 1.8e11);
    }

    // ---------------------------------------------------------------- put collateral rounds UP

    function test_putCollateralRoundsUp() public pure {
        // C*K/UQ = 1 * 1e18 / 1e30 * ... choose a value that does not divide evenly
        uint256 uq = OptionMath.uqScale(18, 6); // 1e30
        // C = 1e18 (1 whole MON), K = 1.0000001e18 -> C*K/UQ = 1.0000001e6 exactly. Use a non-exact one:
        uint256 cpo = OptionMath.collateralPerOption(OptionType.PUT, 3, 1e18, uq); // 3e18/1e30 = 3e-12 -> ceil = 1
        assertEq(cpo, 1);
    }

    // ---------------------------------------------------------------- price boundaries

    function test_priceBoundaries() public {
        uint256 uq = OptionMath.uqScale(18, 6);
        uint256 c = 1e18;
        uint256 k = 10e18;
        // very high S (call): payout approaches C but never reaches it
        uint256 rbHigh = OptionMath.buyerPayoutRate(OptionType.CALL, c, k, 1e30, uq);
        assertLt(rbHigh, c);
        // very low S (put): payout approaches collateralPerOption but never exceeds it
        uint256 cpoP = OptionMath.collateralPerOption(OptionType.PUT, c, k, uq);
        uint256 rbLow = OptionMath.buyerPayoutRate(OptionType.PUT, c, k, 1, uq);
        assertLe(rbLow, cpoP);
        assertLt(rbLow, cpoP);
        // S == 0 is never passed by the oracle library (it rejects non-positive answers), but the math
        // must still be safe if it were: a call is out of the money, a put pays at most its collateral.
        assertEq(h.buyerPayoutRate(OptionType.CALL, c, k, 0, uq), 0);
        assertLe(h.buyerPayoutRate(OptionType.PUT, c, k, 0, uq), cpoP);
    }

    // ---------------------------------------------------------------- fuzz: invariants

    /// buyerPayoutRate + residualRate == collateralPerOption, and the rate never exceeds it.
    function testFuzz_rateIdentityAndBounds(
        bool isPut,
        uint8 uDec,
        uint8 qDec,
        uint128 cRaw,
        uint128 kRaw,
        uint128 sRaw
    ) public pure {
        uDec = uint8(bound(uDec, 0, 18));
        qDec = uint8(bound(qDec, 0, 18));
        uint256 c = bound(cRaw, 1, 1e30);
        uint256 k = bound(kRaw, 1, 1e30);
        uint256 s = bound(sRaw, 1, 1e30);
        OptionType t = isPut ? OptionType.PUT : OptionType.CALL;
        uint256 uq = OptionMath.uqScale(uDec, qDec);

        uint256 cpo = OptionMath.collateralPerOption(t, c, k, uq);
        uint256 rb = OptionMath.buyerPayoutRate(t, c, k, s, uq);
        uint256 rw = OptionMath.residualRate(cpo, rb);

        assertEq(rb + rw, cpo);
        assertLe(rb, cpo);
        // the rate is zero when out of the money, strictly below collateral when in the money
        if (t == OptionType.CALL) {
            if (s <= k) assertEq(rb, 0);
            else assertLt(rb, cpo);
        } else {
            if (s >= k) assertEq(rb, 0);
            else assertLt(rb, cpo);
        }
    }

    /// Single-position solvency: buyer gross + writer gross <= required collateral.
    function testFuzz_singlePositionSolvency(
        bool isPut,
        uint8 uDec,
        uint8 qDec,
        uint128 cRaw,
        uint128 kRaw,
        uint128 sRaw,
        uint128 aRaw
    ) public pure {
        uDec = uint8(bound(uDec, 0, 18));
        qDec = uint8(bound(qDec, 0, 18));
        uint256 c = bound(cRaw, 1, 1e30);
        uint256 k = bound(kRaw, 1, 1e30);
        uint256 s = bound(sRaw, 1, 1e30);
        uint256 a = bound(aRaw, 1, 1e30);
        OptionType t = isPut ? OptionType.PUT : OptionType.CALL;
        uint256 uq = OptionMath.uqScale(uDec, qDec);
        uint256 os = 1e18;

        uint256 cpo = OptionMath.collateralPerOption(t, c, k, uq);
        uint256 rb = OptionMath.buyerPayoutRate(t, c, k, s, uq);
        uint256 rw = OptionMath.residualRate(cpo, rb);

        uint256 required = OptionMath.requiredCollateral(a, cpo, os);
        uint256 claims = OptionMath.grossClaim(a, rb, os) + OptionMath.grossClaim(a, rw, os);
        assertLe(claims, required);
    }

    /// Aggregate solvency with FRAGMENTED mints and claims: splitting can only add dust.
    function testFuzz_fragmentedSolvency(
        bool isPut,
        uint128 cRaw,
        uint128 kRaw,
        uint128 sRaw,
        uint64[6] memory mints,
        uint64[6] memory redeemSplits
    ) public pure {
        (uint256 cpo, uint256 rb, uint256 rw) =
            _rates(isPut, bound(cRaw, 1, 1e24), bound(kRaw, 1, 1e24), bound(sRaw, 1, 1e24));

        (uint256 totalMinted, uint256 totalCollateral) = _mintAll(mints, cpo);
        uint256 paidBuyers = _redeemAll(redeemSplits, totalMinted, rb);
        uint256 paidWriters = _claimAll(mints, rw);

        assertLe(paidBuyers + paidWriters, totalCollateral);
    }

    function _rates(bool isPut, uint256 c, uint256 k, uint256 s)
        internal
        pure
        returns (uint256 cpo, uint256 rb, uint256 rw)
    {
        OptionType t = isPut ? OptionType.PUT : OptionType.CALL;
        uint256 uq = OptionMath.uqScale(18, 6);
        cpo = OptionMath.collateralPerOption(t, c, k, uq);
        rb = OptionMath.buyerPayoutRate(t, c, k, s, uq);
        rw = OptionMath.residualRate(cpo, rb);
    }

    /// Several separate mints, each rounding its collateral up on its own.
    function _mintAll(uint64[6] memory mints, uint256 cpo)
        internal
        pure
        returns (uint256 totalMinted, uint256 totalCollateral)
    {
        for (uint256 i; i < 6; i++) {
            uint256 a = uint256(mints[i]) + 1;
            totalMinted += a;
            totalCollateral += OptionMath.requiredCollateral(a, cpo, 1e18);
        }
    }

    /// Holders redeem in arbitrary fragments that sum to exactly the supply.
    function _redeemAll(uint64[6] memory splits, uint256 total, uint256 rb) internal pure returns (uint256 paid) {
        uint256 remaining = total;
        for (uint256 i; i < 6; i++) {
            uint256 piece = uint256(splits[i]) % (remaining + 1);
            remaining -= piece;
            paid += OptionMath.grossClaim(piece, rb, 1e18);
        }
        paid += OptionMath.grossClaim(remaining, rb, 1e18);
    }

    /// Each writer claims the short amount of their own mint.
    function _claimAll(uint64[6] memory mints, uint256 rw) internal pure returns (uint256 paid) {
        for (uint256 i; i < 6; i++) {
            paid += OptionMath.grossClaim(uint256(mints[i]) + 1, rw, 1e18);
        }
    }

    /// Fees: mint fee rounds up, exercise fee rounds down and never exceeds the gross amount.
    function testFuzz_feeBounds(uint128 amount, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, 100));
        uint256 a = uint256(amount);
        uint256 mf = OptionMath.mintFee(a, bps);
        uint256 ef = OptionMath.exerciseFee(a, bps);
        assertLe(ef, mf);
        assertLe(ef, a);
        assertGe(mf * 10_000, a * bps);
        assertLe(ef * 10_000, a * bps);
        if (bps == 0) {
            assertEq(mf, 0);
            assertEq(ef, 0);
        }
    }
}
