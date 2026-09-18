# Contract Interfaces

## Purpose

This file defines the Solidity-facing interfaces for the V1 implementation. Function names may change during implementation only if this file is updated at the same time.

Fee semantics behind the `FeeConfig` fields and the fee-bearing return values are defined in [fee-spec.md](./fee-spec.md). Rate and collateral math is normative in [math-of-core-invariants.md](./math-of-core-invariants.md).

## Shared Types

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum OptionType {
    CALL,
    PUT
}

enum SeriesState {
    ACTIVE,
    SETTLED
}

enum OracleStatus {
    VALID,
    STALE,
    INVALID,
    DEVIATION_TOO_HIGH,
    MISSING_REQUIRED_SOURCE
}

struct OracleConfig {
    address chainlinkFeed;
    bytes32 pythFeedId;
    address dexTwapAdapter;
    bool requireChainlink;
    bool requirePyth;
    bool requireDexTwap;
    uint32 maxOracleDeviationBps;
    uint32 chainlinkStaleAfter;
    uint32 pythStaleAfter;
    uint32 dexTwapStaleAfter;
}

struct FeeConfig {
    uint16 mintFeeBps;      // <= MAX_MINT_FEE_BPS
    uint16 exerciseFeeBps;  // <= MAX_EXERCISE_FEE_BPS
    uint16 residualFeeBps;  // <= MAX_RESIDUAL_FEE_BPS, V1 default 0
}

struct SeriesParams {
    bytes32 seriesId;
    OptionType optionType;
    address underlying;
    address quote;
    address collateralAsset;
    uint256 strikePrice;
    uint64 expiry;
    uint256 contractSize;
    uint8 optionDecimals;
    uint256 minOptionAmount;
    OracleConfig oracleConfig;
    FeeConfig feeConfig;        // snapshotted at creation, immutable thereafter
    uint256 collateralPerOption; // derived at creation, immutable
    uint256 uqScale;             // derived at creation, immutable
    string name;
    string symbol;
}

struct SettlementResult {
    bool settled;
    uint256 settlementPrice;
    uint256 buyerPayoutRate;
    uint256 writerResidualRate;
    uint64 settledAt;
}

struct KuruMarketConfig {
    address market;
    address baseAsset;
    address quoteAsset;
    uint96 sizePrecision;
    uint32 pricePrecision;
    uint32 tickSize;
    uint96 minSize;
    uint96 maxSize;
    uint256 takerFeeBps;
    uint256 makerFeeBps;
    uint96 kuruAmmSpread;
}

struct PremiumCheckParams {
    bytes32 seriesId;
    address market;
    uint256 optionAmount;
    uint256 writerAskPremium;
    uint256 buyerMaxTotalPremium;   // binds on all-in cost, not gross premium
    uint256 buyerMinOptionAmount;
    uint256 deadline;
}

struct PremiumCheckResult {
    bool valid;
    uint256 acceptableMinPremium;
    uint256 acceptableMaxPremium;
    uint256 estimatedGrossPremium;
    uint256 estimatedKuruTakerFee;
    uint256 estimatedAllInCost;      // grossPremium + venue fee + route fee
    uint256 estimatedPriceImpactBps;
    uint256 estimatedSpreadBps;
    string reason;
}
```

## `ISeriesRegistry`

```solidity
interface ISeriesRegistry {
    event SeriesRegistered(bytes32 indexed seriesId, address indexed vault, address indexed optionToken);
    event KuruMarketLinked(bytes32 indexed seriesId, address indexed market, address baseAsset, address quoteAsset);

    function registerSeries(SeriesParams calldata params, address vault, address optionToken) external;
    function linkKuruMarket(bytes32 seriesId, KuruMarketConfig calldata config) external;

