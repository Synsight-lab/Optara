// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Every custom error in Optara PM (docs/PROTOCOL_SPEC.md §13). Declared once at file level so every module reverts
// with the same selectors and integrators decode one list.

// ---- Access and input ----
error NotAuthorized(address caller);
error ZeroAmount();
error ZeroAddress();
error NotAContract(address account);
error InvalidRecipient();
error UnknownSeries(bytes32 seriesId);
error UnknownAccount(uint256 accountId);
error AssetMismatch();
error AssetNotApproved(address asset);
error UnsupportedDecimals(uint8 decimals);

// ---- Products and series ----
error InvalidProductConfig(uint8 reason);
error ProductNotEnabled(bytes32 productId);
error InvalidSeriesParams(uint8 reason);
error SeriesExists(bytes32 seriesId);
error GroupFull(bytes32 groupId);

// ---- Lifecycle ----
error SeriesNotActive(bytes32 seriesId);
error GroupFinalized(bytes32 groupId);
error GroupNotFinalized(bytes32 groupId);

// ---- Risk gates ----
error ProductCloseOnly(bytes32 productId);
error InsuranceBelowMinimum(address asset);
error ActionPaused(uint8 bit);
error InvalidScope();
error InvalidPauseBits(uint256 bits);
error StaleSpot(bytes32 productId, uint64 age);
error StaleSurface(bytes32 productId, uint64 age);
error MissingSurfaceNode(bytes32 productId, uint8 tenorIndex, uint8 nodeIndex);
error SeriesNotPriceable(bytes32 seriesId);

// ---- Positions and cash ----
error InsufficientCash(uint256 needed, uint256 available);
error NotHealthy(int256 equity, uint256 initialMargin);
error InsufficientShort(int256 balance, uint256 qty);
error InsufficientLong(int256 balance, uint256 qty);
error PositionLimit();
error PositionBelowMinimum(int256 balance);
error InvalidLimits();
error OpenInterestCap(bytes32 key);
error InvalidRiskParams(uint8 reason);
error UnknownRiskSet(bytes32 riskParameterSetId);
error RiskSetExists(bytes32 riskParameterSetId);
error RiskSetAlreadyAssigned(bytes32 productId);

// ---- Fees and venues ----
error FeeTooHigh(uint256 fee, uint256 max);
error InvalidFeeConfig(uint8 reason);
error InsufficientTreasury(uint256 requested, uint256 available);
error TokensNotReceived(uint256 expected, uint256 available);
error DeadlineExpired();
error SlippageExceeded();
error MarketNotVerified();

// ---- Liquidation ----
error NotLiquidatable(int256 equity, uint256 maintenanceMargin);
error AuctionNotActive();
error AuctionActive();
error SliceOutOfBounds(uint16 sliceBps);
error HealthNotImproved();

// ---- Settlement ----
error NotParticipant(uint256 accountId, bytes32 groupId);
error SettlementIncomplete(uint256 participantsLeft);
error RatioAlreadySet();
error RatioNotSet();
error NothingToClaim();

// ---- Oracles ----
error InvalidSpotSource(uint8 reason);
error InvalidSpotPrice(bytes32 productId);
error InsufficientProviderFee(uint256 required, uint256 provided);
error RefundFailed();
error InvalidSurfaceReport(uint8 reason);
error InvalidSignatures();
error InvalidSurfaceConfig(uint8 reason);
error InvalidPublisher(address publisher);
error InvalidSettlementProof(uint8 reason);
error FinalizationTooEarly(uint64 earliest);
error InvalidSettlementConfig(uint8 reason);
error UnknownSettlementConfig(bytes32 configId);
error SettlementConfigExists(bytes32 configId);

// ---- Tokens ----
error NonExactTransfer(uint256 expected, uint256 received);

// ---- Upgrades ----
error InvalidDelay(uint256 delay);
error UnknownProxy(address proxy);
error ImplementationNotAllowed(bytes32 codeHash);
error UnknownUpgrade(bytes32 id);
error UpgradeNotPending(bytes32 id);
error UpgradeNotReady(uint64 eta);
error CodeHashMismatch(bytes32 expected, bytes32 actual);
