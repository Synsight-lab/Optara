# Contract Interfaces

## Purpose

This file defines the Solidity-facing interfaces for the V1 implementation. Function names may change during implementation only if this file is updated at the same time.

Fee semantics behind the `FeeConfig` fields and the fee-bearing return values are defined in [fee-spec.md](./fee-spec.md). Rate and collateral math is normative in [math-of-core-invariants.md](./math-of-core-invariants.md).

## Design Rule Behind These Signatures

One rule explains most of the choices below:

```text
A value that must be immutable or derived is never a function argument.
The callee reads it from authoritative state.
```

Anything passed as an argument can be chosen by the caller. So series identity, derived scales, fee rates, and oracle configuration are read from the registry, the vault's own storage, or `ProtocolConfig` — never accepted from whoever happens to be calling. Violating this rule is how a caller ends up choosing their own fee rate or settling under weakened oracle rules.

## Units

Every numeric field below carries its unit in a comment. The two kinds of number never mix:

```text
raw units    integer token amounts as the ERC-20 stores them
PRICE_SCALE  human price of 1 whole underlying in whole quote, times 1e18
```

See [math-of-core-invariants.md](./math-of-core-invariants.md) for the full unit model.

## Shared Types

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

uint256 constant PRICE_SCALE = 1e18;
uint256 constant BPS_SCALE = 10_000;

// Hard fee caps. Compile-time constants; governance cannot exceed them.
uint16 constant MAX_MINT_FEE_BPS = 100;
uint16 constant MAX_EXERCISE_FEE_BPS = 100;

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

/// @notice Pause flags owned by the vault. Flags owned by other contracts
///         live on those contracts; see ISeriesRegistry and IPremiumExecutionGuard.
enum VaultPause {
    MINT,
    SETTLEMENT,
    REDEMPTION
}

struct OracleConfig {
    address chainlinkFeed;          // aggregator address, address(0) if unused
    bytes32 pythFeedId;             // Pyth price id, bytes32(0) if unused
    bool requireChainlink;
    bool requirePyth;
    uint32 maxOracleDeviationBps;   // bps
    uint32 chainlinkStaleAfter;     // seconds; REFERENCE reads only, never settlement
    uint32 pythStaleAfter;          // seconds; REFERENCE reads only, never settlement
    uint32 maxSettlementLag;        // seconds past expiry the settlement anchor may sit
}

/// @notice Identifies the oracle observation at expiry. Settlement is anchored to it
///         so that the price does not depend on when settle() happens to be called.
struct SettlementProof {
    uint80 chainlinkRoundId;  // the FIRST round with updatedAt >= expiry
    bytes pythUpdateData;     // Pyth update(s) bracketing expiry
}

struct FeeConfig {
    uint16 mintFeeBps;      // bps, <= MAX_MINT_FEE_BPS
    uint16 exerciseFeeBps;  // bps, <= MAX_EXERCISE_FEE_BPS
}

/// @notice Caller-supplied inputs to series creation.
/// @dev Deliberately excludes seriesId, collateralAsset, feeConfig, collateralPerOption,
///      and uqScale. Those are derived or snapshotted by the factory. A caller must never
///      be able to choose them: a caller-chosen feeConfig defeats protocol fees entirely,
///      and a caller-chosen collateralPerOption breaks solvency.
struct CreateSeriesParams {
    OptionType optionType;
    address underlying;
    address quote;
    uint256 strikePrice;        // PRICE_SCALE
    uint64 expiry;              // unix seconds
    uint256 contractSize;       // underlying raw units per ONE WHOLE option
    uint8 optionDecimals;       // <= 18
    uint256 minOptionAmount;    // option token raw units
    uint256 maxTotalShortAmount; // open-interest cap in option raw units; 0 = uncapped
    OracleConfig oracleConfig;
    string name;
    string symbol;
}

