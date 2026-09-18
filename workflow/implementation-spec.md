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
- Optional independent DEX TWAP as a tertiary sanity check.
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
Pause: Pausable, but scoped carefully
```

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
DexTwapOracleAdapter
EmergencyRecoveryModule
```

The optional contracts must not be needed for basic mint, settle, redeem, and writer residual withdrawal.

## Contract Responsibilities

### `SeriesRegistry`

The canonical registry of official option series.

Must:

- Accept new series only from `OptionSeriesFactory`.
- Store immutable series metadata.
- Map `seriesId` to `OptionSeriesVault`.
- Map `optionToken` to `seriesId`.
- Store optional Kuru market metadata.
- Expose canonical verification functions for frontends and contracts.

Must not:

- Modify already registered immutable series parameters.
- Determine settlement price.
- Custody collateral.

### `OptionSeriesFactory`

Creates official series.

Must:

- Validate assets, decimals, expiry, strike, contract size, oracle configuration, and minimum size.
- Compute deterministic `seriesId`.
- Reject duplicate series or return the existing canonical series.
- Deploy `OptionSeriesVault`.
- Register the vault in `SeriesRegistry`.
- Optionally deploy or link a Kuru market through `KuruMarketAdapter`.

Must not:

- Mint options directly.
- Custody collateral after series deployment.
- Mutate series after deployment.

### `OptionSeriesVault`

The per-series vault and ERC-20 option token.

Must:

- Implement ERC-20 for the long option token.
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

- Read Chainlink primary when configured.
- Read Pyth secondary/corroborator when configured.
- Optionally read DEX TWAP tertiary check when configured.
- Normalize all prices to `PRICE_SCALE = 1e18`.
- Reject stale, zero, negative, wrong-pair, or invalid oracle data.
- Enforce max deviation between Chainlink and Pyth when both are configured.
- Return a final reference price only when the configured quorum rules pass.

Must not:

- Read Kuru option-market prices for settlement.
- Silently fall back to a single oracle when the series requires two-oracle quorum.

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
- Allowlist oracle adapters and feed configs.
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
FEE_ADMIN_ROLE            can set future-series fee rates, set fee recipient, and sweep accrued fees
PAUSER_ROLE               can pause new minting or unsafe helper functions
KEEPER_ROLE               optional; settlement should also be permissionless
```

Rules:

- Deployed series parameters cannot be changed by any role.
- Deployed series **fee rates** cannot be changed by any role, including `FEE_ADMIN_ROLE`.
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
MAX_RESIDUAL_FEE_BPS = 100
MAX_ROUTE_FEE_BPS    = 50
```

### Risk Parameter Defaults

```text
MIN_EXPIRY_DELAY = 1 hours          safe default, needs founder approval (FD-19)
MAX_EXPIRY_DELAY = 365 days         safe default, needs founder approval (FD-19)
DEFAULT_MAX_ORACLE_DEVIATION_BPS = 100
DEFAULT_CHAINLINK_STALE_AFTER = 1 hours
DEFAULT_PYTH_STALE_AFTER = 2 minutes
DEFAULT_MAX_PREMIUM_SPREAD_BPS = 500
DEFAULT_MAX_PRICE_IMPACT_BPS = 300
DEFAULT_MIN_KURU_DEPTH = Needs Founder Decision per asset
DEFAULT_MINT_FEE_BPS = Needs Founder Decision (FD-06)
DEFAULT_EXERCISE_FEE_BPS = Needs Founder Decision (FD-06)
DEFAULT_RESIDUAL_FEE_BPS = 0
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
    OracleConfig oracleConfig;
    string name;
    string symbol;
}
```

