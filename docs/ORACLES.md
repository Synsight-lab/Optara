# Oracles

Optara PM uses three separate oracles. They must never be mixed up.

| Oracle | Gives | Used for | Never used for |
|---|---|---|---|
| `LiveSpotOracle` | Current underlying price | Margin, liquidation, fees, moneyness | Settlement |
| `VolSurfaceOracle` | Implied volatility surface | Pricing options for margin and liquidation | Settlement |
| `SettlementOracle` | One price at expiry | Payoffs | Margin |

Kuru prices are **never** an oracle input. If the venue being margined set the margin, that would be circular.

## 1. Monad oracle landscape (recheck before launch)

Monad's docs list Chainlink (including Data Streams), Chronicle, Pyth (pull), RedStone, Stork, Supra and Switchboard.
None offers a ready-made implied-volatility surface for Optara series, so Optara runs its own signed surface oracle.
For ETH and BTC, a specialist provider such as Block Scholes (EIP-712 signed IV surfaces) can serve as a publisher.
For MON, the surface is synthetic.

References: Monad oracles <https://monad.docsbot.app/tooling-and-infra/oracles>, Chainlink Data Streams
<https://docs.chain.link/data-streams>, Pyth <https://docs.pyth.network/price-feeds>, Block Scholes
<https://www.blockscholes.com/use-cases/volatility-oracle-smart-contract-integration>.

## 2. LiveSpotOracle

### 2.1 Source

Each product has one configured spot source (adapter interface `ISpotSource`).

- **v1 (implemented):** Pyth pull feeds. The caller includes signed price updates in the transaction, so prices are
  fresh. Two source kinds per product: `PYTH_DIRECT` (one underlying/asset feed) and `PYTH_DERIVED`
  (underlying/USD ÷ asset/USD, both legs configured explicitly).
- **Later, through an upgrade:** Chainlink Data Streams reports; push feeds only if their heartbeat is shorter than
  `maxSpotAge`.

### 2.2 Rules

- Price must be > 0, in settlement-asset units per underlying, normalized to WAD (`price × 10^(18 + expo)`,
  exponent in [−36, 0]) and at most 1e36.
- `now − publishTime ≤ maxSpotAge` (inclusive) for use in risk-increasing actions and liquidation. A derived price
  takes the **older** leg's publish time, so both legs must be fresh.
- An older (or equal-time) update never overwrites the stored price (INV-18).
- Derived pairs (e.g. ETH/USD ÷ USDC/USD) must be configured explicitly. A USD price is never treated as a
  stablecoin price.
- Provider update fees are paid by the caller (`msg.value`); any excess is refunded.

## 3. VolSurfaceOracle

### 3.1 What a report contains

```solidity
struct SurfaceReport {
    uint256 chainId;
    address verifyingContract;      // VolSurfaceOracle address
    bytes32 productId;              // OPTION_SPEC.md §5: keccak("Optara.PM.Product", underlying, settlementAsset)
    address underlying;
    address settlementAsset;
    uint64  surfaceSeq;             // strictly increasing per product
    uint64  validAfter;             // = reportTime
    uint64  expiresAt;
    bytes32 spotReferenceId;        // which spot feed the publisher used (audit only)
    bytes32 surfaceRoot;            // Merkle root of grid leaves
    uint64[4]  tenorTimestamps;     // absolute expiries, increasing; unused = 0
    uint256[4] atmTotalVarianceByTenor; // WAD, stored for sanity checks
    int256[]   kNodes;              // log-moneyness grid, WAD, increasing, ≤ 32 nodes
    uint32  surfaceMinIvBps;
    uint32  surfaceMaxIvBps;
    uint32  confidenceBps;
    uint16  sourceCount;
    uint32  liquidityScore;
    uint32  maxBidAskWidthBps;
    uint64  lastCalibrationTime;
    bytes32 riskParameterSetId;
}
```

The header (everything except leaves) is stored on-chain per product. `kNodes` is committed in the signed data
and its hash is stored.

### 3.2 Leaves

```text
leaf = keccak256(abi.encode(productId, surfaceSeq, tenorIndex, nodeIndex, totalVarianceWad))
```

Proofs are standard sorted-pair Merkle proofs (OpenZeppelin `MerkleProof`). A proven leaf is cached by
`(productId, surfaceSeq, tenorIndex, nodeIndex)`, so it is proved at most once per report. Only leaves of the
product's current report can be proved, and a leaf whose IV (`sqrt(w / (tenor − validAfter))`) is outside the
report's bounds is rejected. `kNodes` are stored on acceptance only when they differ from the stored grid.

