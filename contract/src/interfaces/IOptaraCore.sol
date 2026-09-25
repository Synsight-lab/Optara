// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    Series,
    SeriesState,
    Group,
    Position,
    Leg,
    OptionType,
    CloseSource,
    AssetStatus,
    SeriesStatus,
    ExposureScope
} from "../libraries/OptaraTypes.sol";

/// @notice Canonical events and errors of the Optara V2 core (PROTOCOL_SPEC.md section 33, LIQUIDATION.md section 92).
interface IOptaraCoreEvents {
    event CoreSealed(address indexed seriesFactory);
    event GroupCreated(
        bytes32 indexed groupId,
        address indexed underlying,
        address indexed settlementAsset,
        uint64 expiry,
        bytes32 oracleConfigId,
        uint16 bufferBps,
        uint256 fixedBufferNative
    );
    event SeriesCreated(
        bytes32 indexed seriesId,
        bytes32 indexed groupId,
        address indexed optionToken,
        address underlying,
        address settlementAsset,
        OptionType optionType,
        uint256 strikeWad,
        uint256 capWad,
        uint256 contractSizeWad,
        uint64 expiry,
        bytes32 oracleConfigId,
        uint256 quantityIncrement
    );
    event CollateralDeposited(address indexed account, address indexed asset, uint256 amount, bool cure);
    event CollateralWithdrawn(
        address indexed account, address indexed asset, address indexed recipient, uint256 amount, uint256 paid
    );
    event Recapitalized(address indexed asset, address indexed from, uint256 amount);
    event OptionWritten(
        address indexed account,
        bytes32 indexed seriesId,
        address indexed recipient,
        uint256 quantity,
        uint256 exposureN
    );
    event ShortClosed(address indexed account, bytes32 indexed seriesId, uint256 quantity, CloseSource source);
    event ShortCancelledUnfinalized(
        address indexed account, bytes32 indexed seriesId, uint256 quantity, CloseSource source
    );
    event LongLocked(address indexed account, bytes32 indexed seriesId, uint256 quantity);
    event LongUnlocked(address indexed account, bytes32 indexed seriesId, address indexed recipient, uint256 quantity);
    /// @param oracleDataHash keccak256 of the verified provider proof, as audit evidence (ORACLE section 64)
    event RiskGroupFinalized(
        bytes32 indexed groupId,
        bytes32 indexed oracleConfigId,
        address indexed settlementAsset,
        uint256 settlementPriceWad,
        uint64 observationTimestamp,
        address finalizer,
        uint256 releasedExposureN,
        bytes32 oracleDataHash
    );
    event RiskGroupSynced(
        address indexed account,
        bytes32 indexed groupId,
        address indexed settlementAsset,
        uint256 shortNumerator,
        uint256 lockedLongNumerator,
        int256 netCashDeltaNative,
        address caller
    );
    event LongRedeemed(
        address indexed account,
        address indexed recipient,
        bytes32 indexed seriesId,
        uint256 quantity,
        address settlementAsset,
        uint256 payoutNative,
        uint256 paidNative
    );
    event AssetRestricted(
        address indexed asset, address indexed account, uint256 deficitNative, bytes32 reason, address caller
    );
    event AssetRestrictionCleared(address indexed asset, bytes32 reconciliationRef, address caller);
    event ShortfallResolutionProposed(address indexed asset, uint256 rhoWad, uint64 eta, bytes32 reconciliationRef);
    event ShortfallResolutionCancelled(address indexed asset, address caller);
    event ShortfallResolved(address indexed asset, uint256 rhoWad, bytes32 reconciliationRef);
}

interface IOptaraCoreErrors {
    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized(address caller);
    error AlreadySealed();
    error NotSealed();
    error OnlySeriesFactory(address caller);
    error UnknownSeries(bytes32 seriesId);
    error SeriesAlreadyExists(bytes32 seriesId);
    error InvalidSeriesRegistration();
    error UnknownGroup(bytes32 groupId);
    error UnknownAsset(address asset);
    error InvalidRecipient(address recipient);
    error SeriesNotActive(bytes32 seriesId);
    error SeriesNotExpired(bytes32 seriesId);
    error GroupAlreadyFinalized(bytes32 groupId);
    error GroupNotFinalized(bytes32 groupId);
    error FinalizationTooEarly(uint256 earliest);
    error ActionPaused(uint256 action);
    error NewRiskDisabled();
    error AssetIsRestricted(address asset);
    error AssetInWindDown(address asset);
    error QuantityGranularity(uint256 quantity, uint256 increment);
    error InsufficientCash(uint256 requested, uint256 available);
    error InsufficientMargin(uint256 required, uint256 available);
    error InsufficientShort(uint256 requested, uint256 available);
    error InsufficientLocked(uint256 requested, uint256 available);
    error PositionLimitReached();
    error ExposureLimitExceeded(ExposureScope scope, uint256 newExposureN, uint256 limitN);
    error NonExactTransfer(uint256 expected, uint256 received);
    error SettlementDeficit(address account, bytes32 groupId, uint256 cash, uint256 debit);
    error CureDepositExceedsDeficit(uint256 amount, uint256 deficit);
    error AssetNotRestricted(address asset);
    error InvalidRho(uint256 rhoWad);
    error ShortfallResolutionExists(address asset);
    error NoPendingResolution(address asset);
    error ResolutionTimelocked(uint64 eta);
    error InvalidDelay();
}

