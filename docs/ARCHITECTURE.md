# Architecture

## 1. The big picture

```text
                 Users / Writers / Buyers / Liquidators / Keepers / Publishers
                                      |
           +--------------------------+---------------------------+
           |                          |                           |
      Frontend / SDK            Keeper bots                 Surface publishers
           |                          |                           |
           v                          v                           v
 +------------------------------------------------------------------------------+
 |                               OPTARA PM (on-chain)                           |
 |                                                                              |
 |  VenueRouter ──> VenueRegistry          FeeController ──> InsuranceFund      |
 |      |              (KuruAdapter, ...)        ^                  ^           |
 |      v                                        |                  |           |
 |  OptionClearing  <──────────────────────────────────────────────────────┐    |
 |   (entry points, custody)                                               |    |
 |      |        \                                                         |    |
 |      v         v                                                        |    |
 |  SubAccounts   ExternalOptionFactory ──> ExternalOptionWrapper (1/series)    |
 |  (ledger)      OptionSeriesRegistry (immutable series terms)            |    |
 |      ^                                                                  |    |
 |      |                                                                  |    |
 |  PortfolioRiskManager ──> OptionPricer (library)                        |    |
 |      |        |                                                         |    |
 |      v        v                                                         |    |
 |  LiveSpotOracle   VolSurfaceOracle                                      |    |
 |                                                                         |    |
 |  LiquidationModule ─────────────────────────────────────────────────────┤    |
 |  SettlementWindow ──> SettlementOracle ─────────────────────────────────┘    |
 |                                                                              |
 |  UpgradeAdmin (timelock + implementation allowlist) owns every proxy         |
 +------------------------------------------------------------------------------+
                                      |
                       External: Kuru markets, Chainlink/Pyth feeds
```

**Rule:** venues trade external long claims; Optara clears the obligation. Nothing outside Optara (Kuru balances,
wallet tokens, venue fills) changes Optara's accounting until assets actually enter an Optara contract.

## 2. Modules

| Module | Responsibility | Holds tokens? | Upgradeable |
|---|---|---|---|
| `SubAccounts` | Ledger: owners, operators, settlement asset, cash, signed option balances, per-account indexes | No | Proxy |
| `OptionSeriesRegistry` | Approved settlement assets (with decimals), products and their bounds, write-once series terms | No | Proxy (terms storage-protected) |
| `ExternalOptionFactory` | Deploys one `ExternalOptionWrapper` per series (minimal proxy clone) | No | Proxy |
| `ExternalOptionWrapper` | ERC-20 long token. Only `OptionClearing` mints; `OptionClearing`, `SettlementWindow` and `LiquidationModule` burn | — | **No** (immutable clone) |
| `OptionClearing` | All user entry points that move positions or cash; custodian of all user collateral and settlement pools | **Yes** (stablecoins) | Proxy |
| `PortfolioRiskManager` | Equity, IM, MM, health; risk parameter sets; effective product close-only (manual flag in `ProtocolControl` or an automatic cause) | No | Proxy |
| `OptionPricer` | Pure library: Black-76 price, IV interpolation, fixed-point math | — | Internal library (inlined into its users) |
| `LiveSpotOracle` | Verifies and stores fresh spot prices per product | No | Proxy |
| `VolSurfaceOracle` | Verifies signed surface reports, stores header + Merkle root, verifies grid nodes | No | Proxy |
| `SettlementOracle` | Verifies the precommitted expiry observation (round-in-force) | No | Proxy |
| `SettlementWindow` | Finalization, per-account settlement, recovery ratio, redemption | No (uses `OptionClearing` custody) | Proxy |
| `LiquidationModule` | Auctions, slice transfers, wrapper-burn liquidation | No | Proxy |
| `FeeController` | Fee formulas, fee caps, fee split, treasury and keeper reserve | **Yes** (treasury, keeper reserve) | Proxy |
| `InsuranceFund` | Insurance balance per asset, seed check, coverage payments | **Yes** | Proxy |
| `VenueRegistry` | Verified external markets per series | No | Proxy |
| `VenueRouter` | Official buy/sell routes through adapters, buyer fee collection | Transiently | Proxy |
| `KuruAdapter` | Kuru-specific order placement and verification | Transiently | Replaceable |
| `ProtocolControl` | Every role, scoped pause bits (global / asset / product), manual product close-only flags. All modules read it | No | Proxy |
| `UpgradeAdmin` | Deploys every proxy and owns its ProxyAdmin; implementation allowlist; timelocked and emergency upgrades | No | **No** |

## 3. Who may call whom

Internal privileged calls go only along these edges. Every edge is checked with an immutable or role-gated
address list, never `tx.origin`.

