// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";
import {PayoffMath} from "../../src/libraries/PayoffMath.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {Leg, OptionType} from "../../src/libraries/OptaraTypes.sol";

/// @notice External wrapper so tests can call internal library functions (and expect their reverts).
contract MathHarness {
    function phi(OptionType t, uint256 k, uint256 c, uint256 s) external pure returns (uint256) {
        return PayoffMath.phi(t, k, c, s);
    }

    function payoffNumerator(OptionType t, uint256 k, uint256 c, uint256 cs, uint256 s, uint256 q)
        external
        pure
        returns (uint256)
    {
        return PayoffMath.payoffNumerator(t, k, c, cs, s, q);
    }

    function boundedProduct(uint256 a, uint256 b, uint256 c) external pure returns (bool, uint256) {
        return PayoffMath.boundedProduct(a, b, c);
    }

    function product(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return PayoffMath.product(a, b, c);
    }

    function boundedAdd(uint256 a, uint256 b) external pure returns (uint256) {
        return PayoffMath.boundedAdd(a, b);
    }

    function ceilDiv(uint256 n, uint256 d) external pure returns (uint256) {
        return FixedPointMath.ceilDiv(n, d);
    }

    function floorDiv(uint256 n, uint256 d) external pure returns (uint256) {
        return FixedPointMath.floorDiv(n, d);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMath.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMath.mulDivUp(x, y, d);
    }

    function mulDivHalfUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMath.mulDivHalfUp(x, y, d);
    }

    function toNativeDown(uint256 x, uint8 d) external pure returns (uint256) {
        return FixedPointMath.toNativeDown(x, d);
    }

    function toNativeUp(uint256 x, uint8 d) external pure returns (uint256) {
        return FixedPointMath.toNativeUp(x, d);
    }

    function nativeDenominator(uint8 d) external pure returns (uint256) {
        return FixedPointMath.nativeDenominator(d);
    }

    function scaleByRho(uint256 a, uint256 rho) external pure returns (uint256) {
        return FixedPointMath.scaleByRho(a, rho);
    }

    function worstCaseLossNumerator(Leg[] memory legs) external pure returns (uint256) {
        return RiskMath.worstCaseLossNumerator(legs);
    }

    function numeratorsAt(Leg[] memory legs, uint256 s) external pure returns (uint256, uint256) {
        return RiskMath.numeratorsAt(legs, s);
    }

    function lossNumeratorAt(Leg[] memory legs, uint256 s) external pure returns (uint256) {
        return RiskMath.lossNumeratorAt(legs, s);
    }

    function maxNumeratorSums(Leg[] memory legs) external pure returns (uint256, uint256) {
        return RiskMath.maxNumeratorSums(legs);
    }

    function marginNative(Leg[] memory legs, uint8 decimals) external pure returns (uint256) {
        return FixedPointMath.ceilDiv(RiskMath.worstCaseLossNumerator(legs), FixedPointMath.nativeDenominator(decimals));
    }
}
