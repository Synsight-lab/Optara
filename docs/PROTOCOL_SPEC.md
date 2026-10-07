# Protocol Specification

Every external function: who may call it, what it checks, what it changes, what it emits. If another document
disagrees about function behavior, this one wins (formulas: [MATH.md](MATH.md)).

## 0. Conventions

- Every state-changing function is `nonReentrant` and checks its pause bit (§11).
- "Authorized for `accountId`" = `msg.sender` is the owner or an approved operator of the subaccount.
- "Fresh oracles" = apply the `OracleUpdate`, then require a fresh spot price and a fresh surface for every product
  the account touches ([MARGIN_AND_RISK.md](MARGIN_AND_RISK.md) §5).
- "Require healthy(a)" = `equity(a) ≥ IM(a)` computed after all effects of the call.
- All ledger writes go through one internal function that maintains per-series totals and the group participant
  counter ([SETTLEMENT.md](SETTLEMENT.md) §5).
- Amounts: quantities 18 decimals; cash native units.
- Every ledger write that leaves a balance non-zero requires `|balance| ≥ minPositionQty` (INV-6). Error
  `PositionBelowMinimum`.
- Functions taking `OracleUpdate` are `payable` (for provider update fees); unused value is refunded.

## 1. SubAccounts

### `createSubAccount(address settlementAsset) → uint256 accountId`
- Anyone. `settlementAsset` must be approved in the registry (`AssetNotApproved`).
- Creates the account with owner `msg.sender`; ids start at 1 and increase.
- Event `SubAccountCreated(accountId, owner, settlementAsset)`.

### `setOperator(uint256 accountId, address operator, bool approved)`
- Owner only (operators can't manage operators). `operator ≠ 0`.
- Event `OperatorSet(accountId, operator, approved)`.

### Writer functions (`OptionClearing`, `LiquidationModule`, `SettlementWindow` only; fixed at deployment)

| Function | Effect | Reverts | Event |
|---|---|---|---|
| `addCash(accountId, amount)` | `cash += amount` | `UnknownAccount` | `CashUpdated(accountId, +amount, cash)` |
| `subCash(accountId, amount)` | `cash −= amount` | `InsufficientCash`, `UnknownAccount` | `CashUpdated(accountId, −amount, cash)` |
| `applyDelta(accountId, seriesId, delta) → balance` | `balance += delta`; updates per-series totals, the account's series list and underlying buckets, the per-(account, group) series count and `participants[group]` (SETTLEMENT.md §5). `delta = 0` is a no-op | `AssetMismatch` (series asset ≠ account asset), `PositionBelowMinimum` (new balance non-zero and not a multiple of, or below, `minPositionQty`), `PositionLimit` (a new series beyond `maxSeriesPerAccount` or a new underlying beyond `maxBucketsPerAccount`), `UnknownSeries`, `UnknownAccount` | `BalanceUpdated(accountId, seriesId, delta, balance)`; `ParticipantsUpdated(groupId, n)` when the count changes |

The ledger checks accounting rules only. Business rules (who may act, closing at most the short, finalization,
health) are checked by the calling module. The ledger's `CashUpdated` and `BalanceUpdated` events alone are enough
to rebuild every cash balance and position.

### Governance

- `setPositionLimits(maxSeries, maxBuckets)`: `1 ≤ maxBuckets ≤ maxSeries`, `maxSeries ≤ 64`, `maxBuckets ≤ 16`
  (`InvalidLimits`). Lowering forces nothing; it only blocks new positions beyond the limit. Event
  `PositionLimitsSet`.
- `setMinPositionQty(q)`: `q` must divide the current minimum exactly (`InvalidLimits`), so every existing balance
  stays a valid multiple (INV-6). Event `MinPositionQtySet`.

Views: `positionsOf(accountId) → Position[]` (each with its cached series data, one call for the risk manager),
`seriesInfo(seriesId) → (LedgerSeries, cached)`, `productShortNotional(productId)` (Σ |short| × CS, 1e36 units),
`ownerOf`, `settlementAssetOf`, `cashOf`, `balanceOf(accountId, seriesId) → int256`,
`seriesOf(accountId) → bytes32[]`, `bucketsOf(accountId) → address[]`, `isAuthorized(accountId, caller)`,
`isOperator`, `participants(groupId)`, `seriesCountInGroup(accountId, groupId)`,
`totals(seriesId) → (internalLong, internalShort)`, `accountCount`, `maxSeriesPerAccount`, `maxBucketsPerAccount`,
`minPositionQty`, `writers`.

## 2. OptionSeriesRegistry and ExternalOptionFactory

### `setSettlementAssetApproved(address asset, bool approved)`
- Approve: governance. Revoke: governance or guardian (risk-reducing).
- Approving reads `decimals()` from the token: it must be a contract with 0–18 decimals (`NotAContract`,
  `UnsupportedDecimals`). Revoking blocks new subaccounts, products and series in that asset; existing positions
  run to settlement.
- Event `SettlementAssetApproved(asset, approved, decimals)`.

### `approveProduct(address underlying, address settlementAsset, ProductConfig cfg) → bytes32 productId`
- Governance. The settlement asset must be approved (`AssetNotApproved`). Calling it again for an existing product
  updates its bounds (new series only) and re-enables it.
- `ProductConfig`: strike bounds, contract-size bounds, time-to-expiry bounds, `maxSettlementPriceWad`, and display
  symbols. Checks (`InvalidProductConfig(reason)`): 1 addresses (zero or equal), 2 strike (`0 < min ≤ max ≤
  maxSettlementPrice`), 3 contract size (`0 < min ≤ max`), 4 time (`0 < min ≤ max ≤ 730 days`), 5 settlement price
  (`≤ 1e36` and `maxContractSize × maxSettlementPrice ≤ 1e50`, see [MATH.md](MATH.md) §14), 6 symbols (1–16 bytes).
- Events `ProductApproved(productId, underlying, settlementAsset, config)`, `ProductEnabled(productId, true)`.

### `setProductEnabled(bytes32 productId, bool enabled)`
- Enable: governance. Disable: governance or guardian. Unknown product → `ProductNotEnabled`.
- A disabled product gets no new series; existing series run to settlement. Event `ProductEnabled`.

### `createSeries(SeriesParams p) → bytes32 seriesId`
- Role `SERIES_CREATOR`; pause bit `SERIES_CREATE` (global, asset, product scope). Checks in
  [OPTION_SPEC.md](OPTION_SPEC.md) §6 (`ProductNotEnabled`, `AssetNotApproved`, `InvalidSeriesParams(reason)`,
  `SeriesExists`, `GroupFull`).
- Deploys the wrapper through `ExternalOptionFactory.deployWrapper` (clone at a deterministic address), stores the
  terms (write-once), registers the group if new (at most 256 series per group).
- Events `GroupCreated(groupId, underlying, settlementAsset, expiry, settlementOracleConfigId)` if new,
  `WrapperDeployed(seriesId, wrapper, name, symbol)` (factory), `SeriesCreated(seriesId, groupId, wrapper, terms)`.

Views: `getSeries(seriesId)` (reverts `UnknownSeries`), `seriesExists`, `groupOf(seriesId)`, `productOf(seriesId)`,
`seriesInGroup(groupId)`, `getGroup(groupId)`, `getProduct(productId)`, `isProductEnabled`,
`isSettlementAssetApproved`, `settlementAssetDecimals`, `seriesDomain`, `computeSeriesId`, `computeGroupId`,
`computeProductId`.

### `ExternalOptionFactory.deployWrapper(seriesId, name, symbol) → wrapper`
- Registry only. Clones the wrapper implementation with salt `seriesId` and initializes it with the fixed minter
  (`OptionClearing`) and burners (`OptionClearing`, `SettlementWindow`, `LiquidationModule`).
- Views: `predictWrapper(seriesId)`, `wrapperImplementation`, `registry`, `clearing`, `settlementWindow`,
  `liquidationModule`.

### `ExternalOptionWrapper`
- `mint(to, amount)`: minter only. `burn(from, amount)`: burners only. Standard ERC-20 and EIP-2612 `permit`
  (domain name = the wrapper name, version "1"). Views: `seriesId`, `minter`, `isBurner`.

## 3. OptionClearing — collateral

`OptionClearing` holds every settlement-asset token backing account cash and settlement pools (INV-7). Pause bits
are checked with the account's asset (collateral) or the series' asset and product (positions). Functions taking an
`OracleUpdate` apply it first ([ORACLES.md](ORACLES.md) §4) and refund unused `msg.value` last.

### `depositCollateral(uint256 accountId, uint256 amount)`
- Anyone may deposit into any account (deposits only help). Pause bit `DEPOSIT`.
- Account exists (`UnknownAccount`); `amount > 0` (`ZeroAmount`). Pulls exactly `amount` of the account's settlement
  asset (balance-difference check; `NonExactTransfer` on fee-on-transfer tokens).
- `cash += amount`.
- Event `CollateralDeposited(accountId, from, amount)`.

### `withdrawCollateral(uint256 accountId, uint256 amount, address recipient, OracleUpdate u)` (payable)
- Pause bit `WITHDRAW`. Authorized for `accountId` (`NotAuthorized`). `amount > 0`, `recipient != 0`
  (`InvalidRecipient`).
- Apply `u`; `cash −= amount` (`InsufficientCash`); require healthy (STRICT). An account with no positions reads no
  oracle data, so it can always withdraw its cash.
- Transfer to `recipient`. Event `CollateralWithdrawn(accountId, recipient, amount)`.

## 4. OptionClearing — positions

### `mintExternalLong(uint256 accountId, bytes32 seriesId, uint256 qty, address recipient, uint256 maxSellerFeeNative, OracleUpdate u)` (payable)
- Series exists (`UnknownSeries`); pause bit `MINT`; authorized; `qty > 0`; `recipient != 0`.
- Insurance seed and keeper reserve of the series' asset at their minimums (`InsuranceBelowMinimum(asset)`, checked
  before the oracle update so the specific error surfaces).
