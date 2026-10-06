// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ILiveSpotOracle
/// @notice Fresh spot prices per product, in settlement-asset units per underlying, WAD (docs/ORACLES.md §2).
///         Used for margin, liquidation and moneyness; never for settlement.
interface ILiveSpotOracle {
    /// @dev PYTH_DIRECT: one feed quoting the underlying in the settlement asset.
    ///      PYTH_DERIVED: underlying/USD ÷ settlementAsset/USD (both legs must be configured explicitly;
    ///      a USD price is never treated as a stablecoin price).
    enum SourceKind {
        NONE,
        PYTH_DIRECT,
        PYTH_DERIVED
    }

    struct SpotSource {
        SourceKind kind;
        bytes32 baseFeedId; // DIRECT: underlying/asset. DERIVED: underlying/USD.
        bytes32 quoteFeedId; // DERIVED only: settlementAsset/USD.
        uint32 maxSpotAge; // seconds
    }

    event SpotSourceSet(bytes32 indexed productId, SpotSource source);
    event SpotUpdated(bytes32 indexed productId, uint256 priceWad, uint64 publishTime);

    /// @notice Push provider updates (paying the provider fee from msg.value, refunding the rest to the caller),
    ///         then refresh the stored price of each product from the provider. Older prices never overwrite newer
    ///         ones. `updates` may be empty to refresh from data someone else pushed.
    /// @return feePaid The provider fee paid.
    function update(bytes[] calldata updates, bytes32[] calldata productIds) external payable returns (uint256 feePaid);

    /// @notice Provider fee for `updates` (what `update` will charge).
    function updateFee(bytes[] calldata updates) external view returns (uint256);

    function setSource(bytes32 productId, SpotSource calldata source) external;

    function spotPrice(bytes32 productId) external view returns (uint256 priceWad, uint64 publishTime);
    /// @notice The stored price if `age ≤ maxSpotAge`; reverts `StaleSpot(productId, age)` otherwise.
    function requireFreshSpot(bytes32 productId) external view returns (uint256 priceWad);
    function isSpotFresh(bytes32 productId) external view returns (bool);
    function sourceOf(bytes32 productId) external view returns (SpotSource memory);
}
