// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";

/// @title FixedPoint
/// @notice Units, conversions and rounding helpers shared by every Optara PM module (docs/MATH.md §1–§2).
/// @dev WAD = 1e18. Cash is held in native units of the settlement asset (`decimals` in [0, 18]).
library FixedPoint {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev A year is fixed at 365 days (MATH.md §4).
    uint256 internal constant YEAR = 31_536_000;
    uint256 internal constant MAX_DECIMALS = 18;

    error DecimalsTooLarge(uint8 decimals);

    /// @notice 10^(18 − decimals): the factor between WAD and native units.
    function scale(uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_DECIMALS) revert DecimalsTooLarge(decimals);
        return 10 ** (MAX_DECIMALS - decimals);
    }

    /// @notice native → WAD, exact.
    function toWad(uint256 native, uint8 decimals) internal pure returns (uint256) {
        return native * scale(decimals);
    }

    /// @notice WAD → native, rounded down (credits, payouts, values of assets).
    function toNativeDown(uint256 xWad, uint8 decimals) internal pure returns (uint256) {
        return xWad / scale(decimals);
    }

    /// @notice WAD → native, rounded up (debts, fees, values of liabilities).
    function toNativeUp(uint256 xWad, uint8 decimals) internal pure returns (uint256) {
        return M.divUp(xWad, scale(decimals));
    }

    /// @notice Time to expiry in WAD years: max(expiry − now, 0) × 1e18 / YEAR, rounded down (MATH.md §4).
    function yearsUntil(uint256 expiry, uint256 nowTs) internal pure returns (uint256) {
        if (expiry <= nowTs) return 0;
        return (expiry - nowTs) * WAD / YEAR;
    }

    /// @notice x × bps / 10_000, rounded down.
    function bpsDown(uint256 x, uint256 bps) internal pure returns (uint256) {
        return M.fullMulDiv(x, bps, BPS);
    }

    /// @notice x × bps / 10_000, rounded up.
    function bpsUp(uint256 x, uint256 bps) internal pure returns (uint256) {
        return M.fullMulDivUp(x, bps, BPS);
    }
}