- Apply `u`. Effects, in order:
  1. `balance −= qty` (ledger: `AssetMismatch`, `PositionLimit`, `PositionBelowMinimum`);
  2. `checkOpenRisk(seriesId, caps = true)` on the post-mint ledger: `SeriesNotActive`, `ProductCloseOnly`,
     `OpenInterestCap(seriesId | productId)`;
  3. `fee = previewSellerFee(seriesId, qty)`; `fee ≤ maxSellerFeeNative` (`FeeTooHigh`); if `fee > 0`:
     `cash −= fee` (`InsufficientCash`), transfer it to `FeeController`, `notifySellerFee` (split);
  4. require healthy (STRICT: `StaleSpot`, `StaleSurface`, `NotHealthy`, …);
  5. `wrapper.mint(recipient, qty)`.
- Event `ExternalLongMinted(accountId, seriesId, qty, recipient, fee)` (plus `SellerFeeCharged`, `FeeSplit`).

### `wrapLong(uint256 accountId, bytes32 seriesId, uint256 qty, address recipient, OracleUpdate u)` (payable)
- Pause bit `WRAP`; authorized; `qty > 0`; `recipient != 0`; series active (`SeriesNotActive`); `balance ≥ qty`
  (`InsufficientLong`).
- Apply `u`; `balance −= qty`; require healthy (the long may have been a hedge); `wrapper.mint(recipient, qty)`.
- Event `LongWrapped(accountId, seriesId, qty, recipient)`.

### `unwrapLong(uint256 accountId, bytes32 seriesId, uint256 qty)`
- Pause bit `UNWRAP`. Anyone holding wrappers may unwrap into an account they're authorized for. `qty > 0`. Series
  active (before expiry; afterwards wrappers redeem through settlement).
- `wrapper.burn(msg.sender, qty)`; `balance += qty` (ledger: asset match, position limits — this only adds a series
  if the balance was 0).
- No oracle data or margin check (adding a long never lowers health).
- Event `LongUnwrapped(accountId, seriesId, qty, from)`.

### `closeShortWithWrapper(uint256 accountId, bytes32 seriesId, uint256 qty)`
- Pause bit `CLOSE`; group not finalized (`GroupAlreadyFinalized`; allowed after expiry until finalization); authorized;
  `qty > 0`; `balance ≤ −qty` (`InsufficientShort`).