Fee rates are **not** a caller-supplied input. The factory snapshots them from `ProtocolConfig` at creation time and writes them into the series immutably, so a series creator cannot choose favorable fees and governance cannot alter them afterward. See [fee-spec.md](./fee-spec.md).

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
- Oracle config is not approved.
- Chainlink feed is missing when a Chainlink feed exists for the pair and policy requires it.
- Pyth feed is missing when a Pyth feed exists for the pair and policy requires it.
- Computed required collateral for `minOptionAmount` is zero.
- `seriesId` already exists with different params.
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
function settle(bytes calldata pythUpdateData) external payable returns (uint256 settlementPrice);
```

`pythUpdateData` may be empty if the series does not use Pyth or if Pyth price is already available through an approved pathway.

### Rules

Must revert if:

- `block.timestamp < expiry`.
- Already settled.
- Oracle quorum fails.
- Any required oracle price is stale, zero, invalid, or wrong-pair.
- Chainlink/Pyth deviation exceeds allowed threshold.
- Optional TWAP check is configured and fails.

Execution order:

1. Read final oracle price from `OracleRouter`.
2. Compute `buyerPayoutRate` using the call or put formula in [math-of-core-invariants.md](./math-of-core-invariants.md), rounding down.
3. Compute `writerResidualRate = collateralPerOption - buyerPayoutRate`, by subtraction only.
4. Store settlement result.
5. Set state to `SETTLED`.
6. Emit `SeriesSettled`.

Step 3 must be a subtraction. Deriving the residual rate from its own formula and rounding it independently breaks the exact identity `buyerPayoutRate + writerResidualRate == collateralPerOption` that the solvency proof depends on, and does so in a way ordinary unit tests will not catch.

Settlement must be idempotent: after settlement, repeated calls revert with `AlreadySettled` or return the stored result without state mutation. Choose one behavior and keep it consistent.

Recommended V1 behavior: revert with `AlreadySettled`.

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
    returns (uint256 residualAmount, uint256 feeAmount);
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
grossResidual  = floor(shortAmount * writerResidualRate / OPTION_SCALE)
feeAmount      = floor(grossResidual * residualFeeBps / BPS_SCALE)
residualAmount = grossResidual - feeAmount
```

With the V1 default `residualFeeBps = 0`, `feeAmount` is zero and `residualAmount == grossResidual`.

Execution order, normative:

1. Validate all inputs and state.
2. Compute `grossResidual`, `feeAmount`, `residualAmount`.
3. `writerShortBalance[msg.sender] -= shortAmount`.
4. `totalUnclaimedShortAmount -= shortAmount`.
5. `collateralLocked -= grossResidual`.
6. `accruedFees += feeAmount`.
7. `totalWriterResidualClaimed += grossResidual`.
8. Emit `WriterResidualClaimed`.
9. `SafeERC20.safeTransfer(collateralAsset, receiver, residualAmount)` if `residualAmount > 0`.

The function is `nonReentrant`.

## Fee and Dust Sweep Specification

### Functions

```solidity
function sweepFees(address receiver) external returns (uint256 amount);
function sweepDust(address receiver) external returns (uint256 amount);
```

### `sweepFees`

Must revert if:

- Caller lacks `FEE_ADMIN_ROLE`.
- `receiver == address(0)`.
- `accruedFees == 0`.

Execution order:

1. `amount = accruedFees`.
2. `accruedFees = 0`.
3. Emit `FeesSwept`.
4. `SafeERC20.safeTransfer(collateralAsset, receiver, amount)`.

`sweepFees` must never read or reduce `collateralLocked`. The transferable amount is exactly `accruedFees` and nothing else.

### `sweepDust`

Must revert if:

- Caller lacks `DEFAULT_ADMIN_ROLE`.
- `state != SETTLED`.
- `totalSupply() != 0`.
- `totalUnclaimedShortAmount != 0`.

Under those preconditions no claim can ever be made against the series again, so the entire remaining balance is provably unclaimable dust. Any weaker precondition requires proving remaining claimants stay covered and must not be implemented without redoing that proof.

Execution order:

1. `amount = collateralAsset.balanceOf(address(this)) - accruedFees`.
2. `collateralLocked = 0`.
3. Emit `DustSwept`.
4. `SafeERC20.safeTransfer(collateralAsset, receiver, amount)`.

## Pause and Emergency Specification

Pause modes:

```text
pauseMinting
pauseKuruLinking
pausePremiumRouting
pauseSettlement
pauseRedemption
```

Rules:

- `pauseMinting`, `pauseKuruLinking`, and `pausePremiumRouting` are acceptable first-line controls.
- `pauseSettlement` should be used only when oracle settlement is actively unsafe.
- `pauseRedemption` should be avoided and used only if redemption itself is actively exploitable.
- Pauses must be evented with reason codes.

## Needs Founder Decision

Do not let an AI agent silently choose these:

- Launch assets and quote assets.
- Whether single-oracle series are allowed when only Chainlink or only Pyth exists.
- Exact oracle deviation thresholds.
- Exact stale-price thresholds.
- Launch fee rates for mint, exercise, and residual fees.
- Fee recipient address.
- Emergency multisig addresses.
- Governance/timelock model.
- Whether primary-sale helpers are in scope for V1.
- Default Kuru market precision parameters per asset.
- Maximum acceptable Kuru venue fee for a market to be linkable.
- Prolonged oracle outage recovery process.
- Whether swept dust is protocol revenue or returned pro-rata.
- Final `MIN_EXPIRY_DELAY` and `MAX_EXPIRY_DELAY` values.

Protocol fees themselves are now **in scope for V1** by founder direction. What remains open is the rate values, not whether fees exist. See [fee-spec.md](./fee-spec.md) and FD-06.