/// @notice The complete, immutable definition of a series. Produced by the factory,
///         stored by the registry and the vault. Never used as a creation input.
struct SeriesParams {
    bytes32 seriesId;
    OptionType optionType;
    address underlying;
    address quote;
    address collateralAsset;     // derived: underlying for CALL, quote for PUT
    uint256 strikePrice;         // PRICE_SCALE
    uint64 expiry;               // unix seconds
    uint256 contractSize;        // underlying raw units per ONE WHOLE option
    uint8 optionDecimals;
    uint256 minOptionAmount;     // option token raw units
    uint256 maxTotalShortAmount; // open-interest cap; 0 = uncapped; immutable
    OracleConfig oracleConfig;
    FeeConfig feeConfig;         // snapshotted from ProtocolConfig at creation, immutable
    uint256 optionScale;         // derived: 10 ** optionDecimals
    uint256 uqScale;             // derived: PRICE_SCALE * 10**underlyingDec / 10**quoteDec
    uint256 collateralPerOption; // derived: collateral raw units per ONE WHOLE option
    string name;
    string symbol;
}

struct SettlementResult {
    bool settled;
    uint256 settlementPrice;     // PRICE_SCALE
    uint256 buyerPayoutRate;     // collateral raw units per ONE WHOLE option
    uint256 writerResidualRate;  // collateral raw units per ONE WHOLE option
    uint64 settledAt;            // unix seconds
}

struct KuruMarketConfig {
    address market;
    address baseAsset;       // must equal the option token
    address quoteAsset;      // must equal series.quote
    uint96 sizePrecision;
    uint32 pricePrecision;
    uint32 tickSize;
    uint96 minSize;
    uint96 maxSize;
    uint16 takerFeeBps;      // bps, venue fee paid to Kuru
    uint16 makerFeeBps;      // bps, venue fee paid to Kuru
    uint96 kuruAmmSpread;
    uint64 linkedAt;         // unix seconds
    address linkedBy;
}

/// @dev Field types for sizePrecision, pricePrecision, tickSize, minSize, maxSize
///      and kuruAmmSpread are provisional. Confirm the widths and semantics against
///      the deployed Kuru contracts before implementation; see FD-14 and FD-17.

struct PremiumCheckParams {
    bytes32 seriesId;
    address market;
    uint256 optionAmount;          // option token raw units, size the buyer wants
    uint256 writerAskPremium;      // quote raw units, TOTAL for optionAmount
    uint256 buyerMaxTotalPremium;  // quote raw units, TOTAL all-in cost cap
    uint256 buyerMinOptionAmount;  // option token raw units, minimum acceptable output
    uint256 deadline;              // unix seconds
}

/// @dev Every premium figure here is a TOTAL for `optionAmount`, never per option.
///      Per-option values are display conveniences only and are never compared
///      against these bounds. See Invariant 13 in math-of-core-invariants.md.
struct PremiumCheckResult {
    bool valid;
    uint256 acceptableMinPremium;    // quote raw units, TOTAL
    uint256 acceptableMaxPremium;    // quote raw units, TOTAL
    uint256 estimatedGrossPremium;   // quote raw units, TOTAL, before venue fees
    uint256 estimatedKuruTakerFee;   // quote raw units, TOTAL
    uint256 estimatedAllInCost;      // quote raw units, TOTAL: gross + venue fee + route fee
    uint256 estimatedPriceImpactBps; // bps
    uint256 estimatedSpreadBps;      // bps
    string reason;                   // empty when valid
}
```

## `ISeriesRegistry`

The vault and the option token are **the same contract**. `OptionSeriesVault` is itself the series' ERC-20. The registry therefore stores one address per series; `getVault` and `getSeriesByToken` are inverse lookups over that single address, not two different objects.

```solidity
interface ISeriesRegistry {
    event SeriesRegistered(bytes32 indexed seriesId, address indexed vault, address indexed underlying);
    event KuruMarketLinked(bytes32 indexed seriesId, address indexed market, address baseAsset, address quoteAsset);
    event KuruLinkPauseSet(bool paused, bytes32 reason);

    /// @dev Callable only by the canonical factory. Reverts with NotFactory otherwise.
    function registerSeries(SeriesParams calldata params, address vault) external;

    /// @dev Callable only by KURU_ADMIN_ROLE or the KuruMarketAdapter.
    ///      Reverts with NotKuruAdmin otherwise. Append-only unless an explicitly
    ///      reviewed migration path exists; see FD-13.
    function linkKuruMarket(bytes32 seriesId, KuruMarketConfig calldata config) external;

    function setKuruLinkPaused(bool paused, bytes32 reason) external;
    function kuruLinkPaused() external view returns (bool);

