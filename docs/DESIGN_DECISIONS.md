# Design Decisions

Why Optara PM is built this way, where these docs differ from the original plan
([`better implementation.md`](better%20implementation.md)), and what is still open.

## 1. Decisions

| ID | Decision | Why | Rejected alternative |
|---|---|---|---|
| DD-1 | Uncapped standard European calls and puts | Users expect normal options | Capped payoffs (V2) |
| DD-2 | Portfolio margin with IM/MM, liquidation and insurance | Uncapped calls can't be fully collateralized in stablecoin; same model as major CEXs | Full collateral; clearinghouse default fund |
| DD-3 | Signed internal balances + one ERC-20 wrapper per series | Internal balances make portfolio margin possible; wrappers keep claims tradable anywhere | Wrappers as the only position model |
| DD-4 | No centralized matching; venues trade wrappers | Keeps trading permissionless; no operator | Derive-style matching engine |
| DD-5 | `mintExternalLong` creates a short and wrappers together | Writers can sell without a counterparty inside Optara | Requiring an internal match |
| DD-6 | Kuru through a replaceable adapter, router and registry | Kuru-specific code stays out of clearing; venues can be added | Hardcoded Kuru calls in clearing |
| DD-7 | Own signed volatility-surface oracle (option a) with quorum and Merkle grid | No IV feed exists on Monad; Merkle grid keeps on-chain storage small | Governance-set vol; intrinsic-only margin |
| DD-8 | Black-76 on-chain, zero rates, sticky-strike scenarios | Deterministic; sticky strike avoids extra leaf proofs per scenario | Off-chain marks |
| DD-9 | Margin per underlying bucket, summed | Simple and safe; no correlation assumptions | Cross-underlying offsets |
| DD-10 | Direction-aware stale IV | A stale surface can't inflate equity | One stale multiplier for all legs |
| DD-11 | Dutch portfolio-slice auction; the liquidator funds its own margin | Always improves the account; no venue dependency | Selling on Kuru; seizing collateral |
| DD-12 | Settlement window gated by a participant counter, then one recovery ratio | No first-come-first-served drain; bounded gas | Immediate redemption |
| DD-13 | Insurance before any haircut; seed required before risk | Buyers are protected first | Haircut first |
| DD-14 | Fees from day one: seller fee on mark, buyer fee on router premium | Funds insurance and keepers; `maxFee` protects users | Fee-free launch |
| DD-15 | Upgradeable proxies + timelock; protected storage for terms and results | Allows fixes and future matching | Immutable core (V2) |
| DD-16 | One settlement asset per subaccount | No cross-stablecoin risk | Multi-collateral accounts |
| DD-17 | Round-in-force Chainlink settlement (V2 rule) | Proven, caller can't choose the price | Unspecified TWAP |
| DD-18 | `minPositionQty` | Stops dust accounts from delaying settlement | No minimum |
| DD-19 | `OptionPricer` is an internal (inlined) library; normal CDF from Numerical Recipes `erfcc` | No linked-library deploy step and no `DELEGATECALL` per price; `erfcc` keeps relative accuracy in the tails (measured: abs error 4.2e-8, tail relative error 1.1e-7) | Linked library; Abramowitz & Stegun 7.1.26 (tail relative error up to 100%) |
| DD-20 | One `ProtocolControl` for roles, pause bits and manual close-only flags; modules inherit `OptaraModule` (ERC-7201 storage, transient reentrancy guard) | One place to grant roles and pause across modules; a guardian action takes one transaction. Costs one cold account access per transaction (10,100 gas on Monad) | Per-module AccessControl and pause state; close-only flags inside `PortfolioRiskManager` |
| DD-21 | `UpgradeAdmin` deploys OpenZeppelin Transparent proxies and owns their ProxyAdmins; anyone executes after `eta`; delays immutable and bounded (2–365 days, 1 hour–365 days) | Upgrade code stays out of implementations; deterministic execution; bounded delays keep `eta` in `uint64` (an unbounded delay could wrap it and allow an immediate upgrade) | UUPS; OpenZeppelin AccessManager; governance-only execution |
| DD-22 | Module dependencies are passed to initializers as addresses computed in advance from `UpgradeAdmin`'s nonce; no wiring setters | Dependencies are fixed at deployment as ACCESS_CONTROL §1 requires, with no setter to misuse; changing one needs an upgrade | Wire-once setters; registry lookups at run time |
| DD-23 | Hard caps on product bounds, series per group and open interest so settlement numerators never overflow ([MATH.md](MATH.md) §14); settlement price clamped per group (C-14) | An overflow at settlement would block payouts forever; a clamp at an unreachable price keeps settlement live | Unbounded terms; reverting on extreme prices |
| DD-24 | One ledger write path (`applyDelta`) that maintains totals, position indexes and participants and emits `BalanceUpdated` / `CashUpdated`; immutable series data cached on first use; `minPositionQty` only changes to a divisor | One place where INV-2, INV-6, INV-27 and INV-43 can break, tested in isolation; indexers rebuild balances from ledger events alone; the cache avoids cold registry calls (10,100 gas each on Monad); the divisor rule keeps every existing balance valid | Per-module bookkeeping; registry lookups on every write; a free minimum |
| DD-25 | Spot: Pyth direct or derived (base/USD ÷ quote/USD); a derived price is as old as its older leg; prices stored only if strictly newer | Pyth on Monad quotes in USD; the older leg decides freshness so a stale stablecoin leg can't hide; storing gives INV-18 and one freshness rule | Reading Pyth directly at use time; the newer leg's time |
| DD-26 | Surface: emergency mode and low confidence are flags in `VolSurfaceOracle` that the risk manager treats as close-only causes; IV moves compared at the same expiry; `kNodes` stored only when changed; only current-report leaves provable | No cross-module writes into `ProtocolControl`; clears automatically when a confident report arrives; a meaningful move check even when tenors roll; grids rarely change, so most reports skip 33 storage writes | Oracle calling `setProductCloseOnly`; comparing tenor indexes |
| DD-27 | One risk parameter set per product (assigned once); set contents change through direction-aware functions: conservative ones (`raiseImBuffer`, `raiseMinIv`, `addScenarios`, lowering caps) instant for the risk admin, anything else governance | A bucket needs one scenario set; checking "more conservative" for arbitrary sets is not decidable on-chain, so only provably conservative edits are instant | Risk set per series (mixed sets in one bucket); one setter with a conservativeness check |
| DD-28 | Three margin modes (STRICT, LIQUIDATION, VIEW); `previewMint` lives in `OptionClearing` | One engine serves risk-increasing checks, liquidation (stale-tolerant, INV-45) and the UI (never reverts on staleness); the mint preview needs the seller fee, which the risk manager doesn't own | Separate code paths per use |
| DD-29 | Fee and insurance custody is push-then-notify: the payer transfers, then a permissioned `notify*` call credits only after checking `held ≥ recorded + amount`; open `deposit`/`fundKeeperReserve` pull the exact amount | Clearing and the router keep one transfer per fee and no allowances to fee contracts; recorded balances can never exceed tokens held; only the module that pushed can notify, so pushed tokens can't be claimed by others | `transferFrom` pulls from Clearing (needs standing allowances); trusting the notified amount without a balance check |
| DD-30 | `OracleUpdate` names the products to refresh (`spotProductIds`); reports at or below the current sequence are skipped; the module forwards exactly the provider fee and refunds the rest itself | `LiveSpotOracle.update` needs product ids to copy provider prices into its store; deriving them from the account costs a full position scan per call; skipping stale reports stops one user's transaction from failing because another submitted the same report first | Deriving products from the account's buckets; reverting on a stale report; letting the spot oracle refund the module |
| DD-31 | Liquidation measures slices with the risk engine: `sliceMark` = the account's equity drop from the moves and `sliceMM` = its MM drop, both from LIQUIDATION-mode risk before and after; the liquidator's IM check also uses LIQUIDATION mode; `previewSlice` uses the new `previewWithDeltas`; auctions end inside the slice that reaches the target or empties the bucket | One valuation for margin and liquidation (stale-IV direction included), so the improvement bound holds exactly; INV-45 requires liquidation during a stale-but-allowed surface, which a STRICT check on the liquidator would block; previews must equal execution (PRV-004) | Re-pricing moved legs in the liquidation module; STRICT liquidator check; a separate call to end auctions |

