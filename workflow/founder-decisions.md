# Founder Decisions

## Purpose

This file lists decisions that an AI agent or engineer must not silently choose. If unresolved, implementation should use safe defaults and leave the feature disabled where appropriate.

This file is the canonical blocker list. Other specs may include "Needs Founder Decision" sections as pointers back here. If any of those sections introduces something not listed here, that is a bug in this file — raise it rather than choosing a value.

Two items can cause irreversible user harm and should be resolved first: FD-20, where the default is permanent collateral lock during a prolonged oracle outage, and FD-17, where a wrong assumption about Kuru's fee, rebate, or AMM-spread behavior silently breaks buyer cost limits or seller-protection checks.

## Oracle Decisions

### FD-01: Single-Oracle Series

Question:

Should V1 allow a series when only Chainlink or only Pyth exists for the pair?

Safe default:

```text
No, unless explicitly approved per pair.
```

Impact:

- Stricter safety.
- Fewer launchable pairs.

### FD-02: Oracle Deviation and Confidence Thresholds

Question:

What is the max allowed Chainlink/Pyth deviation, and the max Pyth confidence interval?

Recommended starting values:

```text
maxOracleDeviationBps = 100 bps
maxPythConfidenceBps  = 100 bps
```

A tight confidence cap rejects a Pyth price that Pyth itself is unsure about, but if set too tight it can block settlement when confidence briefly widens right after expiry.

Needs final approval per asset volatility.

### FD-03: Oracle Stale Thresholds

Question:

How old can Chainlink and Pyth prices be **for reference reads**?

These thresholds bound premium-safety reads before expiry. They do not apply to settlement, which is anchored to expiry instead; see FD-21.

Recommended starting values:

```text
Chainlink: 1 hour
Pyth: 2 minutes
```

Needs final approval per feed update behavior.

### FD-04: DEX TWAP Requirement

**Closed. No decision needed.** V1 has no DEX TWAP oracle at all.

A TWAP cannot be anchored to expiry, so it cannot be a settlement source. Keeping it as a reference-only signal was also rejected, because the reference path selects sources by the same flags settlement uses — a source that can never be required can never be read. Rather than ship an adapter nothing calls, V1 drops the component. See [oracle-spec.md](./oracle-spec.md) and DD-18.

Reopening this is a V2 question and needs three things together: a historical-window read, a separate flag that actually selects the source on the reference path, and a policy for insufficient observation cardinality that reconciles with FD-20.

### FD-21: Settlement Anchor Windows

Question:

What are the two expiry-anchor windows for each required feed?

```text
maxChainlinkAgeAtExpiry   how old the Chainlink round in force at expiry may be
maxPythSettlementLag      how far after expiry Pyth's first qualifying update may sit
```

Safe default:

```text
No universal default. Do not approve a series until both are set per required feed.
```

Context: settlement is pinned to expiry, which is what stops a caller from choosing the settlement price by choosing when to call. Chainlink is anchored to the round **in force** at expiry (the last round at or before expiry, proven by its successor). Pyth is anchored to its first update at or after expiry. Both therefore describe the same moment, so the Chainlink/Pyth deviation check compares like with like, and no timestamp-skew parameter exists.

`maxChainlinkAgeAtExpiry`:

```text
too short  a healthy feed with a quiet stretch before expiry is rejected, which locks the series (FD-20 territory)
too long   a feed that already died well before expiry is accepted, so the "expiry price" is very old
```

Set it from the feed's actual heartbeat plus a buffer: a feed with a 1 hour heartbeat needs comfortably more than 1 hour, not exactly 1 hour. Note it is measured against `expiry`, not against when `settle()` is called.

`maxPythSettlementLag`:

```text
too short  a brief Pyth stall across expiry blocks settlement
too long   the Pyth price drifts further from the Chainlink price at expiry, tightening the deviation check for no reason
```

Pyth publishes about once a second, so a small value is appropriate. A starting point of 60 seconds is reasonable, subject to observing the deployed feed.

Chainlink's slowness is **not** a lock risk under this design: its next round after expiry only delays settlement, because the price used is the round already in force. A series locks only if that successor round never appears, if the round in force is older than `maxChainlinkAgeAtExpiry`, or if Pyth has no update in its window. Pair the decision with FD-20, since those are the cases its recovery path must handle.

### FD-23: Oracle Feed Verification

Question:

Which exact Chainlink feed addresses and Pyth feed IDs are approved for each launch pair on Monad mainnet?

Needs:

- Exact Chainlink feed address for each pair where Chainlink is required.
- Exact Pyth feed ID for each pair where Pyth is required.
- Confirmation that each feed prices the intended underlying/quote pair.
- Confirmation that Chainlink actually operates feeds for intended launch pairs on Monad.
- Confirmation that every approved feed is direct for the intended pair. V1 does not support composed settlement feeds.

Safe default:

```text
Do not approve an oracle config until both the feed identifiers and pair binding have been verified by two reviewers.
```

If Chainlink does not operate a feed for an intended pair, FD-01 becomes a launch blocker rather than a policy preference.

## Product Decisions

### FD-05: Launch Assets

Question:

Which underlying and quote assets are allowed at launch?

Safe default:

```text
Only assets with strong oracle support and standard ERC-20 behavior.
```

### FD-06: Protocol Fee Rates

**Resolved by founder: V1 charges protocol fees.** The mechanism is specified in [fee-spec.md](./fee-spec.md). What remains open is the rate values, not whether fees exist.

Question:

What are the launch values for the two fee rates? V1 charges a mint fee and an exercise fee, and nothing else. No fee is charged on writer residual claims.

Recommended starting values:

```text
mintFeeBps     = 10     (0.10% of required collateral, charged on top)
exerciseFeeBps = 25     (0.25% of gross payout, in-the-money redemptions only)
```

Hard caps are compile-time constants at 100 bps each and cannot be raised by governance.

Impact:

- Revenue accrues from the first mint rather than requiring a later migration.
- Fee rates are frozen per series at creation, so a change reaches only future series.
- Any nonzero fee must be reflected in premium quotes and UI, since it changes writer and holder economics.

### FD-06a: Fee Recipient

Question:

Which address receives swept protocol fees?

Needs:

- Recipient address, ideally the same multisig as FD-10 or a dedicated treasury.
- Confirmation that the recipient is not a contract with transfer hooks.

Note that the recipient is read live rather than snapshotted, so it can be rotated without affecting any series.

### FD-06b: Sweep Cadence

Question:

Are fees swept per vault on demand, or batched on a schedule?

Safe default:

```text
On demand, per vault, by FEE_ADMIN_ROLE. No automation in V1.
```

### FD-07: Primary-Sale Helper

Question:

Should V1 include protocol-controlled mint-and-list or primary-sale helpers?

Safe default:

```text
No onchain primary-sale helper until core lifecycle is audited.
```

## Risk Parameter Decisions

### FD-08: Premium Range Tolerances

Question:

What tolerances should define acceptable premium range?

Needs:

- Seller discount tolerance bps. Recommended to be at least `MAX_EXERCISE_FEE_BPS` (100), so the acceptable range cannot be empty on deep in-the-money options.
- Buyer overpay tolerance bps.
- Max spread bps.
- Max price impact bps.
- Minimum Kuru depth.
- Whether below-intrinsic listings are blocked or only warned.
- Whether official UI supports manual override after warning.

Safe default:

```text
Disable one-click routing until configured per market.
```

### FD-09: Series Caps

Question:

Should V1 impose max open interest per series or asset?

Recommended:

```text
Yes for guarded launch.
```

Mechanism: `maxTotalShortAmount` on each series, checked at mint. It is immutable, so a cap cannot be raised after writers and buyers have sized their risk against it. Raising a cap means creating a new series. Setting it to 0 means uncapped.

Needs exact cap values per launch pair.

### FD-22: Who Can Create Series

Question:

Is `createSeries` permissionless, or restricted to `SERIES_CREATOR_ROLE`?

Safe default:

```text
Restricted to SERIES_CREATOR_ROLE in V1.
```

Context: `name`, `symbol`, `minOptionAmount` and `maxTotalShortAmount` sit outside `seriesId`, and a repeat call with identical economics resolves to the existing series (or reverts if those four differ). So whoever creates a series first fixes its metadata, minimum size and cap permanently, and no one can ever create a correctly-named series for those economics afterward.

Permissionless creation would let anyone pre-create every plausible strike and expiry for a popular pair with misleading or offensive metadata. Funds stay safe, because `isOptionToken` is the source of truth and a squatted series is still correctly collateralized, but the damage to the display layer is permanent.

Opening creation up later requires first deciding how metadata is arbitrated. Options include including name and symbol in `seriesId` and accepting the liquidity fragmentation, or letting governance override display metadata while leaving economics immutable.

## Governance Decisions

### FD-10: Admin Multisig

Question:

Who controls admin roles?

Needs:

- Multisig address.
- Signer list.
- Threshold.

### FD-11: Timelock

