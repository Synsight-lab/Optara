// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {ILiveSpotOracle} from "../interfaces/ILiveSpotOracle.sol";
import {IPyth} from "../interfaces/IPyth.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {ProductStatus} from "../libraries/OptaraTypes.sol";
import {
    ZeroAddress,
    StaleSpot,
    InvalidSpotSource,
    InvalidSpotPrice,
    InsufficientProviderFee,
    RefundFailed
} from "../libraries/Errors.sol";

/// @title LiveSpotOracle
/// @notice Verifies (through Pyth) and stores the latest spot price per product (docs/ORACLES.md §2).
///         - Price > 0, normalized to WAD settlement-asset units per underlying, at most 1e36.
///         - A stored price is never replaced by an older one (INV-18).
///         - Derived prices use the older of the two legs' publish times, so both legs must be fresh.
///         - Provider fees are paid from msg.value; the excess is refunded to the caller.
contract LiveSpotOracle is OptaraModule, ILiveSpotOracle {
    uint256 public constant MAX_PRICE_WAD = 1e36;
    uint32 public constant MAX_SPOT_AGE_CAP = 1 days;

    // InvalidSpotSource reasons
    uint8 internal constant SRC_PRODUCT = 1;
    uint8 internal constant SRC_KIND = 2;
    uint8 internal constant SRC_FEEDS = 3;
    uint8 internal constant SRC_AGE = 4;

    struct StoredPrice {
        uint192 priceWad;
        uint64 publishTime;
    }

    /// @custom:storage-location erc7201:optara.storage.LiveSpotOracle
    struct SpotStorage {
        IPyth pyth;
        IOptionSeriesRegistry registry;
        mapping(bytes32 productId => SpotSource) sources;
        mapping(bytes32 productId => StoredPrice) prices;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.LiveSpotOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x1e07571fbc3d561cc37286352e4623f43c8c4ec4de392362411e8d2df9c7b700;

    function initialize(IProtocolControl control_, IPyth pyth_, IOptionSeriesRegistry registry_) external initializer {
        __OptaraModule_init(control_);
        if (address(pyth_) == address(0) || address(registry_) == address(0)) revert ZeroAddress();
        _s().pyth = pyth_;
        _s().registry = registry_;
    }

    // ------------------------------------------------------------------------------------------------- updates

    /// @inheritdoc ILiveSpotOracle
    function update(bytes[] calldata updates, bytes32[] calldata productIds)
        external
        payable
        nonReentrant
        returns (uint256 feePaid)
    {
        SpotStorage storage $ = _s();
        if (updates.length != 0) {
            feePaid = $.pyth.getUpdateFee(updates);
            if (msg.value < feePaid) revert InsufficientProviderFee(feePaid, msg.value);
            $.pyth.updatePriceFeeds{value: feePaid}(updates);
        }
        for (uint256 i; i < productIds.length; ++i) {
            _refresh(productIds[i]);
        }
        uint256 refund = msg.value - feePaid;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc ILiveSpotOracle
    function updateFee(bytes[] calldata updates) external view returns (uint256) {
        return updates.length == 0 ? 0 : _s().pyth.getUpdateFee(updates);
    }

    // ------------------------------------------------------------------------------------------------- admin

    /// @notice Governance (timelocked). The product must exist in the registry.
    function setSource(bytes32 productId, SpotSource calldata source) external onlyRole(Roles.GOVERNANCE) {
        if (_s().registry.getProduct(productId).status == ProductStatus.NONE) revert InvalidSpotSource(SRC_PRODUCT);
        if (source.kind == SourceKind.PYTH_DIRECT) {
            if (source.baseFeedId == 0 || source.quoteFeedId != 0) revert InvalidSpotSource(SRC_FEEDS);
        } else if (source.kind == SourceKind.PYTH_DERIVED) {
            if (source.baseFeedId == 0 || source.quoteFeedId == 0 || source.baseFeedId == source.quoteFeedId) {
                revert InvalidSpotSource(SRC_FEEDS);
            }
        } else {
            revert InvalidSpotSource(SRC_KIND);
        }
        if (source.maxSpotAge == 0 || source.maxSpotAge > MAX_SPOT_AGE_CAP) revert InvalidSpotSource(SRC_AGE);
        _s().sources[productId] = source;
        emit SpotSourceSet(productId, source);
    }

    // ------------------------------------------------------------------------------------------------- views

    function spotPrice(bytes32 productId) external view returns (uint256 priceWad, uint64 publishTime) {
        StoredPrice storage p = _s().prices[productId];
        return (p.priceWad, p.publishTime);
    }

    /// @inheritdoc ILiveSpotOracle
    function requireFreshSpot(bytes32 productId) external view returns (uint256 priceWad) {
        SpotStorage storage $ = _s();
        StoredPrice storage p = $.prices[productId];
        uint64 age = _age(p.publishTime);
        if (p.priceWad == 0 || age > $.sources[productId].maxSpotAge) revert StaleSpot(productId, age);
        return p.priceWad;
    }

    function isSpotFresh(bytes32 productId) external view returns (bool) {
        SpotStorage storage $ = _s();
        StoredPrice storage p = $.prices[productId];
        return p.priceWad != 0 && _age(p.publishTime) <= $.sources[productId].maxSpotAge;
    }

    function sourceOf(bytes32 productId) external view returns (SpotSource memory) {
        return _s().sources[productId];
    }

    function pyth() external view returns (address) {
        return address(_s().pyth);
    }

    // ------------------------------------------------------------------------------------------------- internal

    /// @dev Reads the provider and stores the price if strictly newer (INV-18). Unconfigured products are skipped
    ///      only if never configured; a configured product with an invalid price reverts.
    function _refresh(bytes32 productId) private {
        SpotStorage storage $ = _s();
        SpotSource storage src = $.sources[productId];
        if (src.kind == SourceKind.NONE) revert InvalidSpotSource(SRC_KIND);

        (uint256 price, uint256 publishTime) = _read(src.baseFeedId, productId);
        if (src.kind == SourceKind.PYTH_DERIVED) {
            (uint256 quote, uint256 quoteTime) = _read(src.quoteFeedId, productId);
            price = M.fullMulDiv(price, 1e18, quote); // underlying/USD ÷ asset/USD, rounded down
            if (quoteTime < publishTime) publishTime = quoteTime; // the older leg decides freshness
        }
        if (price == 0 || price > MAX_PRICE_WAD) revert InvalidSpotPrice(productId);

        StoredPrice storage stored = $.prices[productId];
        if (publishTime <= stored.publishTime) return; // never replace a newer (or equal) price
        // forge-lint: disable-next-line(unsafe-typecast)
        stored.priceWad = uint192(price); // ≤ 1e36 < 2^192
        // forge-lint: disable-next-line(unsafe-typecast)
        stored.publishTime = uint64(publishTime); // Pyth timestamps are unix seconds
        emit SpotUpdated(productId, price, stored.publishTime);
    }

    /// @dev One Pyth leg normalized to WAD: price × 10^(18 + expo). Non-positive prices are invalid.
    function _read(bytes32 feedId, bytes32 productId) private view returns (uint256 wad, uint256 publishTime) {
        IPyth.Price memory p = _s().pyth.getPriceUnsafe(feedId);
        if (p.price <= 0 || p.expo > 0 || p.expo < -36) revert InvalidSpotPrice(productId);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(uint64(p.price)); // p.price > 0
        int256 shift = 18 + int256(p.expo);
        // forge-lint: disable-next-line(unsafe-typecast)
        wad = shift >= 0 ? raw * 10 ** uint256(shift) : raw / 10 ** uint256(-shift);
        publishTime = p.publishTime;
    }

    function _age(uint64 publishTime) private view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return block.timestamp > publishTime ? uint64(block.timestamp - publishTime) : 0;
    }

    function _s() private pure returns (SpotStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
