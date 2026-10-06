// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {MathHarness} from "../harness/MathHarness.sol";

/// @notice Property fuzz tests for OptionPricer.
///         PRC-003 parity, PRC-005 bounds, PRC-007 monotonicity (INV-38), INV-40 interpolation, INV-16 stale
///         direction, MATH.md §7 rounding of position values.
/// @dev Monotonicity and parity hold for the exact model; the implementation may deviate by the INV-39 error
///      budget (F + K) × 1e-7 per price, so comparisons between two prices allow twice that.
contract OptionPricerFuzzTest is Test {
    MathHarness internal h;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MIN_PRICE = 1e15; // 0.001
    uint256 internal constant MAX_PRICE = 1e25; // 10,000,000
    uint256 internal constant MIN_T = WAD / FixedPoint.YEAR; // one second
    uint256 internal constant MAX_T = 2 * WAD; // two years

    function setUp() public {
        h = new MathHarness();
    }

    struct In {
        uint256 f;
        uint256 k;
        uint256 sigma;
        uint256 t;
    }

    function _bound(uint256 f, uint256 k, uint256 sigma, uint256 t) internal pure returns (In memory x) {
        x.f = bound(f, MIN_PRICE, MAX_PRICE);
        x.k = bound(k, MIN_PRICE, MAX_PRICE);
        x.sigma = bound(sigma, 0.01e18, 5e18);
        x.t = bound(t, MIN_T, MAX_T);
    }

    function _tol(uint256 f, uint256 k) internal pure returns (uint256) {
        return (f + k) / 1e7 + 1;
    }

    // ------------------------------------------------------------------ PRC-005 / INV-38 bounds

    function testFuzz_PRC005_priceBounds(bool isCall, uint256 f, uint256 k, uint256 sigma, uint256 t) public view {
        In memory x = _bound(f, k, sigma, t);
        uint256 p = h.black76(isCall, x.f, x.k, x.sigma, x.t);
        assertGe(p, h.intrinsic(isCall, x.f, x.k), "price < intrinsic");
        if (isCall) assertLe(p, x.f, "call > F");
        else assertLe(p, x.k, "put > K");
    }

    // ------------------------------------------------------------------ PRC-003 / INV-38 parity

    function testFuzz_PRC003_putCallParity(uint256 f, uint256 k, uint256 sigma, uint256 t) public view {
        In memory x = _bound(f, k, sigma, t);
        int256 c = int256(h.black76(true, x.f, x.k, x.sigma, x.t));
        int256 p = int256(h.black76(false, x.f, x.k, x.sigma, x.t));
        assertApproxEqAbs(c - p, int256(x.f) - int256(x.k), 2 * _tol(x.f, x.k));
    }

    // ------------------------------------------------------------------ PRC-007 / INV-38 monotonicity

    function testFuzz_PRC007_monotoneInSpot(uint256 f, uint256 df, uint256 k, uint256 sigma, uint256 t) public view {
        In memory x = _bound(f, k, sigma, t);
        uint256 f2 = bound(df, x.f, MAX_PRICE);
        uint256 tol = 2 * _tol(f2, x.k);
        assertGe(h.black76(true, f2, x.k, x.sigma, x.t) + tol, h.black76(true, x.f, x.k, x.sigma, x.t), "call");
        assertLe(h.black76(false, f2, x.k, x.sigma, x.t), h.black76(false, x.f, x.k, x.sigma, x.t) + tol, "put");
    }

    function testFuzz_PRC007_monotoneInVol(bool isCall, uint256 f, uint256 k, uint256 sigma, uint256 ds, uint256 t)
        public
        view
    {
        In memory x = _bound(f, k, sigma, t);
        uint256 s2 = bound(ds, x.sigma, 5e18);
        uint256 tol = 2 * _tol(x.f, x.k);
        assertGe(h.black76(isCall, x.f, x.k, s2, x.t) + tol, h.black76(isCall, x.f, x.k, x.sigma, x.t));
    }

    function testFuzz_PRC007_monotoneInTime(bool isCall, uint256 f, uint256 k, uint256 sigma, uint256 t, uint256 dt)
        public
        view
    {
        In memory x = _bound(f, k, sigma, t);
        uint256 t2 = bound(dt, x.t, MAX_T);
        uint256 tol = 2 * _tol(x.f, x.k);
        assertGe(h.black76(isCall, x.f, x.k, x.sigma, t2) + tol, h.black76(isCall, x.f, x.k, x.sigma, x.t));
    }

    // ------------------------------------------------------------------ Normal CDF

    function testFuzz_cdfRangeAndSymmetry(int256 x) public view {
        x = bound(x, -50e18, 50e18);
        uint256 n = h.normCdf(x);
        assertLe(n, WAD);
        assertEq(n + h.normCdf(-x), WAD);
    }

    function testFuzz_cdfMonotone(int256 a, int256 b) public view {
        a = bound(a, -50e18, 50e18);
        b = bound(b, a, 50e18);
        assertGe(h.normCdf(b) + 1e11, h.normCdf(a)); // within the 1e-7 error budget
    }

    // ------------------------------------------------------------------ INV-40 interpolation

    function testFuzz_INV40_nodeInterpolationWithinRange(int256 k, int256 kLo, int256 width, uint256 wLo, uint256 wHi)
        public
        view
    {
        kLo = bound(kLo, -5e18, 5e18);
        int256 kHi = kLo + bound(width, 1, 5e18);
        k = bound(k, -20e18, 20e18);
        wLo = bound(wLo, 0, 100e18);
        wHi = bound(wHi, 0, 100e18);
        uint256 w = h.interpolateNodes(k, kLo, kHi, wLo, wHi);
        assertGe(w, wLo < wHi ? wLo : wHi);
        assertLe(w, wLo < wHi ? wHi : wLo);
        assertEq(h.interpolateNodes(kLo, kLo, kHi, wLo, wHi), wLo, "exact at low node");
        assertEq(h.interpolateNodes(kHi, kLo, kHi, wLo, wHi), wHi, "exact at high node");
    }

    function testFuzz_INV40_tenorInterpolationMonotoneWhenGridIs(
        uint256 wA,
        uint256 dw,
        uint64 ta,
        uint64 gap,
        uint64 e1,
        uint64 e2
    ) public view {
        wA = bound(wA, 0, 50e18);
        uint256 wB = wA + bound(dw, 0, 50e18); // calendar-consistent grid: w non-decreasing in tenor
        ta = uint64(bound(ta, 1, 2 ** 40));
        uint64 tb = ta + uint64(bound(gap, 1, 2 ** 30));
        e1 = uint64(bound(e1, ta, tb));
        e2 = uint64(bound(e2, e1, tb));
        uint256 w1 = h.interpolateTenors(wA, wB, ta, tb, e1);
        uint256 w2 = h.interpolateTenors(wA, wB, ta, tb, e2);
        assertLe(w1, w2);
        assertGe(w1, wA);
        assertLe(w2, wB);
    }

    function testFuzz_ivWithinBounds(uint256 w, uint64 report, uint64 dt, uint256 minIv, uint256 maxIv) public view {
        w = bound(w, 0, 1000e18);
        report = uint64(bound(report, 0, 2 ** 40));
        uint64 expiry = report + uint64(bound(dt, 1, 4 * 365 days));
        minIv = bound(minIv, 0, 10e18);
        maxIv = bound(maxIv, minIv, 10e18);
        uint256 s = h.ivFromTotalVariance(w, expiry, report, minIv, maxIv);
        assertGe(s, minIv);
        assertLe(s, maxIv);
    }

    // ------------------------------------------------------------------ INV-16 stale direction

    function testFuzz_INV16_staleIvDirection(uint256 sigma, uint256 stale, uint256 rate, uint256 more) public view {
        uint256 minIv = 0.1e18;
        uint256 maxIv = 5e18;
        sigma = bound(sigma, minIv, maxIv);
        stale = bound(stale, 0, 30 days);
        rate = bound(rate, 0, 100_000);
        (uint256 s, uint256 l) = h.staleIvs(sigma, stale, rate, minIv, maxIv);
        assertGe(s, sigma, "short IV fell");
        assertLe(l, sigma, "long IV rose");
        assertLe(s, maxIv);
        assertGe(l, minIv);
        // more staleness never helps either side
        (uint256 s2, uint256 l2) = h.staleIvs(sigma, stale + bound(more, 0, 30 days), rate, minIv, maxIv);
        assertGe(s2, s);
        assertLe(l2, l);
    }

    // ------------------------------------------------------------------ MATH.md §7 position value

    function testFuzz_legValueRoundsTowardNegativeInfinity(uint128 q, uint256 cs, uint256 price) public view {
        cs = bound(cs, 1, 1000e18);
        price = bound(price, 0, 1e30);
        int256 lng = h.legValue(int256(uint256(q)), cs, price);
        int256 sht = h.legValue(-int256(uint256(q)), cs, price);
        assertGe(lng, 0);
        assertLe(sht, 0);
        // the long rounds down and the short's liability rounds up, so they differ by at most 1 wei of magnitude
        assertTrue(lng + sht == 0 || lng + sht == -1);
    }
}
