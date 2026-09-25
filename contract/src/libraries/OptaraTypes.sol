// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Shared Optara V2 types. Economic meaning follows OPTION_SPEC.md sections 5-9 and MATH.md section 5.

/// @dev CALL = 0, PUT = 1. Any other value is rejected by ABI decoding.
enum OptionType {
    CALL,
    PUT
}

/// @notice Source of the long token consumed by a close or unfinalized cancellation (PROTOCOL_SPEC.md section 16).
/// EXTERNAL: the caller supplies identical long tokens from its own balance in the same call.
/// LOCKED: the caller's own locked hedge in the identical series is consumed. Never implicit.
enum CloseSource {
    EXTERNAL,
    LOCKED
}

/// @notice Per-asset incident state (LIQUIDATION.md sections 101-102, STATE_MACHINE.md section 8).
enum AssetStatus {
    NORMAL,
    RESTRICTED,
    WIND_DOWN
}

/// @notice Economic series lifecycle (STATE_MACHINE.md section 18). CLEARED is derived off-chain.
enum SeriesStatus {
    NONE,
    ACTIVE,
    EXPIRED_UNSETTLED,
    SETTLED
}

/// @notice Pair lifecycle (STATE_MACHINE.md section 10).
enum PairStatus {
    UNAPPROVED,
    ENABLED,
    NEW_RISK_DISABLED,
    RETIRED
}

/// @notice Oracle configuration lifecycle (STATE_MACHINE.md section 16).
enum OracleConfigStatus {
    NONE,
    APPROVED_FOR_NEW_SERIES,
    SUSPENDED_FOR_NEW_SERIES,
    RETIRED
}

/// @notice Exposure-cap scopes (PROTOCOL_SPEC.md section 42). SERIES limits apply to every series of a pair.
enum ExposureScope {
    SERIES,
    PAIR,
    ORACLE_CONFIG,
    ASSET
}

/// @notice One position line of an account risk group, in the exact units of MATH.md section 24.
struct Leg {
    OptionType optionType;
    uint256 strikeWad;
    uint256 capWad;
    uint256 contractSizeWad;
    uint256 shortQty;
    uint256 lockedQty;
}

/// @notice Immutable series terms stored by the core at registration (OPTION_SPEC.md section 5).
struct Series {
    address underlying;
    address settlementAsset;
    address optionToken;
    uint64 expiry;
    OptionType optionType;
    uint8 assetDecimals;
    bytes32 oracleConfigId;
    bytes32 groupId;
    bytes32 pairId;
    uint256 strikeWad;
    uint256 capWad;
    uint256 contractSizeWad;
    uint256 quantityIncrement;
}

/// @notice Series-level supply and exposure accounting (MATH.md sections 56-58, PROTOCOL_SPEC.md section 42).
/// openShortQty is O_i; minted M_i; closed C_i (active closes + unfinalized cancellations); redeemed R_i;
/// hedgeConsumed H_i; shortSynced S_i. exposureN is the exact max-payoff numerator of outstanding long supply.
struct SeriesState {
    uint256 openShortQty;
    uint256 exposureN;
    uint256 minted;
    uint256 closed;
    uint256 redeemed;
    uint256 hedgeConsumed;
    uint256 shortSynced;
}

/// @notice Risk group = (underlying, expiry, settlementAsset, oracleConfigId), MATH.md section 15.
/// bufferBps and fixedBufferNative are snapshotted at creation (MATH.md section 25).
struct Group {
    address underlying;
    uint64 expiry;
    address settlementAsset;
    uint8 assetDecimals;
    bool exists;
    bool finalized;
    bool released;
    uint16 bufferBps;
    uint64 finalizedAt;
    uint64 observationTimestamp;
    bytes32 oracleConfigId;
    bytes32 pairId;
    uint256 fixedBufferNative;
    uint256 exposureN;
    uint256 settlementPriceWad;
}

struct Position {
    uint256 shortQty;
    uint256 lockedQty;
}

/// @notice Incident record per settlement asset. rhoWad is set once, only via the timelocked resolution.
struct AssetIncident {
    AssetStatus status;
    uint64 pendingEta;
    uint256 rhoWad;
    uint256 pendingRhoWad;
    bytes32 pendingReference;
}

/// @notice Series parameter bounds for a pair. quantityIncrement is snapshotted into each series.
struct SeriesBounds {
    uint256 minStrikeWad;
    uint256 maxStrikeWad;
    uint256 minCapWad;
    uint256 maxCapWad;
    uint256 minContractSizeWad;
    uint256 maxContractSizeWad;
    uint64 minTimeToExpiry;
    uint64 maxTimeToExpiry;
    uint256 quantityIncrement;
}

/// @notice Immutable oracle configuration (ORACLE_AND_SETTLEMENT.md sections 6-7, 15-19, 119).
struct OracleConfig {
    address underlying;
    address settlementAsset;
    address adapter;
    int64 observationStartOffset;
    int64 observationEndOffset;
    uint64 minFinalizationDelay;
    uint64 maxFinalizationDelay;
    bytes32 ruleVersion;
    bytes sourceParams;
}

/// @notice Action bits used by scoped pauses (PROTOCOL_SPEC.md section 29, STATE_MACHINE.md section 3).
library Actions {
    uint256 internal constant DEPOSIT = 1 << 0;
    uint256 internal constant WITHDRAW = 1 << 1;
    uint256 internal constant WRITE = 1 << 2;
    uint256 internal constant CLOSE = 1 << 3; // closeShort and cancelUnfinalizedShort
    uint256 internal constant LOCK = 1 << 4;
    uint256 internal constant UNLOCK = 1 << 5;
    uint256 internal constant FINALIZE = 1 << 6;
    uint256 internal constant SYNC = 1 << 7;
    uint256 internal constant REDEEM = 1 << 8;
    uint256 internal constant SERIES_CREATION = 1 << 9;
    uint256 internal constant ALL = (1 << 10) - 1;
}
