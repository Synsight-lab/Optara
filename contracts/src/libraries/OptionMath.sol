// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionType, PRICE_SCALE, BPS_SCALE} from "../Types.sol";
import {InvalidDecimals} from "../Errors.sol";

/// @notice Every formula that decides who gets what. See simple-workflow/math.md.
/// @dev Every rounding direction here is fixed and is part of the solvency proof:
///      changing one means redoing the proof.
///
///      collateralPerOption (PUT)   ceil
///      requiredCollateral          ceil
///      buyerPayoutRate             floor
///      writerResidualRate          exact subtraction (see residualRate)
///      gross claims                floor
///      mintFee                     ceil
///      exerciseFee                 floor
///
///      All multiply-then-divide steps use Math.mulDiv, which is exact (512-bit intermediate)
///      and reverts if the result does not fit in 256 bits.
library OptionMath {
    /// @notice 10 ** optionDecimals.
    function optionScale(uint8 optionDecimals) internal pure returns (uint256) {
        if (optionDecimals > 18) revert InvalidDecimals();
        return uint256(10) ** optionDecimals;
    }

    /// @notice UQ_SCALE = PRICE_SCALE * 10**underlyingDecimals / 10**quoteDecimals.
    /// @dev Both decimals are at most 18, so the result is an exact integer of at least 1.
    ///      Computed without ever forming a product that could overflow.
    function uqScale(uint8 underlyingDecimals, uint8 quoteDecimals) internal pure returns (uint256) {
        if (underlyingDecimals > 18 || quoteDecimals > 18) revert InvalidDecimals();
        if (underlyingDecimals >= quoteDecimals) {
            return PRICE_SCALE * (uint256(10) ** (underlyingDecimals - quoteDecimals));
        }
        // PRICE_SCALE = 1e18 is divisible by 10 ** (quoteDecimals - underlyingDecimals) because that
        // exponent is at most 18, so this division is exact.
        return PRICE_SCALE / (uint256(10) ** (quoteDecimals - underlyingDecimals));
    }

    /// @notice Maximum liability of ONE WHOLE option, in collateral raw units.
    /// @dev CALL: C. PUT: ceilDiv(C * K, UQ_SCALE). Rounds up so the stored constant is never
    ///      less than the true strike value.
    function collateralPerOption(OptionType optionType, uint256 contractSize, uint256 strikePrice, uint256 uq)
        internal
        pure
        returns (uint256)
    {
        if (optionType == OptionType.CALL) return contractSize;
        return Math.mulDiv(contractSize, strikePrice, uq, Math.Rounding.Ceil);
    }

    /// @notice Collateral required to mint `optionAmount`. Rounds up.
    function requiredCollateral(uint256 optionAmount, uint256 collateralPerOption_, uint256 optionScale_)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(optionAmount, collateralPerOption_, optionScale_, Math.Rounding.Ceil);
    }

    /// @notice buyerPayoutRate: collateral raw units paid per ONE WHOLE option at settlement price S.
    /// @dev CALL (paid in underlying): S <= K ? 0 : floor(C * (S - K) / S)
    ///      PUT  (paid in quote):      S >= K ? 0 : floor(C * (K - S) / UQ_SCALE)
    ///      Rounds down. `settlementPrice` must be nonzero (the oracle library guarantees it).
    function buyerPayoutRate(
        OptionType optionType,
        uint256 contractSize,
        uint256 strikePrice,
        uint256 settlementPrice,
        uint256 uq
    ) internal pure returns (uint256) {
        if (optionType == OptionType.CALL) {
            if (settlementPrice <= strikePrice) return 0;
            return Math.mulDiv(contractSize, settlementPrice - strikePrice, settlementPrice);
        }
        if (settlementPrice >= strikePrice) return 0;
        return Math.mulDiv(contractSize, strikePrice - settlementPrice, uq);
    }

    /// @notice writerResidualRate. ALWAYS computed by subtraction so that
    ///         buyerPayoutRate + writerResidualRate == collateralPerOption exactly.
    /// @dev Deriving this from its own formula and rounding it separately would break the identity
    ///      the solvency proof depends on. Reverts on underflow, which cannot happen because
    ///      buyerPayoutRate < collateralPerOption for every valid price.
    function residualRate(uint256 collateralPerOption_, uint256 buyerPayoutRate_) internal pure returns (uint256) {
        return collateralPerOption_ - buyerPayoutRate_;
    }

    /// @notice floor(amount * rate / optionScale). Used for both the gross buyer payout and the
    ///         gross writer residual. Rounds down.
    function grossClaim(uint256 optionAmount, uint256 rate, uint256 optionScale_) internal pure returns (uint256) {
        return Math.mulDiv(optionAmount, rate, optionScale_);
    }

    /// @notice Mint fee: ceilDiv(collateral * bps, BPS_SCALE). Charged ON TOP of collateral.
    function mintFee(uint256 collateralAmount, uint16 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(collateralAmount, feeBps, BPS_SCALE, Math.Rounding.Ceil);
    }

    /// @notice Exercise fee: floor(grossPayout * bps / BPS_SCALE). Carved out of a gross amount.
    function exerciseFee(uint256 grossPayout, uint16 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(grossPayout, feeBps, BPS_SCALE);
    }

    /// @notice Rounding helpers for the premium guard bounds. Each step of a bound rounds in the
    ///         direction that rejects more.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d);
    }
}