    function isSeries(bytes32 seriesId) external view returns (bool);
    function isOptionToken(address token) external view returns (bool);
    function getSeries(bytes32 seriesId) external view returns (SeriesParams memory);
    function getVault(bytes32 seriesId) external view returns (address);
    function getSeriesByToken(address optionToken) external view returns (bytes32);
    function getKuruMarket(bytes32 seriesId) external view returns (KuruMarketConfig memory);
    function factory() external view returns (address);
}
```

`isOptionToken` is the canonical-identity check referenced by Invariant 12 in [math-of-core-invariants.md](./math-of-core-invariants.md). Name, symbol, and Kuru listing are never sufficient.

## `IOptionSeriesFactory`

```solidity
interface IOptionSeriesFactory {
    event SeriesCreated(
        bytes32 indexed seriesId,
        address indexed vault,
        address indexed underlying,
        OptionType optionType,
        address quote,
        uint256 strikePrice,
        uint64 expiry
    );

    /// @dev V1: restricted to SERIES_CREATOR_ROLE. Creation is NOT permissionless.
    ///      `name` and `symbol` are excluded from seriesId and are permanent once set, and a
    ///      later call with identical economics resolves to the existing series rather than
    ///      creating a second one. Open creation would therefore let anyone front-run every
    ///      popular strike and expiry with misleading metadata that can never be corrected.
    ///      See FD-22.
    function createSeries(CreateSeriesParams calldata params)
        external
        returns (bytes32 seriesId, address vault);

    function computeSeriesId(CreateSeriesParams calldata params) external view returns (bytes32);

    function registry() external view returns (address);
    function protocolConfig() external view returns (address);
    function oracleRouter() external view returns (address);
}
```

`createSeries` derives `collateralAsset`, `optionScale`, `uqScale`, and `collateralPerOption`, snapshots `feeConfig` from `ProtocolConfig`, assembles the full `SeriesParams`, deploys the vault, and registers it. Validation rules are in [implementation-spec.md](./implementation-spec.md).

`computeSeriesId` takes the same creation inputs so it can be called before a series exists. The identifier excludes name, symbol, and fee rates; see [implementation-spec.md](./implementation-spec.md) for why.

## `IOptionSeriesVault`

The vault **is** the ERC-20 option token, so this interface extends `IERC20`.

```solidity
interface IOptionSeriesVault is IERC20 {
    event OptionsMinted(
        bytes32 indexed seriesId,
        address indexed writer,
        address indexed receiver,
        uint256 optionAmount,
        uint256 collateralAmount,
        uint256 feeAmount
    );
    event SeriesSettled(
        bytes32 indexed seriesId,
        uint256 settlementPrice,
        uint256 buyerPayoutRate,
        uint256 writerResidualRate
    );
    event OptionsRedeemed(
        bytes32 indexed seriesId,
        address indexed holder,
        address indexed receiver,
        uint256 optionAmount,
        uint256 grossPayout,
        uint256 feeAmount
    );
    event WriterResidualClaimed(
        bytes32 indexed seriesId,
        address indexed writer,
        address indexed receiver,
        uint256 shortAmount,
        uint256 residualAmount
    );
    event FeesSwept(bytes32 indexed seriesId, address indexed receiver, uint256 amount);
    event PauseSet(bytes32 indexed seriesId, VaultPause indexed flag, bool paused, bytes32 reason);

    // --- series definition ---

    function seriesParams() external view returns (SeriesParams memory);
    function settlementResult() external view returns (SettlementResult memory);
    function state() external view returns (SeriesState);
    function isExpired() external view returns (bool);

    // --- lifecycle ---

    /// @return collateralAmount collateral raw units added to collateralLocked
    /// @return feeAmount        collateral raw units accrued as protocol fee, charged ON TOP
    function mint(uint256 optionAmount, address receiver)
        external
        returns (uint256 collateralAmount, uint256 feeAmount);

    /// @notice Settles the series at the oracle observation anchored to expiry.
    /// @dev `proof` identifies that observation and is verified against the source, so the
    ///      resulting price is the same regardless of who calls or when. See oracle-spec.md.
    ///      Payable to fund the Pyth update fee; any unused native balance is refunded to
    ///      msg.sender. The vault must not retain native token.
    function settle(SettlementProof calldata proof)
        external
        payable
        returns (uint256 settlementPrice);