| Caller | May call | Purpose |
|---|---|---|
| `OptionClearing` | `SubAccounts` write functions | Change cash and balances |
| `OptionClearing` | `ExternalOptionWrapper.mint/burn` | Wrap, unwrap, close |
| `LiquidationModule` | `SubAccounts` write functions, `OptionClearing.pay*`, `ExternalOptionWrapper.burn` | Move slices and cash; wrapper-burn liquidation |
| `SettlementWindow` | `SubAccounts` write functions, `OptionClearing.pay*`, `ExternalOptionWrapper.burn` | Settle and redeem |
| `OptionClearing` | `FeeController.notifySellerFee`; `InsuranceFund.notifyDeposit` (after pushing tokens) | Seller fees; liquidation penalties and swept dust |
| `SettlementWindow` | `FeeController.payFinalizeReward`, `paySettleReward` | Keeper rewards |
| `FeeController` | `InsuranceFund.notifyDeposit` (after pushing tokens) | Insurance share of each fee |
| `SettlementWindow`, `LiquidationModule` | `InsuranceFund.cover` | Bad-debt coverage |
| `VenueRouter` | `FeeController.notifyBuyerFee` (after pushing tokens), adapters | Official trades |
| `UpgradeAdmin` | `ProxyAdmin.upgradeAndCall`, `ProtocolControl.setProductCloseOnly(…, true)` | Upgrades; emergency close-only |
| Every module | `ProtocolControl` views (`hasRole`, `requireNotPaused`, `isProductCloseOnly`) | Role and pause checks |
| Everyone | All view functions | Reads |

`OptionClearing.pay*` are internal-module-only functions that transfer stablecoins out of custody. They are never
callable by users or admins.

## 4. Data ownership

| Data | Stored in | Written by |
|---|---|---|
| Series terms, wrapper address, group id | `OptionSeriesRegistry` | Registry (once) |
| Owner, operators, settlement asset | `SubAccounts` | Owner |
| Cash `cash[accountId]` (native units) | `SubAccounts` | Clearing, Liquidation, Settlement |
| Signed balance `balance[accountId][seriesId]` (18 decimals) | `SubAccounts` | Clearing, Liquidation, Settlement |
| Per-series totals: internal longs, internal shorts | `SubAccounts` | Same |
| Wrapper supply | The wrapper token itself | Clearing, Settlement |
| Per-group participant counter | `SubAccounts` | Same |
| Risk parameter sets | `PortfolioRiskManager` | Risk admin (conservative) / governance |
| Roles, pause bits, manual product close-only flags | `ProtocolControl` | Governance, guardian, `UpgradeAdmin` (close-only on emergency) |
| Proxy admins, implementation allowlist, scheduled upgrades | `UpgradeAdmin` | Governance, emergency council |
| Spot price + timestamp per product | `LiveSpotOracle` | Anyone with a valid update |
| Latest surface header + root per product, proven nodes | `VolSurfaceOracle` | Anyone with a valid report |
| Settlement price per group, recovery ratio, pools | `SettlementWindow` | Keepers (deterministic) |
| Auctions | `LiquidationModule` | Liquidators |
| Fee rates, treasury, keeper reserve, reserve minimums | `FeeController` | Governance (timelocked); minimums raised instantly by risk admin / guardian |
| Insurance balances | `InsuranceFund` | Fees, deposits, penalties, dust; paid out only by `cover` |
| Verified markets | `VenueRegistry` | Venue admin |

## 5. Data flow of the main actions

### Mint external long (writer)
```text
writer -> OptionClearing.mintExternalLong(accountId, seriesId, qty, recipient, maxSellerFee, oracleUpdate)
   1. oracleUpdate -> LiveSpotOracle / VolSurfaceOracle (verify + cache)
   2. SubAccounts: balance -= qty
   3. FeeController.previewSellerFee -> fee; require fee <= maxSellerFee
   4. SubAccounts: cash -= fee; transfer fee to FeeController; FeeController.notifySellerFee (split to insurance/treasury/keeper)
   5. PortfolioRiskManager.requireHealthy(accountId)       // equity >= IM after everything
   6. ExternalOptionWrapper.mint(recipient, qty)
```

### Buy through the router (buyer)
```text
buyer -> VenueRouter.buyThroughVenue({venueId, seriesId, premiumIn, minQty, maxBuyerFee, maxVenueFee, recipient, deadline}, data)
   1. pull the premium budget (exact-in, DD-33) and hand it to the adapter
   2. KuruAdapter executes a market order on Kuru; the router measures wrappers received and premium spent
   3. buyer fee on the premium spent -> FeeController; FeeController.notifyBuyerFee
   4. wrappers -> recipient; unspent premium refunded exactly
```