    function isSeries(bytes32 seriesId) external view returns (bool);
    function isOptionToken(address token) external view returns (bool);
    function getSeries(bytes32 seriesId) external view returns (SeriesParams memory);
    function getVault(bytes32 seriesId) external view returns (address);
    function getOptionToken(bytes32 seriesId) external view returns (address);
    function getSeriesByToken(address optionToken) external view returns (bytes32);
    function getKuruMarket(bytes32 seriesId) external view returns (KuruMarketConfig memory);
}
```

## `IOptionSeriesFactory`

```solidity
interface IOptionSeriesFactory {
    event SeriesCreated(
        bytes32 indexed seriesId,
        address indexed vault,
        address indexed optionToken,
        OptionType optionType,
        address underlying,
        address quote,
        uint256 strikePrice,
        uint64 expiry
    );

    function createSeries(SeriesParams calldata params) external returns (bytes32 seriesId, address vault);
    function computeSeriesId(SeriesParams calldata params) external view returns (bytes32);
}
```

## `IOptionSeriesVault`

```solidity
interface IOptionSeriesVault {
    event OptionsMinted(bytes32 indexed seriesId, address indexed writer, address indexed receiver, uint256 optionAmount, uint256 collateralAmount, uint256 feeAmount);
    event SeriesSettled(bytes32 indexed seriesId, uint256 settlementPrice, uint256 buyerPayoutRate, uint256 writerResidualRate);
    event OptionsRedeemed(bytes32 indexed seriesId, address indexed holder, address indexed receiver, uint256 optionAmount, uint256 payoutAmount, uint256 feeAmount);
    event WriterResidualClaimed(bytes32 indexed seriesId, address indexed writer, address indexed receiver, uint256 shortAmount, uint256 residualAmount, uint256 feeAmount);
    event FeesSwept(bytes32 indexed seriesId, address indexed receiver, uint256 amount);
    event DustSwept(bytes32 indexed seriesId, address indexed receiver, uint256 amount);
    event SeriesPaused(bytes32 indexed seriesId, bytes32 indexed reason);
    event SeriesUnpaused(bytes32 indexed seriesId);

    function seriesParams() external view returns (SeriesParams memory);
    function settlementResult() external view returns (SettlementResult memory);

    function mint(uint256 optionAmount, address receiver) external returns (uint256 collateralAmount, uint256 feeAmount);
    function settle(bytes calldata pythUpdateData) external payable returns (uint256 settlementPrice);
    function redeem(uint256 optionAmount, address receiver) external returns (uint256 payoutAmount, uint256 feeAmount);
    function claimWriterResidual(uint256 shortAmount, address receiver) external returns (uint256 residualAmount, uint256 feeAmount);

    function sweepFees(address receiver) external returns (uint256 amount);
    function sweepDust(address receiver) external returns (uint256 amount);

    function previewRequiredCollateral(uint256 optionAmount) external view returns (uint256 collateralAmount, uint256 feeAmount);
    function previewRedeem(uint256 optionAmount) external view returns (uint256 payoutAmount, uint256 feeAmount);
    function previewWriterResidual(uint256 shortAmount) external view returns (uint256 residualAmount, uint256 feeAmount);

    function writerShortBalance(address writer) external view returns (uint256);
    function totalShortAmount() external view returns (uint256);
    function totalUnclaimedShortAmount() external view returns (uint256);
    function collateralLocked() external view returns (uint256);
    function accruedFees() external view returns (uint256);
}
```

## `IOracleRouter`

```solidity
interface IOracleRouter {
    event OraclePriceAccepted(bytes32 indexed seriesId, uint256 price, uint256 chainlinkPrice, uint256 pythPrice, uint256 dexTwapPrice);
    event OraclePriceRejected(bytes32 indexed seriesId, OracleStatus status, string reason);

    function getSettlementPrice(bytes32 seriesId, OracleConfig calldata config, bytes calldata pythUpdateData)
        external
        payable
        returns (uint256 price);

    function getReferencePrice(bytes32 seriesId, OracleConfig calldata config, bytes calldata pythUpdateData)
        external
        payable
        returns (uint256 price);

    function previewReferencePrice(bytes32 seriesId, OracleConfig calldata config)
        external
        view
        returns (uint256 price, OracleStatus status);
}
```

## `IOracleAdapter`

```solidity
interface IOracleAdapter {
    struct PriceData {
        uint256 price;
        uint64 updatedAt;
        uint8 decimals;
        bool valid;
    }

