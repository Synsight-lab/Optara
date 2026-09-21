# Implementation Spec

## Purpose

This file is the build specification for the Monad/Kuru options protocol. It turns the design documents into implementable contract behavior.

Primary references:

- [PRD.md](./PRD.md)
- [architectural.md](./architectural.md)
- [contract-interfaces.md](./contract-interfaces.md)
- [storage-layout.md](./storage-layout.md)
- [state-machine.md](./state-machine.md)
- [oracle-spec.md](./oracle-spec.md)
- [premium-pricing-spec.md](./premium-pricing-spec.md)
- [fee-spec.md](./fee-spec.md)
- [kuru-integration-spec.md](./kuru-integration-spec.md)
- [security-threat-model.md](./security-threat-model.md)
- [testing-and-invariants.md](./testing-and-invariants.md)
- [deployment-runbook.md](./deployment-runbook.md)
- [production-checklist.md](./production-checklist.md)
- [founder-decisions.md](./founder-decisions.md)

## V1 Build Decision Summary

V1 must implement:

- Fully collateralized European calls and puts.
- One immutable ERC-20 option token per series.
- Calls collateralized in underlying.
- Puts collateralized in quote.
- Oracle-based settlement only.
- Chainlink primary oracle if feed exists.
- Pyth corroborator if feed exists.
- No DEX TWAP oracle. A window average cannot be anchored to expiry, and a source that can never be required can never be read.
- Kuru only for secondary trading, premium execution, and depth sanity.
- No Kuru price usage for settlement.
- No early exercise.
- No leverage, margin, borrowing, liquidation, rehypothecation, or undercollateralized writing.
- No pre-expiry writer close flow in V1.
- No dynamic mutation of series parameters after creation.
- Non-upgradeable `OptionSeriesVault` instances.
- Protocol fees at mint and exercise, charged so they can never touch collateral backing live claims.
- Fee rates snapshotted immutably per series at creation, capped by compile-time constants.
- Kuru venue fees accounted for in every premium bound and user-facing quote, never captured by Optara.

## Solidity and Library Baseline

Recommended implementation baseline:

```text
Solidity: 0.8.24 or newer stable 0.8.x
Test framework: Foundry
Core library: OpenZeppelin Contracts 5.x
Math: OpenZeppelin Math.mulDiv with explicit rounding
Token safety: SafeERC20
Access control: AccessControl
Reentrancy: ReentrancyGuard
Pause: custom per-action flags, NOT OpenZeppelin Pausable
```

OpenZeppelin `Pausable` is deliberately not used. It provides a single global flag, while this protocol needs independent per-action flags so that pausing minting does not also block redemption. Using it would force either an all-or-nothing pause or a second parallel mechanism alongside it.

Because `Pausable` is unused, its `EnforcedPause` error is unavailable; the custom `PausedAction(VaultPause flag)` error in [contract-interfaces.md](./contract-interfaces.md) is used instead. Do not mix the two.

Access control uses OpenZeppelin `AccessControl` and its `AccessControlUnauthorizedAccount` error. Do not add custom per-role errors, which would produce two error shapes for one condition.

If a later implementation chooses a different compiler, library version, or test framework, update this file and [deployment-runbook.md](./deployment-runbook.md) before coding.

## Contract Set

### Required V1 Contracts

```text
SeriesRegistry
OptionSeriesFactory
OptionSeriesVault
OracleRouter
ChainlinkOracleAdapter
PythOracleAdapter
PremiumExecutionGuard
KuruMarketAdapter
ProtocolConfig
```

### Optional V1 Contracts

```text
EmergencyRecoveryModule
```

The optional contracts must not be needed for basic mint, settle, redeem, and writer residual withdrawal.

## Contract Responsibilities

### `SeriesRegistry`

The canonical registry of official option series.

Must:

- Accept new series only from `OptionSeriesFactory`.
- Store immutable series metadata.
- Map `seriesId` to the vault address, and the vault address back to `seriesId`.
- Store optional Kuru market metadata.
- Own the `kuruLinkPaused` flag, since it owns `linkKuruMarket`.
- Expose canonical verification functions for frontends and contracts.