- `wrapper.burn(msg.sender, qty)`; `balance += qty`.
- No oracle data or margin check.
- Event `ShortClosedWithWrapper(accountId, seriesId, qty)`.

### `closeShortWithInternalLong(uint256 fromAccountId, uint256 toAccountId, bytes32 seriesId, uint256 qty, OracleUpdate u)` (payable)
- Pause bit `CLOSE`; group not finalized; caller authorized for **both** accounts; `qty > 0`;
  `balance[from] ≥ qty` (`InsufficientLong`) and `balance[to] ≤ −qty` (`InsufficientShort`). The ledger rejects a
  different settlement asset (`AssetMismatch`).
- Apply `u`; `balance[from] −= qty`; `balance[to] += qty`; require healthy(`from`). The target only loses a short,
  so its health never falls (INV-13).
- Event `ShortClosedWithInternalLong(fromAccountId, toAccountId, seriesId, qty)`.

### `updateOracles(OracleUpdate u)` (payable)
- Anyone. Applies spot updates, surface reports and node proofs without any other action; refunds unused value.

### Custody (internal modules only)

| Function | Caller | Effect |
|---|---|---|
| `payInsurance(asset, amount)` | `LiquidationModule`, `SettlementWindow` | Transfer to `InsuranceFund` + `notifyDeposit` (penalties, swept dust). The caller has already debited the matching cash or pool. `amount = 0` is a no-op |
| `payOut(asset, to, amount)` | `SettlementWindow` | Transfer to `to ≠ 0` (wrapper redemptions). The caller has already debited the matching pool |

### Views

- `previewMint(accountId, seriesId, qty) → (fee, equityAfter, imAfter, ok)`: the fee and VIEW-mode risk after the
  hypothetical mint (`previewWithDelta(−qty, −fee)`), equal to what `mintExternalLong` produces in the same block
  (PRV-001). `ok` = data fresh, series active, product not close-only, cash covers the fee and `equityAfter ≥ imAfter`;
  it does not check open-interest caps or position limits.
- `modules()`: the module addresses fixed at initialization.

## 5. PortfolioRiskManager

Margin per [MATH.md](MATH.md) §5–§9. Every series of a product uses the product's one risk parameter set, so a
risk bucket (one product) has one scenario set. Values are WAD of the account's settlement asset.

### 5.1 Checks used by other modules

| Function | Mode | Reverts |
|---|---|---|
| `requireHealthy(accountId) → Risk` | STRICT: fresh spot and FRESH surface for every product the account holds | `StaleSpot`, `StaleSurface`, `MissingSurfaceNode`, `SeriesNotPriceable`, `NotHealthy(equity, IM)` |
| `checkOpenRisk(seriesId, checkCaps)` | — | `SeriesNotActive` (at or after expiry), `ProductCloseOnly`, and with `checkCaps` (mints): `OpenInterestCap(seriesId)` if total internal short > the set's `maxOpenInterestPerSeries`, `OpenInterestCap(productId)` if product short notional > `maxShortUnderlyingWad` |
| `riskForLiquidation(accountId) → Risk` | LIQUIDATION: fresh spot; surface FRESH or STALE (penalties applied) | `StaleSpot`, `StaleSurface` beyond `maxSurfaceStale` (INV-45) |

A product is close-only when `ProtocolControl` flags it, its surface is missing or older than `maxSurfaceStale`,
the current report has low confidence, the surface is in emergency mode, or the settlement asset's reserves are
below their minimums.

### 5.2 Views (VIEW mode: never revert on staleness; `fresh` reports it)

| View | Returns |
|---|---|
| `riskOf(accountId)` | `Risk {equity, initialMargin, maintenanceMargin, fresh}` |
| `healthOf(accountId)` | `(HEALTHY / CLOSE_ONLY / LIQUIDATABLE / INSOLVENT, equity, IM, MM, fresh)`; INSOLVENT = equity < 0 with no unexpired legs left |
| `equityOf(accountId)`, `marginOf(accountId)` | equity; `(IM, MM)` |
| `previewWithDelta(accountId, seriesId, qtyDelta, cashDeltaNative)` | `Risk` after a hypothetical balance and cash change |
| `previewWithDeltas(accountId, seriesIds[], qtyDeltas[], cashDeltaNative)` | `Risk` after several hypothetical balance changes (repeated ids add up; `LengthMismatch` if the arrays differ) |
| `previewWrap(accountId, seriesId, qty)` | `(equityAfter, imAfter, ok)` |
| `previewWithdraw(accountId, amount)` | `(equityAfter, imAfter, ok)` |
| `maxWithdrawable(accountId)` | `min(cash, floor((equity − IM) / scale))`, 0 if not healthy |
| `priceOf(seriesId)` | `(mid, shortPrice, longPrice)` per option (intrinsic once expired, payoff once finalized) |
| `ivOf(seriesId)` | `(σ, σ_short, σ_long)` |
| `isProductCloseOnly(productId)`, `isRiskSetForProduct(productId, setId)`, `getRiskSet(id)`, `productRiskSet(productId)`, `productShortCap(productId)` | |

Views revert only when pricing is impossible: no spot ever (`StaleSpot`), no surface (`StaleSurface`), a missing
leaf (`MissingSurfaceNode`) or an expiry outside the surface's tenors (`SeriesNotPriceable`). `previewMint` (which
needs the seller fee) is in `OptionClearing`.

### 5.3 Admin

