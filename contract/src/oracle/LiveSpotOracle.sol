// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {ILiveSpotOracle} from "../interfaces/ILiveSpotOracle.sol";
import {IPyth} from "../interfaces/IPyth.sol";
import {IOptionSeriesRegistry} from "../interfaces/IOptionSeriesRegistry.sol";
import {RedstonePayload} from "./RedstonePayload.sol";
import {ProductStatus} from "../libraries/OptaraTypes.sol";
import {
    ZeroAddress,
    StaleSpot,
    InvalidSpotSource,
    InvalidSpotPrice,
    SpotConfidenceTooWide,
    InsufficientProviderFee,
    RefundFailed
} from "../libraries/Errors.sol";

/// @title LiveSpotOracle
/// @notice Verifies (through Pyth or RedStone) and stores the latest spot price per product (docs/ORACLES.md §2).
///         - Price > 0, normalized to WAD settlement-asset units per underlying, at most 1e36.
///         - A stored price is never replaced by an older one (INV-18).
///         - Derived prices use the older of the two legs' publish times, so both legs must be fresh.
///         - Provider fees are paid from msg.value; the excess is refunded to the caller.
///         - RedStone payloads (recognized by their marker) are verified here: each package's signer must be an
///           authorized RedStone signer, each feed needs `redstoneThreshold` distinct signers on one timestamp,
///           and the median is stored per feed (with the signers' spread) if newer. They cost no provider fee.
contract LiveSpotOracle is OptaraModule, ILiveSpotOracle {
    uint256 public constant MAX_PRICE_WAD = 1e36;
    uint32 public constant MAX_SPOT_AGE_CAP = 1 days;

    // InvalidSpotSource reasons
    uint8 internal constant SRC_PRODUCT = 1;
    uint8 internal constant SRC_KIND = 2;
    uint8 internal constant SRC_FEEDS = 3;
    uint8 internal constant SRC_AGE = 4;
    uint8 internal constant SRC_CONFIDENCE = 5;
    uint8 internal constant SRC_SIGNERS = 6;

    // InvalidRedstonePayload reasons beyond the parser's (1–6)
    uint8 internal constant RP_NOT_CONFIGURED = 7;
    uint8 internal constant RP_TIMESTAMP = 8;
    uint8 internal constant RP_SIGNERS = 9;
    uint8 internal constant RP_FUTURE = 10;
    uint8 internal constant RP_VALUE = 11;

    uint256 public constant MAX_REDSTONE_SIGNERS = 16;
    uint256 internal constant REDSTONE_DECIMALS = 8; // numeric data points
    uint256 internal constant MAX_FUTURE_SKEW = 60; // seconds a RedStone timestamp may lead the block
    uint256 internal constant BPS = 10_000;

    struct StoredPrice {
        uint192 priceWad;
        uint64 publishTime;
    }

    struct RedstonePrice {
        uint192 priceWad;
        uint64 publishTime;
        uint16 spreadBps; // (max − min) / median of the signers' values
    }

    /// @custom:storage-location erc7201:optara.storage.LiveSpotOracle
    struct SpotStorage {
        IPyth pyth;
        IOptionSeriesRegistry registry;
        mapping(bytes32 productId => SpotSource) sources;
        mapping(bytes32 productId => StoredPrice) prices;
        // RedStone (appended: upgrade-safe)
        mapping(address signer => bool) redstoneSigner;
        address[] redstoneSigners;
        uint8 redstoneThreshold;
        mapping(bytes32 feedId => RedstonePrice) redstonePrices;
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
        feePaid = _applyProviders(updates);
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
        bytes[] memory pythUpdates = _pythOnly(updates);
        return pythUpdates.length == 0 ? 0 : _s().pyth.getUpdateFee(pythUpdates);
    }

    // ------------------------------------------------------------------------------------------------- admin

    /// @notice Governance (timelocked). The product must exist in the registry.
    function setSource(bytes32 productId, SpotSource calldata source) external onlyRole(Roles.GOVERNANCE) {
        if (_s().registry.getProduct(productId).status == ProductStatus.NONE) revert InvalidSpotSource(SRC_PRODUCT);
        if (source.kind == SourceKind.PYTH_DIRECT || source.kind == SourceKind.REDSTONE_DIRECT) {
            if (source.baseFeedId == 0 || source.quoteFeedId != 0) revert InvalidSpotSource(SRC_FEEDS);
        } else if (source.kind == SourceKind.PYTH_DERIVED || source.kind == SourceKind.REDSTONE_DERIVED) {
            if (source.baseFeedId == 0 || source.quoteFeedId == 0 || source.baseFeedId == source.quoteFeedId) {
                revert InvalidSpotSource(SRC_FEEDS);
            }
        } else {
            revert InvalidSpotSource(SRC_KIND);
        }
        if (source.maxSpotAge == 0 || source.maxSpotAge > MAX_SPOT_AGE_CAP) revert InvalidSpotSource(SRC_AGE);
        if (source.maxConfidenceBps == 0 || source.maxConfidenceBps > BPS) revert InvalidSpotSource(SRC_CONFIDENCE);
        _s().sources[productId] = source;
        emit SpotSourceSet(productId, source);
    }

    /// @notice Governance (timelocked). The RedStone signers whose packages count, and how many distinct ones a
    ///         feed needs. Replaces the previous set. An empty set disables RedStone updates.
    function setRedstoneSigners(address[] calldata signers, uint8 threshold) external onlyRole(Roles.GOVERNANCE) {
        SpotStorage storage $ = _s();
        if (signers.length > MAX_REDSTONE_SIGNERS || threshold > signers.length || (signers.length != 0 && threshold == 0)) {
            revert InvalidSpotSource(SRC_SIGNERS);
        }
        for (uint256 i; i < $.redstoneSigners.length; ++i) {
            $.redstoneSigner[$.redstoneSigners[i]] = false;
        }
        delete $.redstoneSigners;
        for (uint256 i; i < signers.length; ++i) {
            if (signers[i] == address(0) || $.redstoneSigner[signers[i]]) revert InvalidSpotSource(SRC_SIGNERS);
            $.redstoneSigner[signers[i]] = true;
            $.redstoneSigners.push(signers[i]);
        }
        $.redstoneThreshold = threshold;
        emit RedstoneSignersSet(signers, threshold);
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

    function redstoneSigners() external view returns (address[] memory signers, uint8 threshold) {
        return (_s().redstoneSigners, _s().redstoneThreshold);
    }

    /// @notice The latest verified RedStone median for a feed (WAD), its time and the signers' spread.
    function redstonePrice(bytes32 feedId) external view returns (uint256 priceWad, uint64 publishTime, uint16 spreadBps) {
        RedstonePrice storage p = _s().redstonePrices[feedId];
        return (p.priceWad, p.publishTime, p.spreadBps);
    }

    // ------------------------------------------------------------------------------------------------- internal

    /// @dev Reads the provider and stores the price if strictly newer (INV-18). Unconfigured products are skipped
    ///      only if never configured; a configured product with an invalid price reverts.
    function _refresh(bytes32 productId) private {
        SpotStorage storage $ = _s();
        SpotSource storage src = $.sources[productId];
        if (src.kind == SourceKind.NONE) revert InvalidSpotSource(SRC_KIND);

        (uint256 price, uint256 publishTime) = _leg(src, src.baseFeedId, productId);
        if (src.kind == SourceKind.PYTH_DERIVED || src.kind == SourceKind.REDSTONE_DERIVED) {
            (uint256 quote, uint256 quoteTime) = _leg(src, src.quoteFeedId, productId);
            price = M.fullMulDiv(price, 1e18, quote); // underlying/USD ÷ asset/USD, rounded down
            if (quoteTime < publishTime) publishTime = quoteTime; // the older leg decides freshness
        }
        if (price == 0 || price > MAX_PRICE_WAD) revert InvalidSpotPrice(productId);

        StoredPrice storage stored = $.prices[productId];
        if (publishTime <= stored.publishTime) return; // never replace a newer (or equal) price
        // forge-lint: disable-next-line(unsafe-typecast)
        stored.priceWad = uint192(price); // ≤ 1e36 < 2^192
        // forge-lint: disable-next-line(unsafe-typecast)
        stored.publishTime = uint64(publishTime); // unix seconds
        emit SpotUpdated(productId, price, stored.publishTime);
    }

    /// @dev One Pyth leg normalized to WAD: price × 10^(18 + expo). Non-positive prices are invalid.
    /// @dev One Pyth leg in WAD. Rejects a confidence interval wider than `maxConfidenceBps` of the price (DD-34):
    ///      Pyth publishes `conf` in the price's own units, so the comparison needs no scaling.
    function _read(bytes32 feedId, bytes32 productId, uint16 maxConfidenceBps)
        private
        view
        returns (uint256 wad, uint256 publishTime)
    {
        IPyth.Price memory p = _s().pyth.getPriceUnsafe(feedId);
        if (p.price <= 0 || p.expo > 0 || p.expo < -36) revert InvalidSpotPrice(productId);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(uint64(p.price)); // p.price > 0
        if (uint256(p.conf) * BPS > raw * maxConfidenceBps) {
            revert SpotConfidenceTooWide(productId, (uint256(p.conf) * BPS + raw - 1) / raw);
        }
        int256 shift = 18 + int256(p.expo);
        // forge-lint: disable-next-line(unsafe-typecast)
        wad = shift >= 0 ? raw * 10 ** uint256(shift) : raw / 10 ** uint256(-shift);
        publishTime = p.publishTime;
    }

    /// @dev One leg in WAD from the source's provider.
    function _leg(SpotSource storage src, bytes32 feedId, bytes32 productId)
        private
        view
        returns (uint256 wad, uint256 publishTime)
    {
        if (src.kind == SourceKind.REDSTONE_DIRECT || src.kind == SourceKind.REDSTONE_DERIVED) {
            return _readRedstone(feedId, productId, src.maxConfidenceBps);
        }
        return _read(feedId, productId, src.maxConfidenceBps);
    }

    /// @dev A RedStone leg in WAD, from the verified median stored by `_ingestRedstone`.
    function _readRedstone(bytes32 feedId, bytes32 productId, uint16 maxConfidenceBps)
        private
        view
        returns (uint256 wad, uint256 publishTime)
    {
        RedstonePrice storage p = _s().redstonePrices[feedId];
        if (p.priceWad == 0) revert InvalidSpotPrice(productId);
        if (p.spreadBps > maxConfidenceBps) revert SpotConfidenceTooWide(productId, p.spreadBps);
        return (p.priceWad, p.publishTime);
    }

    /// @dev Verifies a RedStone payload and stores, per feed, the median of its distinct authorized signers'
    ///      values when at least `redstoneThreshold` agree on one timestamp and it is newer than the stored one.
    function _ingestRedstone(bytes calldata payload) private {
        uint8 threshold = _s().redstoneThreshold;
        if (threshold == 0) revert RedstonePayload.InvalidRedstonePayload(RP_NOT_CONFIGURED);
        RedstonePayload.Point[] memory pts = RedstonePayload.parse(payload);
        bool[] memory done = new bool[](pts.length);
        for (uint256 i; i < pts.length; ++i) {
            if (!done[i]) _ingestFeed(pts, done, i, threshold);
        }
    }

    /// @dev One feed of the payload: its distinct authorized signers' values, then the stored median.
    function _ingestFeed(RedstonePayload.Point[] memory pts, bool[] memory done, uint256 i, uint8 threshold) private {
        (uint256[] memory values, uint256 n) = _collect(pts, done, i);
        if (n < threshold) revert RedstonePayload.InvalidRedstonePayload(RP_SIGNERS);
        _storeRedstone(pts[i].feedId, pts[i].timestampMs, values, n);
    }

    /// @dev The values of feed `pts[i].feedId` from distinct authorized signers (all on `pts[i]`'s timestamp),
    ///      marking those points done. Unauthorized or invalid signatures are ignored.
    function _collect(RedstonePayload.Point[] memory pts, bool[] memory done, uint256 i)
        private
        view
        returns (uint256[] memory values, uint256 n)
    {
        values = new uint256[](MAX_REDSTONE_SIGNERS);
        address[] memory seen = new address[](MAX_REDSTONE_SIGNERS);
        for (uint256 j = i; j < pts.length; ++j) {
            if (done[j] || pts[j].feedId != pts[i].feedId) continue;
            done[j] = true;
            if (pts[j].timestampMs != pts[i].timestampMs) revert RedstonePayload.InvalidRedstonePayload(RP_TIMESTAMP);
            if (!_s().redstoneSigner[pts[j].signer] || _contains(seen, n, pts[j].signer)) continue;
            seen[n] = pts[j].signer;
            values[n++] = pts[j].value;
        }
    }

    function _storeRedstone(bytes32 feed, uint64 timestampMs, uint256[] memory values, uint256 n) private {
        uint64 publishTime = timestampMs / 1000;
        if (publishTime > block.timestamp + MAX_FUTURE_SKEW) revert RedstonePayload.InvalidRedstonePayload(RP_FUTURE);
        RedstonePrice storage stored = _s().redstonePrices[feed];
        if (publishTime <= stored.publishTime) return; // never replace a newer (or equal) price
        (uint256 wad, uint16 spreadBps) = _aggregate(values, n);
        // forge-lint: disable-next-line(unsafe-typecast)
        stored.priceWad = uint192(wad); // ≤ 1e36 < 2^192
        stored.publishTime = publishTime;
        stored.spreadBps = spreadBps;
        emit RedstonePriceUpdated(feed, wad, publishTime, spreadBps);
    }

    /// @dev Median of the signers' values in WAD and their spread ((max − min) / median, rounded up, capped).
    function _aggregate(uint256[] memory values, uint256 n) private pure returns (uint256 wad, uint16 spreadBps) {
        (uint256 median, uint256 lo, uint256 hi) = _median(values, n);
        if (median == 0) revert RedstonePayload.InvalidRedstonePayload(RP_VALUE);
        wad = median * 10 ** (18 - REDSTONE_DECIMALS);
        if (wad > MAX_PRICE_WAD) revert RedstonePayload.InvalidRedstonePayload(RP_VALUE);
        uint256 spread = M.divUp((hi - lo) * BPS, median);
        // forge-lint: disable-next-line(unsafe-typecast)
        spreadBps = spread > type(uint16).max ? type(uint16).max : uint16(spread);
    }

    function _contains(address[] memory list, uint256 n, address a) private pure returns (bool) {
        for (uint256 k; k < n; ++k) {
            if (list[k] == a) return true;
        }
        return false;
    }

    /// @dev Median (lower-middle average for an even count), minimum and maximum of the first `n` values.
    function _median(uint256[] memory v, uint256 n) private pure returns (uint256 median, uint256 lo, uint256 hi) {
        for (uint256 i = 1; i < n; ++i) {
            uint256 x = v[i];
            uint256 j = i;
            while (j > 0 && v[j - 1] > x) {
                v[j] = v[j - 1];
                --j;
            }
            v[j] = x;
        }
        lo = v[0];
        hi = v[n - 1];
        median = n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
    }

    /// @dev Verifies the RedStone payloads among `updates` and forwards the rest to Pyth, paying its fee.
    function _applyProviders(bytes[] calldata updates) private returns (uint256 feePaid) {
        for (uint256 i; i < updates.length; ++i) {
            if (RedstonePayload.isRedstone(updates[i])) _ingestRedstone(updates[i]);
        }
        bytes[] memory pythUpdates = _pythOnly(updates);
        if (pythUpdates.length != 0) {
            IPyth p = _s().pyth;
            feePaid = p.getUpdateFee(pythUpdates);
            if (msg.value < feePaid) revert InsufficientProviderFee(feePaid, msg.value);
            p.updatePriceFeeds{value: feePaid}(pythUpdates);
        }
    }

    /// @dev The Pyth update blobs of `updates` (everything that is not a RedStone payload).
    function _pythOnly(bytes[] calldata updates) private pure returns (bytes[] memory out) {
        uint256 n;
        for (uint256 i; i < updates.length; ++i) {
            if (!RedstonePayload.isRedstone(updates[i])) ++n;
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i; i < updates.length; ++i) {
            if (!RedstonePayload.isRedstone(updates[i])) out[n++] = updates[i];
        }
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
