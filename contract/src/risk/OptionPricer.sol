// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPoint} from "./FixedPoint.sol";

/// @title OptionPricer
/// @notice Pure pricing math (docs/MATH.md §3, §5–§7): normal CDF, Black-76 with zero rates (F = S), implied
///         volatility from a total-variance surface grid, direction-aware stale IV, and signed position value.
/// @dev All prices, strikes, spots and volatilities are WAD. `T` is WAD years. Every function is internal, so the
///      library is inlined into the modules that use it.
library OptionPricer {
    using SafeCastLib for uint256;

    uint256 private constant WAD = FixedPoint.WAD;
    int256 private constant SWAD = 1e18;
    /// @dev sqrt(2) in WAD, rounded to nearest.
    uint256 private constant SQRT2_WAD = 1_414_213_562_373_095_049;
    /// @dev Beyond |x| = 40 the CDF is 0 or 1 at WAD precision; the cutoff also keeps z² far from overflow.
    int256 private constant CDF_CUTOFF = 40e18;

    error InvalidStrike();
    error InvalidSurfaceInput();

    // ---------------------------------------------------------------------------------------------------------
    // Payoff (MATH.md §3)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice max(S − K, 0) for a call, max(K − S, 0) for a put. WAD per unit of underlying.
    function intrinsic(bool isCall, uint256 spot, uint256 strike) internal pure returns (uint256) {
        if (isCall) return spot > strike ? spot - strike : 0;
        return strike > spot ? strike - spot : 0;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Normal CDF (MATH.md §6)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Standard normal CDF N(x), WAD in and out.
    /// @dev N(x) = 1 − ½·erfc(x/√2) for x > 0, ½·erfc(|x|/√2) for x < 0 and exactly ½ at 0, so N(−x) = 1 − N(x)
    ///      exactly for every x (put-call parity then holds up to two mulWad roundings).
    ///      erfc is the Numerical Recipes `erfcc` Chebyshev fit: relative error < 1.2e-7 everywhere, so the CDF's
    ///      absolute error is < 6e-8 and the tails stay accurate (deep out-of-the-money prices don't collapse to 0).
    function normCdf(int256 x) internal pure returns (uint256) {
        if (x == 0) return WAD / 2;
        if (x >= CDF_CUTOFF) return WAD;
        if (x <= -CDF_CUTOFF) return 0;
        uint256 h = _halfErfc(M.abs(x));
        return x >= 0 ? WAD - h : h;
    }

    /// @dev ½·erfc(ax / √2) for 0 < ax < 40e18.
    ///      Unchecked is safe: z < 28.3e18, so z² < 8.1e38; t ∈ (0, 1e18]; every Horner partial sum is bounded by
    ///      the sum of |coefficients| (< 5.8e18), so every product is < 5.8e36. All casts are of values < 2^255.
    function _halfErfc(uint256 ax) private pure returns (uint256) {
        unchecked {
            uint256 z = ax * WAD / SQRT2_WAD;
            uint256 tu = WAD * WAD / (WAD + z / 2);
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 t = int256(tu);
            // Horner evaluation of the erfcc polynomial (coefficients × 1e18).
            int256 p = 170_872_770_000_000_000;
            p = -822_152_230_000_000_000 + t * p / SWAD;
            p = 1_488_515_870_000_000_000 + t * p / SWAD;
            p = -1_135_203_980_000_000_000 + t * p / SWAD;
            p = 278_868_070_000_000_000 + t * p / SWAD;
            p = -186_288_060_000_000_000 + t * p / SWAD;
            p = 96_784_180_000_000_000 + t * p / SWAD;
            p = 374_091_960_000_000_000 + t * p / SWAD;
            p = 1_000_023_680_000_000_000 + t * p / SWAD;
            p = t * p / SWAD;
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 arg = -int256(z * z / WAD) - 1_265_512_230_000_000_000 + p;
            // arg < 0.01e18 here, so expWad neither overflows nor returns a negative value
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 e = uint256(M.expWad(arg));
            return tu * e / WAD / 2;
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Black-76, zero rates, F = S (MATH.md §6)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Price of one option per unit of underlying.
    /// @param forward Spot (= forward, zero rates), WAD. May be 0 (a −100% spot shock).
    /// @param strike  Strike, WAD, > 0.
    /// @param sigma   Implied volatility, WAD (1e18 = 100%).
    /// @param t       Time to expiry, WAD years.
    /// @return price  Floored at intrinsic. A call never exceeds F and a put never exceeds K: N ≤ 1 and mulWad rounds
    ///                down, so price ≤ F·N(d1) ≤ F for a call and ≤ K·N(−d2) ≤ K for a put (MATH.md §6 caps hold by
    ///                construction).
    function black76(bool isCall, uint256 forward, uint256 strike, uint256 sigma, uint256 t)
        internal
        pure
        returns (uint256 price)
    {
        if (strike == 0) revert InvalidStrike();
        uint256 intr = intrinsic(isCall, forward, strike);
        if (t == 0 || sigma == 0 || forward == 0) return intr;

        uint256 v = M.mulWad(sigma, M.sqrtWad(t));
        uint256 ratio = M.divWad(forward, strike);
        // v == 0: total volatility below 1e-18; ratio == 0: F < K·1e-18. Either way time value is below 1 wei.
        if (v == 0 || ratio == 0) return intr;

        int256 vi = v.toInt256();
        int256 d1 = (M.lnWad(ratio.toInt256()) + (M.mulWad(v, v) / 2).toInt256()) * SWAD / vi;
        int256 d2 = d1 - vi;

        uint256 a;
        uint256 b;
        if (isCall) {
            a = M.mulWad(forward, normCdf(d1));
            b = M.mulWad(strike, normCdf(d2));
            price = a > b ? a - b : 0;
        } else {
            a = M.mulWad(strike, normCdf(-d2));
            b = M.mulWad(forward, normCdf(-d1));
            price = a > b ? a - b : 0;
        }
        if (price < intr) price = intr;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Implied volatility from the surface grid (MATH.md §5)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Inputs for one series' IV. Leaves are total variances `w(tenor, node)` in WAD.
    /// @dev Use `findTenors` and `findNodes` to choose (a, b) and (lo, hi). When a == b or lo == hi the
    ///      corresponding pair holds the same leaf twice.
    struct IvQuery {
        int256 k; // ln(K / S), WAD
        int256 kLo; // kNodes[lo]
        int256 kHi; // kNodes[hi]
        uint256 wALo; // w(a, lo)
        uint256 wAHi; // w(a, hi)
        uint256 wBLo; // w(b, lo)
        uint256 wBHi; // w(b, hi)
        uint64 tenorA; // tenorTimestamps[a]
        uint64 tenorB; // tenorTimestamps[b]
        uint64 expiry; // series expiry τ
        uint64 reportTime; // report validAfter
        uint256 minIv;
        uint256 maxIv;
    }

    /// @notice k = ln(K / S), WAD.
    function logMoneyness(uint256 strike, uint256 spot) internal pure returns (int256) {
        if (strike == 0 || spot == 0) revert InvalidSurfaceInput();
        uint256 ratio = M.divWad(strike, spot);
        if (ratio == 0) revert InvalidSurfaceInput();
        return M.lnWad(ratio.toInt256());
    }

    /// @notice Tenors a ≤ b with tenors[a] ≤ expiry ≤ tenors[b]; a == b when the expiry equals a tenor.
    /// @dev Tenors are increasing; unused trailing entries are 0. `ok` is false when the expiry is outside
    ///      [first, last]: the series is then not priceable (MATH.md §5 step 2).
    function findTenors(uint64[4] memory tenors, uint64 expiry) internal pure returns (bool ok, uint256 a, uint256 b) {
        uint256 n;
        while (n < 4 && tenors[n] != 0) ++n;
        if (n == 0 || expiry < tenors[0] || expiry > tenors[n - 1]) return (false, 0, 0);
        // Terminates with i < n because tenors[0] ≤ expiry ≤ tenors[n − 1].
        for (uint256 i;; ++i) {
            if (tenors[i] == expiry) return (true, i, i);
            if (tenors[i] > expiry) return (true, i - 1, i); // i ≥ 1 because expiry ≥ tenors[0]
        }
    }

    /// @notice Nodes lo ≤ hi with kNodes[lo] ≤ k ≤ kNodes[hi]. Flat extrapolation beyond the edges (lo == hi), and
    ///         a single node when k is exactly on one (MATH.md §5 step 3).
    /// @dev `kNodes` must be strictly increasing (enforced by VolSurfaceOracle on acceptance).
    function findNodes(int256[] memory kNodes, int256 k) internal pure returns (uint256 lo, uint256 hi) {
        uint256 m = kNodes.length;
        if (m == 0) revert InvalidSurfaceInput();
        if (k <= kNodes[0]) return (0, 0);
        if (k >= kNodes[m - 1]) return (m - 1, m - 1);
        // Terminates with j + 1 < m because kNodes[0] < k < kNodes[m − 1].
        for (uint256 j;; ++j) {
            if (k <= kNodes[j + 1]) return k == kNodes[j + 1] ? (j + 1, j + 1) : (j, j + 1);
        }
    }

    /// @notice Linear interpolation of total variance in log-moneyness (MATH.md §5 step 4).
    function interpolateNodes(int256 k, int256 kLo, int256 kHi, uint256 wLo, uint256 wHi)
        internal
        pure
        returns (uint256)
    {
        if (kHi <= kLo || k <= kLo) return wLo;
        if (k >= kHi) return wHi;
        // casting to 'uint256' is safe because kLo < k < kHi here
        // forge-lint: disable-next-line(unsafe-typecast)
        return _lerp(wLo, wHi, uint256(k - kLo), uint256(kHi - kLo));
    }

    /// @notice Linear interpolation of total variance in time (MATH.md §5 step 5).
    /// @dev (T_τ − T_a) / (T_b − T_a) equals (τ − t_a) / (t_b − t_a): the report time cancels, so absolute
    ///      timestamps are used directly.
    function interpolateTenors(uint256 wA, uint256 wB, uint64 tenorA, uint64 tenorB, uint64 expiry)
        internal
        pure
        returns (uint256)
    {
        if (tenorB <= tenorA || expiry <= tenorA) return wA;
        if (expiry >= tenorB) return wB;
        return _lerp(wA, wB, expiry - tenorA, tenorB - tenorA);
    }

    /// @notice σ = sqrt(w / T_τ), clamped to [minIv, maxIv] (MATH.md §5 steps 6–7). T_τ is measured from the
    ///         report time.
    function ivFromTotalVariance(uint256 w, uint64 expiry, uint64 reportTime, uint256 minIv, uint256 maxIv)
        internal
        pure
        returns (uint256 sigma)
    {
        if (expiry <= reportTime || minIv > maxIv) revert InvalidSurfaceInput();
        uint256 tWad = uint256(expiry - reportTime) * WAD / FixedPoint.YEAR; // ≥ 3.17e10 for one second
        sigma = M.sqrt(M.fullMulDiv(w, WAD * WAD, tWad)); // sqrt(w / T) in WAD = sqrt(w · 1e36 / T_wad)
        if (sigma < minIv) sigma = minIv;
        if (sigma > maxIv) sigma = maxIv;
    }

    /// @notice Full MATH.md §5 pipeline for one series.
    function surfaceIv(IvQuery memory q) internal pure returns (uint256) {
        uint256 wA = interpolateNodes(q.k, q.kLo, q.kHi, q.wALo, q.wAHi);
        uint256 wB = interpolateNodes(q.k, q.kLo, q.kHi, q.wBLo, q.wBHi);
        uint256 w = interpolateTenors(wA, wB, q.tenorA, q.tenorB, q.expiry);
        return ivFromTotalVariance(w, q.expiry, q.reportTime, q.minIv, q.maxIv);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Stale surface (MATH.md §5.1)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Direction-aware IVs for a stale surface: shorts priced higher, longs lower.
    /// @param staleSeconds Seconds beyond `surfaceStaleAfter` (0 when fresh).
    /// @dev penalty = penaltyBpsPerHour × staleSeconds / 3600 / 10_000, in absolute IV, accrued per second and
    ///      rounded up.
    function staleIvs(uint256 sigma, uint256 staleSeconds, uint256 penaltyBpsPerHour, uint256 minIv, uint256 maxIv)
        internal
        pure
        returns (uint256 sigmaShort, uint256 sigmaLong)
    {
        uint256 penalty = M.fullMulDivUp(penaltyBpsPerHour * staleSeconds, WAD, FixedPoint.BPS * 3600);
        sigmaShort = sigma + penalty;
        if (sigmaShort > maxIv) sigmaShort = maxIv;
        sigmaLong = sigma > penalty ? sigma - penalty : 0;
        if (sigmaLong < minIv) sigmaLong = minIv;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Position value (MATH.md §7)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice q × CS × price, WAD of settlement asset, rounded toward −∞: a long's value rounds down and a short's
    ///         liability rounds up. One rounding step on the exact product.
    /// @param q          Signed balance, 18 decimals.
    /// @param contractSize CS, WAD.
    /// @param price      Per-unit price, WAD.
    function legValue(int256 q, uint256 contractSize, uint256 price) internal pure returns (int256) {
        // casting to 'uint256' is safe because q ≥ 0 on this line and q < 0 (so −q > 0) on the next
        // forge-lint: disable-next-line(unsafe-typecast)
        if (q >= 0) return M.fullMulDiv(uint256(q) * contractSize, price, WAD * WAD).toInt256();
        // forge-lint: disable-next-line(unsafe-typecast)
        return -M.fullMulDivUp(uint256(-q) * contractSize, price, WAD * WAD).toInt256();
    }

    // ---------------------------------------------------------------------------------------------------------

    /// @dev a + (b − a) × num / den for num ≤ den, without signed arithmetic.
    function _lerp(uint256 a, uint256 b, uint256 num, uint256 den) private pure returns (uint256) {
        if (b >= a) return a + M.fullMulDiv(b - a, num, den);
        return a - M.fullMulDiv(a - b, num, den);
    }
}