| Function | Caller | Rule | Event |
|---|---|---|---|
| `createRiskSet(id, RiskParams)` | Governance | New id (`RiskSetExists`); valid (`InvalidRiskParams(reason)`: 1 buffer ≤ 5000 bps, 2 `0 < minIv < maxIv ≤ 1000%`, 3 near-expiry floor ≤ 1 day, 4 `0 < maxOpenInterestPerSeries ≤ 1e24`, 5 1–24 MM and ≤ 24 IM scenarios, 6 scenario values: shocks in [−100%, +1000%], `timeMode ≤ 2`, shift only with mode 2) | `RiskSetCreated`, `RiskSetEnabled` |
| `updateRiskSet(id, RiskParams)` | Governance (timelocked) | Replace everything, either direction | `RiskSetUpdated` |
| `raiseImBuffer(id, bps)`, `raiseMinIv(id, minIv)` | Risk admin or governance (instant) | Increase only (reason 7) | `RiskSetUpdated` |
| `addScenarios(id, initialAdd, maintenanceAdd)` | Risk admin or governance (instant) | Append (a larger set can only raise a maximum loss); ≤ 24 per set | `RiskSetUpdated` |
| `setOpenInterestCap(id, cap)` | Lower: risk admin or governance. Raise: governance | `0 < cap ≤ 1e24` | `RiskSetUpdated` |
| `setRiskSetEnabled(id, enabled)` | Disable: risk admin, guardian or governance. Enable: governance | Disabled sets can't be used by new series; existing series keep being margined with them | `RiskSetEnabled` |
| `assignProductRiskSet(productId, id)` | Governance, once per product (`RiskSetAlreadyAssigned`) | Set enabled (`UnknownRiskSet`); product exists (reason 8) | `ProductRiskSetAssigned` |
| `setProductShortCap(productId, capWad)` | Lower: risk admin or governance. Raise: governance | Product has a set (reason 8) | `ProductShortCapSet` |

## 6. LiquidationModule

Risk is measured in LIQUIDATION mode throughout (fresh spot; surface fresh, or within `maxSurfaceStale` with stale
penalties; INV-45). A bucket is one account × one underlying. Pause bit `LIQUIDATE` (asset and product scope) on
`startAuction`, `liquidateSlice` and `liquidateWithWrapper`; `endAuction` is never paused. The liquidator account must
be operated by the caller (`NotAuthorized`), differ from the liquidated account (`InvalidRecipient`) and share its
settlement asset (`AssetMismatch`). Functions taking `OracleUpdate` are payable and refund unused value.

### `startAuction(uint256 accountId, address underlying, OracleUpdate u)`
- Anyone. No active auction for the bucket (`AuctionActive`). Apply `u`.
- The bucket has unexpired positions (`EmptyBucket(accountId, underlying)`); `equity < MM`
  (`NotLiquidatable(equity, MM)`, INV-21).
- Records the start time. Event `AuctionStarted(accountId, underlying, equity, MM, startTime)`.

### `liquidateSlice(accountId, underlying, liquidatorAccountId, sliceBps, minCashToLiquidator, maxCashFromLiquidator, OracleUpdate u)` — see [LIQUIDATION.md](LIQUIDATION.md) §3
- Auction active (`AuctionNotActive`); `minSliceBps ≤ sliceBps ≤ maxSliceBps`, or `≤ 10,000` in whole-bucket mode
  (`SliceOutOfBounds`). Apply `u`.
- The account is below the target `IM × (1 + targetHealthBufferBps)` (`NotLiquidatable(equity, target)`, INV-46).
- Moves `sliceBps` of every unexpired leg of the bucket (rounded down to `minPositionQty`) to the liquidator; the
  ledger nets against opposite positions and checks the liquidator's position limits (`PositionLimit`).
- `sliceMark` = the account's equity drop from the moves, `sliceMM` = its MM drop (must be `> 0`,
  `HealthNotImproved`). Cash per [MATH.md](MATH.md) §12, insurance top-up up to `maxInsurancePerLiquidation`
  (`BadDebtCovered`), penalty to insurance through `OptionClearing.payInsurance`.
- `cash received ≥ minCashToLiquidator` and `cash paid ≤ maxCashFromLiquidator` (`SlippageExceeded`); the
  account's `equity − MM` strictly increased (`HealthNotImproved`, INV-22); the liquidator covers its IM
  (`NotHealthy`, INV-23).
- Event `SliceLiquidated`. If the account reached the target, or the bucket has no unexpired positions left, the
  auction ends in the same call (`AuctionEnded`, reason 0 or 1).

### `liquidateWithWrapper(accountId, seriesId, qty, liquidatorAccountId, minCashToLiquidator, OracleUpdate u)` — see [LIQUIDATION.md](LIQUIDATION.md) §4
- `qty > 0`; series unexpired (`SeriesNotActive`); the account is short at least `qty` (`InsufficientShort`).
  Apply `u`. Account below MM (`NotLiquidatable(equity, MM)`); an auction is not required, but its current bonus
  applies if one is active (otherwise `startBonusBps`).
- Burns the caller's wrappers; the account's short shrinks by `qty`; `ΔMM > 0` (`HealthNotImproved`).
- The account pays the liability's mark value (its equity rise) plus `ΔMM × bonus`, with the same insurance top-up and
  penalty rules; `cash received ≥ minCashToLiquidator`; health strictly improves.
- Event `WrapperLiquidated(accountId, seriesId, qty, liquidatorAccountId, cashToLiquidator, penalty)`.

### `endAuction(uint256 accountId, address underlying, OracleUpdate u)`
- Anyone. Auction active (`AuctionNotActive`). Apply `u`. Ends with reason 1 if the bucket has no unexpired
  positions, else requires `equity ≥ IM × (1 + targetHealthBufferBps)` (`AuctionActive` otherwise) and ends with
  reason 0. Event `AuctionEnded`.

### Admin

| Function | Caller | Rule | Event |
|---|---|---|---|
| `setLiquidationParams(p)` | Governance (timelocked) | `InvalidLiquidationParams(reason)`: 1 `startBonus > maxBonus` or `maxBonus + penalty ≥ 10,000`; 2 `auctionDuration` 0 or above 7 days; 3 not `0 < minSlice ≤ maxSlice ≤ 10,000`; 4 `targetHealthBufferBps > 10,000` | `LiquidationParamsSet` |
| `setMaxInsurancePerLiquidation(asset, amount)` | Governance (timelocked) | Native units; 0 disables top-ups | `MaxInsurancePerLiquidationSet` |

Views: `previewSlice(accountId, underlying, sliceBps) → (sliceMark, sliceMM, discount, penalty, cashToLiquidator)`
(VIEW-mode risk via `previewWithDeltas`; equal to execution in the same block, PRV-004; `sliceMark`, `sliceMM`,
`discount` in WAD, `penalty` and `cashToLiquidator` in native units, positive = account → liquidator),
`auctionStart(accountId, underlying)`, `currentBonus(accountId, underlying) → (bonusBps, wholeBucket)`,
`liquidationParams()`, `maxInsurancePerLiquidation(asset)`, `modules()`.