### Liquidation
```text
liquidator -> LiquidationModule.liquidateSlice(accountId, underlying, liquidatorAccountId, sliceBps, minCashToLiquidator, oracleUpdate)
   1. verify bucket is in an active auction and still below target
   2. move sliceBps of every position in the bucket to the liquidator account
   3. move cash per MATH.md §13 (mark value ± discount, penalty to insurance)
   4. require liquidator healthy, liquidated account's health improved
```

### Settlement
```text
keeper -> SettlementWindow.finalizeGroup(groupId, settlementData)      // once
keeper -> SettlementWindow.settleAccountGroup(accountId, groupId)      // every participant
keeper -> SettlementWindow.computeRecoveryRatio(groupId)               // when participants == 0
holder -> SettlementWindow.redeemWrapper(seriesId, qty, recipient)
creditor -> SettlementWindow.claimSettlement(accountId, groupId)
```

## 6. Oracle data delivery

Risk-increasing calls take an `OracleUpdate` argument (see [ORACLES.md](ORACLES.md) §6). The contract verifies any
included spot update, surface report and grid-node proofs, caches them, then reads the cache. Clients fetch fresh
signed data from the publisher API and spot provider just before sending a transaction. Risk-reducing calls ignore
oracle data.

## 7. Upgradeability

- Every core module sits behind an OpenZeppelin `TransparentUpgradeableProxy`. `UpgradeAdmin` deploys each proxy
  (initializing it in the same transaction) and owns its `ProxyAdmin`, so upgrade logic never lives in a module.
- Governance is a timelock (`parameterTimelock`) holding the `GOVERNANCE` role in `ProtocolControl` and the
  governance seat in `UpgradeAdmin`. Everything it does is therefore delayed; instant powers (guardian, risk admin)
  can only reduce risk.
- Upgrades go through a timelock (`upgradeTimelock`, default 7 days) and must target an allowlisted implementation
  whose code hash is published in the upgrade event.
- A guardian cannot upgrade. It can only pause actions and set products close-only.
- An emergency upgrade path exists with a shorter delay (`emergencyUpgradeTimelock`) and multisig quorum. It
  automatically sets affected products close-only until governance clears them.
- **Never rewritable**, enforced by storage layout and tests: series terms, wrapper token addresses, finalized
  settlement prices, recovery ratios, redeemed amounts. See [ACCESS_CONTROL.md](ACCESS_CONTROL.md) §5.
- Wrapper tokens are immutable minimal-proxy clones. Their behavior can't be changed. Only the address allowed to
  mint and burn (a proxy) is fixed in the clone.

Trust note: because modules are upgradeable, users trust governance and the timelock. This is stated in the UI.
See [SECURITY.md](SECURITY.md) §3.

## 8. Bounded computation

The protocol never loops over all users. Every loop is bounded:

| Loop | Bound |
|---|---|
| Positions per subaccount | `maxSeriesPerAccount` |
| Underlyings (risk buckets) per subaccount | `maxBucketsPerAccount` |
| Scenarios per margin check | `maxScenarioCount` (24) |
| Surface tenors / moneyness nodes per check | 4 / 4 per series |
| Series per settlement group per account | ≤ `maxSeriesPerAccount` |

Settlement of many accounts is spread across many keeper transactions, tracked by an O(1) counter.

## 9. External dependencies

| Dependency | Used for | If it fails |
|---|---|---|
| Spot price provider (Pyth pull or Chainlink) | Margin, liquidation | New risk blocked; liquidation needs a fresh report |
| Surface publishers | Pricing | Product goes close-only; directional stale marks |
| Chainlink settlement feeds | Expiry price | Group waits; `ORACLE_STALLED` after the deadline |
| Kuru | Trading | Only trading stops; clearing and settlement unaffected |
| Keepers | Settlement, liquidation | Anyone can call; rewards attract them |

## 10. Suggested repository layout

```text
contract/
  src/
    accounts/SubAccounts.sol
    series/OptionSeriesRegistry.sol  series/ExternalOptionFactory.sol  series/ExternalOptionWrapper.sol
    clearing/OptionClearing.sol
    risk/PortfolioRiskManager.sol  risk/OptionPricer.sol  risk/FixedPoint.sol
    oracle/LiveSpotOracle.sol  oracle/VolSurfaceOracle.sol  oracle/SettlementOracle.sol
    settlement/SettlementWindow.sol
    liquidation/LiquidationModule.sol
    fees/FeeController.sol  insurance/InsuranceFund.sol
    venues/VenueRegistry.sol  venues/VenueRouter.sol  venues/KuruAdapter.sol
    governance/UpgradeAdmin.sol  governance/ProtocolControl.sol  governance/OptaraModule.sol (base)
    interfaces/  libraries/
  test/ unit/ fuzz/ invariant/ integration/ fork/ gas/
  script/
reference/   independent Python reference model (pricing, margin, settlement)
publisher/   surface publisher service
keepers/     settlement keeper, liquidation bot, spot updater
indexer/
frontend/
```
