# Indexer, Keepers and Surface Publisher

Off-chain services. None is trusted for correctness: the contracts verify everything. Keepers only call
permissionless functions; publishers only produce signed data that the contracts check.

## 1. Indexer

### 1.1 What it stores (rebuilt from events)

| Table | Key | Fields |
|---|---|---|
| `series` | seriesId | terms, wrapper, groupId, productId, status |
| `groups` | groupId | expiry, price, participants, ratio, collected, insurance, state |
| `accounts` | accountId | owner, operators, settlement asset, cash |
| `positions` | (accountId, seriesId) | signed balance |
| `wrapper_supply` | seriesId | supply, finalization snapshot |
| `surfaces` | (productId, seq) | header, root, signers, accepted time |
| `spot` | productId | price, publish time |
| `auctions` | (accountId, underlying) | start, bonus, slices |
| `fees` | tx | seller/buyer fee, split |
| `insurance` | asset | balance, covers |
| `markets` | (venueId, seriesId) | market, status |
| `alerts` | id | see [SECURITY.md](SECURITY.md) §5 |

`SubAccounts` emits `CashUpdated` and `BalanceUpdated` for every ledger write, so `accounts.cash` and `positions`
are rebuilt from those two events alone; module events (mint, liquidation, settlement) add the context.

Health (equity, IM, MM) is **not** derivable from events. The indexer reads `healthOf` periodically for accounts with
open positions and caches it with a timestamp.

### 1.2 API

```text
GET /series, /series/:id
GET /groups, /groups/:id                     (+ participants list for keepers)
GET /accounts/:owner, /accounts/:id/health, /accounts/:id/events
GET /liquidatable                            (accounts with equity < MM, sorted by size)
GET /surfaces/:productId/latest
GET /markets
GET /system                                  (oracle freshness, close-only flags, insurance)
GET /positions                               (every non-zero position: keepers' participant source)
GET /alerts                                  (SECURITY.md §5, plus INDEX_MISMATCH and INDEX_LAG)
```

### 1.3 Reliability

- Follow confirmed blocks only; handle reorgs by rolling back to the last matching block hash.
- Idempotent event handling; every write keyed by (txHash, logIndex).
- Reconcile periodically against on-chain views (balances, totals, participants, INV-1, INV-7).

## 2. Spot updater

- Pushes Pyth (or the configured provider) updates every `maxSpotAge / 2` for products with open interest, so
  passive views stay fresh. When a publisher has a newer signed report, it pushes that report with the leaves of
  every listed unexpired series in the same `updateOracles` call (the leaves stay cached for everyone).
- Optional: users and bots also include updates in their own transactions.
- Source: Pyth Hermes (`/v2/updates/price/latest`), which needs an API key (401 without one, observed 2026-10-07).
  On Monad mainnet a third party pushes ETH/USD and USDC/USD every ~30–60 s, which helps but cannot be relied on;
  on testnet nobody pushes them, so the updater is required there (DEPLOYMENT.md §4.2).

## 3. Settlement keeper

```text
loop:
  for groups past expiry + minFinalizationDelay and not finalized:
      build the round-in-force proof -> finalizeGroup
  for finalized groups with participants > 0:
      fetch participant ids from the indexer -> settleAccountsGroup(batch of up to N)
  for groups with participants == 0 and no ratio:
      computeRecoveryRatio
```

Earns `finalizeRewardNative` and `settleRewardNative` (escalating). Anyone can run one; the protocol should run at
least two independent instances.

## 4. Liquidation bot (reference implementation)

```text
loop:
  for accounts in /liquidatable:
      update oracles; if equity < MM and no auction: startAuction
      for active auctions: previewSlice at the current bonus
          if profit after hedge cost > threshold: liquidateSlice (or liquidateWithWrapper if wrappers are cheap)
```

Needs a funded subaccount per settlement asset. Ship it open source so liquidation doesn't depend on one operator.

## 5. Surface publisher service

### 5.1 Pipeline

```text
inputs  ──> calibrate ──> validate ──> grid ──> Merkle ──> sign ──> serve
```

| Stage | What it does |
|---|---|
| Inputs | CEX option quotes (ETH, BTC), specialist provider feed (e.g. Block Scholes), market-maker quotes as **inputs**, realized volatility, Kuru quotes only once liquid |
| Calibrate | Fit a smile per tenor (e.g. SVI) and convert to total variance on the `kNodes` grid at tenors covering every listed expiry |
| Validate | No calendar arbitrage (`w` non-decreasing in tenor), no butterfly arbitrage, IV within product bounds, ATM move ≤ `maxIvMoveBps` vs the last report (else hold and alert) |
| Grid | Leaves `w(i, j)` for ≤ 4 tenors × ≤ 32 nodes |
| Merkle | Leaf format in [ORACLES.md](ORACLES.md) §3.2; sorted-pair tree |
| Sign | EIP-712 by each publisher's key; collect quorum signatures |
| Serve | API below; new report every 60 s (MON: 30 s) |

### 5.2 API

```text
GET /surface/:productId/latest            -> { report, signatures }
GET /surface/:productId/:seq/nodes?series=0x..,0x..   -> NodeProof[] for those series at current spot
GET /oracle-update?account=:id            -> complete OracleUpdate for an account's positions
```

### 5.3 Operations

- At least 3 independent publishers; quorum 2, with at least one independent signer.
- Keys in HSMs or remote signers.
- Publish `confidenceBps`, `sourceCount`, `liquidityScore` honestly. Raise `confidenceBps` when inputs are thin, so
  the protocol goes close-only instead of trusting a weak surface.
