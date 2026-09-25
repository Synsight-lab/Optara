// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OptionType} from "./OptaraTypes.sol";

/// @notice Capped payoff and exact payoff numerators (MATH.md sections 6-11, 24, 89-90).
/// RiskEngine math, settlement and redemption all use these functions, so risk and settlement cannot disagree.
library PayoffMath {
    /// @notice Every product and every account/group sum of payoff numerators must fit int256 (MATH.md section 24).
    uint256 internal constant MAX_NUMERATOR = uint256(type(int256).max);

    error NumeratorBoundExceeded();

    /// @notice Capped payoff per underlying unit, WAD scaled: call min(max(S-K,0),C), put min(max(K-S,0),C).
    /// @dev Comparisons only; no intermediate can overflow for any S (OPTION_SPEC.md section 34).
    function phi(OptionType optionType, uint256 strikeWad, uint256 capWad, uint256 priceWad)
        internal
        pure
        returns (uint256)
    {
        if (optionType == OptionType.CALL) {
            if (priceWad <= strikeWad) return 0;
            uint256 intrinsic = priceWad - strikeWad;
            return intrinsic < capWad ? intrinsic : capWad;
        } else {
            if (priceWad >= strikeWad) return 0;
            uint256 intrinsic = strikeWad - priceWad;
            return intrinsic < capWad ? intrinsic : capWad;
        }
    }

    /// @notice a * b * c if it fits MAX_NUMERATOR, checked with division-based bounds before each multiplication.
    function boundedProduct(uint256 a, uint256 b, uint256 c) internal pure returns (bool ok, uint256 result) {
        if (a == 0 || b == 0 || c == 0) return (true, 0);
        if (a > MAX_NUMERATOR / b) return (false, 0);
        uint256 ab = a * b;
        if (ab > MAX_NUMERATOR / c) return (false, 0);
        return (true, ab * c);
    }

    /// @notice boundedProduct that reverts when the product is unrepresentable.
    function product(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        (bool ok, uint256 p) = boundedProduct(a, b, c);
        if (!ok) revert NumeratorBoundExceeded();
        return p;
    }

    /// @notice Exact payoff numerator N = phiWad * contractSizeWad * quantityWad (MATH.md section 90).
    function payoffNumerator(
        OptionType optionType,
        uint256 strikeWad,
        uint256 capWad,
        uint256 contractSizeWad,
        uint256 priceWad,
        uint256 quantity
    ) internal pure returns (uint256) {
        return product(phi(optionType, strikeWad, capWad, priceWad), contractSizeWad, quantity);
    }

    /// @notice Maximum contractual payoff numerator C * CS * Q (MATH.md section 10).
    function maxPayoffNumerator(uint256 capWad, uint256 contractSizeWad, uint256 quantity)
        internal
        pure
        returns (uint256)
    {
        return product(capWad, contractSizeWad, quantity);
    }

    /// @notice a + b if the sum stays within MAX_NUMERATOR.
    function boundedAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > MAX_NUMERATOR - b) revert NumeratorBoundExceeded();
        return a + b;
    }
}