The vault **is** the option token: `OptionSeriesVault` is itself the series' ERC-20. The registry therefore stores one address per series, not two. `getVault` and `getSeriesByToken` are inverse lookups over that single address, and `isOptionToken` is the canonical-identity check from Invariant 12.

Must not:

- Modify already registered immutable series parameters.
- Determine settlement price.
- Custody collateral.

### `OptionSeriesFactory`

Creates official series.

Must:

- Restrict `createSeries` to `SERIES_CREATOR_ROLE` in V1.
- Accept `CreateSeriesParams`, never `SeriesParams`.
- Validate assets, decimals, expiry, strike, contract size, oracle configuration, and minimum size.
- Derive `collateralAsset`, `optionScale`, `uqScale`, and `collateralPerOption`.
- Snapshot `feeConfig` from `ProtocolConfig` and validate it against the hard caps.
- Compute deterministic `seriesId`.
- Resolve a repeat call with an identical `seriesId` and identical remaining inputs to the existing series, and revert with `DuplicateSeries` if the `seriesId` exists but `minOptionAmount`, `maxTotalShortAmount`, `name`, or `symbol` differ.
- Deploy `OptionSeriesVault`.
- Register the vault in `SeriesRegistry`.
- Optionally deploy or link a Kuru market through `KuruMarketAdapter`.

Must not:

- Accept any derived or snapshotted value as a caller argument.
- Mint options directly.
- Custody collateral after series deployment.
- Mutate series after deployment.

### `OptionSeriesVault`

The per-series vault and ERC-20 option token.

Must:

- Implement ERC-20 for the long option token.
- Expose a one-time `initialize(params, registry, oracleRouter, protocolConfig)` callable only by the canonical factory, which writes every series field, the ERC-20 name, symbol and decimals, and the wiring addresses. A second call reverts with `AlreadyInitialized`. See [contract-interfaces.md](./contract-interfaces.md).
- Store immutable series parameters.
- Accept collateral and mint options before expiry.
- Track writer short balances.
- Disallow minting at or after expiry.
- Settle once after expiry using `OracleRouter`.
- Burn option tokens during redemption.
- Pay buyer payout using the fixed settlement result.
- Let writers claim residual collateral after settlement.
- Accrue protocol fees in a balance strictly segregated from `collateralLocked`.
- Preserve all invariants in [math-of-core-invariants.md](./math-of-core-invariants.md) and [fee-spec.md](./fee-spec.md).

Must not:

- Use Kuru price for settlement.
- Allow early exercise.
- Allow collateral withdrawal before settlement.
- Allow settlement result mutation.
- Allow writer residual withdrawal before buyer payout rates are fixed.
- Allow any fee path to reduce `collateralLocked` below outstanding claims.
- Allow its own immutable fee rates to be changed after creation.

### `OracleRouter`

Aggregates oracle adapters for settlement and reference prices.

Must:

- Read the series' `OracleConfig` from `SeriesRegistry` using `seriesId`.
- Read Chainlink primary when configured.
- Read Pyth secondary/corroborator when configured.

- Pass feed identifiers from that config into adapters as call arguments.
- Apply all cross-source and reference policy itself: reference staleness, Pyth confidence, deviation, and quorum.
- Reject stale reference data, over-wide Pyth confidence, and zero, negative, or invalid prices. Anchor-proof and anchor-window failures are raised by the adapters and propagate through the router.
- Return a final price only when the configured quorum rules pass.
- Forward native value only when a pull oracle is required and refund any unused remainder to its caller.

Must not:

- Accept a caller-supplied `OracleConfig`. A caller could pass weakened requirements, and nothing would bind the config to the series it claims to describe.
- Read Kuru option-market prices for settlement.
- Silently fall back to a single oracle when the series requires two-oracle quorum.
- Retain native token.

### `ChainlinkOracleAdapter` and `PythOracleAdapter`

Each adapter fetches exactly one source and reports what it found.

Must:

- Accept the feed address or feed id as a call argument.
- Normalize the price to `PRICE_SCALE = 1e18` regardless of source decimals.
- Report `updatedAt` as the source reports it.
- On `readAt`, verify the anchor proof and enforce that source's anchor window, reverting with `SettlementAnchorInvalid`, `SettlementAnchorTooStale`, or `SettlementAnchorTooLate`. This is proof verification, not cross-source policy.
- Report `valid = false` for structurally unusable data such as a zero or negative answer.
- Refund unused native token.

