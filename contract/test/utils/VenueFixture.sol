// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettlementFixture} from "./SettlementFixture.sol";
import {KuruAdapter} from "../../src/venues/kuru/KuruAdapter.sol";
import {IKuruRouter} from "../../src/venues/kuru/IKuru.sol";
import {IVenueRouter} from "../../src/interfaces/IVenueRouter.sol";
import {Roles} from "../../src/governance/Roles.sol";

/// @notice The whole Optara stack with the real VenueRegistry and VenueRouter (at the `router` address).
abstract contract VenueFixture is SettlementFixture {
    bytes32 internal constant KURU = keccak256("KURU");
    address internal venueAdmin = makeAddr("venueAdmin");

    function _deployRealVenues() internal pure override returns (bool) {
        return true;
    }

    function _grantVenueAdmin() internal {
        vm.prank(governance);
        pc.grantRole(Roles.VENUE_ADMIN, venueAdmin);
    }

    /// @dev Deploys a KuruAdapter on `kuruRouter`, registers and enables it.
    function _installKuru(address kuruRouter) internal returns (KuruAdapter a) {
        a = new KuruAdapter(address(venueRouter), IKuruRouter(kuruRouter));
        vm.startPrank(governance);
        venues.registerAdapter(KURU, address(a));
        venues.setAdapterEnabled(KURU, true);
        vm.stopPrank();
    }

    function _buyOrder(bytes32 seriesId, uint256 premiumIn, uint256 minQty, address recipient)
        internal
        view
        returns (IVenueRouter.BuyOrder memory)
    {
        return IVenueRouter.BuyOrder({
            venueId: KURU,
            seriesId: seriesId,
            premiumIn: premiumIn,
            minQty: minQty,
            maxBuyerFeeNative: type(uint256).max,
            maxVenueFeeNative: type(uint256).max,
            recipient: recipient,
            deadline: uint64(block.timestamp)
        });
    }

    function _sellOrder(bytes32 seriesId, uint256 qty, uint256 minProceeds, address recipient)
        internal
        view
        returns (IVenueRouter.SellOrder memory)
    {
        return IVenueRouter.SellOrder({
            venueId: KURU,
            seriesId: seriesId,
            qty: qty,
            minProceeds: minProceeds,
            maxVenueFeeNative: type(uint256).max,
            recipient: recipient,
            deadline: uint64(block.timestamp)
        });
    }
}
