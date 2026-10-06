// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";
import {MathHarness} from "../harness/MathHarness.sol";

/// @notice Unit tests for OptionPricer (docs/MATH.md §3, §5–§7). Expected values come from reference/pm_model.py
///         (math.erfc as the CDF). Tolerance for prices is INV-39: (F + K) × 1e-7.
contract OptionPricerTest is Test {
    MathHarness internal h;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant T30 = 30 days * WAD / FixedPoint.YEAR;
    uint256 internal constant T20 = 20 days * WAD / FixedPoint.YEAR;

    function setUp() public {
        h = new MathHarness();
    }

    function _tol(uint256 f, uint256 k) internal pure returns (uint256) {
        return (f + k) / 1e7;
    }

    // ------------------------------------------------------------------ PRC-006: MATH.md §10 and §12.1 examples

    function test_PRC006_workedExamples() public view {
        // short 4,500 call (mark 106.77), long 5,000 call (39.65), short 3,500 put (96.62); ETH 4,000, 30 days
        assertApproxEqAbs(h.black76(true, 4000e18, 4500e18, 0.6e18, T30), 106.77472488996352e18, _tol(4000e18, 4500e18));
        assertApproxEqAbs(h.black76(true, 4000e18, 5000e18, 0.62e18, T30), 39.65456996739067e18, _tol(4000e18, 5000e18));
        assertApproxEqAbs(
            h.black76(false, 4000e18, 3500e18, 0.65e18, T30), 96.61931165952285e18, _tol(4000e18, 3500e18)
        );
        // MATH.md §12.1: ETH 6,200, 20 days → mark of the 4,500 call 1,702.86
        assertApproxEqAbs(h.black76(true, 6200e18, 4500e18, 0.6e18, T20), 1702.8592909743056e18, _tol(6200e18, 4500e18));
    }

    function test_deepOutOfTheMoney_tailStaysAccurate() public view {
        // true price 1.5063e-8: both Black-76 terms are ~6e-7, so a CDF with only absolute accuracy would fail here
        uint256 p = h.black76(true, 4000e18, 12_000e18, 0.6e18, T30);
        assertApproxEqRel(p, 15_063_020_670, 0.001e18); // within 0.1% of the true value
    }

    // ------------------------------------------------------------------ PRC-004: T = 0 or σ = 0 → intrinsic

    function test_PRC004_zeroTimeOrVolGivesIntrinsic() public view {
        assertEq(h.black76(true, 5000e18, 4500e18, 0.6e18, 0), 500e18);
        assertEq(h.black76(false, 4000e18, 4500e18, 0.6e18, 0), 500e18);
        assertEq(h.black76(true, 4000e18, 4500e18, 0.6e18, 0), 0);
        assertEq(h.black76(true, 5000e18, 4500e18, 0, T30), 500e18);
        assertEq(h.black76(false, 5000e18, 4500e18, 0, T30), 0);
    }

    function test_zeroSpot_callWorthlessPutWorthStrike() public view {
        assertEq(h.black76(true, 0, 4500e18, 0.6e18, T30), 0);
        assertEq(h.black76(false, 0, 4500e18, 0.6e18, T30), 4500e18);
    }

    function test_zeroStrike_reverts() public {
        vm.expectRevert(OptionPricer.InvalidStrike.selector);
        h.black76(true, 4000e18, 0, 0.6e18, T30);
    }

    function test_tinyTotalVolatility_givesIntrinsic() public view {
        // one second at 1e-9 volatility: v rounds to 0
        uint256 oneSecond = WAD / FixedPoint.YEAR;
        assertEq(h.black76(true, 4600e18, 4500e18, 1, oneSecond), 100e18);
    }

    function test_extremeMoneyness_givesIntrinsic() public view {
        // F < K·1e-18: divWad(F, K) == 0
        assertEq(h.black76(false, 1, 4500e18, 0.6e18, T30), 4500e18 - 1);
        assertEq(h.black76(true, 1, 4500e18, 0.6e18, T30), 0);
    }

    function test_intrinsic() public view {
        assertEq(h.intrinsic(true, 5200e18, 4500e18), 700e18);
        assertEq(h.intrinsic(true, 4100e18, 4500e18), 0);
        assertEq(h.intrinsic(false, 3000e18, 3500e18), 500e18);
        assertEq(h.intrinsic(false, 3600e18, 3500e18), 0);
    }

    // ------------------------------------------------------------------ PRC-001: normal CDF

    function test_PRC001_cdfKnownValues() public view {
        assertEq(h.normCdf(0), 0.5e18);
        assertApproxEqAbs(h.normCdf(1.96e18), 0.9750021048517795e18, 1e11);
        assertApproxEqAbs(h.normCdf(-3e18), 1_349_898_031_630_096, 1e11);
        // relative accuracy in the tail: N(−8) = 6.22e-16
        assertApproxEqRel(h.normCdf(-8e18), 622, 0.01e18);
    }

    function test_cdfSymmetryIsExact() public view {
        int256[6] memory xs = [int256(0.3e18), 1e18, 2.5e18, 5e18, 8.9e18, 39e18];
        for (uint256 i; i < xs.length; ++i) {
            assertEq(h.normCdf(xs[i]) + h.normCdf(-xs[i]), WAD);
        }
    }

    function test_cdfCutoffs() public view {
        assertEq(h.normCdf(40e18), WAD);
        assertEq(h.normCdf(type(int256).max), WAD);
        assertEq(h.normCdf(-40e18), 0);
        assertEq(h.normCdf(type(int256).min), 0);
        assertEq(h.normCdf(-10e18), 0); // N(−10) = 7.6e-24 < 1 wei
        assertEq(h.normCdf(10e18), WAD);
    }

    // ------------------------------------------------------------------ PRC-003 / PRC-005 spot checks

    function test_PRC003_putCallParity() public view {
        uint256 c = h.black76(true, 4000e18, 4500e18, 0.6e18, T30);
        uint256 p = h.black76(false, 4000e18, 4500e18, 0.6e18, T30);
        // C − P = F − K up to rounding of the two mulWad products
        // forge-lint: disable-next-line(unsafe-typecast)
        assertApproxEqAbs(int256(c) - int256(p), int256(4000e18) - int256(4500e18), 4);
    }

    // ------------------------------------------------------------------ VOL-010: surface interpolation

    function test_logMoneyness() public view {
        assertEq(h.logMoneyness(4000e18, 4000e18), 0);
        assertApproxEqAbs(h.logMoneyness(4000e18 * 271828182845904523 / 1e17, 4000e18), 1e18, 10);
        assertLt(h.logMoneyness(3000e18, 4000e18), 0);
    }

    function test_logMoneyness_revertsOnZero() public {
        vm.expectRevert(OptionPricer.InvalidSurfaceInput.selector);
        h.logMoneyness(0, 4000e18);
        vm.expectRevert(OptionPricer.InvalidSurfaceInput.selector);
        h.logMoneyness(4000e18, 0);
        vm.expectRevert(OptionPricer.InvalidSurfaceInput.selector);
        h.logMoneyness(1, 4000e18); // ratio rounds to 0
    }

    function test_findTenors() public view {
        uint64[4] memory t = [uint64(100), 200, 300, 0];
        _assertTenors(t, 50, false, 0, 0);
        _assertTenors(t, 100, true, 0, 0);
        _assertTenors(t, 150, true, 0, 1);
        _assertTenors(t, 200, true, 1, 1);
        _assertTenors(t, 299, true, 1, 2);
        _assertTenors(t, 300, true, 2, 2);
        _assertTenors(t, 301, false, 0, 0);
        _assertTenors([uint64(0), 0, 0, 0], 100, false, 0, 0);
        _assertTenors([uint64(10), 20, 30, 40], 35, true, 2, 3);
        _assertTenors([uint64(10), 20, 30, 40], 40, true, 3, 3);
    }

    function _assertTenors(uint64[4] memory t, uint64 e, bool ok, uint256 a, uint256 b) internal view {
        (bool gotOk, uint256 gotA, uint256 gotB) = h.findTenors(t, e);
        assertEq(gotOk, ok);
        assertEq(gotA, a);
        assertEq(gotB, b);
    }

    function test_findNodes() public view {
        int256[] memory n = new int256[](3);
        (n[0], n[1], n[2]) = (-1e18, 0, 1e18);
        _assertNodes(n, -2e18, 0, 0); // flat extrapolation below
        _assertNodes(n, -1e18, 0, 0); // exactly on the first node
        _assertNodes(n, -0.5e18, 0, 1);
        _assertNodes(n, 0, 1, 1); // exactly on an interior node: one leaf
        _assertNodes(n, 0.5e18, 1, 2);
        _assertNodes(n, 1e18, 2, 2);
        _assertNodes(n, 3e18, 2, 2); // flat extrapolation above
        int256[] memory one = new int256[](1);
        _assertNodes(one, 5e18, 0, 0);
    }

    function _assertNodes(int256[] memory n, int256 k, uint256 lo, uint256 hi) internal view {
        (uint256 gotLo, uint256 gotHi) = h.findNodes(n, k);
        assertEq(gotLo, lo);
        assertEq(gotHi, hi);
    }

    function test_findNodes_revertsOnEmptyGrid() public {
        vm.expectRevert(OptionPricer.InvalidSurfaceInput.selector);
        h.findNodes(new int256[](0), 0);
    }

    function test_interpolateNodes() public view {
        assertEq(h.interpolateNodes(0, -1e18, 1e18, 0.1e18, 0.3e18), 0.2e18); // midpoint, increasing
        assertEq(h.interpolateNodes(0, -1e18, 1e18, 0.3e18, 0.1e18), 0.2e18); // midpoint, decreasing
        assertEq(h.interpolateNodes(-1e18, -1e18, 1e18, 0.1e18, 0.3e18), 0.1e18); // exact low node
        assertEq(h.interpolateNodes(1e18, -1e18, 1e18, 0.1e18, 0.3e18), 0.3e18); // exact high node
        assertEq(h.interpolateNodes(5e18, 1e18, 1e18, 0.4e18, 0.4e18), 0.4e18); // single node (flat)
        assertEq(h.interpolateNodes(-5e18, -1e18, 1e18, 0.1e18, 0.3e18), 0.1e18); // clamped below
        assertEq(h.interpolateNodes(5e18, -1e18, 1e18, 0.1e18, 0.3e18), 0.3e18); // clamped above
    }

    function test_interpolateTenors() public view {
        assertEq(h.interpolateTenors(0.1e18, 0.3e18, 100, 300, 200), 0.2e18);
        assertEq(h.interpolateTenors(0.1e18, 0.3e18, 100, 300, 100), 0.1e18);
        assertEq(h.interpolateTenors(0.1e18, 0.3e18, 100, 300, 300), 0.3e18);
        assertEq(h.interpolateTenors(0.1e18, 0.1e18, 100, 100, 100), 0.1e18); // a == b
        assertEq(h.interpolateTenors(0.1e18, 0.3e18, 100, 400, 200), uint256(0.1e18) + uint256(0.2e18) / 3);
    }

    function test_ivFromTotalVariance_roundTrip() public view {
        // w = σ²·T with σ = 60%, T = 30 days measured from the report
        uint64 report = 1_000_000;
        uint64 expiry = report + 30 days;
        uint256 w = 0.36e18 * T30 / WAD;
        assertApproxEqAbs(h.ivFromTotalVariance(w, expiry, report, 0.1e18, 5e18), 0.6e18, 1e9);
    }

    function test_ivFromTotalVariance_clamps() public view {
        uint64 report = 1_000_000;
        uint64 expiry = report + 30 days;
        assertEq(h.ivFromTotalVariance(0, expiry, report, 0.1e18, 5e18), 0.1e18);
        assertEq(h.ivFromTotalVariance(100e18, expiry, report, 0.1e18, 5e18), 5e18);
    }

    function test_ivFromTotalVariance_reverts() public {
        vm.expectRevert(OptionPricer.InvalidSurfaceInput.selector);
        h.ivFromTotalVariance(0.1e18, 100, 100, 0.1e18, 5e18); // expiry == report time
        vm.expectRevert(OptionPricer.InvalidSurfaceInput.selector);
        h.ivFromTotalVariance(0.1e18, 200, 100, 5e18, 0.1e18); // minIv > maxIv
    }

    function test_surfaceIv_flatSurfaceGivesFlatVol() public view {
        // σ = 50% everywhere: w(tenor) = 0.25 × T(tenor). Linear-in-time variance reproduces σ exactly between tenors.
        uint64 report = 1_000_000;
        uint64 ta = report + 7 days;
        uint64 tb = report + 60 days;
        uint256 wa = 0.25e18 * (uint256(7 days) * WAD / FixedPoint.YEAR) / WAD;
        uint256 wb = 0.25e18 * (uint256(60 days) * WAD / FixedPoint.YEAR) / WAD;
        OptionPricer.IvQuery memory q = OptionPricer.IvQuery({
            k: 0.1e18,
            kLo: 0,
            kHi: 0.5e18,
            wALo: wa,
            wAHi: wa,
            wBLo: wb,
            wBHi: wb,
            tenorA: ta,
            tenorB: tb,
            expiry: report + 30 days,
            reportTime: report,
            minIv: 0.1e18,
            maxIv: 5e18
        });
        assertApproxEqAbs(h.surfaceIv(q), 0.5e18, 1e9);
    }

    // ------------------------------------------------------------------ VOL-011: stale surface (MATH.md §5.1)

    function test_staleIvs_freshIsUnchanged() public view {
        (uint256 s, uint256 l) = h.staleIvs(0.6e18, 0, 1000, 0.1e18, 5e18);
        assertEq(s, 0.6e18);
        assertEq(l, 0.6e18);
    }

    function test_staleIvs_oneHourAtTenPercentPerHour() public view {
        (uint256 s, uint256 l) = h.staleIvs(0.6e18, 3600, 1000, 0.1e18, 5e18);
        assertEq(s, 0.7e18);
        assertEq(l, 0.5e18);
    }

    function test_staleIvs_accruesPerSecondRoundedUp() public view {
        // 1 second at 1000 bps/hour = 0.1 / 3600 = 2.777…e-5 → rounded up
        (uint256 s, uint256 l) = h.staleIvs(0.6e18, 1, 1000, 0.1e18, 5e18);
        assertEq(s, 0.6e18 + 27_777_777_777_778);
        assertEq(l, 0.6e18 - 27_777_777_777_778);
    }

    function test_staleIvs_clampsToBounds() public view {
        (uint256 s, uint256 l) = h.staleIvs(0.6e18, 100 hours, 1000, 0.1e18, 5e18);
        assertEq(s, 5e18);
        assertEq(l, 0.1e18);
    }

    // ------------------------------------------------------------------ Position value (MATH.md §7)

    function test_legValue() public view {
        assertEq(h.legValue(1.5e18, 1e18, 3e18), 4.5e18);
        assertEq(h.legValue(-1.5e18, 1e18, 3e18), -4.5e18);
        assertEq(h.legValue(2e18, 0.1e18, 100e18), 20e18); // contract size 0.1
        assertEq(h.legValue(0, 1e18, 3e18), 0);
    }

    function test_legValue_roundsTowardNegativeInfinity() public view {
        // exact value 1e-36: a long rounds down to 0, a short's liability rounds up to 1 wei
        assertEq(h.legValue(1, 1, 1), 0);
        assertEq(h.legValue(-1, 1, 1), -1);
    }

    function test_legValue_revertsOnMinInt() public {
        vm.expectRevert();
        h.legValue(type(int256).min, 1e18, 1e18);
    }
}