Must not:

- Hold an internal `(base, quote) -> feed` mapping. That would be a second, governable source of truth able to change a live series' settlement oracle.
- Apply reference staleness, Pyth confidence, deviation, or quorum policy. Those belong to the router.
- Return a price that is not `PRICE_SCALE`-normalized.

Adapter replacement is a trust assumption. A replacement cannot change the feed identifiers frozen into a live series, but it can still return a false price for those identifiers. Adapter changes must be timelocked, evented, reviewed, and treated as settlement-critical.

### `PremiumExecutionGuard`

Protects simplified premium execution.

Must:

- Verify canonical series and Kuru market.
- Compute hard premium bounds from approved oracle reference price.
- Check Kuru market depth, spread, quote age, and price impact.
- Enforce buyer-provided max premium, min amount out, and deadline.
- Reject writer asks outside acceptable premium range.

Must not:

- Define settlement value.
- Force buyer execution.
- Treat last-traded Kuru price as fair value.

### `KuruMarketAdapter`

Deploys or records Kuru market metadata.

Must:

- Validate market base asset is the option token.
- Validate quote asset equals the series quote asset.
- Validate Kuru market precision and min/max size.
- Store market metadata in the registry.

Must not:

- Custody settlement collateral.
- Use Kuru price for settlement.
- Receive unlimited collateral approvals.

### `ProtocolConfig`

Stores protocol-wide allowlists and roles.

Must:

- Allowlist assets.
- Allowlist approved oracle configs, keyed on `(underlying, quote, configHash)`. There is no adapter allowlist: adapters are stateless fetchers held by `OracleRouter`.
- Store default risk parameters.
- Store default fee rates for **future** series, bounded by the hard caps.
- Store the current fee recipient, which is read live at sweep time rather than snapshotted.
- Store role assignments.

Must not:

- Modify immutable parameters of deployed series.
- Modify fee rates of deployed series.
- Change settlement results.
- Hold collateral or fees itself; accrual lives in each vault.

## Roles

Recommended roles:

```text
DEFAULT_ADMIN_ROLE        multisig or governance timelock
PARAMETER_ADMIN_ROLE      can update future-series risk parameters
ASSET_ADMIN_ROLE          can allowlist assets for future series
ORACLE_ADMIN_ROLE         can allowlist oracle configs for future series
KURU_ADMIN_ROLE           can update Kuru adapter addresses and defaults
SERIES_CREATOR_ROLE       can create new series; V1 is guarded, not permissionless
FEE_ADMIN_ROLE            can set future-series fee rates, set fee recipient, and sweep accrued fees
PAUSER_ROLE               can pause new minting or unsafe helper functions
KEEPER_ROLE               optional; settlement should also be permissionless
```

Rules:

- Deployed series parameters cannot be changed by any role.
- Deployed series **fee rates** cannot be changed by any role, including `FEE_ADMIN_ROLE`.
- Roles live on `ProtocolConfig` only. Vaults, the factory, the registry, and the guard check `ProtocolConfig.hasRole(...)` rather than holding their own role state.
- Settlement price cannot be changed by any role after settlement.
- `FEE_ADMIN_ROLE` can move `accruedFees` and nothing else. No role can withdraw `collateralLocked`.
- `PAUSER_ROLE` should not block valid post-settlement redemptions unless redemption is the active exploit vector.

## Constants and Scales

### Global Constants

```text
PRICE_SCALE = 1e18
BPS_SCALE = 10000
MAX_BPS = 10000
```

### Per-Series Derived Scales

Computed once at series creation and stored immutably on the vault. Never recomputed at runtime.

```text
OPTION_SCALE         = 10 ** optionDecimals
UQ_SCALE             = PRICE_SCALE * (10 ** underlyingDecimals) / (10 ** quoteDecimals)
collateralPerOption  = C                                for CALL
collateralPerOption  = ceilDiv(C * K, UQ_SCALE)         for PUT
```

`UQ_SCALE` is an exact integer because both decimal values are capped at 18. The definitions and the conversion helper they feed are normative in [math-of-core-invariants.md](./math-of-core-invariants.md) — implement them exactly, including rounding direction.

