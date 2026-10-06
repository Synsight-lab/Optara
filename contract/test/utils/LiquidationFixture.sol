// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClearingFixture} from "./ClearingFixture.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";

/// @notice ClearingFixture plus the real LiquidationModule at the `liquidationModule` address.
abstract contract LiquidationFixture is ClearingFixture {
    function _deployRealLiquidation() internal pure override returns (bool) {
        return true;
    }

    /// @dev Spot `priceWad` and a flat surface at `iv` (nodes at 3,500 / 4,500 / 6,200 / 8,000), tenors covering
    ///      the 30- and 45-day series from the current time.
    function _flatMarket(uint256 priceWad, uint256 iv) internal {
        _setSpot(ethUsdc, priceWad);
        uint256[] memory k = new uint256[](4);
        uint256[] memory v = new uint256[](4);
        (k[0], k[1], k[2], k[3]) = (3500e18, 4500e18, 6200e18, 8000e18);
        (v[0], v[1], v[2], v[3]) = (iv, iv, iv, iv);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = block.timestamp < EXP30 ? (EXP30, T0 + 60 days) : (T0 + 45 days, T0 + 60 days);
        _setSurface(ethUsdc, priceWad, k, v, tenors);
    }

    function _params(uint16 startBonus, uint16 maxBonus)
        internal
        pure
        returns (ILiquidationModule.LiquidationParams memory)
    {
        return ILiquidationModule.LiquidationParams({
            startBonusBps: startBonus,
            maxBonusBps: maxBonus,
            auctionDuration: 1800,
            minSliceBps: 500,
            maxSliceBps: 2500,
            targetHealthBufferBps: 500,
            liquidationPenaltyBps: 200
        });
    }
}
