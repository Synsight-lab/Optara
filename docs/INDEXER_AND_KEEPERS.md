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
```

### 1.3 Reliability

- Follow confirmed blocks only; handle reorgs by rolling back to the last matching block hash.
- Idempotent event handling; every write keyed by (txHash, logIndex).
- Reconcile periodically against on-chain views (balances, totals, participants, INV-1, INV-7).

## 2. Spot updater

- Pushes Pyth (or the configured provider) updates every `maxSpotAge / 2` for products with open interest, so
  passive views stay fresh.
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
