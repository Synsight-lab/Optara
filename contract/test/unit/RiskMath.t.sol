// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MathHarness} from "../utils/MathHarness.sol";
import {Leg, OptionType} from "../../src/libraries/OptaraTypes.sol";
import {PayoffMath} from "../../src/libraries/PayoffMath.sol";

/// @notice TEST_CASES.md Part VI (RSK-001..015, 021, 022) at the library level. Expected values are hand-derived.
contract RiskMathTest is Test {
    uint256 constant W = 1e18;
    uint256 constant D6 = 1e48; // D_A for a 6-decimal asset
    MathHarness m;

    function setUp() public {
        m = new MathHarness();
    }

    function _call(uint256 k, uint256 c, uint256 sh, uint256 lo) internal pure returns (Leg memory) {
        return Leg(OptionType.CALL, k * W, c * W, W, sh, lo);
    }

    function _put(uint256 k, uint256 c, uint256 sh, uint256 lo) internal pure returns (Leg memory) {
        return Leg(OptionType.PUT, k * W, c * W, W, sh, lo);
    }

    function _one(Leg memory a) internal pure returns (Leg[] memory l) {
        l = new Leg[](1);
        l[0] = a;
    }

    function _two(Leg memory a, Leg memory b) internal pure returns (Leg[] memory l) {
        l = new Leg[](2);
        l[0] = a;
        l[1] = b;
    }

    function _margin6(Leg[] memory legs) internal view returns (uint256) {
        return m.marginNative(legs, 6);
    }

    function test_RSK_001_oneUnhedgedCall() public view {
        assertEq(_margin6(_one(_call(12, 5, W, 0))), 5e6); // MATH.md section 66
    }

    function test_RSK_002_oneUnhedgedPut() public view {
        assertEq(_margin6(_one(_put(10, 4, W, 0))), 4e6); // MATH.md section 68
    }

    function test_RSK_003_twoShortsSameSeriesAdd() public view {
        // Same series written twice is one leg with quantity 2.
        assertEq(_margin6(_one(_call(10, 5, 2 * W, 0))), 10e6);
    }

    function test_RSK_004_multipleStrikeCalls() public view {
        // short K10 C5 + short K12 C3: worst at S >= 15 = 5 + 3 = 8
        assertEq(_margin6(_two(_call(10, 5, W, 0), _call(12, 3, W, 0))), 8e6);
    }

    function test_RSK_005_multipleStrikePuts() public view {
        // short put K10 C4 + short put K8 C2: worst at S <= 6 = 4 + 2 = 6
        assertEq(_margin6(_two(_put(10, 4, W, 0), _put(8, 2, W, 0))), 6e6);
    }

    function test_RSK_006_mixedCallsAndPuts() public view {
        // short call K12 C3 + short put K8 C3: max(3, 3) = 3, not 6 (MATH.md section 75)
        assertEq(_margin6(_two(_call(12, 3, W, 0), _put(8, 3, W, 0))), 3e6);
    }

    function test_RSK_007_shortCallPlusHigherLockedCall() public view {
        assertEq(_margin6(_two(_call(10, 5, W, 0), _call(12, 3, 0, W))), 2e6); // MATH.md section 67
    }

    function test_RSK_008_shortPutPlusLowerLockedPut() public view {
        // short put K10 C4 + locked put K8 C2. S<=6: 4-2 = 2; S=8: 2-0 = 2; S=10: 0 -> worst 2
        assertEq(_margin6(_two(_put(10, 4, W, 0), _put(8, 2, 0, W))), 2e6);
    }

    function test_RSK_009_hedgeWithZeroRiskReduction() public view {
        // A locked low put does not reduce a short call's worst case (reached at high S).
        uint256 before = _margin6(_one(_call(10, 5, W, 0)));
        assertEq(_margin6(_two(_call(10, 5, W, 0), _put(5, 1, 0, W))), before);
    }

    function test_RSK_010_hedgeEliminatesLoss() public view {
        // Identical locked long fully offsets the short.
        assertEq(_margin6(_two(_call(10, 5, W, 0), _call(10, 5, 0, W))), 0);
        // A wider-cap long at the same strike also dominates.
        assertEq(_margin6(_two(_call(10, 5, W, 0), _call(10, 6, 0, W))), 0);
    }

    function test_RSK_011_multipleContractSizes() public view {
        Leg[] memory l = _two(Leg(OptionType.CALL, 10 * W, 5 * W, W / 10, 3 * W, 0), _call(10, 5, W, 0));
        // 0.3 underlying * 5 + 1 * 5 = 6.5 USDT
        assertEq(_margin6(l), 6_500_000);
    }

    function test_RSK_012_fractionalQuantities() public view {
        assertEq(_margin6(_one(_call(10, 5, W / 4, 0))), 1_250_000);
        // one wei of quantity rounds margin UP to one native unit
        assertEq(_margin6(_one(_call(10, 5, 1, 0))), 1);
    }

    function test_RSK_013_duplicateCriticalPoints() public view {
        // K+C of one leg equals K of another: 10+2 = 12
        Leg[] memory l = _two(_call(10, 2, W, 0), _call(12, 3, W, 0));
        assertEq(_margin6(l), 5e6);
    }

    function test_RSK_014_criticalPointAtZero() public view {
        // A short put is worst at S = 0 when its K - C > 0 and nothing else is short.
        Leg[] memory l = _one(_put(10, 4, W, 0));
        assertEq(m.lossNumeratorAt(l, 0), 4 * W * W * W);
    }

    function test_RSK_015_putKMinusCZeroBoundary() public view {
        // put cap == strike: K - C = 0 is a critical point and payoff there is C.
        Leg[] memory l = _one(_put(4, 4, W, 0));
        assertEq(_margin6(l), 4e6);
        assertEq(m.phi(OptionType.PUT, 4 * W, 4 * W, 0), 4 * W);
    }

    /// FIX-016: short CS=1 Q=1, locked CS=0.5 Q=2, same call K10 C2. Exact numerators net to zero at every price,
    /// including interior S = 11 + 1 wei, for 6- and 18-decimal assets.
    function test_FIX_016_interiorPerfectHedge() public view {
        Leg[] memory l =
            _two(Leg(OptionType.CALL, 10 * W, 2 * W, W, W, 0), Leg(OptionType.CALL, 10 * W, 2 * W, W / 2, 0, 2 * W));
        assertEq(m.marginNative(l, 6), 0);
        assertEq(m.marginNative(l, 18), 0);
        (uint256 s, uint256 lo) = m.numeratorsAt(l, 11 * W + 1);
        assertEq(s, lo);
    }

    /// RSK-021: the exact critical-point maximum dominates the loss at every sampled price.
    function testFuzz_RSK_021_denseGridDominance(uint256 seed) public view {
        Leg[] memory legs = _randomLegs(seed);
        uint256 worst = m.worstCaseLossNumerator(legs);
        for (uint256 i = 0; i < 64; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, i))) % (60 * W);
            assertLe(m.lossNumeratorAt(legs, s), worst);
        }
        assertLe(m.lossNumeratorAt(legs, type(uint128).max), worst);
    }

    /// RSK-022: native requirement is the single upward rounding of the exact worst numerator.
    function testFuzz_RSK_022_nativeRoundingNeverBelowExact(uint256 seed, uint8 d) public view {
        d = uint8(bound(d, 0, 18));
        Leg[] memory legs = _randomLegs(seed);
        uint256 worst = m.worstCaseLossNumerator(legs);
        uint256 den = m.nativeDenominator(d);
        uint256 native = m.marginNative(legs, d);
        assertGe(native * den, worst);
        assertLt(native * den - worst, den);
    }

    function test_maxNumeratorSumsBound() public {
        Leg[] memory l = _one(Leg(OptionType.CALL, W, uint256(type(int256).max), 1, 1, 0));
        (uint256 sh,) = m.maxNumeratorSums(l);
        assertEq(sh, uint256(type(int256).max));
        l = _two(l[0], l[0]);
        vm.expectRevert(PayoffMath.NumeratorBoundExceeded.selector);
        m.maxNumeratorSums(l);
    }

    function test_emptyPortfolioIsZero() public view {
        assertEq(m.worstCaseLossNumerator(new Leg[](0)), 0);
    }

    function _randomLegs(uint256 seed) internal pure returns (Leg[] memory legs) {
        uint256 n = 1 + seed % 8;
        legs = new Leg[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "leg")));
            OptionType t = r % 2 == 0 ? OptionType.CALL : OptionType.PUT;
            uint256 k = (1 + (r >> 8) % 40) * W / 2 + (r >> 16) % 1000;
            uint256 c = (1 + (r >> 24) % 20) * W / 4 + (r >> 32) % 1000;
            if (t == OptionType.PUT && c > k) c = k;
            uint256 cs = [W, W / 10, W / 4, 3 * W / 2][(r >> 40) % 4];
            uint256 sh = (r >> 48) % 3 == 0 ? 0 : 1 + (r >> 56) % (10 * W);
            uint256 lo = (r >> 120) % 2 == 0 ? 0 : 1 + (r >> 128) % (10 * W);
            if (sh == 0 && lo == 0) sh = W;
            legs[i] = Leg(t, k, c, cs, sh, lo);
        }
    }
}
