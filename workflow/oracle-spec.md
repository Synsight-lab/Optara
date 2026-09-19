# Oracle Spec

## Purpose

This file defines V1 oracle behavior for settlement and premium safety.

Founder-approved V1 oracle model:

```text
Settlement sources
  Primary:                Chainlink if feed exists for pair.
  Secondary/corroborator: Pyth if feed exists for pair.
  Priced at:              the first observation at or after expiry, proven onchain.

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
adapter   fetches ONE source, normalizes it, reports what it found
router    applies ALL policy: staleness, deviation, quorum, fail-closed
```

Adapters hold no thresholds and make no accept/reject decision beyond marking data structurally unusable. Every threshold comes from the series' immutable `OracleConfig`, applied by the router.

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
    uint32 maxSettlementLag;      // how far past expiry the anchor may sit
}
```

Recommended production policy:

- If Chainlink feed exists for the pair, `requireChainlink = true`.
- If Pyth feed exists for the pair, `requirePyth = true`.
- If both exist, both must anchor to the same expiry window and pass the deviation check.
- If only one exists, listing the series requires explicit founder/governance approval.
- There is no DEX TWAP source in V1. See the note under Settlement Quorum Rules.

## The Settlement Price Is Anchored to Expiry

This is the single most important rule in this file, and getting it wrong is silently exploitable.

A European option settles at the price **at expiry**. It does not settle at the price whenever somebody happens to call `settle()`.

If settlement simply read the current price and required it to be fresh relative to `block.timestamp`, then whoever calls `settle()` chooses the settlement price by choosing when to call. Settlement is permissionless and the vault has no deadline of its own, so a holder with a large position would simply wait: if the option is out of the money at expiry, wait for a favorable move and settle then. The writer's collateral is taken by a caller who did nothing but pick a moment. Freshness checks do not help, because a price from an hour ago is perfectly fresh and still not the expiry price.

V1 therefore requires that the settlement observation be **pinned to expiry and proven onchain**:

```text
settlementPrice = the FIRST oracle observation with timestamp >= expiry
                  and timestamp <= expiry + maxSettlementLag
```

The caller supplies a proof identifying that observation. The adapter verifies the proof against the source. A caller who supplies a later, more favorable observation is rejected, so the settlement price is a deterministic function of the series and the feed's history — identical no matter who settles or when.

### Proving the Anchor

```solidity
struct SettlementProof {
    uint80 chainlinkRoundId;  // the first round with updatedAt >= expiry
    bytes pythUpdateData;     // Pyth update(s) bracketing expiry
}
```

**Chainlink.** The caller names a round id. The adapter verifies it is genuinely the first round at or after expiry by checking the named round and the one before it:

```text
(, answer, , updatedAtN,   ) = feed.getRoundData(roundId)
(, ,      , updatedAtPrev, ) = feed.getRoundData(roundId - 1)