    /// @return payoutAmount NET collateral raw units transferred to receiver
    /// @return feeAmount    collateral raw units accrued as protocol fee, carved from gross
    function redeem(uint256 optionAmount, address receiver)
        external
        returns (uint256 payoutAmount, uint256 feeAmount);

    /// @return residualAmount collateral raw units transferred to receiver. No fee is
    ///         charged here: the writer already paid at mint.
    function claimWriterResidual(uint256 shortAmount, address receiver)
        external
        returns (uint256 residualAmount);

    // --- fee and dust ---

    /// @dev FEE_ADMIN_ROLE only. Sends to ProtocolConfig.feeRecipient(), read live.
    ///      Deliberately takes no receiver; see implementation-spec.md.
    function sweepFees() external returns (uint256 amount);

    // --- pause ---

    function setPaused(VaultPause flag, bool paused, bytes32 reason) external;
    function isPaused(VaultPause flag) external view returns (bool);

    // --- previews ---

    function previewMint(uint256 optionAmount)
        external
        view
        returns (uint256 collateralAmount, uint256 feeAmount);
    function previewRedeem(uint256 optionAmount)
        external
        view
        returns (uint256 payoutAmount, uint256 feeAmount);
    function previewWriterResidual(uint256 shortAmount)
        external
        view
        returns (uint256 residualAmount);

    // --- accounting ---

    function writerShortBalance(address writer) external view returns (uint256);
    function totalShortAmount() external view returns (uint256);
    function totalUnclaimedShortAmount() external view returns (uint256);
    function collateralLocked() external view returns (uint256);
    function accruedFees() external view returns (uint256);
    function totalBuyerPayoutClaimed() external view returns (uint256);
    function totalWriterResidualClaimed() external view returns (uint256);

    // --- wiring ---

    function registry() external view returns (address);
    function oracleRouter() external view returns (address);
    function protocolConfig() external view returns (address);
}
```

`previewMint` replaces the earlier `previewRequiredCollateral`, since it now returns the fee alongside the collateral and a writer needs both to know what to approve.

## `IOracleRouter`

The router reads each series' `OracleConfig` from the registry. It does **not** accept a caller-supplied config: doing so would let any caller request a price under weakened rules, for example by passing `requireChainlink: false` with a large staleness window.

```solidity
interface IOracleRouter {
    event OraclePriceAccepted(
        bytes32 indexed seriesId,
        uint256 price,
        uint256 chainlinkPrice,
        uint256 pythPrice
    );
    event OraclePriceRejected(bytes32 indexed seriesId, OracleStatus status, string reason);

    /// @notice Strict settlement path. Enforces the full quorum for the series, on the
    ///         observation anchored to expiry rather than on a live read.
    /// @dev Payable for the Pyth update fee; refunds any unused native balance to msg.sender.
    ///      Reverts rather than returning an invalid price. Has no side effects on series
    ///      state: it returns a price, it does not settle.
    function getSettlementPrice(bytes32 seriesId, SettlementProof calldata proof)
        external
        payable
        returns (uint256 price);

    /// @notice Pre-expiry reference price for premium bounds only.
    /// @dev Same quorum rules as settlement. Must never be used to write settlement state.
    ///      Kept separate from getSettlementPrice so the two can diverge later without
    ///      silently loosening settlement, and so events distinguish the two uses.
    function getReferencePrice(bytes32 seriesId, bytes calldata pythUpdateData)
        external
        payable
        returns (uint256 price);

    /// @notice Non-reverting view for UI. Returns the status instead of reverting.
    /// @dev Cannot pull a fresh Pyth update because it is view; reads the last stored price.
    function previewReferencePrice(bytes32 seriesId)
        external
        view
        returns (uint256 price, OracleStatus status);

    function registry() external view returns (address);
}
```

## `IOracleAdapter`

Adapters are deliberately dumb. They fetch and normalize one source and report what they found. **All policy — staleness thresholds, deviation limits, quorum — is applied by the router using the series' immutable config.** Keeping policy in one place means an adapter cannot silently change how strictly a live series is validated.

The feed identifier is passed in rather than looked up. An adapter that held its own `(base, quote) -> feed` mapping would be a second, governable source of truth, and repointing it would change the settlement oracle of an already-live series — breaking the immutability guarantee in DD-03 that the whole token model rests on.

```solidity
interface IOracleAdapter {
    struct PriceData {
        uint256 price;        // ALWAYS normalized to PRICE_SCALE, regardless of source decimals
        uint64 updatedAt;     // unix seconds, as reported by the source
        uint8 sourceDecimals; // informational only; the price above is already normalized
        bool valid;           // false if the source returned unusable data
    }