## 7. SettlementWindow

Formulas: [MATH.md](MATH.md) §13; lifecycle: [SETTLEMENT.md](SETTLEMENT.md). Every amount is computed from exact
numerators `q × intrinsic × CS` (1e54 scale) and rounded once: debts up; credits, the ratio and payouts down
(INV-49). Account cash and group pools both live in `OptionClearing` custody, so collecting a debt or paying a credit
moves no tokens; insurance cover comes in through `InsuranceFund.cover`, wrapper payouts go out through
`OptionClearing.payOut`, swept dust through `OptionClearing.payInsurance`. Unknown groups revert `UnknownGroup`.
Pause bits (asset and product scope): `FINALIZE`, `SETTLE` (settling and the ratio), `CLAIM_REDEEM` (claims,
redemptions, sweep).

### `finalizeGroup(bytes32 groupId, bytes settlementData)`
- Anyone. Not finalized (`GroupAlreadyFinalized`, INV-26). `SettlementOracle.verify` proves the round in force
  (`FinalizationTooEarly`, `InvalidSettlementProof(reason)`).
- Caps the payoff price at `min(S*, min over the group's series of floor(1e50 / CS))` (MATH.md §14, C-14), snapshots
  every series' wrapper supply (INV-33) and sums the wrapper claims at the capped price.
- Pays the caller `finalizeRewardNative` (`FeeController.payFinalizeReward`). Event
  `GroupFinalized(groupId, priceWad, observationTime, participants)`.

### `flagOracleStalled(bytes32 groupId)`
- Anyone, once `now ≥ stalledAfter(config, expiry)` and the group is not finalized (`OracleNotStalled(groupId,
  stalledAfter)`). Emits `OracleStalled(groupId, stalledAfter)` once; later calls are no-ops. The group stays
  finalizable by a late authentic round.

### `settleAccountGroup(uint256 accountId, bytes32 groupId)` / `settleAccountsGroup(uint256[] accountIds, bytes32 groupId)`
- Anyone. Finalized (`GroupNotFinalized`). Single: the account is a participant (`NotParticipant`, INV-48); batch:
  non-participants (and repeats) are skipped.
- Nets all the account's series in the group into `N_a`, zeroes those balances through the ledger (decrementing
  `participants`, INV-27). Debt: `ceil(−N_a / D)`, collects `min(cash, debt)` into the pool, the rest is unpaid.
  Credit: records `creditN = N_a`.
- Pays the caller the escalating settle reward per account settled. Event
  `AccountSettled(accountId, groupId, netNumerator, collected, unpaid)`.

### `computeRecoveryRatio(bytes32 groupId)`
- Anyone. Finalized; ratio not set (`RatioAlreadySet`); `participants == 0` (`SettlementIncomplete(n)`, INV-28).
- `grossClaim = ceil((wrapperClaimN + netCreditN) / D)`; if it exceeds `collected`, `InsuranceFund.cover` pays up to
  the shortfall into the pool (`InsuranceCovered(groupId, asset, amount)` if non-zero).
- `ratio = grossClaimN == 0 ? 1 : min(1, floor((collected + insurance) × D × 1e18 / grossClaimN))`, stored once
  (INV-29). Event `RecoveryRatioSet(groupId, ratioWad, grossClaim, collected, insuranceContribution)`.

### `claimSettlement(uint256 accountId, bytes32 groupId)`
- Anyone (pays into the account). Ratio set (`RatioNotSet`); credit not yet claimed (`NothingToClaim`, INV-48).
- `cash += floor(creditN × ratio / (D × 1e18))`, taken from the pool. Event `SettlementClaimed(accountId, groupId,
  amount)`.

### `redeemWrapper(bytes32 seriesId, uint256 qty, address recipient)`
- Wrapper holder. `qty > 0` (`ZeroAmount`), `recipient ≠ 0` (`InvalidRecipient`), ratio set (`RatioNotSet`).
- Burns `qty` from the caller and pays `floor(qty × intrinsic × CS × ratio / (D × 1e18))` from the pool to
  `recipient` (zero-payoff wrappers burn for 0). Event `WrapperRedeemed(seriesId, holder, recipient, qty, payout)`.

### `sweepDust(bytes32 groupId)`
- Anyone. Ratio set; every credit claimed and every series' wrapper supply 0 (`PayoutsOutstanding(groupId)`).
- The remaining pool (rounding dust) goes to `InsuranceFund`. Event `DustSwept(groupId, amount)`.

Views: `settlementPriceOf(groupId) → (finalized, priceWad)` (the risk manager's and clearing's settlement state),
`groupState(groupId)` (ACTIVE, EXPIRED, ORACLE_STALLED, FINALIZED, ALL_SETTLED, REDEEMABLE),
`groupAccounting(groupId)`, `settlementPrice(groupId)`, `recoveryRatio(groupId) → (set, ratioWad)`,
`previewSettle(accountId, groupId) → (netNumerator, debt, collectable)`, `previewRedeem(seriesId, qty) → (payout,
ratioFixed)` (ratio 1 until fixed), `isOracleStalled(groupId)`, `creditOf(accountId, groupId)`,
`wrapperSupplyAtFinalization(seriesId)`, `modules()`.

## 8. FeeController and InsuranceFund

Custody is push-then-notify (FEES.md §9, DD-29): the payer transfers, then notifies; every credit checks
`held ≥ recorded + amount` (`TokensNotReceived`). `InvalidFeeConfig` reasons: 1 rate above `MAX_FEE_BPS` (1,000),
2 split not summing to 10,000, 3 zero recipient.

### 8.1 FeeController

