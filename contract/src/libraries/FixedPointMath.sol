// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fixed-point helpers (MATH.md sections 49-54). Every payoff is an exact integer numerator
/// N = phiWad * contractSizeWad * quantityWad; the native value is N / D_A with D_A = 10^(54 - d).
/// Only the final accounting boundary rounds, and it rounds exactly once.
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint8 internal constant MAX_ASSET_DECIMALS = 18;

    error DivisionByZero();
    error UnsupportedDecimals(uint8 decimals);

    /// @notice D_A = 10^(54 - d) for settlement-asset decimals 0 <= d <= 18 (MATH.md section 24).
    function nativeDenominator(uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert UnsupportedDecimals(decimals);
        return 10 ** (54 - uint256(decimals));
    }

    /// @notice floor(n / d).
    function floorDiv(uint256 n, uint256 d) internal pure returns (uint256) {
        if (d == 0) revert DivisionByZero();
        return n / d;
    }

    /// @notice ceil(n / d) without the overflow-prone n + d - 1 form (MATH.md section 54).
    function ceilDiv(uint256 n, uint256 d) internal pure returns (uint256) {
        if (d == 0) revert DivisionByZero();
        return n / d + (n % d == 0 ? 0 : 1);
    }

    /// @notice floor(x * y / d) with full 512-bit precision.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if (d == 0) revert DivisionByZero();
        return Math.mulDiv(x, y, d);
    }

    /// @notice ceil(x * y / d) with full 512-bit precision.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if (d == 0) revert DivisionByZero();
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }

    /// @notice round-half-up(x * y / d), the documented derived-price rounding (MATH.md section 41).
    function mulDivHalfUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 q) {
        if (d == 0) revert DivisionByZero();
        q = Math.mulDiv(x, y, d);
        uint256 remainder = mulmod(x, y, d);
        // remainder < d, so compare remainder >= d - remainder instead of 2 * remainder >= d.
        if (remainder != 0 && remainder >= d - remainder) q += 1;
    }

    /// @notice floor(xWad * 10^d / WAD) for values already exactly represented as WAD (MATH.md section 51).
    function toNativeDown(uint256 xWad, uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert UnsupportedDecimals(decimals);
        return xWad / 10 ** (18 - uint256(decimals));
    }

    /// @notice ceil(xWad * 10^d / WAD) for values already exactly represented as WAD (MATH.md section 51).
    function toNativeUp(uint256 xWad, uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert UnsupportedDecimals(decimals);
        return ceilDiv(xWad, 10 ** (18 - uint256(decimals)));
    }

    /// @notice floor(rho * amount) for a WAD ratio, used only after verified-shortfall resolution (MATH.md section 119).
    function scaleByRho(uint256 amount, uint256 rhoWad) internal pure returns (uint256) {
        return Math.mulDiv(amount, rhoWad, WAD);
    }
}
