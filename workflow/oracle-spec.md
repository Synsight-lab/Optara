# Oracle Spec

## Purpose

This file defines V1 oracle behavior for settlement and premium safety.

Founder-approved V1 oracle model:

```text
Settlement sources
  Primary:                Chainlink if feed exists for pair.
  Secondary/corroborator: Pyth if feed exists for pair.
  Priced at:              expiry. Chainlink: the round in force at expiry.
                          Pyth: the first update at or after expiry. Both proven onchain.

Not oracle sources
  Kuru:                   premium execution and depth sanity only, never a price input.
```

## Security Principle

There is no unhackable oracle. V1 reduces oracle risk by using independent sources, freshness checks, deviation checks, and fail-closed behavior.

Kuru market prices must not determine settlement because Kuru markets can be thin, manipulated, paused, or unavailable.

## Price Format

All oracle adapters must normalize to:

```text
PRICE_SCALE = 1e18
price = human price of 1 WHOLE underlying in WHOLE quote, times PRICE_SCALE
```

Example:

```text
MON/USDC = 5.25
normalized price = 5.25e18
```

This holds regardless of how many decimals either token has. Converting a normalized price into token amounts is done with the `UQ_SCALE` helper in [math-of-core-invariants.md](./math-of-core-invariants.md), never inside an adapter.

Adapters must read the source's decimals and convert explicitly. `PriceData.sourceDecimals` is reported for auditing only — the `price` field it accompanies is **already normalized**, and consumers must never rescale it.

## Division of Responsibility

Adapters and the router have deliberately separate jobs:

```text
adapter   fetches ONE source, normalizes it, reports what it found, and for settlement
          verifies the anchor proof and that source's anchor window
router    applies ALL cross-source and reference policy: reference staleness,
          Pyth confidence, deviation, quorum, fail-closed
```