| Function | Caller | Checks | Effects | Event |
|---|---|---|---|---|
| `notifySellerFee(accountId, seriesId, asset, fee)` | `OptionClearing` | Tokens received | Split: insurance and keeper shares rounded down, treasury takes the remainder; insurance share pushed to `InsuranceFund` + `notifyDeposit` | `SellerFeeCharged`, `FeeSplit` |
| `notifyBuyerFee(buyer, seriesId, asset, fee)` | `VenueRouter` | Tokens received | Same split | `BuyerFeeCharged`, `FeeSplit` |
| `fundKeeperReserve(asset, amount)` | Anyone | `amount > 0`; exact transfer | Keeper reserve += amount | `KeeperReserveFunded` |
| `payFinalizeReward(asset, keeper)` | `SettlementWindow` | — | Pay `min(finalizeRewardNative, reserve)`; 0 if keeper is zero | `KeeperRewardPaid` (if paid) |
| `paySettleReward(asset, keeper, finalizedAt)` | `SettlementWindow` | — | Pay `min(settleRewardAt(asset, finalizedAt), reserve)` | `KeeperRewardPaid` (if paid) |
| `setFeeRates(sellerBps, buyerBps)` | Governance (timelock) | Each ≤ 1,000 | Store | `FeeRatesSet` |
| `setSplit(insuranceBps, treasuryBps, keeperBps)` | Governance (timelock) | Sum = 10,000 | Store | `SplitSet` |
| `setMinSellerFee(asset, minSellerFeeNative)` | Governance (timelock) | — | Store | `MinSellerFeeSet` |
| `setMinimums(asset, insuranceSeed, keeperMin)` | Raise: risk admin, guardian, governance; lower either: governance | — | Store | `MinimumsSet` |
| `setRewards(asset, finalizeReward, settleReward)` | Governance (timelock) | — | Store | `RewardsSet` |
| `withdrawTreasury(asset, amount, to)` | Governance (timelock) | `to ≠ 0`; `amount ≤ treasury` | Treasury only (INV-10) | `TreasuryWithdrawn` |

Views: `previewSellerFee(seriesId, qty)` = `max(ceil(mark(qty) × sellerBps / 10,000), minSellerFeeNative)` with the
mark at the mid IV rounded down; `previewBuyerFee(premium)` = `ceil(premium × buyerBps / 10,000)`;
`settleRewardAt(asset, finalizedAt)`; `reservesHealthy(asset)`; `treasury(asset)`, `keeperReserve(asset)`,
`insuranceBalance(asset)`, `feeRates()`, `split()`, `assetConfig(asset)`.

### 8.2 InsuranceFund

| Function | Caller | Checks | Effects | Event |
|---|---|---|---|---|
| `deposit(asset, amount)` | Anyone | `amount > 0`; exact transfer | Seed or recapitalization; credits no account | `InsuranceDeposited` |
| `notifyDeposit(asset, amount)` | `FeeController`, `OptionClearing` | Tokens received | Balance += amount (fee share, liquidation penalty, swept dust) | `InsuranceDeposited` |
| `cover(asset, amount)` | `LiquidationModule`, `SettlementWindow` | — | Pay `min(amount, balance)` to `OptionClearing` | `InsurancePaid` (if paid) |

Views: `balanceOf(asset)`, `modules()`.

## 9. Oracles

### 9.1 LiveSpotOracle