### Hard Fee Caps

Compile-time constants. Not governable. Enforced at series creation.

```text
MAX_MINT_FEE_BPS     = 100
MAX_EXERCISE_FEE_BPS = 100
```

### Risk Parameter Defaults

```text
MIN_EXPIRY_DELAY = 1 hours          safe default, needs founder approval (FD-19)
MAX_EXPIRY_DELAY = 365 days         safe default, needs founder approval (FD-19)
MIN_ORACLE_DEVIATION_BPS = 10       floor; below this a series can never settle
MAX_ORACLE_DEVIATION_BPS = 1000     ceiling; above this corroboration is meaningless
MAX_PYTH_CONFIDENCE_BPS = 500       ceiling; above this the confidence check is meaningless
```

The following are recommended starting values used when **approving** an oracle config. They are not stored on chain: the series' own `OracleConfig` holds the values that apply, pinned by its approved hash.

```text
RECOMMENDED_MAX_ORACLE_DEVIATION_BPS = 100
RECOMMENDED_CHAINLINK_STALE_AFTER = 1 hours
RECOMMENDED_PYTH_STALE_AFTER = 2 minutes
RECOMMENDED_MAX_PYTH_CONFIDENCE_BPS = 100
NO UNIVERSAL VALUE: maxChainlinkAgeAtExpiry, configure per feed heartbeat plus buffer (FD-21)
NO UNIVERSAL VALUE: maxPythSettlementLag, configure per feed, small (FD-21)
```

Route-safety and fee defaults stored in `ProtocolConfig`:

```text
DEFAULT_MAX_PREMIUM_SPREAD_BPS = 500
DEFAULT_MAX_PRICE_IMPACT_BPS = 300
DEFAULT_MIN_KURU_DEPTH = Needs Founder Decision per asset (FD-08)
DEFAULT_MINT_FEE_BPS = Needs Founder Decision (FD-06)
DEFAULT_EXERCISE_FEE_BPS = Needs Founder Decision (FD-06)
```

Defaults are safety starting points. Production values must be finalized in [founder-decisions.md](./founder-decisions.md).

## Series Creation Specification

### Inputs

```solidity
struct CreateSeriesParams {
    OptionType optionType;
    address underlying;
    address quote;
    uint256 strikePrice;       // PRICE_SCALE quote per 1 underlying
    uint64 expiry;
    uint256 contractSize;      // underlying raw units per whole option
    uint8 optionDecimals;
    uint256 minOptionAmount;   // option token raw units
    uint256 maxTotalShortAmount; // open-interest cap; 0 means uncapped
    OracleConfig oracleConfig;
    string name;
    string symbol;
}
```

`maxTotalShortAmount` implements the per-series open-interest cap recommended in FD-09. It is immutable once set, so a cap cannot be raised on a live series after writers and buyers have sized their risk against it. A series intended to be uncapped sets it to 0.

This is the complete caller-supplied input set. It is a different struct from `SeriesParams`, which is the assembled, immutable series definition the factory produces.

Five fields appear in `SeriesParams` but deliberately **not** here, because a caller must never be able to choose them:

```text
seriesId             derived   keccak256 over the canonical field set
collateralAsset      derived   underlying for CALL, quote for PUT
optionScale          derived   10 ** optionDecimals
uqScale              derived   PRICE_SCALE * 10**underlyingDec / 10**quoteDec
collateralPerOption  derived   C for CALL, ceilDiv(C * K, uqScale) for PUT
feeConfig            snapshot  copied from ProtocolConfig.defaultFeeConfig()
```

A caller-supplied `feeConfig` would let anyone create a zero-fee series, defeating protocol fees entirely. A caller-supplied `collateralPerOption` would break solvency outright, since every collateral and payout figure derives from it. Accepting `SeriesParams` as the creation input is therefore a security bug, not a convenience.

### Derivation

The factory computes, in order:

1. `collateralAsset` from `optionType`.
2. `optionScale = 10 ** optionDecimals`.
3. `uqScale` from the two assets' decimals, read via `IERC20Metadata.decimals()`.
4. `collateralPerOption` per [math-of-core-invariants.md](./math-of-core-invariants.md), rounding up for puts.
5. `feeConfig = protocolConfig.defaultFeeConfig()`, then validated against the hard caps.
6. `seriesId`.

