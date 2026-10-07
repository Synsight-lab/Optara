// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVenueRouter
/// @notice The official route to venues, with the buyer fee and every limit enforced (docs/VENUES_AND_KURU.md §5,
///         FEES.md §4). Buys are exact-in (DD-33): the buyer spends at most `premiumIn` and receives at least
///         `minQty` wrappers, measured by the router. The router and adapter hold nothing after a call (INV-50).
interface IVenueRouter {
    event VenueTrade(
        bytes32 indexed venueId,
        bytes32 indexed seriesId,
        address indexed trader,
        address recipient,
        bool isBuy,
        uint256 qty,
        uint256 premium,
        uint256 buyerFee,
        uint256 venueFee
    );

    /// @param premiumIn Most of the settlement asset to spend on the venue (exact-in).
    /// @param minQty Fewest wrappers to receive, measured by the router.
    /// @param maxBuyerFeeNative Bound on the Optara buyer fee (charged on the premium actually spent).
    /// @param maxVenueFeeNative Bound on the venue's fee, in the settlement asset.
    struct BuyOrder {
        bytes32 venueId;
        bytes32 seriesId;
        uint256 premiumIn;
        uint256 minQty;
        uint256 maxBuyerFeeNative;
        uint256 maxVenueFeeNative;
        address recipient;
        uint64 deadline;
    }

    struct SellOrder {
        bytes32 venueId;
        bytes32 seriesId;
        uint256 qty;
        uint256 minProceeds;
        uint256 maxVenueFeeNative;
        address recipient;
        uint64 deadline;
    }

    /// @notice Pulls `premiumIn` plus the buyer fee bound, buys on the venue, charges the buyer fee on the premium
    ///         actually spent, sends the wrappers to `recipient` and refunds the rest.
    function buyThroughVenue(BuyOrder calldata order, bytes calldata adapterData)
        external
        returns (uint256 qtyOut, uint256 premiumSpent, uint256 buyerFee, uint256 venueFee);

    /// @notice Pulls `qty` wrappers, sells on the venue, sends the proceeds to `recipient` and refunds unsold
    ///         wrappers. No Optara fee.
    function sellThroughVenue(SellOrder calldata order, bytes calldata adapterData)
        external
        returns (uint256 qtySold, uint256 proceeds, uint256 venueFee);

    function modules() external view returns (address registry, address venues, address fees);
}
