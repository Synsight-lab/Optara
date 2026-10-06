// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISettlementConfigs} from "./IExternalDependencies.sol";

/// @title ISettlementOracle
/// @notice Immutable settlement oracle configs and the round-in-force Chainlink settlement rule
///         (docs/ORACLES.md §5). Used only for expiry prices, never for margin.
interface ISettlementOracle is ISettlementConfigs {
    /// @dev DIRECT: one UNDERLYING/SETTLEMENT_ASSET feed. DERIVED: UNDERLYING/USD ÷ SETTLEMENT_ASSET/USD.
    enum FeedKind {
        NONE,
        DIRECT,
        DERIVED
    }

    struct FeedSource {
        FeedKind kind;
        address feed; // DIRECT: underlying/asset. DERIVED: underlying/USD.
        uint8 feedDecimals;
        address quoteFeed; // DERIVED only: asset/USD.
        uint8 quoteFeedDecimals;
    }

    /// @notice Precommitted and immutable once registered (its id is the hash of its contents).
    struct SettlementOracleConfig {
        address underlying;
        address settlementAsset;
        FeedSource primary;
        FeedSource fallbackSource; // kind NONE when there is no fallback
        int64 observationStartOffset; // e.g. −3600: a round must be at least this recent at expiry
        int64 observationEndOffset; // e.g. 0: the round in force at expiry + this offset
        uint64 minFinalizationDelay;
        uint64 maxFinalizationDelay; // ORACLE_STALLED after expiry + this
        uint32 maxLegSkew; // DERIVED: max |updatedAt(underlying leg) − updatedAt(quote leg)|
    }

    /// @dev nextRoundId == 0 means "roundId is the feed's latest round".
    struct RoundProof {
        uint80 roundId;
        uint80 nextRoundId;
    }

    /// @dev sourceIndex 0 = primary, 1 = fallback. Primary proofs are always required: using the fallback needs
    ///      a proof that the primary's in-force observation is invalid. DIRECT needs 1 proof, DERIVED 2.
    struct SettlementData {
        uint8 sourceIndex;
        RoundProof[] primaryProofs;
        RoundProof[] fallbackProofs;
    }

    event SettlementConfigRegistered(bytes32 indexed configId, SettlementOracleConfig config);
    event SettlementConfigApproved(bytes32 indexed configId, bool approved);

    function registerConfig(SettlementOracleConfig calldata config) external returns (bytes32 configId);
    function setConfigApproved(bytes32 configId, bool approved) external;

    /// @notice The settlement price for an expiry, proven from feed history. Deterministic: exactly one round per
    ///         feed satisfies the proof, so the caller can't choose the price.
    /// @return priceWad Settlement asset per underlying, WAD (unclamped; SettlementWindow applies the group cap).
    /// @return observationTime The proven round's updatedAt (the later leg for DERIVED).
    /// @return sourceUsed 0 primary, 1 fallback.
    function verify(bytes32 configId, uint64 expiry, bytes calldata settlementData)
        external
        view
        returns (uint256 priceWad, uint64 observationTime, uint8 sourceUsed);

    function getConfig(bytes32 configId) external view returns (SettlementOracleConfig memory);
    function configExists(bytes32 configId) external view returns (bool);
    function isConfigApproved(bytes32 configId) external view returns (bool);
    function computeConfigId(SettlementOracleConfig calldata config) external pure returns (bytes32);
    /// @notice max(expiry + minFinalizationDelay, observation end + 1).
    function earliestFinalization(bytes32 configId, uint64 expiry) external view returns (uint64);
    /// @notice expiry + maxFinalizationDelay: after this the group is flagged ORACLE_STALLED if not finalized.
    function stalledAfter(bytes32 configId, uint64 expiry) external view returns (uint64);
}
