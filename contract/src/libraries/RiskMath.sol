// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Leg, OptionType} from "./OptaraTypes.sol";
import {PayoffMath} from "./PayoffMath.sol";

/// @notice Exact worst-case loss and settlement numerators for one account risk group
/// (MATH.md sections 17-24, 54, 91-92, 97).
/// @dev All sums are exact integer numerators. Nothing is divided before the caller's single native conversion.
///      Callers guarantee (at write/lock time) that sum(C * CS * shortQty) and sum(C * CS * lockedQty) each fit
///      int256, so every per-price sum below fits as well (phi <= C).
library RiskMath {
    /// @notice Short and locked-long numerators at settlement price S (MATH.md sections 17-18).
    function numeratorsAt(Leg[] memory legs, uint256 priceWad) internal pure returns (uint256 shortN, uint256 longN) {
        for (uint256 i = 0; i < legs.length; ++i) {
            Leg memory leg = legs[i];
            uint256 p = PayoffMath.phi(leg.optionType, leg.strikeWad, leg.capWad, priceWad);
            if (p == 0) continue;
            if (leg.shortQty != 0) shortN += PayoffMath.product(p, leg.contractSizeWad, leg.shortQty);
            if (leg.lockedQty != 0) longN += PayoffMath.product(p, leg.contractSizeWad, leg.lockedQty);
        }
    }

    /// @notice max(0, ShortN(S) - LongN(S)).
    function lossNumeratorAt(Leg[] memory legs, uint256 priceWad) internal pure returns (uint256) {
        (uint256 shortN, uint256 longN) = numeratorsAt(legs, priceWad);
        return shortN > longN ? shortN - longN : 0;
    }

    /// @notice Largest nonnegative short-minus-long numerator over the account's critical prices
    /// {0} U {K, K+C for calls} U {K-C, K for puts} (MATH.md sections 22, 92).
    /// @dev Duplicates are evaluated twice, which cannot change a maximum. O(n^2) with n bounded by position limits.
    function worstCaseLossNumerator(Leg[] memory legs) internal pure returns (uint256 worst) {
        worst = lossNumeratorAt(legs, 0);
        for (uint256 j = 0; j < legs.length; ++j) {
            Leg memory leg = legs[j];
            uint256 low;
            uint256 high;
            if (leg.optionType == OptionType.CALL) {
                low = leg.strikeWad;
                high = leg.strikeWad + leg.capWad; // bounded at series creation
            } else {
                low = leg.strikeWad - leg.capWad; // put cap <= strike (OPTION_SPEC.md section 12)
                high = leg.strikeWad;
            }
            uint256 loss = lossNumeratorAt(legs, low);
            if (loss > worst) worst = loss;
            loss = lossNumeratorAt(legs, high);
            if (loss > worst) worst = loss;
        }
    }

    /// @notice sum(C * CS * shortQty) and sum(C * CS * lockedQty) with the int256 bound enforced
    /// (MATH.md section 24: bounds apply to locks as well as writes, even at zero net risk).
    function maxNumeratorSums(Leg[] memory legs) internal pure returns (uint256 shortMax, uint256 longMax) {
        for (uint256 i = 0; i < legs.length; ++i) {
            Leg memory leg = legs[i];
            shortMax =
                PayoffMath.boundedAdd(shortMax, PayoffMath.product(leg.capWad, leg.contractSizeWad, leg.shortQty));
            longMax = PayoffMath.boundedAdd(longMax, PayoffMath.product(leg.capWad, leg.contractSizeWad, leg.lockedQty));
        }
    }
}