## 2. Corrections to the original plan

These change formulas in the plan that would not work as written.

| ID | Plan said | These docs say | Why |
|---|---|---|---|
| C-1 | `grossClaim = payoff × (internal longs + wrapper supply)` | `grossClaim = wrapper claims + net creditor claims` ([MATH.md](MATH.md) §13) | Settlement nets each account's longs against its shorts. Counting gross internal longs double-counts and creates a false shortfall (worked example: 0.78 instead of 1.0) |
| C-2 | `unsettledDebtorCount += 1` for accounts whose net settlement is a debt | `participants` = accounts with any non-zero balance in the group, maintained on every 0↔non-zero change ([SETTLEMENT.md](SETTLEMENT.md) §5) | Whether an account is a debtor depends on the final price, unknown before finalization. Creditors must settle too, so their netted claims are known |
| C-3 | Liquidation `discount = |sliceMark| × bonusBps` | `discount = sliceMM × bonusBps` ([MATH.md](MATH.md) §12) | Deep out-of-the-money shorts have a tiny mark but a large MM; a mark-based bonus would give liquidators no reason to take them. MM-based keeps the health improvement provable |
| C-4 | "Risk bucket" not defined | One subaccount × one underlying | Needed for margin aggregation and liquidation scope |
| C-5 | `closeShortWithInternalLong` undefined | Moves a long from one of the caller's subaccounts to another that is short | Within one subaccount, same-series longs and shorts net automatically |
| C-6 | Liquidation timing after expiry unspecified | Expired legs are never transferred; finalized legs never auctioned | Their value no longer depends on live markets |
| C-7 | (first draft of these docs) IM buffer = `imBufferBps × maxLoss` | Buffer = `imBufferBps × current mark of all shorts` | A loss-based buffer lets unwrapping or closing *lower* `equity − IM` (`verify_math.py` M6b found hundreds of cases). The short-mark buffer never rises on risk-reducing actions, so INV-13 holds exactly (M6) |
| C-8 | (first draft) IM over the IM set only | IM over the IM set ∪ MM set | With separate sets, a mixed long/short-vega portfolio can lose more in a milder MM scenario, so `MM > IM` (M7b found a case). The union guarantees INV-14 |
| C-9 | (first draft) "total short unchanged by slices" | Net balance unchanged; total short never increases (may fall by netting) | The simulation showed liquidators with opposite positions net against moved shorts |
| C-10 | (first draft) shortfall example paid 650; slice MM = `f × MM` | Payout 649.999999 (round-down); slice MM = actual MM drop after rounding moved quantities to `minPositionQty`; dust slices revert | Found by M5e and the simulation; makes rounding explicit |
| C-11 | (first draft) event list had `SurfaceRejected` and an unused `InsuranceCovered` | `SurfaceRejected` removed (a rejected report reverts, so it can't emit); `InsuranceCovered` emitted by `computeRecoveryRatio` when insurance pays a settlement shortfall | Found by `reference/check_traceability.py` |
| C-12 | (first draft) stale penalty in whole "hours stale", rounding unspecified | Penalty accrues per second and rounds up ([MATH.md](MATH.md) §5.1) | Integer hours would give zero penalty for the first hour, then jump; per-second rounding up is continuous and conservative |
| C-13 | (first draft) wrappers burnable only by Clearing and SettlementWindow; surface tenor coverage checked at series creation | `LiquidationModule` is also a burner (it burns wrappers in wrapper-burn liquidation); tenor coverage is checked at mint (`SeriesNotPriceable`), not creation | The draft contradicted STATE_MACHINE §7 and LIQUIDATION §4; publishers add tenors after listing, so creation can't depend on the current surface |
| C-14 | (step 4) settlement price clamped to the product's `maxSettlementPriceWad` | Clamp per group to `min over its series of floor(1e50 / contractSize)`, in `SettlementWindow` | Product bounds can be changed by re-approval after series exist; the per-series contract size is what bounds each numerator |
| C-15 | Surface acceptance only required `surfaceSeq` to increase | Also `validAfter ≥` the stored one, every tenor after `validAfter`, ATM IV within the report's bounds | A newer sequence number with older data would reset staleness; a tenor at or before the report time gives no IV |

## 3. Open decisions (must be resolved before launch)

| ID | Question | Options | Default in these docs |
|---|---|---|---|
| OD-1 | Stress calibration | (a) As written: shocks to expiry incl. +100% and near-expiry; (b) liquidation-horizon shocks `±k·σ·√h` via `timeMode = 2` | (a). It is conservative: a naked 30-day call needs ~33× its premium (3,524.55 vs 106.77). (b) would give roughly CEX-level margins but relies more on liquidation working quickly |
| OD-2 | Collateral custody | (a) In upgradeable `OptionClearing`; (b) a small non-upgradeable vault | (a) per the plan; (b) reduces upgrade trust |
| OD-3 | Spot source per product | Pyth pull; Chainlink Data Streams; push feeds | Pyth pull |
| OD-4 | Publisher operators | Block Scholes (ETH/BTC), independent operators, MON synthetic | 3 publishers, quorum 2, ≥ 1 independent |
| OD-5 | Final parameter values | [PARAMETERS.md](PARAMETERS.md) | Defaults listed there |
| OD-6 | Kuru adapter details | Verify Kuru contracts, margin-account flow, fees | Spec is interface-level only |
| OD-7 | Internal-balance matching later | In-house adapter on wrappers vs an internal transfer primitive | Adapter slot only |
| OD-8 | Permanent oracle failure | Governance recovery procedure | Disclosed residual risk |
| OD-9 | Gas fallback | Signed price table | Only if benchmarks fail |