Per-product settings live in the oracle (`SurfaceConfig`): report lifetime, IV move and confidence limits, IV floor
and cap, and the staleness thresholds (`surfaceStaleAfter`, `maxSurfaceStale`, `staleIvPenaltyBpsPerHour`,
`maxLongTimeValueStale`). `surfaceStatus` returns FRESH (age ≤ `surfaceStaleAfter` and before `expiresAt`), STALE
(with seconds beyond `surfaceStaleAfter`) or EXPIRED_DATA (age > `maxSurfaceStale`).

### 3.3 Verification modes

1. **Provider verifier** (not in v1; can be added by upgrade). If an approved provider offers an on-chain verifier for
   this exact format, the oracle calls it.
2. **Optara EIP-712 quorum** (implemented). At least `minPublisherQuorum` distinct approved publishers sign the EIP-712
   hash of the report.

```text
EIP712Domain(name = "Optara VolSurfaceOracle", version = "1", chainId, verifyingContract)
SurfaceReport(...all fields above, with kNodes hashed...)
```

Signatures must be from distinct publishers, sorted by signer address (cheap duplicate check). Market-maker
publishers must never make up a quorum on their own (enforced by publisher groups: at least one signer must be from
the independent group).

### 3.4 Acceptance checks (all must pass)

```text
chainId == block.chainid and verifyingContract == this
product exists and the report's underlying/settlementAsset match it
surfaceSeq > stored surfaceSeq and validAfter ≥ stored validAfter   (no replays, no going back)
validAfter ≤ now < expiresAt
expiresAt − validAfter ≤ maxReportLifetime
quorum valid (signatures sorted by signer, all active publishers, ≥ 1 independent)
1–4 tenors, increasing, all after validAfter, unused trailing entries zero
ATM total variance > 0 and non-decreasing with tenor (calendar sanity)
every ATM IV within [surfaceMinIvBps, surfaceMaxIvBps]
surfaceMinIvBps ≥ product IV floor, surfaceMaxIvBps ≤ product IV cap, min ≤ max
ATM IV change ≤ maxIvMoveBps for every tenor        (unless emergency mode is on)
    compared at the same expiry: the stored surface's ATM IV there (linear in total variance between its
    tenors, the nearest tenor's IV outside them)
kNodes strictly increasing, 1–32 nodes
confidenceBps ≤ maxConfidenceBps    (otherwise the report is stored with lowConfidence = true and the risk manager
                                     treats the product as close-only until a confident report arrives)
```

Every leaf used must also satisfy `surfaceMinIvBps ≤ implied IV ≤ surfaceMaxIvBps` once converted.

### 3.5 Emergency mode

The guardian may enable emergency mode for a product. It waives `maxIvMoveBps` so a sharp real volatility move can be
accepted. While it is on, the risk manager treats the product as close-only (an automatic cause, not a separate
flag). Only governance turns it off.

### 3.6 Publishers

- Publishers are added and removed through `publisherSetTimelock`. The guardian may remove one immediately.
- Keys belong to independent operators or an approved provider, never only to market makers who trade.
- Publisher uptime is a protocol liveness dependency. If reports stop, products go close-only after
  `maxSurfaceStale`.
- Inputs (off-chain): CEX option markets where they exist, market-maker quotes (as inputs, never as on-chain truth),
  Kuru prices only once liquid, and realized volatility as a sanity check.
- Full no-arbitrage checks are done off-chain before signing. On-chain checks are lightweight guards.
- The publisher service is specified in [INDEXER_AND_KEEPERS.md](INDEXER_AND_KEEPERS.md) §5.

### 3.7 Grid requirements

- Tenors must cover the expiries of all listed series of the product (the series expiry must lie between two
  tenors, or equal one). Publishers should include every listed expiry as a tenor.
- `kNodes` should span at least ±1.0 log-moneyness so the stress spot shocks stay inside the grid for listed strikes.

### 3.8 How IV is read

See [MATH.md](MATH.md) §5. The risk manager asks the oracle for the leaves it needs. They come in the
`OracleUpdate` (or from the cache).

### 3.9 Gas fallback (optional)

If on-chain Black-76 is too expensive, a publisher may also sign a **price table**: model prices per
(series, scenario) tied to the same `surfaceRoot` and `riskParameterSetId`. The risk manager then reads prices
instead of computing them. This needs a spec revision before use.

## 4. OracleUpdate argument