It then assembles `SeriesParams`, deploys the vault, and calls `registry.registerSeries(params, vault)`.

See [fee-spec.md](./fee-spec.md) for why fee rates are frozen per series.

### Validation

Creation must revert if:

- `underlying == address(0)` or `quote == address(0)`.
- `underlying == quote`.
- Asset is not allowlisted.
- Asset decimals cannot be read or exceed 18 unless explicitly supported.
- `strikePrice == 0`.
- `contractSize == 0`.
- `optionDecimals > 18`.
- `minOptionAmount == 0`.
- `expiry <= block.timestamp + MIN_EXPIRY_DELAY`.
- `expiry > block.timestamp + MAX_EXPIRY_DELAY`.
- Oracle config is not approved **for this exact pair**, checked as `isApprovedOracleConfig(underlying, quote, keccak256(abi.encode(oracleConfig)))`. Approving on the config hash alone would let one approval bind the same feeds to every pair.
- Chainlink feed is missing when a Chainlink feed exists for the pair and policy requires it.
- Pyth feed is missing when a Pyth feed exists for the pair and policy requires it.
- **No settlement source is required**, meaning both `requireChainlink` and `requirePyth` are false. Such a config passes quorum vacuously and would settle with no oracle at all. At least one must be true, with `InvalidOracleConfig`.
- A required source has no identifier: `requireChainlink` with `chainlinkFeed == address(0)`, or `requirePyth` with `pythFeedId == bytes32(0)`.
- Both Chainlink and Pyth are required and `maxOracleDeviationBps < MIN_ORACLE_DEVIATION_BPS`. A near-zero tolerance means only exactly-equal prices ever settle, which makes the series permanently unsettleable — a lock that looks like a working config until expiry.
- `maxOracleDeviationBps > MAX_ORACLE_DEVIATION_BPS`, which would make the corroboration check meaningless.
- `requireChainlink` and `maxChainlinkAgeAtExpiry == 0`, which admits only a Chainlink round published exactly at expiry and makes an ordinary feed unsettleable.
- `requirePyth` and `maxPythSettlementLag == 0`, which admits only a Pyth update published exactly at expiry.
- `requireChainlink` and `chainlinkStaleAfter == 0`, or `requirePyth` and `pythStaleAfter == 0`. A zero reference threshold would make every premium-safety reference read fail.
- `requirePyth` and `maxPythConfidenceBps == 0`, or `maxPythConfidenceBps > MAX_PYTH_CONFIDENCE_BPS`, which would make the confidence check meaningless.
- Oracle config requires a composed feed or any feed adapter path that derives the settlement price from more than one feed leg. V1 supports direct settlement feeds only.
- Computed required collateral for `minOptionAmount` is zero.
- `seriesId` already exists and any of `minOptionAmount`, `maxTotalShortAmount`, `name`, or `symbol` differ, with `DuplicateSeries`. An exact repeat of the original inputs does not revert: it returns the existing `(seriesId, vault)`.
- Any snapshotted fee rate exceeds its hard cap, with `FeeExceedsCap`.
- `UQ_SCALE` computation would be zero, which cannot occur while both decimals are capped at 18 but must be asserted anyway.

### `seriesId`

Recommended deterministic identifier:

```text
seriesId = keccak256(abi.encode(
    chainid,
    optionType,
    underlying,
    quote,
    strikePrice,
    expiry,
    contractSize,
    optionDecimals,
    oracleConfigHash,
    collateralAsset
))
```

Do not include name or symbol in `seriesId`.

This has a consequence that must be handled at the access-control layer rather than here. Because metadata is outside the identifier, and because a repeat call with identical economics resolves to the existing series, **whoever creates a series first fixes its name, symbol, `minOptionAmount`, and `maxTotalShortAmount` permanently**, since none of them are in the identifier and a conflicting repeat reverts. If creation were permissionless, an attacker could pre-create every plausible strike and expiry for a popular pair with misleading or offensive metadata, and no one could ever create a correctly-named series for those economics.

