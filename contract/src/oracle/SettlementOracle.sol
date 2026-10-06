// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";
import {OptaraModule} from "../governance/OptaraModule.sol";
import {Roles} from "../governance/Roles.sol";
import {IProtocolControl} from "../interfaces/IProtocolControl.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {ISettlementConfigs} from "../interfaces/IExternalDependencies.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {
    NotAuthorized,
    InvalidSettlementProof,
    FinalizationTooEarly,
    InvalidSettlementConfig,
    UnknownSettlementConfig,
    SettlementConfigExists
} from "../libraries/Errors.sol";

/// @title SettlementOracle
/// @notice Immutable settlement oracle configs and the Chainlink round-in-force rule (docs/ORACLES.md §5),
///         ported from V2's ChainlinkSettlementAdapter (commit d89d3a1).
///
/// OBSERVATION RULE. For every feed leg, the observation is the round IN FORCE at T = expiry +
/// observationEndOffset: the last round with updatedAt ≤ T. The caller proves it with the round's immediate
/// successor (updatedAt > T) or by showing it is the feed's latest round. Exactly one round satisfies the proof, so
/// the price is a fixed function of feed history. A leg is VALID when answer > 0, updatedAt ≥ expiry +
/// observationStartOffset and the normalized price fits.
///
/// SELECTION. The primary settles if valid. The fallback is eligible only when the caller proves on-chain that the
/// primary's in-force observation is invalid. Omitting primary data proves nothing.
contract SettlementOracle is OptaraModule, ISettlementOracle {
    bytes32 internal constant CONFIG_TAG = keccak256("Optara.PM.SettlementConfig");
    int64 internal constant MAX_OFFSET = 7 days;
    uint64 internal constant MAX_FINALIZATION_DELAY = 90 days;

    // InvalidSettlementConfig reasons
    uint8 internal constant CFG_ADDRESSES = 1;
    uint8 internal constant CFG_PRIMARY_MISSING = 2;
    uint8 internal constant CFG_SOURCE_FIELDS = 3;
    uint8 internal constant CFG_FEED = 4;
    uint8 internal constant CFG_WINDOW = 5;
    uint8 internal constant CFG_SKEW = 6;

    // InvalidSettlementProof reasons
    uint8 internal constant P_ROUND_UNAVAILABLE = 1;
    uint8 internal constant P_ROUND_AFTER_OBSERVATION = 2;
    uint8 internal constant P_NOT_LATEST_ROUND = 3;
    uint8 internal constant P_SUCCESSOR_UNAVAILABLE = 4;
    uint8 internal constant P_NOT_IMMEDIATE_SUCCESSOR = 5;
    uint8 internal constant P_SUCCESSOR_NOT_AFTER = 6;
    uint8 internal constant P_PRIMARY_INVALID = 7;
    uint8 internal constant P_PRIMARY_VALID = 8;
    uint8 internal constant P_NO_FALLBACK = 9;
    uint8 internal constant P_FALLBACK_INVALID = 10;
    uint8 internal constant P_PROOF_COUNT = 11;
    uint8 internal constant P_SOURCE_INDEX = 12;

    struct StoredConfig {
        bool exists;
        bool approved;
        SettlementOracleConfig config;
    }

    /// @custom:storage-location erc7201:optara.storage.SettlementOracle
    struct SettlementOracleStorage {
        mapping(bytes32 configId => StoredConfig) configs;
    }

    // keccak256(abi.encode(uint256(keccak256("optara.storage.SettlementOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x51b346771edb52ed69369198824275417556c3e0379616cbecf2df5e2d985900;

    function initialize(IProtocolControl control_) external initializer {
        __OptaraModule_init(control_);
    }

    // ------------------------------------------------------------------------------------------------- configs

    /// @notice ORACLE_ADMIN. The config is validated against the live feeds, stored forever under the hash of its
    ///         contents and approved. It can never be edited; a new rule is a new config.
    function registerConfig(SettlementOracleConfig calldata c)
        external
        onlyRole(Roles.ORACLE_ADMIN)
        returns (bytes32 configId)
    {
        if (c.underlying == address(0) || c.settlementAsset == address(0) || c.underlying == c.settlementAsset) {
            revert InvalidSettlementConfig(CFG_ADDRESSES);
        }
        if (c.primary.kind == FeedKind.NONE) revert InvalidSettlementConfig(CFG_PRIMARY_MISSING);
        bool derived = _validateSource(c.primary);
        if (c.fallbackSource.kind != FeedKind.NONE) {
            derived = _validateSource(c.fallbackSource) || derived;
        } else if (
            c.fallbackSource.feed != address(0) || c.fallbackSource.quoteFeed != address(0)
                || c.fallbackSource.feedDecimals != 0 || c.fallbackSource.quoteFeedDecimals != 0
        ) {
            revert InvalidSettlementConfig(CFG_SOURCE_FIELDS);
        }
        if (derived ? c.maxLegSkew == 0 : c.maxLegSkew != 0) revert InvalidSettlementConfig(CFG_SKEW);
        if (
            c.observationStartOffset < -MAX_OFFSET || c.observationStartOffset > c.observationEndOffset
                || c.observationEndOffset > MAX_OFFSET || c.minFinalizationDelay > c.maxFinalizationDelay
                || c.maxFinalizationDelay > MAX_FINALIZATION_DELAY
                || int256(uint256(c.maxFinalizationDelay)) <= int256(c.observationEndOffset)
        ) revert InvalidSettlementConfig(CFG_WINDOW);

        configId = computeConfigId(c);
        StoredConfig storage s = _s().configs[configId];
        if (s.exists) revert SettlementConfigExists(configId);
        s.exists = true;
        s.approved = true;
        s.config = c;
        emit SettlementConfigRegistered(configId, c);
        emit SettlementConfigApproved(configId, true);
    }

    /// @notice Approving is governance; revoking is also allowed for the guardian. Only affects whether new series
    ///         may use the config; existing groups keep their precommitted rule.
    function setConfigApproved(bytes32 configId, bool approved) external {
        if (!_hasRole(Roles.GOVERNANCE, msg.sender) && (approved || !_hasRole(Roles.GUARDIAN, msg.sender))) {
            revert NotAuthorized(msg.sender);
        }
        StoredConfig storage s = _stored(configId);
        s.approved = approved;
        emit SettlementConfigApproved(configId, approved);
    }

    // ------------------------------------------------------------------------------------------------- verification

    /// @inheritdoc ISettlementOracle
    function verify(bytes32 configId, uint64 expiry, bytes calldata settlementData)
        external
        view
        returns (uint256 priceWad, uint64 observationTime, uint8 sourceUsed)
    {
        SettlementOracleConfig storage c = _stored(configId).config;
        (uint64 start, uint64 end) = _window(c, expiry);
        uint64 earliest = _earliest(c, expiry, end);
        if (block.timestamp < earliest) revert FinalizationTooEarly(earliest);

        SettlementData memory d = abi.decode(settlementData, (SettlementData));
        if (d.sourceIndex == 0) {
            bool valid;
            (valid, priceWad, observationTime) = _evaluate(c.primary, c.maxLegSkew, d.primaryProofs, start, end);
            if (!valid) revert InvalidSettlementProof(P_PRIMARY_INVALID);
            return (priceWad, observationTime, 0);
        }
        if (d.sourceIndex == 1) {
            if (c.fallbackSource.kind == FeedKind.NONE) revert InvalidSettlementProof(P_NO_FALLBACK);
            (bool primaryValid,,) = _evaluate(c.primary, c.maxLegSkew, d.primaryProofs, start, end);
            if (primaryValid) revert InvalidSettlementProof(P_PRIMARY_VALID);
            bool valid;
            (valid, priceWad, observationTime) = _evaluate(c.fallbackSource, c.maxLegSkew, d.fallbackProofs, start, end);
            if (!valid) revert InvalidSettlementProof(P_FALLBACK_INVALID);
            return (priceWad, observationTime, 1);
        }
        revert InvalidSettlementProof(P_SOURCE_INDEX);
    }

    // ------------------------------------------------------------------------------------------------- views

    /// @inheritdoc ISettlementConfigs
    function isConfigUsable(bytes32 configId, address underlying, address settlementAsset)
        external
        view
        returns (bool)
    {
        StoredConfig storage s = _s().configs[configId];
        return
            s.exists && s.approved && s.config.underlying == underlying && s.config.settlementAsset == settlementAsset;
    }

    function getConfig(bytes32 configId) external view returns (SettlementOracleConfig memory) {
        return _stored(configId).config;
    }

    function configExists(bytes32 configId) external view returns (bool) {
        return _s().configs[configId].exists;
    }

    function isConfigApproved(bytes32 configId) external view returns (bool) {
        return _s().configs[configId].approved;
    }

    function computeConfigId(SettlementOracleConfig calldata c) public pure returns (bytes32) {
        return keccak256(abi.encode(CONFIG_TAG, c));
    }

    function earliestFinalization(bytes32 configId, uint64 expiry) external view returns (uint64) {
        SettlementOracleConfig storage c = _stored(configId).config;
        (, uint64 end) = _window(c, expiry);
        return _earliest(c, expiry, end);
    }

    function stalledAfter(bytes32 configId, uint64 expiry) external view returns (uint64) {
        return expiry + _stored(configId).config.maxFinalizationDelay;
    }

    /// @notice Chainlink proxy round ids are phase-encoded: id = (phaseId << 64) | aggregatorRound. `next` is the
    ///         immediate successor of `round` if, in the same phase, aggregatorRound(next) = aggregatorRound(round)
    ///         + 1; or across a phase boundary, phase(next) = phase(round) + 1 with aggregatorRound(next) = 1 and
    ///         `round` the last round of its phase (round + 1 does not exist).
    function isImmediateSuccessor(address feed, uint80 round, uint80 next) public view returns (bool) {
        uint256 phaseRound = uint256(round) >> 64;
        uint256 phaseNext = uint256(next) >> 64;
        uint256 aggRound = uint256(round) & type(uint64).max;
        uint256 aggNext = uint256(next) & type(uint64).max;
        if (phaseNext == phaseRound) return aggNext == aggRound + 1;
        if (phaseNext == phaseRound + 1) {
            if (aggNext != 1 || round == type(uint80).max) return false;
            try IAggregatorV3(feed).getRoundData(round + 1) returns (uint80, int256, uint256, uint256 u, uint80) {
                return u == 0;
            } catch {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------------- internal

    /// @return derived True for a DERIVED source.
    function _validateSource(FeedSource calldata s) private view returns (bool derived) {
        if (s.kind == FeedKind.DIRECT) {
            _validateFeed(s.feed, s.feedDecimals);
            if (s.quoteFeed != address(0) || s.quoteFeedDecimals != 0) {
                revert InvalidSettlementConfig(CFG_SOURCE_FIELDS);
            }
            return false;
        }
        // kind is DERIVED here (NONE is handled by the callers; the enum has no other values)
        _validateFeed(s.feed, s.feedDecimals);
        _validateFeed(s.quoteFeed, s.quoteFeedDecimals);
        if (s.feed == s.quoteFeed) revert InvalidSettlementConfig(CFG_SOURCE_FIELDS);
        return true;
    }

    function _validateFeed(address feed, uint8 feedDecimals) private view {
        if (feed.code.length == 0 || feedDecimals > 18) revert InvalidSettlementConfig(CFG_FEED);
        try IAggregatorV3(feed).decimals() returns (uint8 d) {
            if (d != feedDecimals) revert InvalidSettlementConfig(CFG_FEED);
        } catch {
            revert InvalidSettlementConfig(CFG_FEED);
        }
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (updatedAt == 0 || answer <= 0) revert InvalidSettlementConfig(CFG_FEED);
        } catch {
            revert InvalidSettlementConfig(CFG_FEED);
        }
    }

    function _window(SettlementOracleConfig storage c, uint64 expiry) private view returns (uint64 start, uint64 end) {
        int256 s = int256(uint256(expiry)) + c.observationStartOffset;
        int256 e = int256(uint256(expiry)) + c.observationEndOffset;
        // forge-lint: disable-next-line(unsafe-typecast)
        start = s < 0 ? 0 : uint64(uint256(s)); // |offset| ≤ 7 days, expiry < 2^64 − 7 days in practice
        // forge-lint: disable-next-line(unsafe-typecast)
        end = e < 0 ? 0 : uint64(uint256(e));
    }

    function _earliest(SettlementOracleConfig storage c, uint64 expiry, uint64 end) private view returns (uint64) {
        uint64 byDelay = expiry + c.minFinalizationDelay;
        return byDelay > end ? byDelay : end + 1; // every round with updatedAt ≤ end is on chain once now > end
    }

    /// @dev Proofs must establish the in-force rounds (reverts otherwise). `valid` reports whether the proven
    ///      observation is usable; an invalid-but-proven primary is what makes the fallback eligible.
    function _evaluate(FeedSource storage s, uint32 maxSkew, RoundProof[] memory proofs, uint64 start, uint64 end)
        private
        view
        returns (bool valid, uint256 priceWad, uint64 observationTime)
    {
        if (s.kind == FeedKind.DIRECT) {
            if (proofs.length != 1) revert InvalidSettlementProof(P_PROOF_COUNT);
            return _leg(s.feed, s.feedDecimals, proofs[0], start, end);
        }
        if (proofs.length != 2) revert InvalidSettlementProof(P_PROOF_COUNT);
        (bool okU, uint256 pU, uint64 tsU) = _leg(s.feed, s.feedDecimals, proofs[0], start, end);
        (bool okS, uint256 pS, uint64 tsS) = _leg(s.quoteFeed, s.quoteFeedDecimals, proofs[1], start, end);
        if (!okU || !okS) return (false, 0, 0);
        uint64 skew = tsU > tsS ? tsU - tsS : tsS - tsU;
        if (skew > maxSkew) return (false, 0, 0);
        // underlying/asset = (underlying/USD) / (asset/USD), rounded half up; pS > 0 for a valid leg
        priceWad = M.fullMulDiv(pU, 1e18, pS);
        if (mulmod(pU, 1e18, pS) * 2 >= pS) priceWad += 1;
        if (priceWad == 0) return (false, 0, 0);
        return (true, priceWad, tsU > tsS ? tsU : tsS);
    }

    function _leg(address feed, uint8 feedDecimals, RoundProof memory proof, uint64 start, uint64 end)
        private
        view
        returns (bool valid, uint256 priceWad, uint64 updatedAt)
    {
        int256 answer;
        (answer, updatedAt) = _inForce(feed, proof, end);
        if (answer <= 0 || updatedAt < start) return (false, 0, updatedAt);
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok, uint256 price) = _tryMul(uint256(answer), 10 ** (18 - uint256(feedDecimals))); // answer > 0
        if (!ok) return (false, 0, updatedAt);
        return (true, price, updatedAt);
    }

    /// @dev Proves `proof.roundId` is the round in force at `observationEnd`.
    function _inForce(address feed, RoundProof memory proof, uint64 observationEnd)
        private
        view
        returns (int256 answer, uint64 updatedAt)
    {
        (bool ok, int256 a, uint256 u) = _tryRound(feed, proof.roundId);
        if (!ok) revert InvalidSettlementProof(P_ROUND_UNAVAILABLE);
        if (u > observationEnd) revert InvalidSettlementProof(P_ROUND_AFTER_OBSERVATION);

        if (proof.nextRoundId == 0) {
            uint80 latestId;
            try IAggregatorV3(feed).latestRoundData() returns (uint80 id, int256, uint256, uint256, uint80) {
                latestId = id;
            } catch {
                revert InvalidSettlementProof(P_NOT_LATEST_ROUND);
            }
            if (latestId != proof.roundId) revert InvalidSettlementProof(P_NOT_LATEST_ROUND);
        } else {
            (bool okNext,, uint256 uNext) = _tryRound(feed, proof.nextRoundId);
            if (!okNext) revert InvalidSettlementProof(P_SUCCESSOR_UNAVAILABLE);
            if (!isImmediateSuccessor(feed, proof.roundId, proof.nextRoundId)) {
                revert InvalidSettlementProof(P_NOT_IMMEDIATE_SUCCESSOR);
            }
            if (uNext <= observationEnd) revert InvalidSettlementProof(P_SUCCESSOR_NOT_AFTER);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (a, uint64(u)); // u ≤ observationEnd < 2^64
    }

    /// @dev ok is false if the call reverts, updatedAt == 0, or the feed returns another round.
    function _tryRound(address feed, uint80 id) private view returns (bool ok, int256 answer, uint256 updatedAt) {
        if (id == 0) return (false, 0, 0);
        try IAggregatorV3(feed).getRoundData(id) returns (
            uint80 returnedId, int256 a, uint256, uint256 u, uint80 answeredInRound
        ) {
            if (u == 0 || returnedId != id || answeredInRound < id) return (false, 0, 0);
            return (true, a, u);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev a > 0 (a valid answer), so the division check is safe.
    function _tryMul(uint256 a, uint256 b) private pure returns (bool, uint256) {
        unchecked {
            uint256 c = a * b;
            return c / a == b ? (true, c) : (false, 0);
        }
    }

    function _stored(bytes32 configId) private view returns (StoredConfig storage s) {
        s = _s().configs[configId];
        if (!s.exists) revert UnknownSettlementConfig(configId);
    }

    function _s() private pure returns (SettlementOracleStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