Every risk-increasing entry point and every liquidation call takes:

```solidity
struct NodeProof {
    bytes32 productId; uint64 surfaceSeq; uint8 tenorIndex; uint8 nodeIndex;
    uint256 totalVarianceWad; bytes32[] proof;
}
struct OracleUpdate {
    bytes[]        spotUpdates;      // provider-specific, may be empty if cached data is fresh
    bytes32[]      spotProductIds;   // products whose stored spot is refreshed from the provider after the blobs
    SurfaceReport[] reports;         // may be empty
    bytes[][]      reportSignatures; // one list per report
    NodeProof[]    nodes;            // leaves not yet cached
}
```

The contract applies the updates first, then runs the action against the cache. An empty update is fine if the
cache is fresh. Application rules (`contract/src/oracle/OracleUpdates.sol`, DD-30):

- Spot: if `spotUpdates` or `spotProductIds` is non-empty, the module forwards exactly the provider fee
  (`LiveSpotOracle.updateFee`) and calls `update(spotUpdates, spotProductIds)`; `msg.value` below the fee reverts
  `InsufficientProviderFee`. The module refunds `msg.value − fee` to its caller at the end of the call
  (`RefundFailed` if the caller rejects it).
- Reports: `reports.length` must equal `reportSignatures.length` (`InvalidOracleUpdate`). A report whose
  `surfaceSeq` is at or below the product's current sequence is **skipped**, not rejected, so two transactions
  carrying the same report both succeed.
- Nodes: passed to `proveNodes`; already-cached leaves are skipped there.
- The frontend's `/oracle-update` builds `spotProductIds` from the products the account holds plus the product of
  the series being traded.

## 5. SettlementOracle

### 5.1 Configuration (immutable per config id)

```solidity
struct SettlementOracleConfig {
    address underlying;
    address settlementAsset;
    address primaryFeed;  uint8 primaryDecimals;  uint8 primaryKind;   // DIRECT or DERIVED
    address primaryQuoteFeed; uint8 primaryQuoteDecimals;             // DERIVED: underlying/USD ÷ asset/USD
    address fallbackFeed; ...                                          // optional, same shape
    int64   observationStartOffset;   // e.g. −3600
    int64   observationEndOffset;     // e.g. 0
    uint64  minFinalizationDelay;
    uint64  maxFinalizationDelay;
    uint32  maxLegSkew;               // DERIVED legs must be within this many seconds
}
```

### 5.2 Rule: round in force

- The settlement price is the Chainlink round that was **in force at the observation end**
  (`expiry + observationEndOffset`): the last round with `updatedAt ≤ end`.
- The finalizer proves it by naming that round and either its immediate successor (`updatedAt > end`) or showing it
  is the feed's latest round. Exactly one round satisfies this, so the caller cannot choose the price.
- The round must also have `updatedAt ≥ expiry + observationStartOffset` and a positive answer.
- `SettlementOracle.verify` returns the proven price unclamped. `SettlementWindow` clamps it per group to
  `min over the group's series of floor(1e50 / contractSizeWad)` ([MATH.md](MATH.md) §14). The cap is above every
  product's `maxSettlementPriceWad`, so it only engages at absurd prices, and it keeps every payoff numerator bounded
  for every series in the group, whatever product bounds were in force when each series was created.
- **Trust assumption.** Chainlink stamps each round with the block time it is written in, so once
  `now > observation end` every round with `updatedAt ≤ end` is already on chain and the in-force round can't
  change. `minFinalizationDelay` adds a margin for reorgs.
- **Fallback:** the fallback feed may be used only if the caller proves on-chain that the primary's in-force round
  is invalid (stale or non-positive). Omitting primary data proves nothing.
- Finalization is allowed only when `now ≥ expiry + minFinalizationDelay` and `now > observation end`.

This is the same rule as the V2 `ChainlinkSettlementAdapter`. Its code is in git history at commit `d89d3a1`,
`contract/src/oracle/ChainlinkSettlementAdapter.sol`, and can be reused.

### 5.3 ORACLE_STALLED

If no valid price exists by `expiry + maxFinalizationDelay`, the group is flagged `ORACLE_STALLED`:

- no redemption, no settlement;
- no invented or current-spot price;
- positions stay reserved (valued at intrinsic at live spot with spot shocks);
- closes with wrappers stay open;
- a late authentic historical round can still finalize.

If every source fails permanently, the group stays unresolved until governance applies a recovery procedure
announced through the timelock. This is a disclosed residual risk.