Registry identity still protects funds: `isOptionToken` is the source of truth and a squatted series is a real, correctly-collateralized series. The damage is confined to the display layer, but it is permanent and unfixable, which is why V1 gates creation behind `SERIES_CREATOR_ROLE`. See FD-22.

Do not include fee rates in `seriesId` either. Fees are snapshotted at first creation, so excluding them means one canonical series per economic definition: a later `createSeries` call with identical parameters resolves to the existing series rather than minting a second, fee-differentiated twin that would fragment liquidity and confuse canonical identity. The consequence is that a governance fee change never applies to an already-created series, which is exactly the intended behavior.

## Mint Specification

### Function

```solidity
function mint(uint256 optionAmount, address receiver)
    external
    returns (uint256 collateralAmount, uint256 feeAmount);
```

### Rules

Must revert if:

- Series is paused for minting.
- `block.timestamp >= expiry`.
- `optionAmount < minOptionAmount`.
- `maxTotalShortAmount != 0` and `totalShortAmount + optionAmount > maxTotalShortAmount`, with `OpenInterestCapExceeded`.
- `receiver == address(0)`.
- Required collateral is zero.
- Collateral transfer fails.

Amounts:

```text
collateralAmount = ceilDiv(optionAmount * collateralPerOption, OPTION_SCALE)
feeAmount        = ceilDiv(collateralAmount * mintFeeBps, BPS_SCALE)
writer transfers   collateralAmount + feeAmount
```

Execution order, normative:

1. Validate all inputs and state.
2. Compute `collateralAmount` and `feeAmount`.
3. `writerShortBalance[msg.sender] += optionAmount`.
4. `totalShortAmount += optionAmount`.
5. `totalUnclaimedShortAmount += optionAmount`.
6. `collateralLocked += collateralAmount`.
7. `accruedFees += feeAmount`.
8. Emit `OptionsMinted`.
9. `SafeERC20.safeTransferFrom(collateralAsset, msg.sender, address(this), collateralAmount + feeAmount)`.
10. `_mint(receiver, optionAmount)`.

The function is `nonReentrant`. All accounting completes before any external call, per checks-effects-interactions. `_mint` is last because an ERC-20 receiver hook on the option token itself could otherwise observe partially-updated state; since the option token is the vault, this ordering is fully under protocol control.

### Fee-on-Transfer and Rebasing Assets

**Do not implement balance-delta accounting.** V1 relies on the asset allowlist to exclude fee-on-transfer and rebasing tokens, as specified in [security-threat-model.md](./security-threat-model.md).

This is a deliberate choice, not an oversight. Balance-delta accounting would appear to add safety while actually creating a second, harder problem: a fee-on-transfer collateral asset makes `collateralLocked` diverge from real balance over time, and every payout path would need to re-derive actual holdings. Excluding such assets at the allowlist is a single, auditable control.

The allowlist check must therefore be treated as a security-critical control rather than a convenience, and adding an asset requires confirming it is non-rebasing and charges no transfer fee.

## Settlement Specification

### Function

```solidity
function settle(SettlementProof calldata proof) external payable returns (uint256 settlementPrice);
```

`proof` identifies the oracle observation at expiry. Its `pythUpdateData` may be empty if the series does not use Pyth; its Chainlink round ids are ignored if the series does not use Chainlink. When Chainlink is used, the proof includes both the round in force at expiry and its explicit immediate successor, because Chainlink proxy round ids can cross phase boundaries and the successor must not be derived as `roundId + 1`.

Settlement is anchored to that observation rather than to a live read, so the price does not depend on when `settle()` is called. [oracle-spec.md](./oracle-spec.md) explains why a live read is unsafe here; DD-22 records the decision and the rejected alternative.

`msg.value` funds the Pyth update fee. The vault forwards native value to the router when Pyth is required and refunds any unused remainder to `msg.sender` before returning. No contract in the settlement path may retain native token: the vault has no native withdrawal path, since `sweepFees` moves the collateral asset only. See [oracle-spec.md](./oracle-spec.md).

### Rules

Must revert if:

- `block.timestamp < expiry`.
- Already settled.
- `VaultPause.SETTLEMENT` is set.
- Oracle quorum fails.
- The Chainlink proof does not identify the round in force at expiry and its immediate successor, with `SettlementAnchorInvalid`.
- The Chainlink round in force at expiry is older than `maxChainlinkAgeAtExpiry`, with `SettlementAnchorTooStale`.
- No Pyth update exists within `expiry + maxPythSettlementLag`, with `SettlementAnchorTooLate`.
- Any required oracle price is zero or invalid.
- Chainlink/Pyth deviation exceeds allowed threshold.

Note what is **not** a revert condition: how long after expiry `settle()` is called. The call may happen at any later time, because the proof pins the price to expiry regardless. Only the anchoring observations must satisfy their windows.

Execution order:

1. Read final oracle price from `OracleRouter.getSettlementPrice(seriesId, proof)`, forwarding native value when Pyth is required.
2. Compute `buyerPayoutRate` using the call or put formula in [math-of-core-invariants.md](./math-of-core-invariants.md), rounding down.
3. Compute `writerResidualRate = collateralPerOption - buyerPayoutRate`, by subtraction only.
4. Store settlement result.
5. Set state to `SETTLED`.
6. Emit `SeriesSettled`.
7. Refund any unused native token to `msg.sender`.

The function is `nonReentrant`. The oracle call happens before settlement state is written, and the native-token refund happens after all state updates.

The router is called with `seriesId` only; it reads the series' oracle config from the registry itself. The vault must not pass its stored config as an argument, because a signature that accepts a config is one any caller can pass a weakened config to.

Step 3 must be a subtraction. Deriving the residual rate from its own formula and rounding it independently breaks the exact identity `buyerPayoutRate + writerResidualRate == collateralPerOption` that the solvency proof depends on, and does so in a way ordinary unit tests will not catch.

Settlement must be idempotent: after settlement, repeated calls revert with `AlreadySettled` and never mutate state.

## Redemption Specification

### Function

```solidity
function redeem(uint256 optionAmount, address receiver)
    external
    returns (uint256 payoutAmount, uint256 feeAmount);
```

### Rules

Must revert if:

- Series is not settled.
- `optionAmount == 0`.
- `receiver == address(0)`.
- Caller balance is less than `optionAmount`.
- Computed payout transfer fails.

Amounts:

```text
grossPayout  = floor(optionAmount * buyerPayoutRate / OPTION_SCALE)
feeAmount    = floor(grossPayout * exerciseFeeBps / BPS_SCALE)
payoutAmount = grossPayout - feeAmount
```

Execution order, normative:

1. Validate all inputs and state.
2. Compute `grossPayout`, `feeAmount`, `payoutAmount`.
3. `_burn(msg.sender, optionAmount)`.
4. `collateralLocked -= grossPayout`.
5. `accruedFees += feeAmount`.
6. `totalBuyerPayoutClaimed += grossPayout`.
7. Emit `OptionsRedeemed`.
8. `SafeERC20.safeTransfer(collateralAsset, receiver, payoutAmount)` if `payoutAmount > 0`.

The function is `nonReentrant`. The burn precedes every accounting update and the single external call comes last.

Note that `collateralLocked` decreases by the **gross** amount while only the net is transferred out; the difference stays in the vault as accrued fees. This keeps `vaultBalance >= collateralLocked + accruedFees` exact.

If payout is zero, the burn must still succeed so holders can clear worthless balances, and no fee is charged. Skip the transfer entirely rather than transferring zero, since some tokens revert on zero-value transfers.

## Writer Residual Claim Specification

### Function

```solidity
function claimWriterResidual(uint256 shortAmount, address receiver)
    external
    returns (uint256 residualAmount);
```

### Rules

Must revert if:

- Series is not settled.
- `shortAmount == 0`.
- `shortAmount > writerShortBalance[msg.sender]`.
- `receiver == address(0)`.
- Residual transfer fails.

Amounts:

```text
residualAmount = floor(shortAmount * writerResidualRate / OPTION_SCALE)
```

No fee is charged here. The writer paid at mint.

Execution order, normative:

1. Validate all inputs and state.
2. Compute `residualAmount`.
3. `writerShortBalance[msg.sender] -= shortAmount`.
4. `totalUnclaimedShortAmount -= shortAmount`.
5. `collateralLocked -= residualAmount`.
6. `totalWriterResidualClaimed += residualAmount`.
7. Emit `WriterResidualClaimed`.
8. `SafeERC20.safeTransfer(collateralAsset, receiver, residualAmount)` if `residualAmount > 0`.