    /// @notice Live read, for REFERENCE prices only. Never used for settlement.
    /// @param feed   source contract address; used by the Chainlink adapter
    /// @param feedId source feed identifier; used by the Pyth adapter
    /// @param updateData pull-oracle update payload; empty for push oracles
    /// @dev Each adapter uses the identifier that applies to it and ignores the other.
    ///      Payable for pull-oracle update fees; refunds unused native balance to msg.sender.
    function read(address feed, bytes32 feedId, bytes calldata updateData)
        external
        payable
        returns (PriceData memory);

    function peek(address feed, bytes32 feedId) external view returns (PriceData memory);

    /// @notice ANCHORED read, for settlement. Returns the first observation at or after
    ///         `atTimestamp`, and reverts unless the proof shows it is genuinely the first.
    /// @param atTimestamp the series expiry
    /// @param maxLag      how far past expiry the observation may sit
    /// @param proofData   source-specific proof; a Chainlink round id, or Pyth update data
    /// @dev The returned PriceData.updatedAt must lie in [atTimestamp, atTimestamp + maxLag].
    ///      An adapter must not fall back to a latest-price read if the proof fails: that
    ///      would restore the caller's ability to choose the settlement price by timing.
    function readAt(
        address feed,
        bytes32 feedId,
        uint64 atTimestamp,
        uint32 maxLag,
        bytes calldata proofData
    ) external payable returns (PriceData memory);
}
```

### Where Pair Identity Is Checked

Because the adapter receives a feed identifier rather than an asset pair, it cannot verify that the feed describes the series' underlying/quote pair. That check is therefore a **creation-time** control, not a settlement-time one:

```text
configHash = keccak256(abi.encode(oracleConfig))
factory requires ProtocolConfig.isApprovedOracleConfig(underlying, quote, configHash)
the config is then frozen into the series and can never change
```

**The pair must be part of the approval key.** An `OracleConfig` names feeds but not which assets they price, so a config-only key would bind one approval to every pair. [oracle-spec.md](./oracle-spec.md) works through what that allows.

Approving an oracle config is therefore security-critical: an approval that binds the wrong feed to a pair cannot be corrected on any series already created against it.

## `IProtocolConfig`

```solidity
interface IProtocolConfig {
    event AssetAllowed(address indexed asset, bool allowed);
    event OracleConfigApproved(
        address indexed underlying,
        address indexed quote,
        bytes32 indexed configHash,
        bool approved
    );
    event DefaultFeesUpdated(uint16 mintFeeBps, uint16 exerciseFeeBps);
    event FeeRecipientUpdated(address indexed recipient);
    event RiskParamsUpdated();

    function isAllowedAsset(address asset) external view returns (bool);

    /// @notice Is this oracle configuration approved FOR THIS PAIR?
    /// @dev The pair is part of the key, not incidental to it. See the note below.
    function isApprovedOracleConfig(address underlying, address quote, bytes32 configHash)
        external
        view
        returns (bool);

    /// @dev Read by the factory at creation time and snapshotted into the series.
    ///      Changes here never reach an already-created series.
    function defaultFeeConfig() external view returns (FeeConfig memory);

    /// @dev Read live at sweep time, never snapshotted, so a compromised treasury
    ///      can be rotated without affecting any series' economics.
    function feeRecipient() external view returns (address);

    // Route-safety defaults, consumed by PremiumExecutionGuard.
    function maxPremiumSpreadBps() external view returns (uint32);
    function maxPriceImpactBps() external view returns (uint32);
    function maxQuoteAge() external view returns (uint32);
    function minKuruDepth(address quoteAsset) external view returns (uint256);
    function sellerDiscountToleranceBps() external view returns (uint16);
    function buyerOverpayToleranceBps() external view returns (uint16);

    // Maximum venue fees a Kuru market may charge and still be linkable.
    function maxLinkableMakerFeeBps() external view returns (uint16);
    function maxLinkableTakerFeeBps() external view returns (uint16);

