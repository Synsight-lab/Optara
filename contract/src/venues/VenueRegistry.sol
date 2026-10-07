// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {IVenueRegistry} from "../interfaces/IVenueRegistry.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {SeriesTerms} from "../libraries/OptaraTypes.sol";
import {
    NotAuthorized,
    ZeroAddress,
    InvalidMarket,
    InvalidAdapter,
    AdapterDisabled,
    MarketNotVerified
} from "../libraries/Errors.sol";

/// @title VenueRegistry
/// @notice Venue adapters and the official market per (venue, series) (docs/VENUES_AND_KURU.md §3).
/// @dev Market tokens come from the adapter, which reads the venue's own records (Kuru: its router's verified
///      market), never from the caller (INV-51). Nothing here affects margin, liquidation or settlement (INV-20,
///      INV-52): only VenueRouter reads it.
contract VenueRegistry is OptaraModule, IVenueRegistry {
    // InvalidAdapter reasons
    uint8 internal constant AD_ADDRESS = 1; // zero adapter or venueId mismatch
    uint8 internal constant AD_EXISTS = 2;
    // InvalidMarket reasons
    uint8 internal constant MK_BASE = 1; // base ≠ series wrapper
    uint8 internal constant MK_QUOTE = 2; // quote ≠ series settlement asset
    uint8 internal constant MK_EXISTS = 3;
    uint8 internal constant MK_EXPIRED = 4;
    uint8 internal constant MK_STATUS = 5; // unknown market, or EXPIRED set by hand

    struct Adapter {
        address adapter;
        bool enabled;
    }

    /// @custom:storage-location erc7201:optara.storage.VenueRegistry
    struct VenueRegistryStorage {
        IOptionSeriesRegistry series;
        mapping(bytes32 venueId => Adapter) adapters;
        mapping(bytes32 venueId => mapping(bytes32 seriesId => VenueMarket)) markets;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.VenueRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xf240511577b17bcf89f64bb93a2d42f4aa7828d6d0c68f3c02a04524cd836b00;

    function initialize(IProtocolControl control_, IOptionSeriesRegistry series_) external initializer {
        __OptaraModule_init(control_);
        if (address(series_) == address(0)) revert ZeroAddress();
        _s().series = series_;
    }

    // ================================================================================================== adapters

    /// @inheritdoc IVenueRegistry
    function registerAdapter(bytes32 venueId, address adapter) external onlyRole(Roles.GOVERNANCE) {
        VenueRegistryStorage storage $ = _s();
        if (adapter == address(0) || IVenueAdapter(adapter).venueId() != venueId) revert InvalidAdapter(AD_ADDRESS);
        if ($.adapters[venueId].adapter != address(0)) revert InvalidAdapter(AD_EXISTS);
        $.adapters[venueId] = Adapter({adapter: adapter, enabled: false});
        emit AdapterRegistered(venueId, adapter);
        emit AdapterEnabled(venueId, false);
    }

    /// @inheritdoc IVenueRegistry
    function setAdapterEnabled(bytes32 venueId, bool enabled) external {
        if (enabled) {
            _checkRole(Roles.GOVERNANCE);
        } else if (
            !_hasRole(Roles.GOVERNANCE, msg.sender) && !_hasRole(Roles.GUARDIAN, msg.sender)
                && !_hasRole(Roles.VENUE_ADMIN, msg.sender)
        ) {
            revert NotAuthorized(msg.sender);
        }
        Adapter storage a = _s().adapters[venueId];
        if (a.adapter == address(0)) revert InvalidAdapter(AD_ADDRESS);
        a.enabled = enabled;
        emit AdapterEnabled(venueId, enabled);
    }

    // =================================================================================================== markets

    /// @inheritdoc IVenueRegistry
    function registerMarket(bytes32 venueId, address market, bytes32 seriesId, bytes calldata metadata)
        external
        onlyRole(Roles.VENUE_ADMIN)
    {
        VenueRegistryStorage storage $ = _s();
        address adapter = $.adapters[venueId].adapter;
        if (adapter == address(0)) revert InvalidAdapter(AD_ADDRESS);
        if ($.markets[venueId][seriesId].market != address(0)) revert InvalidMarket(MK_EXISTS);
        SeriesTerms memory t = $.series.getSeries(seriesId); // reverts UnknownSeries
        if (block.timestamp >= t.expiry) revert InvalidMarket(MK_EXPIRED);
        (address base, address quote) = IVenueAdapter(adapter).marketTokens(market);
        if (base != t.wrapper) revert InvalidMarket(MK_BASE);
        if (quote != t.settlementAsset) revert InvalidMarket(MK_QUOTE);
        $.markets[venueId][seriesId] = VenueMarket({
            venueId: venueId,
            market: market,
            seriesId: seriesId,
            base: base,
            quote: quote,
            chainId: block.chainid,
            status: MarketStatus.ACTIVE,
            metadata: metadata
        });
        emit MarketRegistered(venueId, seriesId, market);
    }

    /// @inheritdoc IVenueRegistry
    function setMarketStatus(bytes32 venueId, bytes32 seriesId, MarketStatus status)
        external
        onlyRole(Roles.VENUE_ADMIN)
    {
        VenueMarket storage m = _s().markets[venueId][seriesId];
        if (m.market == address(0) || status == MarketStatus.EXPIRED) revert InvalidMarket(MK_STATUS);
        m.status = status;
        emit MarketStatusSet(venueId, seriesId, status);
    }

    // ===================================================================================================== views

    /// @inheritdoc IVenueRegistry
    function getMarket(bytes32 venueId, bytes32 seriesId) public view returns (VenueMarket memory m) {
        VenueRegistryStorage storage $ = _s();
        m = $.markets[venueId][seriesId];
        if (m.market != address(0) && block.timestamp >= $.series.getSeries(seriesId).expiry) {
            m.status = MarketStatus.EXPIRED;
        }
    }

    /// @inheritdoc IVenueRegistry
    function tradableMarket(bytes32 venueId, bytes32 seriesId) external view returns (address adapter, address market) {
        Adapter storage a = _s().adapters[venueId];
        if (!a.enabled) revert AdapterDisabled(venueId);
        VenueMarket memory m = getMarket(venueId, seriesId);
        if (m.status != MarketStatus.ACTIVE) revert MarketNotVerified();
        return (a.adapter, m.market);
    }

    function adapterOf(bytes32 venueId) external view returns (address adapter, bool enabled) {
        Adapter storage a = _s().adapters[venueId];
        return (a.adapter, a.enabled);
    }

    function _s() private pure returns (VenueRegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