Question:

Does admin action require timelock?

Recommended:

```text
Yes for non-emergency parameter changes.
```

Needs timelock duration.

### FD-12: Emergency Guardian

Question:

Who can pause minting and premium routing quickly?

Needs:

- Guardian address.
- Scope.
- Expiry or review period.

## Kuru Decisions

### FD-13: Market Creation Timing

Question:

Should Kuru market be created automatically with every series?

Safe default:

```text
Optional. Series can exist without Kuru market.
```

Related question:

Should minting require an already-linked Kuru market?

Safe default:

```text
No. Settlement and redemption must work even for a series with no Kuru market.
```

### FD-14: Kuru Precision Defaults

Question:

What size precision, price precision, tick size, min size, and max size are used per pair?

Safe default:

```text
No default across all assets. Calibrate per pair.
```

## Launch Decisions

### FD-15: Launch Mode

Question:

Guarded beta or open launch, and what is the mainnet launch date?

Recommended:

```text
Guarded beta with caps.
```

### FD-16: Bug Bounty

Question:

What bounty size and platform?

Safe default:

```text
Do not launch uncapped mainnet without bounty or external audit.
```

## Kuru Fee Decisions

### FD-17: Kuru Fee Convention and Caps

Question:

How does Kuru apply taker fees, maker-side fees or rebates, and AMM spread, and what venue cost is too high to route through?

Needs:

- Verified answer on whether the taker fee increases quote spent or reduces base received, confirmed against deployed Monad contracts rather than docs.
- Verified answer on whether the maker-side value is a fee or a rebate.
- Verified answer on how `kuruAmmSpread` changes effective execution cost when fills touch AMM liquidity.
- Verified answer on whether Kuru market orders or limit orders support an onchain deadline/expiry parameter.
- Verified answer on whether resting limit orders can remain open indefinitely unless cancelled.
- `maxLinkableMakerFeeBps`, interpreted as the maximum absolute maker-side adjustment allowed for a canonical market.
- `maxLinkableTakerFeeBps`.

Safe default until verified:

```text
Assume the fee increases quote spent, AND independently enforce minOptionAmountOut.
Treat maker-side adjustment as a fee, not a rebate, for seller-protection checks.
Include AMM spread as execution cost whenever the route may touch Kuru AMM liquidity.
Treat deadline as an official-route submission constraint unless Kuru is verified to enforce it onchain for the exact order type.
```

This is a launch blocker: a wrong assumption here silently breaks buyer all-in cost limits or seller-protection checks. See [kuru-integration-spec.md](./kuru-integration-spec.md).

### FD-18: Trading UI and Kuru Metadata Policy

Question:

What non-core trading paths and metadata updates does the official UI support?

Needs:

- Whether the protocol UI supports non-Kuru OTC transfers.
- Whether Kuru market metadata can be updated after initial linking.
- If metadata can be updated, who can update it and under what migration process.

Safe default:

```text
Show direct ERC-20 transfer as technically possible, but do not build special OTC flows in V1.
Treat Kuru market metadata as append-only unless a reviewed migration process is approved.
```

## Accounting Decisions

### FD-19: Expiry Bounds

Question:

What are the minimum and maximum allowed times between series creation and expiry?

Recommended starting values:

```text
MIN_EXPIRY_DELAY = 1 hours
MAX_EXPIRY_DELAY = 365 days
```

A minimum prevents series that expire before a Kuru market can meaningfully form. A maximum bounds how long collateral can be locked and how far oracle configuration must remain valid.

## Oracle Recovery Decisions

### FD-20: Prolonged Oracle Outage Recovery

Question:

If a required oracle never returns valid data, what releases the collateral?

This is the one unresolved item that can permanently lock user funds. If settlement can never succeed, redemption and residual claims are both unreachable and collateral is stuck forever with no path out.

Options:

```text
A. Accept permanent lock. Simplest, and defensible only if oracle failure is judged near-impossible.
B. Timelocked governance settlement. After a long delay, governance may write a settlement
   price from a documented offchain process, with the delay long enough for users to react.
C. Cancel-and-refund. After a long delay, disable payouts and let every writer reclaim their
   own collateral while holders reclaim nothing, which penalizes holders for an oracle failure
   that was not their fault.
```

Safe default until decided:

```text
Option A by omission, disclosed prominently in user-facing risk copy.
```

Shipping without an explicit decision means choosing A silently, which is the outcome most likely to surprise users. See [oracle-spec.md](./oracle-spec.md) and [state-machine.md](./state-machine.md).