- MON: synthetic surface from realized volatility plus proxies, wide confidence, floors per
  [PARAMETERS.md](PARAMETERS.md).
- Alert if a report can't be produced for 2 minutes; the protocol goes close-only at `maxSurfaceStale` anyway.

## 6. Deployment of services

| Service | Instances | Notes |
|---|---|---|
| Indexer | 2 (active/standby) | Postgres or SQLite |
| Spot updater | 2 | Independent RPCs |
| Settlement keeper | ≥ 2 | Different operators eventually |
| Liquidation bot | ≥ 1 (open source; others encouraged) | Funded accounts |
| Surface publishers | ≥ 3 operators | Independent infrastructure |

## 7. Implementation (step 15)

Workspace (pnpm, TypeScript, viem; `pnpm -r typecheck`, `pnpm -r test`):

| Package | What it is |
|---|---|
| `sdk/` | Manifests, ABIs generated from `deployments/abi` (`gen:abi`, checked in CI), EIP-712 surface reports, Merkle leaves and proofs (OpenZeppelin sorted pairs), `OracleUpdate` JSON codecs, the round-in-force settlement proof builder, Pyth sources (Hermes, MockPyth), the series catalog and ledger directory (from events), revert decoding, gas buffer; `sdk/testing`: the local stack on anvil for every service test |
| `publisher/` | §5: inputs (Deribit public summaries; a synthetic smile for local stacks and products without options markets), SVI per expiry, grid on `kNodes` (default 13 nodes over ±1.2), validation, quorum signing with cosigners (`POST /cosign`), the §5.2 API. `pnpm --filter @optara/publisher start` |
| `keepers/` | §2–§4: `oracle`, `settle`, `liquidate` loops (`tsx src/main.ts oracle settle liquidate`). Stateless; participant and candidate lists from the indexer (`INDEXER_URL`) or the ledger's events |
| `indexer/` | §1: Envio HyperIndex (`config.yaml` generated per network from the manifest: `pnpm gen:config <network>`; `envio start`) and `api/` (`pnpm api`): health worker, reconciliation, alerts, the §1.2 API, reading Envio's Postgres directly |

Rules the implementation settles (DD-35, DD-36):

- **Publisher validation** mirrors every on-chain acceptance check (sequence, time window, lifetime, tenors, ATM
  calendar, `kNodes`, IV bounds, ATM move against the stored surface) and requires every leaf to be provable
  (inside the report's IV bounds). It adds calendar arbitrage on every node and butterfly arbitrage on the surface
  the contract evaluates (total variance linear in `k` between nodes): no concave kink at an interior node and
  Durrleman's `g(k) ≥ 0` on every segment. A cosigner re-runs the same validation on the full grid, after checking it
  hashes to `surfaceRoot`, before signing. The report's IV bounds are the product's (`minIvBps`, `maxIvBps`);
  `validAfter` is the latest block time (never ahead of the chain).
- **`confidenceBps`** = max(50, worst slice fit RMSE ÷ its ATM vol, half the median bid-ask width in vol terms
  (price width ÷ Black-76 vega, relative to the IV)), in bps; 2,000 (close-only) when no expiry could be fitted or a
  tenor lies more than 30 days outside the fitted expiries. On the 2026-10-07 Deribit ETH snapshot: 347 bps, fit
  RMSE under one vol point on every expiry.
- **Node selection** (`/oracle-update`): the tenors around each series' expiry and the nodes around its
  log-moneyness at the on-chain spot, widened by one node on each side for spot moves before inclusion; leaves the
  chain already caches are left out.
- **Indexer idempotency**: ledger events carry absolute values (cash, balance, participants), so replays are
  harmless; series totals move by the stored-versus-new balance difference; delta-based tallies (wrapper supply and
  holders, fee and insurance totals, counters) are applied once per log. Envio itself delivers each
  (block, log index) once, commits batches atomically and rolls back reorgs (verified on anvil: a replaced branch's
  account disappears). Monad uses HyperSync (`ENVIO_API_TOKEN`) with the public RPC as fallback
  (`interval_ceiling: 100`: its `eth_getLogs` covers at most 100 blocks).
- **Reconciliation** (every 5 minutes): every account's cash, every series' long and short totals (catches any
  missing or wrong position), wrapper supplies, participant counts and the account count against the chain, and
  INV-7 custody per asset (clearing balance = Σ cash + Σ group pools). Mismatches are `INDEX_MISMATCH` / `CUSTODY`
  alerts.
- **Liquidation bot profit**: a slice's gain at mark is its `discount` (the liquidator takes legs worth `sliceMark`
  and receives `−sliceMark + discount`); the bot slices when it clears `MIN_PROFIT`, applying the oracle update
  first so `previewSlice` equals execution (PRV-004).
- **Transactions** carry a gas limit 10% above the estimate (`GAS_BUFFER_BPS`, DD-36).

Operational facts found while building (2026-10-07):

- Pyth Hermes' update endpoint needs an API key (401 without one). On Monad mainnet a third party pushes ETH/USD
  and USDC/USD every ~30–60 s; testnet has no pusher, so the oracle keeper must run there.
- Pyth (and the mock) only take a price newer than the stored one: two updates stamped in the same second keep the
  first.
- Monad's public RPC limits `eth_getLogs` to 100 blocks: the catalog and ledger directory scan in 100-block chunks;
  the indexer uses HyperSync.