An adapter's only accept/reject decisions are structural ones: the data is unusable, or, on the anchored read, the proof does not identify the correct observation or the observation falls outside that source's anchor window (`maxChainlinkAgeAtExpiry` or `maxPythSettlementLag`, passed in as an argument from the series' immutable `OracleConfig`). Those are properties of one source's own history, so they live with the code that reads that source. Everything that compares or combines sources, or applies a reference-read threshold, is the router's job.

Each threshold value comes from the series' immutable `OracleConfig`.

This matters because policy in one place can be audited once. Policy spread across three adapters can drift, and an adapter upgrade could silently relax how strictly a live series is validated.

### Feed Identifiers Are Passed, Never Looked Up

An adapter receives the feed address or feed id as a call argument, taken from the series' immutable config. Adapters must **not** hold an internal `(base, quote) -> feed` mapping.

A mapping inside the adapter would be a second source of truth for which feed settles a series, and it would be governable: repointing it would change the settlement oracle of an already-live series, breaking the immutability guarantee in DD-03 that the whole option-token model depends on.

### Where Pair Identity Is Checked

Because an adapter receives a feed identifier rather than an asset pair, it cannot verify at settlement time that the feed describes the series' pair. That check is a **creation-time** control:

```text
configHash = keccak256(abi.encode(oracleConfig))
factory requires ProtocolConfig.isApprovedOracleConfig(underlying, quote, configHash)
the config is frozen into the series and can never change
```

**The pair is part of the approval key and must not be omitted.** An `OracleConfig` names feed addresses and feed ids. It does not record which assets those feeds price. If approval were keyed on the config hash alone, then approving a MON/USD feed set for the MON/USDC pair would approve those same feeds for every other pair at once, and anyone could create a WBTC/USDC series carrying the MON feeds. It would pass validation, mint normally, and settle WBTC options at MON's price. Because the adapter no longer re-checks the pair at settlement, this key is the only thing binding feeds to assets.

This is stronger than comparing a feed's description string at runtime, which is fragile and inconsistently supported across sources. The tradeoff is that approving an oracle config becomes security-critical: an approval binding the wrong feed to a pair cannot be corrected on any series already created against it.

## Source Priority

For each series:

1. Chainlink feed is primary if available for the pair.
2. Pyth feed is secondary and corroborates Chainlink if available.

Kuru is not an oracle source at any level. It may be inspected for premium execution sanity, which is a market-health check, not a price input.

## Series Oracle Configuration

Each series stores:

```solidity
struct OracleConfig {
    address chainlinkFeed;
    bytes32 pythFeedId;
    bool requireChainlink;
    bool requirePyth;
    uint32 maxOracleDeviationBps;
    uint32 chainlinkStaleAfter;   // reference reads only, never settlement
    uint32 pythStaleAfter;        // reference reads only, never settlement
    uint32 maxChainlinkAgeAtExpiry; // how old the Chainlink round in force at expiry may be
    uint32 maxPythSettlementLag;    // how far past expiry Pyth's first qualifying update may sit
    uint32 maxPythConfidenceBps;    // max Pyth confidence interval as bps of price
}
```

Recommended production policy:

- If Chainlink feed exists for the pair, `requireChainlink = true`.
- If Pyth feed exists for the pair, `requirePyth = true`.
- If both exist, each must anchor to expiry by its own rule (Chainlink: the round in force at expiry; Pyth: the first update at or after expiry), each must satisfy its own window, and they must pass the deviation check.
- If only one exists, listing the series requires explicit founder/governance approval.
- There is no DEX TWAP source in V1. See the note under Settlement Quorum Rules.

## The Settlement Price Is Anchored to Expiry

This is the single most important rule in this file, and getting it wrong is silently exploitable.

A European option settles at the price **at expiry**. It does not settle at the price whenever somebody happens to call `settle()`.

If settlement simply read the current price and required it to be fresh relative to `block.timestamp`, then whoever calls `settle()` chooses the settlement price by choosing when to call. Settlement is permissionless and the vault has no deadline of its own, so a holder with a large position would simply wait: if the option is out of the money at expiry, wait for a favorable move and settle then. The writer's collateral is taken by a caller who did nothing but pick a moment. Freshness checks do not help, because a price from an hour ago is perfectly fresh and still not the expiry price.

V1 therefore requires that the settlement observation be **pinned to expiry and proven onchain**. Each source has its own rule, chosen so that both sources describe the same moment:

```text
Chainlink   the round IN FORCE at expiry: the last round with updatedAt <= expiry,
            proven by its immediate successor having updatedAt > expiry
Pyth        the first update with publishTime >= expiry,
            and publishTime <= expiry + maxPythSettlementLag
```

Chainlink is a push feed that updates on a deviation threshold or a heartbeat, so its first update after expiry can be an entire heartbeat away. Taking that later round as "the expiry price" would make it a price from up to an hour after expiry, while Pyth, which publishes about once a second, would describe the moment right at expiry. Comparing them in the deviation check would then compare two different market moments and could fail an honest settlement. Using the round that was **in force** at expiry gives Chainlink's true value at expiry and puts both sources on the same moment. Pyth's first update lands within seconds of expiry, so the only remaining gap is at most `maxPythSettlementLag`, which is small by construction.

The caller supplies a proof identifying the observation. The adapter verifies the proof against the source. A caller who names any other round is rejected, so the settlement price is a deterministic function of the series and the feed's history, identical no matter who settles or when.

### Proving the Anchor

```solidity
struct SettlementProof {
    uint80 chainlinkRoundId;      // the round in force at expiry: updatedAt <= expiry
    uint80 chainlinkNextRoundId;  // its immediate successor: updatedAt > expiry; never derived as roundId + 1
    bytes pythUpdateData;         // Pyth update(s) proving the first publish at or after expiry
}
```

**Chainlink.** The caller names the round in force at expiry and its immediate successor. The adapter verifies that the named round really is the last one at or before expiry by checking both:

```text
(, answer, , updatedAtRound, ) = feed.getRoundData(chainlinkRoundId)
(, ,      , updatedAtNext,   ) = feed.getRoundData(chainlinkNextRoundId)

require(chainlinkRoundId != 0)
require(chainlinkNextRoundId != chainlinkRoundId)
require(isImmediateChainlinkSuccessor(feed, chainlinkRoundId, chainlinkNextRoundId))
require(updatedAtRound <= expiry)                          // in force at expiry
require(updatedAtNext  >  expiry)                          // and nothing newer before expiry
require(expiry - updatedAtRound <= maxChainlinkAgeAtExpiry) // not a long-dead feed
require(answer > 0)
```

The price is `answer` of `chainlinkRoundId`, never the successor's.

The `updatedAtNext > expiry` check is what makes the proof unforgeable: a caller cannot name an earlier round, because that round's successor would still be at or before expiry, and cannot name a later round, because it would not be at or before expiry. Exactly one round satisfies both checks.

The immediate-successor check is as important as the timestamp checks. If the contract accepted any later round as `chainlinkNextRoundId`, a caller could name an older round whose real successor was still at or before expiry, pair it with a distant post-expiry round as its supposed successor, and settle at that older, more favorable price.

Chainlink proxy round ids are phase-encoded:

```text
proxyRoundId = (phaseId << 64) | aggregatorRoundId
```

The adapter must therefore verify adjacency explicitly:

```text
same phase:
    phase(next) == phase(round)
    aggregatorRound(next) == aggregatorRound(round) + 1

phase boundary:
    phase(next) == phase(round) + 1
    aggregatorRound(next) == 1
    feed.getRoundData(round + 1) reverts, proving round was the last valid round of its phase
```

All other successor shapes are invalid. An implementation must never derive the successor by adding one to the round id. The offchain proof builder is responsible for resolving phase boundaries and supplying the right successor.

Because the successor must exist, `settle()` cannot succeed until Chainlink has published its first update after expiry. This is a delay of at most about one heartbeat, not a lock, and it does not change the price. Keepers simply wait for the successor round.

`maxChainlinkAgeAtExpiry` checks that the round in force is not absurdly old. It is measured against `expiry`, not against `block.timestamp`, so it is a deterministic property of the feed's history and does not reintroduce the timing choice this section removes. It exists to catch a feed that had already gone dark before expiry.

**Pyth.** Pyth exposes the first-update shape natively. Use the API that returns the first update within a publish-time window rather than the latest price:

```text
parsePriceFeedUpdatesUnique(
    updateData,
    ids,
    minPublishTime = expiry,
    maxPublishTime = expiry + maxPythSettlementLag
)
```

Do not use a "latest price, no older than" call for settlement. That reintroduces exactly the timing choice this section exists to remove.

### Anchor Windows

Two per-series values, frozen at creation alongside the rest of the oracle config:

```text
maxChainlinkAgeAtExpiry   how old the Chainlink round in force at expiry may be
                          set from the feed's heartbeat plus a buffer
maxPythSettlementLag      how far after expiry Pyth's first qualifying update may sit
                          small, because Pyth publishes continuously
```

If Chainlink's round in force is older than `maxChainlinkAgeAtExpiry`, or Pyth has no update inside its window, settlement fails closed. The windows are deliberately *not* a deadline on calling `settle()`: the call can be made at any later time, because the proofs pin the prices regardless.

The two windows fail in different ways. A too-small `maxChainlinkAgeAtExpiry` rejects a healthy feed that simply had a quiet stretch before expiry, so it must sit comfortably above the feed's heartbeat. A too-small `maxPythSettlementLag` rejects settlement when Pyth briefly stalls across expiry.

Recommended starting values and final approval: FD-21 in [founder-decisions.md](./founder-decisions.md).

### Pyth Confidence

A Pyth price is published with a confidence interval. A price whose interval is wide relative to the price is a price Pyth itself is unsure about, so V1 rejects it:

```text
pyth.confidence * BPS_SCALE / pyth.price <= maxPythConfidenceBps
```

The adapter normalizes the confidence to `PRICE_SCALE` exactly as it does the price and reports it in `PriceData.confidence`. The router applies the threshold, on both settlement and reference reads. Chainlink reports no confidence and its `confidence` is zero.

The check can add a settlement lock path if Pyth's confidence is unusually wide at the instant after expiry, so `maxPythConfidenceBps` is part of FD-02.

### Freshness Versus Anchoring

The two checks answer different questions and both are needed, in different places:

```text
anchoring   used for SETTLEMENT     is this observation the one at expiry?
freshness   used for REFERENCE      is this observation recent enough to price against now?
```

`chainlinkStaleAfter` and `pythStaleAfter` apply to `getReferencePrice`, which feeds premium bounds before expiry. They do **not** apply to settlement, where the anchor replaces them. Applying a now-relative freshness check to settlement is the bug described above.

Settlement has its own, expiry-relative bounds, `maxChainlinkAgeAtExpiry` and `maxPythSettlementLag`. They compare an observation against `expiry`, never against `block.timestamp`, so they are properties of the feed's history and not of when `settle()` was called.

## Settlement Quorum Rules

All settlement pass conditions below operate on the **anchored** observation, never on a live read.

### Chainlink Only

Allowed only if no Pyth feed exists or the series is explicitly approved as single-oracle.

Pass conditions:

```text
chainlinkPrice > 0
round in force at expiry proven per the rules above
expiry - updatedAt <= maxChainlinkAgeAtExpiry
```

Result:

```text
settlementPrice = normalizedChainlinkPrice
```

### Pyth Only

Allowed only if no Chainlink feed exists or the series is explicitly approved as single-oracle.

Pass conditions:

```text
pythPrice > 0
Pyth update proves the first publish time in [expiry, expiry + maxPythSettlementLag]
```

Result:

```text
settlementPrice = normalizedPythPrice
```

### Chainlink + Pyth

Preferred V1 mode.

Pass conditions:

```text
chainlink valid: round in force at expiry, proven, and not older than maxChainlinkAgeAtExpiry
pyth valid: first update at or after expiry, inside maxPythSettlementLag
abs(chainlinkPrice - pythPrice) / min(chainlinkPrice, pythPrice) <= maxOracleDeviationBps
```

Both prices are anchored to expiry, each by its own rule, so they describe the same moment to within `maxPythSettlementLag`. That is what makes the deviation check meaningful: a failure means the sources genuinely disagree, not that they were sampled at different times. Comparing an anchored Chainlink price against a live Pyth price would make the deviation check depend on when settlement is called.

There is deliberately no separate timestamp-skew parameter. Chainlink's round in force at expiry may have been published long before expiry, so comparing publish timestamps would reject healthy feeds; what matters is the moment each price describes, and the anchor rules already align that.

Result:

```text
settlementPrice = normalizedChainlinkPrice
```

Rationale:

- Chainlink is the founder-approved primary source.
- Pyth is the independent corroborator.
- If Pyth disagrees beyond the threshold, settlement fails closed.
- The protocol does not invent a new settlement price from Kuru or market data.

### No DEX TWAP Source in V1

V1 has no DEX TWAP oracle. There is no `dexTwapAdapter`, no `requireDexTwap`, and no `DexTwapOracleAdapter` contract.

A TWAP cannot be anchored the way the other sources can. Anchoring names a single observation — a Chainlink round, a Pyth publish time — and proves it is the correct one for expiry. A TWAP is an average over a window, so there is no observation to name. Making it settlement-grade would require reading the average over a window *ending* at expiry, and those observation buffers have finite cardinality and get overwritten, so a series settled long after expiry would find them gone and become unsettleable. That would silently remove the settle-at-any-time property anchoring exists to provide.

Keeping it as a reference-only signal was considered and rejected too, because nothing would ever read it: the reference path selects sources by the same `require*` flags settlement uses, so a source that can never be required is a source that can never be consulted. An adapter that cannot be reached is not a safety feature, it is unreachable code that an implementer would build and an auditor would have to review.

If a later version wants TWAP corroboration, it needs the historical-window read above, a separate flag that actually selects it on the reference path, and a policy for insufficient cardinality that reconciles with FD-20.

## Failure Behavior

Settlement must fail closed if:

- The Chainlink proof does not identify the round in force at expiry and its immediate successor.
- The Chainlink round in force at expiry is older than `maxChainlinkAgeAtExpiry`.
- The Chainlink successor round has not been published yet (settlement waits; it is not a lock).
- Required Pyth source has no valid first update inside `[expiry, expiry + maxPythSettlementLag]`.
- Chainlink and Pyth deviation exceeds threshold.
- Price is zero or negative.
- Price decimals are unsupported.
- Pyth update data is invalid or underpaid.

When settlement fails:

```text
state remains ACTIVE
minting remains blocked by expiry
redemption remains blocked
writer residual claim remains blocked
```

No fallback to Kuru is allowed.

## Config Is Read, Not Passed

`OracleRouter` reads a series' `OracleConfig` from the registry using `seriesId`. It does not accept a caller-supplied config.

Accepting one would let any caller request a price under weakened rules — passing `requireChainlink: false` with a large staleness window, for example — and nothing in the signature would bind the config to the series it claims to describe.

Because the router derives config from authoritative state and has no side effects on series state, its price functions are safe to leave permissionlessly callable. They return a price; they do not settle anything.

## Premium Reference Price

Premium safety may use `OracleRouter.getReferencePrice`.

Rules:

- Same quorum rules as settlement, on the same series config.
- Can be called before expiry.
- Used only for premium bounds.
- Must not write settlement state.
- Must not be confused with final expiry settlement price.

It is kept as a separate function from `getSettlementPrice` rather than merged, so that the two can diverge later — reference pricing could adopt stricter staleness, for instance — without that change silently loosening or tightening settlement, and so events distinguish the two uses.

## Pyth Pull-Oracle Handling

If Pyth is required:

- `settle` must accept update data or use a verified pre-updated price path.
- Caller pays the required Pyth update fee as `msg.value`.
- Invalid Pyth update causes revert.

### Archiving Pyth Update Data

Chainlink rounds stay readable on chain forever, so a Chainlink proof can always be rebuilt later. Pyth update data comes from an off-chain service, and its retention for old windows is not something this protocol controls. The settle-at-any-time guarantee therefore depends on that data still being obtainable.

Operations must archive, for every series that requires Pyth, the Pyth update data covering `[expiry, expiry + maxPythSettlementLag]` shortly after expiry, and keep it until the series is settled. The keeper should also be able to settle promptly, since a prompt settlement avoids the dependency entirely. A series whose Pyth data cannot be recovered cannot be settled, which is the FD-20 case.

### Native Token Refunds

Pyth update fees are quoted per call, so a caller will routinely send more than is consumed. Every payable function in the path must return the remainder:

```text
vault.settle               forwards msg.value to the router when Pyth is required,
                           refunds the returned remainder to msg.sender
router.getSettlementPrice  forwards available native value to the adapter,
                           refunds the returned remainder to its caller
adapter.read/readAt        consumes the exact update fee, refunds the remainder
```

No contract in this path may retain native token. A vault that accumulates ETH has no withdrawal path, since `sweepFees` moves the collateral asset only.

Refund with a low-level call and check the return value. Refunds happen after all state updates, and every payable state-changing function in the path is `nonReentrant`, so a refund to a contract that re-enters observes fully updated state.

## Chainlink Handling

The adapter checks only what makes the data structurally usable. Thresholds are the router's job.

```text
answer > 0
updatedAt > 0
answeredInRound >= roundId when applicable
feed decimals <= 18
```

Note that `chainlinkStaleAfter` does **not** appear here. Staleness is a router-applied policy, and it applies only to reference reads. For settlement the adapter instead proves the anchor, per the rules above.

### Composed Feeds

V1 does **not** support composed settlement feeds.

If the quote asset is not USD and the available feeds are USD-based, a composed price may look tempting:

```text
MON/USDC from MON/USD and USDC/USD
```

But the V1 interfaces cannot express the required proof safely. `OracleConfig` carries only one Chainlink feed and one Pyth feed id per source, `SettlementProof` carries one Chainlink round/successor pair, and `IOracleAdapter.readAt` accepts one feed identifier at a time. A composed settlement feed would require proving two independently anchored legs, carrying two successor proofs, and composing prices only after both legs pass those checks.

Therefore V1 requires direct feeds for every approved settlement pair:

```text
approved settlement config -> direct Chainlink feed and/or direct Pyth feed id for the pair
no composed Chainlink legs
no composed Pyth legs
no USD-leg composition inside adapters
```

If a later version supports composed feeds, it must expand `OracleConfig`, `SettlementProof`, adapter interfaces, validation tests, and the deviation policy together. Until then, approving a composed feed config is invalid.

## Prolonged Outage and the Permanent-Lock Risk

The fail-closed design has a consequence that must be stated explicitly rather than left implicit in the failure table above.

If a required oracle **never** returns valid data, then:

```text
settle()               always reverts
state stays ACTIVE forever
redeem()               unreachable, because it requires SETTLED
claimWriterResidual()  unreachable, because it requires SETTLED
collateral             permanently locked, for holders and writers alike
```

Under the anchoring rules above, the ways to reach this state are narrow:

```text
Chainlink   the feed never publishes another round after expiry (no successor to prove against),
            or the round in force at expiry is older than maxChainlinkAgeAtExpiry
Pyth        no update exists inside [expiry, expiry + maxPythSettlementLag]
two-oracle  the sources genuinely disagree beyond maxOracleDeviationBps and keep disagreeing
```

A slow-but-alive Chainlink feed is **not** on this list: its next round only delays settlement, because the price used is the round already in force.

There is no code path out of this state in the current design. That is a deliberate consequence of refusing to fall back to a manipulable price source, but it is a real user-funds risk and not merely a liveness inconvenience.

V1 must do one of two things before mainnet, decided in [founder-decisions.md](./founder-decisions.md) FD-20:

- Accept the risk and disclose it prominently in user-facing risk copy, or
- Implement a recovery path with a delay long enough that users can observe and react to it.

Any recovery path must be timelocked, evented, incapable of running while normal settlement is still possible, and incapable of producing a settlement price from Kuru. An `EmergencyRecoveryModule` implementing the chosen option is listed as an optional contract in [implementation-spec.md](./implementation-spec.md); it stays unimplemented until FD-20 is resolved.

Shipping without an explicit decision selects permanent lock by default. That may be an acceptable choice, but it should be a chosen one.

## Needs Founder Decision

Before production:

- FD-01: decide whether single-oracle series are allowed at all.
- FD-02: decide max deviation bps for Chainlink/Pyth and the max Pyth confidence.
- FD-03: decide stale thresholds by asset class.
- FD-21: decide `maxChainlinkAgeAtExpiry` and `maxPythSettlementLag` per feed.
- FD-20: decide the prolonged-outage recovery path. This one can permanently lock user funds.
- FD-23: confirm exact Chainlink and Pyth feed addresses/feed IDs for Monad mainnet.
- FD-23: confirm that Chainlink actually operates feeds for the intended pairs on Monad; if it does not, FD-01 becomes a launch blocker rather than a policy question.
