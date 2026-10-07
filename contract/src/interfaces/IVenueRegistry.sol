// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVenueRegistry
/// @notice Venue adapters and verified markets (docs/VENUES_AND_KURU.md §3). A market is registered only if the
///         venue's own record shows base = the series wrapper and quote = the series settlement asset (INV-51).
interface IVenueRegistry {
    enum MarketStatus {
        INACTIVE,
        ACTIVE,
        EXPIRED
    }

    struct VenueMarket {
        bytes32 venueId;
        address market;
        bytes32 seriesId;
        address base;
        address quote;
        uint256 chainId;
        MarketStatus status; // EXPIRED is reported once the series expires, whatever is stored
        bytes metadata;
    }

    event AdapterRegistered(bytes32 indexed venueId, address adapter);
    event AdapterEnabled(bytes32 indexed venueId, bool enabled);
    event MarketRegistered(bytes32 indexed venueId, bytes32 indexed seriesId, address market);
    event MarketStatusSet(bytes32 indexed venueId, bytes32 indexed seriesId, MarketStatus status);

    /// @notice Governance (timelocked). Registered disabled; `adapter.venueId()` must equal `venueId`.
    function registerAdapter(bytes32 venueId, address adapter) external;
    /// @notice Enable: governance. Disable: guardian, venue admin or governance (instant).
    function setAdapterEnabled(bytes32 venueId, bool enabled) external;
    /// @notice Venue admin. The adapter must be registered; base and quote are read from the venue.
    function registerMarket(bytes32 venueId, address market, bytes32 seriesId, bytes calldata metadata) external;
    /// @notice Venue admin: ACTIVE or INACTIVE (EXPIRED follows from the series expiry).
    function setMarketStatus(bytes32 venueId, bytes32 seriesId, MarketStatus status) external;

    function getMarket(bytes32 venueId, bytes32 seriesId) external view returns (VenueMarket memory);
    /// @notice The adapter and market for a trade; reverts `AdapterDisabled` or `MarketNotVerified`.
    function tradableMarket(bytes32 venueId, bytes32 seriesId) external view returns (address adapter, address market);
    function adapterOf(bytes32 venueId) external view returns (address adapter, bool enabled);
}