| Function | Caller | Checks | Effect | Event |
|---|---|---|---|---|
| `update(bytes[] updates, bytes32[] productIds) payable → feePaid` | Anyone | `msg.value ≥` provider fee (`InsufficientProviderFee`); each product configured (`InvalidSpotSource`); price > 0, exponent in [−36, 0], WAD ≤ 1e36 (`InvalidSpotPrice`) | Pushes updates to Pyth, refreshes each product, stores the price only if strictly newer (INV-18); refunds the excess to the caller (`RefundFailed` if it can't) | `SpotUpdated(productId, priceWad, publishTime)` |
| `setSource(productId, SpotSource)` | Governance (timelock) | Product exists; DIRECT = one feed; DERIVED = base/USD ÷ quote/USD, two distinct feeds; `0 < maxSpotAge ≤ 1 day`; `0 < maxConfidenceBps ≤ 10,000` (`InvalidSpotSource(reason)`: 1 product, 2 kind, 3 feeds, 4 age, 5 confidence) | Stored | `SpotSourceSet` |

Views: `spotPrice(productId) → (priceWad, publishTime)`, `requireFreshSpot(productId)` (reverts
`StaleSpot(productId, age)` if never set or `age > maxSpotAge`), `isSpotFresh`, `sourceOf`, `updateFee(updates)`,
`pyth`. A derived price uses the **older** leg's publish time, so both legs must be fresh.

### 9.2 VolSurfaceOracle

| Function | Caller | Checks | Effect | Event |
|---|---|---|---|---|
| `submitReport(SurfaceReport, bytes[] sigs)` | Anyone | ORACLES.md §3.4 (`InvalidSurfaceReport(reason)`, `InvalidSignatures`) | Stores the header; stores `kNodes` only when they changed; flags low confidence | `SurfaceAccepted(productId, seq, root, validAfter, expiresAt, confidenceBps, lowConfidence)` |
| `proveNodes(NodeProof[])` | Anyone | Leaf of the product's **current** report, valid index, Merkle proof (reason 10), leaf IV within the report's bounds (reason 9) | Caches the leaf; already-proven leaves are skipped | `NodeProven` |
| `addPublisher(publisher, independent)` | Governance | Not zero, not already active (`InvalidPublisher`) | Added | `PublisherAdded` |
| `removePublisher(publisher)` | Governance or guardian | Active (`InvalidPublisher`) | Removed | `PublisherRemoved` |
| `setQuorum(n)` | Governance | `n ≥ 1` (`InvalidSurfaceConfig(10)`) | Set | `QuorumSet` |
| `setSurfaceConfig(productId, SurfaceConfig)` | Governance | `InvalidSurfaceConfig(reason)`: 1 product, 2 lifetime (1 s – 1 day), 3 move / confidence, 4 IV floor < cap ≤ 1000%, 5 stale thresholds (`staleAfter ≤ maxLongTimeValueStale ≤ maxSurfaceStale`), 6 penalty | Set | `SurfaceConfigSet` |
| `setEmergencyMode(productId, enabled)` | Enable: guardian or governance. Disable: governance | — | Waives `maxIvMoveBps`; the risk manager treats the product as close-only while on | `EmergencyModeSet` |

Views: `impliedVols(productId, spot, strikes[], expiries[]) → (sigmas, status, failedIndex, tenorIndex, nodeIndex)`
(unclamped IV per series from the current report's proven leaves; status OK, NO_SURFACE, NOT_PRICEABLE or
MISSING_NODE), `header(productId)`, `kNodes(productId)`, `nodeValue(productId, tenorIndex, nodeIndex) → (proven, w)` for the
current report, `surfaceStatus(productId) → (NONE | FRESH | STALE | EXPIRED_DATA, staleSeconds)`, `isEmergency`,
`surfaceConfig`, `reportDigest(report)`, `isPublisher(account) → (active, independent)`, `quorum`, `registry`.

### 9.3 SettlementOracle

| Function | Caller | Checks | Effect | Event |
|---|---|---|---|---|
| `registerConfig(SettlementOracleConfig) → configId` | Oracle admin | `InvalidSettlementConfig(reason)`: 1 addresses, 2 primary missing, 3 source fields, 4 feed (no code, decimals, not live), 5 window (`−7 d ≤ start ≤ end ≤ 7 d`, `minDelay ≤ maxDelay ≤ 90 d`, `maxDelay > end`), 6 skew (required for, and only for, DERIVED); `SettlementConfigExists` | Stored forever under `keccak256(abi.encode("Optara.PM.SettlementConfig", config))`, approved | `SettlementConfigRegistered`, `SettlementConfigApproved` |
| `setConfigApproved(configId, approved)` | Approve: governance. Revoke: governance or guardian | Exists (`UnknownSettlementConfig`) | Only affects new series | `SettlementConfigApproved` |

`verify(configId, expiry, settlementData) → (priceWad, observationTime, sourceUsed)` (view): reverts
`FinalizationTooEarly(earliest)` before `max(expiry + minFinalizationDelay, observationEnd + 1)`, otherwise
`InvalidSettlementProof(reason)`: 1 round unavailable, 2 round after the observation end, 3 not the latest round,
4 successor unavailable, 5 not the immediate successor, 6 successor not after the observation end, 7 primary
observation invalid, 8 primary valid (fallback refused), 9 no fallback configured, 10 fallback invalid, 11 wrong
proof count, 12 bad source index.

Views: `getConfig`, `configExists`, `isConfigApproved`, `isConfigUsable(configId, underlying, settlementAsset)`,
`computeConfigId`, `earliestFinalization(configId, expiry)`, `stalledAfter(configId, expiry)`,
`isImmediateSuccessor(feed, round, next)`.

## 10. Venues

Full rules: [VENUES_AND_KURU.md](VENUES_AND_KURU.md) §3–§6.

| Function | Caller | Checks | Event |
|---|---|---|---|
| `VenueRegistry.registerAdapter(venueId, adapter)` | Governance (timelocked) | `adapter.venueId() == venueId`, new (`InvalidAdapter` 1–2); registered disabled | `AdapterRegistered`, `AdapterEnabled` |
| `VenueRegistry.setAdapterEnabled(venueId, enabled)` | Enable: governance. Disable: guardian, venue admin, governance | Adapter exists | `AdapterEnabled` |
| `VenueRegistry.registerMarket(venueId, market, seriesId, metadata)` | Venue admin | Venue's own record: base = wrapper, quote = settlement asset; new; series unexpired (`InvalidMarket` 1–4) | `MarketRegistered` |
| `VenueRegistry.setMarketStatus(venueId, seriesId, status)` | Venue admin | Known market; ACTIVE or INACTIVE (`InvalidMarket(5)`) | `MarketStatusSet` |
| `VenueRouter.buyThroughVenue(BuyOrder, adapterData)` | Anyone | Exact-in budget, `minQty`, buyer-fee and venue-fee bounds, deadline, active market (DD-33) | `VenueTrade`, `BuyerFeeCharged` |
| `VenueRouter.sellThroughVenue(SellOrder, adapterData)` | Anyone | `minProceeds`, venue-fee bound, deadline, active market; no Optara fee | `VenueTrade` |

Views: `getMarket`, `tradableMarket`, `adapterOf` (registry); `modules()` (router); `quoteBuy`, `quoteSell`,
`marketTokens`, `venueId` (adapters). The router and the adapter keep no balance across a call (`VenueBalanceLeft`,
INV-50).

## 11. Governance: roles, pauses, close-only, upgrades

### 11.1 ProtocolControl (upgradeable; one per deployment)

Holds every role, every pause bit and the manual product close-only flags. Every module reads it.
`GOVERNANCE` is the AccessControl default admin role and is held by the governance timelock, so only governance
grants or revokes roles.

| Function | Caller | Effect | Event |
|---|---|---|---|
| `grantRole(role, account)` / `revokeRole` | Governance | Standard AccessControl | `RoleGranted` / `RoleRevoked` |
| `pause(scope, id, bits)` | Guardian or governance | Sets `bits` in the scope's mask | `Paused` |
| `unpause(scope, id, bits)` | Governance | Clears `bits` in the scope's mask | `Unpaused` |
| `setProductCloseOnly(productId, true)` | Guardian, governance, or `UpgradeAdmin` (emergency upgrade) | Flag set | `ProductCloseOnlySet` |
| `setProductCloseOnly(productId, false)` | Governance | Flag cleared | `ProductCloseOnlySet` |

Views: `hasRole`, `pausedBits(scope, id)`, `isPaused(bit, asset, productId)`, `requireNotPaused(bit, asset,
productId)` (reverts `ActionPaused`), `isProductCloseOnly(productId)`, `upgradeAdmin()`.

Scopes: `GLOBAL` (id 0), `ASSET` (id = settlement asset address), `PRODUCT` (id = productId). An action is paused if
its bit is set in the global mask, the asset's mask or the product's mask. Bits must be non-zero and defined
(`InvalidPauseBits`); scope ids must match their scope (`InvalidScope`).

```text
bit:  0 DEPOSIT  1 WITHDRAW  2 MINT  3 WRAP  4 UNWRAP  5 CLOSE  6 LIQUIDATE  7 FINALIZE  8 SETTLE
      9 CLAIM_REDEEM  10 ROUTER  11 SERIES_CREATE
```

Guidance: never pause DEPOSIT, UNWRAP or CLOSE unless they themselves are broken. They only reduce risk.

### 11.2 UpgradeAdmin (not upgradeable)

Owns the `ProxyAdmin` of every module proxy ([ACCESS_CONTROL.md](ACCESS_CONTROL.md) §3–§4).

| Function | Caller | Checks | Effect | Event |
|---|---|---|---|---|
| `deployProxy(implementation, initData)` | Governance or the bootstrap deployer | Implementation has code; the proxy's admin is the ProxyAdmin it created, owned by `UpgradeAdmin` | Deploys and initializes a `TransparentUpgradeableProxy` in one transaction | `ProxyDeployed` |
| `setImplementationAllowed(codeHash, allowed)` | Governance | — | Allowlist entry | `ImplementationAllowed` |
| `scheduleUpgrade(proxy, implementation, data)` | Governance | Known proxy; implementation has code; code hash allowlisted | `eta = now + upgradeDelay` | `UpgradeScheduled` |
| `scheduleEmergencyUpgrade(proxy, implementation, data, products)` | Emergency council | Known proxy; implementation has code | `eta = now + emergencyDelay`; each listed product set close-only now | `UpgradeScheduled`, `ProductCloseOnlySet` × n |
| `executeUpgrade(id)` | Anyone | Pending; `now ≥ eta`; code hash unchanged; normal upgrades still allowlisted | `ProxyAdmin.upgradeAndCall` | `UpgradeExecuted` |
| `cancelUpgrade(id)` | Governance (any); council (its own emergency upgrades) | Pending | Cancelled | `UpgradeCancelled` |
| `transferGovernance(next)` / `acceptGovernance()` | Governance / the pending governance | Two-step | — | `GovernanceTransferStarted` / `GovernanceTransferred` |
| `setEmergencyCouncil(council)` | Governance | Non-zero | — | `EmergencyCouncilSet` |
| `setProtocolControl(pc)` | Governance or deployer | Has code | — | `ProtocolControlSet` |
| `renounceDeployer()` | Deployer | — | Deployer cleared forever | `DeployerRenounced` |

Views: `getOperation(id)`, `proxyAdminOf(proxy)`, `implementationAllowed(codeHash)`, `upgradeDelay`,
`emergencyDelay`, `governance`, `emergencyCouncil`. Delays are immutable: `upgradeDelay` ∈ [2 days, 365 days],
`emergencyDelay` ∈ [1 hour, 365 days] (`InvalidDelay`).

## 12. Timelocked vs instant admin actions

| Instant (guardian / risk admin) | Timelocked (governance) |
|---|---|
| Pause, product close-only, emergency surface mode | Unpause, clear close-only |
| Lower OI caps, raise IV floors, raise shocks | Raise caps, lower floors, milder shocks |
| Remove a publisher | Add a publisher, change quorum |
| Disable an adapter or market | Enable an adapter |
| Raise insurance/keeper minimums | Lower minimums, change fees or split, withdraw treasury |
| — | Any upgrade |

## 13. Errors

Declared once in `contract/src/libraries/Errors.sol`; this list mirrors that file exactly
(`reference/check_traceability.py` fails if they differ).

```solidity
// ---- Access and input ----
error NotAuthorized(address caller);
error ZeroAmount();
error ZeroAddress();
error NotAContract(address account);
error InvalidRecipient();
error LengthMismatch();
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
error GroupAlreadyFinalized(bytes32 groupId);
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
error InvalidMarket(uint8 reason);
error InvalidAdapter(uint8 reason);
error AdapterDisabled(bytes32 venueId);
error VenueBalanceLeft(address token);
// ---- Liquidation ----
error NotLiquidatable(int256 equity, uint256 threshold);
error EmptyBucket(uint256 accountId, address underlying);
error InvalidLiquidationParams(uint8 reason);
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
error UnknownGroup(bytes32 groupId);
error OracleNotStalled(bytes32 groupId, uint64 stalledAfter);
error PayoutsOutstanding(bytes32 groupId);
// ---- Oracles ----
error InvalidSpotSource(uint8 reason);
error InvalidSpotPrice(bytes32 productId);
error SpotConfidenceTooWide(bytes32 productId, uint256 confidenceBps);
error InsufficientProviderFee(uint256 required, uint256 provided);
error RefundFailed();
error InvalidOracleUpdate();
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
```

## 14. Events (complete list)

```text
SubAccountCreated, OperatorSet, CashUpdated, BalanceUpdated, ParticipantsUpdated, PositionLimitsSet,
MinPositionQtySet,
SettlementAssetApproved, ProductApproved, ProductEnabled, SeriesCreated, GroupCreated, WrapperDeployed,
CollateralDeposited, CollateralWithdrawn,
ExternalLongMinted, LongWrapped, LongUnwrapped, ShortClosedWithWrapper, ShortClosedWithInternalLong,
SellerFeeCharged, BuyerFeeCharged, FeeSplit,
SpotSourceSet, SpotUpdated, SurfaceAccepted, NodeProven, PublisherAdded, PublisherRemoved, QuorumSet,
EmergencyModeSet, SurfaceConfigSet, SettlementConfigRegistered, SettlementConfigApproved,
ProductCloseOnlySet, RiskSetCreated, RiskSetUpdated, RiskSetEnabled, ProductRiskSetAssigned, ProductShortCapSet,
AuctionStarted, SliceLiquidated, WrapperLiquidated, BadDebtCovered, AuctionEnded, LiquidationParamsSet,
MaxInsurancePerLiquidationSet,
GroupFinalized, AccountSettled, RecoveryRatioSet, SettlementClaimed, WrapperRedeemed, DustSwept, OracleStalled,
InsuranceDeposited, InsurancePaid, InsuranceCovered, TreasuryWithdrawn, KeeperRewardPaid, KeeperReserveFunded,
FeeRatesSet, SplitSet, MinSellerFeeSet, MinimumsSet, RewardsSet,
MarketRegistered, MarketStatusSet, AdapterRegistered, AdapterEnabled, VenueTrade,
Paused, Unpaused, RoleGranted, RoleRevoked,
ProxyDeployed, ImplementationAllowed, UpgradeScheduled, UpgradeExecuted, UpgradeCancelled,
GovernanceTransferStarted, GovernanceTransferred, EmergencyCouncilSet, ProtocolControlSet, DeployerRenounced
```

Every event that changes a position includes `accountId`, `seriesId` (or `groupId`) and the quantity, so the indexer
can rebuild all balances from events alone.
