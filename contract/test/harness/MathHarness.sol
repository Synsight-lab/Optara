// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPoint} from "../../src/risk/FixedPoint.sol";
import {OptionPricer} from "../../src/risk/OptionPricer.sol";

/// @notice Exposes the internal math libraries as external calls so tests can catch reverts and measure gas.
contract MathHarness {
    // FixedPoint
    function scale(uint8 d) external pure returns (uint256) {
        return FixedPoint.scale(d);
    }

    function toWad(uint256 native, uint8 d) external pure returns (uint256) {
        return FixedPoint.toWad(native, d);
    }

    function toNativeDown(uint256 x, uint8 d) external pure returns (uint256) {
        return FixedPoint.toNativeDown(x, d);
    }

    function toNativeUp(uint256 x, uint8 d) external pure returns (uint256) {
        return FixedPoint.toNativeUp(x, d);
    }

    function yearsUntil(uint256 expiry, uint256 nowTs) external pure returns (uint256) {
        return FixedPoint.yearsUntil(expiry, nowTs);
    }

    function bpsDown(uint256 x, uint256 bps) external pure returns (uint256) {
        return FixedPoint.bpsDown(x, bps);
    }

    function bpsUp(uint256 x, uint256 bps) external pure returns (uint256) {
        return FixedPoint.bpsUp(x, bps);
    }

    // OptionPricer
    function intrinsic(bool isCall, uint256 s, uint256 k) external pure returns (uint256) {
        return OptionPricer.intrinsic(isCall, s, k);
    }

    function normCdf(int256 x) external pure returns (uint256) {
        return OptionPricer.normCdf(x);
    }

    function black76(bool isCall, uint256 f, uint256 k, uint256 sigma, uint256 t) external pure returns (uint256) {
        return OptionPricer.black76(isCall, f, k, sigma, t);
    }

    function logMoneyness(uint256 k, uint256 s) external pure returns (int256) {
        return OptionPricer.logMoneyness(k, s);
    }

    function findTenors(uint64[4] memory tenors, uint64 expiry) external pure returns (bool, uint256, uint256) {
        return OptionPricer.findTenors(tenors, expiry);
    }

    function findNodes(int256[] memory kNodes, int256 k) external pure returns (uint256, uint256) {
        return OptionPricer.findNodes(kNodes, k);
    }

    function interpolateNodes(int256 k, int256 kLo, int256 kHi, uint256 wLo, uint256 wHi)
        external
        pure
        returns (uint256)
    {
        return OptionPricer.interpolateNodes(k, kLo, kHi, wLo, wHi);
    }

    function interpolateTenors(uint256 wA, uint256 wB, uint64 ta, uint64 tb, uint64 expiry)
        external
        pure
        returns (uint256)
    {
        return OptionPricer.interpolateTenors(wA, wB, ta, tb, expiry);
    }

    function ivFromTotalVariance(uint256 w, uint64 expiry, uint64 reportTime, uint256 minIv, uint256 maxIv)
        external
        pure
        returns (uint256)
    {
        return OptionPricer.ivFromTotalVariance(w, expiry, reportTime, minIv, maxIv);
    }

    function surfaceIv(OptionPricer.IvQuery memory q) external pure returns (uint256) {
        return OptionPricer.surfaceIv(q);
    }

    function staleIvs(uint256 sigma, uint256 staleSeconds, uint256 penaltyBpsPerHour, uint256 minIv, uint256 maxIv)
        external
        pure
        returns (uint256, uint256)
    {
        return OptionPricer.staleIvs(sigma, staleSeconds, penaltyBpsPerHour, minIv, maxIv);
    }

    function legValue(int256 q, uint256 cs, uint256 price) external pure returns (int256) {
        return OptionPricer.legValue(q, cs, price);
    }
}