    function setAllowedAsset(address asset, bool allowed) external;
    function setApprovedOracleConfig(
        address underlying,
        address quote,
        bytes32 configHash,
        bool approved
    ) external;
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
    event RoutingPauseSet(bool paused, bytes32 reason);

    /// @notice Validates a prospective route. Reverts on failure so a future router
    ///         can call it as an atomic precondition; returns the result on success.
    /// @dev Payable because it may fund a Pyth update to obtain a reference price.
    ///      Refunds any unused native balance to msg.sender: this contract holds no funds.
    function checkPremium(PremiumCheckParams calldata params, bytes calldata oracleData)
        external
        payable
        returns (PremiumCheckResult memory);

    /// @notice Non-reverting variant for frontend display. Returns valid == false with a
    ///         reason instead of reverting, so a UI can explain why a route is unsafe.
    /// @dev Being view, it cannot pull a fresh Pyth update and uses the last stored
    ///      reference price. A UI must treat a stale reason code as a reason to refuse
    ///      the simplified route, not as a soft warning.
    function previewPremium(PremiumCheckParams calldata params)
        external
        view
        returns (PremiumCheckResult memory);

    function setRoutingPaused(bool paused, bytes32 reason) external;
    function routingPaused() external view returns (bool);
}
```

The two entry points differ deliberately: `checkPremium` reverts so it composes as a precondition, while `previewPremium` returns a reason string so the UI can tell a user *why* a trade is blocked rather than showing an opaque failure.

## `IKuruMarketAdapter`

```solidity
interface IKuruMarketAdapter {
    event KuruMarketCreated(bytes32 indexed seriesId, address indexed market);
    event KuruMarketValidated(bytes32 indexed seriesId, address indexed market);

    /// @dev Deploys via the Kuru Router, validates the result, then calls
    ///      ISeriesRegistry.linkKuruMarket. Never custodies collateral.
    function deployMarket(bytes32 seriesId, KuruMarketConfig calldata config)
        external
        returns (address market);

    /// @dev Validates an externally deployed market before it is linked.
    function validateMarket(bytes32 seriesId, address market) external view returns (bool);

    function kuruRouter() external view returns (address);
}
```

## Required Custom Errors

```solidity
// creation and identity
error ZeroAddress();
error InvalidAsset();
error InvalidDecimals();
error InvalidStrike();
error InvalidExpiry();
error InvalidContractSize();
error InvalidMinOptionAmount();
error InvalidOracleConfig();
error DuplicateSeries(bytes32 seriesId);
error NotFactory();
error NotRegistry();
error NotKuruAdmin();
error NotSeries();

// lifecycle
error NotSettled();
error AlreadySettled();
error Expired();
error NotExpired();
error AmountTooSmall();
error OpenInterestCapExceeded();
error InsufficientOptionBalance();
error InsufficientShortBalance();

// oracle
error OracleInvalid();
error OracleStale();
error OracleDeviationTooHigh();
error MissingRequiredSource();
error SettlementAnchorInvalid();   // proof does not identify the first observation at expiry
error SettlementAnchorTooLate();   // no qualifying observation within maxSettlementLag

// kuru and premium
error KuruMarketInvalid();
error KuruFeeTooHigh();
error PremiumOutOfRange();
error BuyerLimitExceeded();
error DeadlineExpired();

// fees and dust
error FeeExceedsCap();
error NoFeesAccrued();
error SeriesNotWoundDown();

// pause
error PausedAction(VaultPause flag);
error RoutingPaused();
error KuruLinkPaused();
```

Notes on what is deliberately absent:

- No `NotFeeAdmin` or similar role errors. Access control uses OpenZeppelin `AccessControl`, which already reverts with `AccessControlUnauthorizedAccount`. Duplicating it produces two error shapes for one condition.
- No `InsufficientCollateral`. Collateral transfer failure surfaces through `SafeERC20`, which reverts with the token's own error.
- No `InvalidOptionType`. The enum makes an out-of-range value unrepresentable; Solidity reverts on an invalid enum decode.
- `PausedAction` is custom rather than OpenZeppelin `Pausable`'s `EnforcedPause`. The vault needs four independent flags and OZ `Pausable` provides a single global one, so it is not used. See [implementation-spec.md](./implementation-spec.md).