/// @notice Surface of the core used by the SeriesFactory, clients and tests.
interface IOptaraCore is IOptaraCoreEvents, IOptaraCoreErrors {
    struct AccountRiskState {
        uint256 cash;
        int256 effectiveCash;
        uint256 requiredMargin;
        uint256 freeCollateral;
        uint256 deficit;
        bool hasUnsyncedMaturedGroups;
        AssetStatus assetStatus;
    }

    // wiring
    function registerSeries(bytes32 seriesId, Series calldata s) external;
    function protocolSeriesDomain() external view returns (bytes32);
    function computeSeriesId(
        address underlying,
        address settlementAsset,
        OptionType optionType,
        uint256 strikeWad,
        uint256 capWad,
        uint256 contractSizeWad,
        uint64 expiry,
        bytes32 oracleConfigId
    ) external view returns (bytes32);
    function computeGroupId(address underlying, uint64 expiry, address settlementAsset, bytes32 oracleConfigId)
        external
        view
        returns (bytes32);
    function seriesExists(bytes32 seriesId) external view returns (bool);

    // user entry points
    function deposit(address asset, uint256 amount) external;
    function recapitalize(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount, address recipient) external;
    function write(bytes32 seriesId, uint256 quantity, address recipient) external;
    function closeShort(bytes32 seriesId, uint256 quantity, CloseSource source) external;
    function cancelUnfinalizedShort(bytes32 seriesId, uint256 quantity, CloseSource source) external;
    function lockLong(bytes32 seriesId, uint256 quantity) external;
    function unlockLong(bytes32 seriesId, uint256 quantity, address recipient) external;
    function syncRiskGroup(address account, bytes32 groupId) external returns (bool synced);
    function syncAccount(address account, address asset) external returns (uint256 groupsSynced);
    function finalizeRiskGroup(bytes32 groupId, bytes calldata oracleData) external payable returns (uint256);
    function redeem(bytes32 seriesId, uint256 quantity, address recipient) external returns (uint256 paid);

    // containment
    function checkAndRestrict(address account, address asset) external returns (bool restricted);
    function restrictAsset(address asset, bytes32 reason) external;
    function clearAssetRestriction(address asset, bytes32 reconciliationRef) external;
    function proposeShortfallResolution(address asset, uint256 rhoWad, bytes32 reconciliationRef) external;
    function executeShortfallResolution(address asset) external;
    function cancelShortfallResolution(address asset) external;

    // views
    function getSeries(bytes32 seriesId) external view returns (Series memory);
    function getSeriesState(bytes32 seriesId) external view returns (SeriesState memory);
    function getGroup(bytes32 groupId) external view returns (Group memory);
    function positionOf(address account, bytes32 seriesId) external view returns (Position memory);
    function cashBalance(address account, address asset) external view returns (uint256);
    function accountGroups(address account) external view returns (bytes32[] memory);
    function accountGroupSeries(address account, bytes32 groupId) external view returns (bytes32[] memory);
    function accountGroupLegs(address account, bytes32 groupId) external view returns (Leg[] memory);
    function requiredMargin(address account, address asset) external view returns (uint256);
    function effectiveCash(address account, address asset) external view returns (int256);
    function freeCollateral(address account, address asset) external view returns (uint256);
    function deficit(address account, address asset) external view returns (uint256);
    function accountRiskState(address account, address asset) external view returns (AccountRiskState memory);
    function seriesStatus(bytes32 seriesId) external view returns (SeriesStatus);
    function isOracleStalled(bytes32 groupId) external view returns (bool);
    function assetStatus(address asset) external view returns (AssetStatus status, uint256 rhoWad);
}