The function is `nonReentrant`.

## Fee Sweep Specification

### Functions

```solidity
function sweepFees() external returns (uint256 amount);
```

It takes no receiver. It sends to `ProtocolConfig.feeRecipient()`, read live at call time.

A caller-supplied receiver would defeat the reason the recipient is a live lookup rather than a snapshot: if the fee admin can direct funds anywhere, rotating a compromised treasury address protects nothing, and the role's blast radius grows from "when fees move" to "where fees go."

### `sweepFees`

Must revert if:

- Caller lacks `FEE_ADMIN_ROLE`.
- `accruedFees == 0`, with `NoFeesAccrued`.
- `ProtocolConfig.feeRecipient() == address(0)`, with `ZeroAddress`.

Execution order:

1. `receiver = protocolConfig.feeRecipient()`.
2. `amount = accruedFees`.
3. `accruedFees = 0`.
4. Emit `FeesSwept`.
5. `SafeERC20.safeTransfer(collateralAsset, receiver, amount)`.

`sweepFees` must never read or reduce `collateralLocked`. The transferable amount is exactly `accruedFees` and nothing else. It is callable in any state, including `ACTIVE`, and no pause flag blocks it, because it moves no collateral.

## Pause and Emergency Specification

Pause flags are owned by the contract that performs the action, not centralized. A vault cannot pause Kuru linking because it does not perform Kuru linking.

```text
OptionSeriesVault        VaultPause.MINT
                         VaultPause.SETTLEMENT
                         VaultPause.REDEMPTION
SeriesRegistry           kuruLinkPaused
PremiumExecutionGuard    routingPaused
```

Rules:

- `MINT`, `kuruLinkPaused`, and `routingPaused` are acceptable first-line controls, held by `PAUSER_ROLE`.
- `SETTLEMENT` should be used only when oracle settlement is actively unsafe, and requires a higher-trust role or timelock.
- `REDEMPTION` gates both `redeem` and `claimWriterResidual`, since both pull collateral out of the vault. It should be avoided and used only if redemption itself is actively exploitable. It is the highest-trust emergency action, because it blocks users from claiming collateral they are already owed.
- **There is no transfer pause.** The option token is freely transferable for the life of the series, and no role can stop it.

  A transfer pause was specified in an earlier draft and removed. It breaks ERC-20 composability, it would strand option tokens resting in Kuru orders with no way for holders to retrieve them, and it was documented as discouraged everywhere it appeared. It also carried a trap: in OpenZeppelin 5.x, `_mint` and `_burn` both route through `_update`, which is where a pause hook naturally goes and exactly where `ERC20Pausable` puts one. A hook there would have blocked redemption burns, letting a low-trust `PAUSER_ROLE` stop users claiming collateral they were owed and bypassing the higher-trust `REDEMPTION` flag entirely. Removing the flag removes the trap.
- Every pause change must emit its event with a reason code.
- No pause flag may prevent `sweepFees`, which moves no collateral.

## Needs Founder Decision

Do not let an AI agent silently choose these:

- FD-05: launch assets and quote assets.
- FD-01: whether single-oracle series are allowed when only Chainlink or only Pyth exists.
- FD-02: exact oracle deviation thresholds.
- FD-03: exact reference stale-price thresholds.
- FD-06: launch fee rates for mint and exercise fees.
- FD-06a: fee recipient address.
- FD-10 and FD-12: admin and emergency multisig addresses.
- FD-10 and FD-11: governance/timelock model.
- FD-07: whether primary-sale helpers are in scope for V1.
- FD-14: default Kuru market precision parameters per asset.
- FD-17: maximum acceptable Kuru venue fee for a market to be linkable.
- FD-20: prolonged oracle outage recovery process.
- FD-19: final `MIN_EXPIRY_DELAY` and `MAX_EXPIRY_DELAY` values.

Protocol fees themselves are now **in scope for V1** by founder direction. What remains open is the rate values, not whether fees exist. See [fee-spec.md](./fee-spec.md) and FD-06.