require(updatedAtN   >= expiry)                      // at or after expiry
require(updatedAtPrev <  expiry)                     // and the first such round
require(updatedAtN   <= expiry + maxSettlementLag)   // feed did not go dark across expiry
require(answer > 0)
```

The `updatedAtPrev < expiry` check is what makes the proof unforgeable. Without it a caller could name any later round.

**Pyth.** Pyth exposes exactly this shape natively. Use the API that returns the first update within a publish-time window rather than the latest price:

```text
parsePriceFeedUpdatesUnique(
    updateData,
    ids,
    minPublishTime = expiry,
    maxPublishTime = expiry + maxSettlementLag
)
```

Do not use a "latest price, no older than" call for settlement. That reintroduces exactly the timing choice this section exists to remove.

### `maxSettlementLag`

A per-series value, frozen at creation alongside the rest of the oracle config. It bounds how far past expiry the anchoring observation may sit, which matters when a feed stops updating across expiry.

If no qualifying observation exists inside the window, settlement fails closed and the series enters the prolonged-outage case governed by FD-20. The window is deliberately *not* a deadline on calling `settle()`: the call can be made at any later time, because the proof pins the price regardless. Only the observation must fall inside the window.

Recommended starting value and final approval: FD-21 in [founder-decisions.md](./founder-decisions.md).

### Freshness Versus Anchoring

The two checks answer different questions and both are needed, in different places:

```text
anchoring   used for SETTLEMENT     is this observation the one at expiry?
freshness   used for REFERENCE      is this observation recent enough to price against now?
```

`chainlinkStaleAfter` and `pythStaleAfter` apply to `getReferencePrice`, which feeds premium bounds before expiry. They do **not** apply to settlement, where the anchor replaces them. Applying a now-relative freshness check to settlement is the bug described above.

## Settlement Quorum Rules

All settlement pass conditions below operate on the **anchored** observation, never on a live read.

### Chainlink Only

Allowed only if no Pyth feed exists or the series is explicitly approved as single-oracle.

Pass conditions:

```text
chainlinkPrice > 0
anchored round proven per the rules above
updatedAt in [expiry, expiry + maxSettlementLag]
```

Result:

```text
settlementPrice = normalizedChainlinkPrice
```

### Chainlink + Pyth

Preferred V1 mode.

Pass conditions:

```text
chainlink valid and anchored at expiry
pyth valid and anchored in the same window
abs(chainlinkPrice - pythPrice) / min(chainlinkPrice, pythPrice) <= maxOracleDeviationBps
```

Both sources must be anchored to the same expiry window. Comparing an anchored Chainlink price against a live Pyth price would make the deviation check depend on when settlement is called.

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

A TWAP cannot be anchored the way the other sources can. Anchoring names a single observation — a Chainlink round, a Pyth publish time — and proves it is the first at or after expiry. A TWAP is an average over a window, so there is no observation to name. Making it settlement-grade would require reading the average over a window *ending* at expiry, and those observation buffers have finite cardinality and get overwritten, so a series settled long after expiry would find them gone and become unsettleable. That would silently remove the settle-at-any-time property anchoring exists to provide.

Keeping it as a reference-only signal was considered and rejected too, because nothing would ever read it: the reference path selects sources by the same `require*` flags settlement uses, so a source that can never be required is a source that can never be consulted. An adapter that cannot be reached is not a safety feature, it is unreachable code that an implementer would build and an auditor would have to review.

If a later version wants TWAP corroboration, it needs the historical-window read above, a separate flag that actually selects it on the reference path, and a policy for insufficient cardinality that reconciles with FD-20.

## Failure Behavior

Settlement must fail closed if:

- Required Chainlink source is stale or invalid.
- Required Pyth source is stale or invalid.

- Chainlink and Pyth deviation exceeds threshold.
- Oracle pair identity does not match series pair.
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

It is kept as a separate function from `getSettlementPrice` rather than merged, so that the two can diverge later — settlement could adopt stricter staleness, for instance — without that change silently loosening or tightening the other, and so events distinguish the two uses.

## Pyth Pull-Oracle Handling

If Pyth is required:

- `settle` must accept update data or use a verified pre-updated price path.
- Caller pays the required Pyth update fee as `msg.value`.
- Invalid Pyth update causes revert.

### Native Token Refunds

Pyth update fees are quoted per call, so a caller will routinely send more than is consumed. Every payable function in the path must return the remainder:

```text
vault.settle           forwards only the required fee to the router,
                       refunds the remainder to msg.sender before returning
router.getSettlementPrice  forwards only the required fee to the adapter,
                       refunds the remainder to its caller
adapter.read           consumes the exact update fee, refunds the remainder
```

No contract in this path may retain native token. A vault that accumulates ETH has no withdrawal path, since `sweepFees` moves the collateral asset only.

Refund with a low-level call and check the return value. Refunds happen after all state updates, and every function in the path is `nonReentrant`, so a refund to a contract that re-enters observes fully updated state.

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

If the quote asset is not USD and the available feeds are USD-based, the adapter must compose them:

```text
MON/USDC from MON/USD and USDC/USD
```

Composition interacts badly with anchoring and needs care. The two legs update on independent schedules, so there is no single round that is "the" observation at expiry — each leg has its own first-round-after-expiry, and those two rounds carry different timestamps.

Rules for a composed settlement anchor:

```text
anchor each leg independently to the first round at or after expiry
require BOTH anchored rounds to fall within expiry + maxSettlementLag
compose the two anchored prices, never an anchored price with a live one
```

The composed result is therefore only as timely as the slower leg, which is why `maxSettlementLag` for a composed pair must accommodate the slower feed's heartbeat rather than the faster one's.

Composed feeds also compound oracle risk: two feeds, two failure modes, two staleness profiles, and a division that amplifies error in the denominator leg. Prefer a direct feed for the pair whenever one exists, and treat composition as a per-pair decision at approval time rather than a default.

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

There is no code path out of this state in the current design. That is a deliberate consequence of refusing to fall back to a manipulable price source, but it is a real user-funds risk and not merely a liveness inconvenience.

V1 must do one of two things before mainnet, decided in [founder-decisions.md](./founder-decisions.md) FD-20:

- Accept the risk and disclose it prominently in user-facing risk copy, or
- Implement a recovery path with a delay long enough that users can observe and react to it.

Any recovery path must be timelocked, evented, incapable of running while normal settlement is still possible, and incapable of producing a settlement price from Kuru. An `EmergencyRecoveryModule` implementing the chosen option is listed as an optional contract in [implementation-spec.md](./implementation-spec.md); it stays unimplemented until FD-20 is resolved.

Shipping without an explicit decision selects permanent lock by default. That may be an acceptable choice, but it should be a chosen one.

## Needs Founder Decision

Before production:

- Decide whether single-oracle series are allowed at all.
- Decide max deviation bps for Chainlink/Pyth.
- Decide stale thresholds by asset class.
- Decide the prolonged-outage recovery path, FD-20. This one can permanently lock user funds.
- Confirm exact Chainlink and Pyth feed addresses/feed IDs for Monad mainnet.
- Confirm that Chainlink actually operates feeds for the intended pairs on Monad; if it does not, FD-01 becomes a launch blocker rather than a policy question.
