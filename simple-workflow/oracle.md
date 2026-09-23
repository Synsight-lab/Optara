# Oracle: Chainlink Only

V1 uses one oracle: the Chainlink price feed named in the series. There is no second oracle, no router, no adapter and no quorum. The vault calls a small library, `ChainlinkAnchor`, directly.

Kuru is never an oracle source.

## Price Format

Everything is normalized to `PRICE_SCALE = 1e18`: the human price of 1 whole underlying in whole quote, times 1e18.

```text
normalizedPrice = uint256(answer) * 10 ** (18 - feedDecimals)
```

`feedDecimals` is read once from `feed.decimals()` when the vault is initialized, must be at most 18, and is stored in regular storage, fixed for the vault's life (not `immutable` - every series vault is an EIP-1167 clone; see `contracts.md`). Converting a price into token amounts is done with `UQ_SCALE` in `math.md`, never inside the oracle library.

Only **direct** feeds for the series' pair are supported. A price composed from two feeds (for example MON/USD divided by USDC/USD) is not supported in V1, because it would need two independently proven rounds. If a pair has no direct Chainlink feed, it cannot be launched.

## The Rule That Matters Most: Price at Expiry

An option settles at the price **at expiry**. It must not settle at the price whenever someone calls `settle()`.

If settlement read the current price, then whoever calls `settle()` would choose the price by choosing the moment. Settlement is permissionless and has no deadline, so a large holder could wait for a favorable move after an out-of-the-money expiry and then settle. Freshness checks do not help: a price from an hour ago is perfectly fresh and still not the expiry price.

So V1 pins the settlement price to expiry and proves it on chain:

```text
settlementPrice = the answer of the Chainlink round IN FORCE at expiry:
                  the last round with updatedAt <= expiry,
                  proven by its immediate successor having updatedAt > expiry
```

The caller supplies the round id and its successor's round id. The library verifies both against the feed. Exactly one round can pass, so the price is a fixed function of the feed's history and is identical no matter who settles or when.

### Why "in force", not "first after expiry"

Chainlink feeds update on a price-deviation threshold or a heartbeat, so the first update after expiry can be as much as a full heartbeat later. Using that later round would price the option at a moment after expiry. The round in force at expiry is Chainlink's actual value at expiry. It also means a slow but healthy feed only delays settlement. It does not block it.

## The Proof

```solidity
struct SettlementProof {
    uint80 chainlinkRoundId;        // the round in force at expiry: updatedAt <= expiry
    uint80 chainlinkNextRoundId;    // its immediate successor:      updatedAt >  expiry
}
```

The settlement price is the answer of `chainlinkRoundId`. The successor's answer is never used. It exists only to prove that nothing newer happened at or before expiry.

## `ChainlinkAnchor`

```solidity
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function getRoundData(uint80 roundId)
        external view returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80);
    function latestRoundData()
        external view returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80);
}

library ChainlinkAnchor {
    /// Settlement read. Reverts unless the proof identifies the round in force at `expiry`.
    function priceAtExpiry(
        IAggregatorV3 feed,
        uint8 feedDecimals,
        uint64 expiry,
        uint32 maxAgeAtExpiry,
        uint80 roundId,
        uint80 nextRoundId
    ) internal view returns (uint256 price);

    /// Reference read for the guard. Never used for settlement. Never reverts.
    function tryLatestPrice(
        IAggregatorV3 feed,
        uint8 feedDecimals,
        uint32 maxAge
    ) internal view returns (bool ok, uint256 price);
}
```

### `priceAtExpiry` checks

```text
require(roundId != 0)                                                 else SettlementAnchorZeroRoundId
require(nextRoundId != roundId)                                       else SettlementAnchorRoundsNotDistinct
(answer, updatedAtRound) = feed.getRoundData(roundId)                 revert or 0 timestamp => SettlementAnchorRoundUnavailable
(         updatedAtNext) = feed.getRoundData(nextRoundId)             revert or 0 timestamp => SettlementAnchorSuccessorUnavailable

require(isImmediateSuccessor(feed, roundId, nextRoundId))             else SettlementAnchorNotImmediateSuccessor
require(updatedAtRound <= expiry)                                     else SettlementAnchorRoundAfterExpiry       // in force at expiry
require(updatedAtNext  >  expiry)                                     else SettlementAnchorSuccessorNotAfterExpiry // nothing newer by expiry
require(expiry - updatedAtRound <= maxAgeAtExpiry)                    else SettlementAnchorTooStale               // feed was not already dead
require(answer > 0)                                                   else OracleInvalid
price = uint256(answer) * 10 ** (18 - feedDecimals)
```

Wrap both `getRoundData` calls in `try/catch`. A round that does not exist reverts on a proxy, and must become `SettlementAnchorRoundUnavailable` (for `roundId`) or `SettlementAnchorSuccessorUnavailable` (for `nextRoundId`), not an unexplained revert. Each failure has its own named error — `SettlementAnchorZeroRoundId`, `SettlementAnchorRoundsNotDistinct`, `SettlementAnchorRoundUnavailable`, `SettlementAnchorSuccessorUnavailable`, `SettlementAnchorNotImmediateSuccessor`, `SettlementAnchorRoundAfterExpiry`, `SettlementAnchorSuccessorNotAfterExpiry` — so a revert traces to exactly one check rather than one generic `SettlementAnchorInvalid` covering all of them.

Why exactly one round passes:

- A round **before** the one in force fails, because its real successor still has `updatedAt <= expiry`.
- A round **after** the one in force fails, because its own `updatedAt` is greater than `expiry`.
- A wrong successor fails the adjacency check. Without that check a caller could pair an older round with a distant post-expiry round and settle at the older, more favorable price.