    function read(address base, address quote, bytes calldata data) external payable returns (PriceData memory);
    function peek(address base, address quote) external view returns (PriceData memory);
}
```

## `IProtocolConfig`

```solidity
interface IProtocolConfig {
    event AssetAllowed(address indexed asset, bool allowed);
    event OracleConfigApproved(bytes32 indexed configHash, bool approved);
    event DefaultFeesUpdated(uint16 mintFeeBps, uint16 exerciseFeeBps, uint16 residualFeeBps);
    event FeeRecipientUpdated(address indexed recipient);

    function isAllowedAsset(address asset) external view returns (bool);
    function isApprovedOracleConfig(bytes32 configHash) external view returns (bool);

    // Read by the factory at creation time and snapshotted into the series.
    function defaultFeeConfig() external view returns (FeeConfig memory);

    // Read live at sweep time; never snapshotted, so a compromised treasury can be rotated.
    function feeRecipient() external view returns (address);

    function setDefaultFeeConfig(FeeConfig calldata config) external;
    function setFeeRecipient(address recipient) external;
}
```

`setDefaultFeeConfig` must revert with `FeeExceedsCap` if any rate exceeds its compile-time cap, and affects only series created after the call.

## `IPremiumExecutionGuard`

**V1 scope: this contract is validation-only.** It does not hold funds, does not execute trades, and cannot force any buyer's transaction through itself. It exists so the official frontend and any future router share one audited implementation of the acceptable-range and market-health rules.

Buyer price protection in V1 comes from Kuru's own limit-order parameters, which are enforced onchain by Kuru. The guard's checks are advisory relative to a user who trades directly against Kuru. See Invariant 13 in [math-of-core-invariants.md](./math-of-core-invariants.md) for the full layering and [premium-pricing-spec.md](./premium-pricing-spec.md) for what each layer can and cannot guarantee.

```solidity
interface IPremiumExecutionGuard {
    event PremiumRouteRejected(bytes32 indexed seriesId, address indexed market, string reason);

    /// @notice Validates a prospective route. Reverts on failure so a future router
    ///         can call it as an atomic precondition; returns the populated result on success.
    function checkPremium(PremiumCheckParams calldata params, bytes calldata oracleData)
        external
        payable
        returns (PremiumCheckResult memory);

    /// @notice Non-reverting variant for frontend display. Returns valid == false with a reason
    ///         instead of reverting, so a UI can explain why a route is unsafe.
    function previewPremium(PremiumCheckParams calldata params)
        external
        view
        returns (PremiumCheckResult memory);
}
```

The two functions differ deliberately: `checkPremium` reverts so it composes as a precondition, while `previewPremium` returns a reason string so the UI can tell a user *why* a trade is blocked rather than showing an opaque failure.

## `IKuruMarketAdapter`

```solidity
interface IKuruMarketAdapter {
    event KuruMarketCreated(bytes32 indexed seriesId, address indexed market);
    event KuruMarketValidated(bytes32 indexed seriesId, address indexed market);

    function deployMarket(bytes32 seriesId, KuruMarketConfig calldata config) external returns (address market);
    function validateMarket(bytes32 seriesId, address market) external view returns (bool);
}
```

## Required Custom Errors

```solidity
error ZeroAddress();
error InvalidAsset();
error InvalidDecimals();
error InvalidOptionType();
error InvalidStrike();
error InvalidExpiry();
error InvalidContractSize();
error InvalidOracleConfig();
error DuplicateSeries(bytes32 seriesId);
error NotFactory();
error NotRegistry();
error NotSeries();
error NotSettled();
error AlreadySettled();
error Expired();
error NotExpired();
error AmountTooSmall();
error InsufficientCollateral();
error InsufficientOptionBalance();
error InsufficientShortBalance();
error OracleInvalid();
error OracleStale();
error OracleDeviationTooHigh();
error KuruMarketInvalid();
error KuruFeeTooHigh();
error PremiumOutOfRange();
error BuyerLimitExceeded();
error DeadlineExpired();
error Paused(bytes32 reason);
error FeeExceedsCap();
error NoFeesAccrued();
error SeriesNotWoundDown();
error NotFeeAdmin();
```