### `_tryRound` also checks the responder answered the right round

Beyond the timestamp existing, `_tryRound` requires the round data returned actually describes the round that was asked for: the returned round id must equal the one requested, and `answeredInRound` must not be behind it. A well-formed Chainlink aggregator always satisfies both; the checks exist only to stop a feed or adapter that returns data for the wrong round from being trusted.

### Immediate successor

Chainlink proxy round ids are phase-encoded, so "the next round" is not always `roundId + 1`:

```text
proxyRoundId = (phaseId << 64) | aggregatorRoundId
phase(id) = uint16(id >> 64)      agg(id) = uint64(id)
```

```text
isImmediateSuccessor(round, next):
    if phase(next) == phase(round):
        return agg(next) == agg(round) + 1

    if phase(next) == phase(round) + 1:
        if agg(next) != 1: return false
        // round must have been the last round of its phase: round + 1 must not exist
        try feed.getRoundData(round + 1) returns (...updatedAt...) { return updatedAt == 0 }
        catch { return true }

    return false
```

Never compute the successor by adding one and trusting it. The caller supplies it and the library verifies it.

This one function is what turns a caller-supplied pair of round ids into proof of a unique round, so it is tested directly and exhaustively, not only through `settle()`: every named attack shape (a skipped round, a missing `aggNext == 1` check, a phase jump of more than one, a reversed pair, the round-in-force probe skipped entirely), the `round == type(uint80).max` overflow guard, and three fuzz tests that check the library's result against an independent reference implementation across the full `uint80` space, biased toward small phase and round numbers where collisions are common, and across a real multi-round phase transition. Four deliberately reintroduced bugs (an off-by-one in the same-phase check, a missing `aggNext == 1` check, skipping the round-in-force probe, and removing the `_tryRound` hardening) were each confirmed to make these tests fail before being reverted.

### `tryLatestPrice`

```text
(, answer,, updatedAt,) = feed.latestRoundData()   // in try/catch
ok = answer > 0 && updatedAt > 0 && updatedAt <= block.timestamp
     && block.timestamp - updatedAt <= maxAge
price = normalized answer
```

This is used only by `PremiumExecutionGuard` to price safety rails. It has a now-relative freshness check because it is a reference, not a settlement. Its `maxAge` is a guard parameter.

## `maxChainlinkAgeAtExpiry`

A per-pair value set by `ADMIN` in `setPairConfig` and copied into each series when it is created. Users cannot choose it, because a user could set it huge to accept a dead feed or tiny to make the series unsettleable. It checks that the round in force at expiry is not absurdly old, which would mean the feed had already stopped before expiry.

- It is measured against **`expiry`**, never against `block.timestamp`. So it is a fixed property of the feed's history and calling `settle()` later cannot change the result.
- Set it to the feed's **heartbeat plus a buffer**. A feed with a one-hour heartbeat needs comfortably more than one hour, for example 1 hour 15 minutes. Too small a value rejects a healthy feed that had a quiet stretch before expiry, and that series can then never settle.
- Read the heartbeat and deviation threshold from Chainlink's feed page for that exact feed on Monad.

## Waiting for the Successor Round

`settle()` cannot succeed until Chainlink has published its first round after expiry. That delay is at most about one heartbeat. It is not a lock and does not change the price. The keeper simply polls until the successor round exists and then settles. See the keeper procedure in `security-and-launch.md`.

## Building the Proof (keeper and frontend)

1. Read the feed's latest round. If its `updatedAt <= expiry`, the successor does not exist yet. Wait.
2. Find the round in force: the last round with `updatedAt <= expiry`. Binary search over round ids inside one phase, using `getRoundData`.
3. If the search reaches the start of a phase (the first round of that phase already has `updatedAt > expiry`), the round in force is the **last round of the previous phase**. Use `phaseAggregators` on the proxy to find it. Its successor is the first round of the next phase.
4. Set `chainlinkNextRoundId` to that round's immediate successor, using the same phase rule as the library.
5. Call `settle({chainlinkRoundId, chainlinkNextRoundId})`.

Anyone can build and submit the proof, and a wrong proof simply reverts.

## Failure Behavior

`settle()` reverts and writes nothing if the proof is wrong, the round in force is too old, the answer is zero or negative, or the successor does not exist yet. The series stays not settled. Redeem and claim stay unavailable. There is no fallback to Kuru or any other source.

### Permanent lock

The only ways to reach a permanent lock are:

- Chainlink never publishes another round after expiry, so no successor exists.
- The round in force at expiry is older than `maxChainlinkAgeAtExpiry` because the feed had already died.

There is deliberately no recovery path in V1. It is a real risk to user funds and must be accepted and disclosed prominently to users, or a timelocked recovery module must be designed before mainnet. See `security-and-launch.md`, decision D9. Mitigations that need no code: launch only on major, actively updated feeds, and keep series short-dated at first.

## Trust Assumptions

- The Chainlink feed is trusted to be correct, live and to price the intended pair.
- Chainlink can change the aggregator behind a proxy (a new phase). The phase-aware successor check handles that transition.
- `ADMIN` is trusted to approve the right feed for each pair. The factory only accepts that one feed, so users cannot attach a different one. A feed approved by mistake cannot be corrected on series already created with it. Freeze minting on those series, and disable the pair with `setPairConfig` (feed set to zero).
- The phase-boundary check trusts that a feed's aggregator round ids have no gaps within a phase (true for Chainlink's own aggregators) and that a round which genuinely does not exist reverts or returns a zero timestamp, rather than reverting for an unrelated reason. Both already follow from the feed being the one `ADMIN` approved.
