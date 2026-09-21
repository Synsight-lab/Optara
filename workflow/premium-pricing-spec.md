# Premium Pricing Spec

## Purpose

This file defines premium pricing, acceptable range checks, and execution safety.

Premium affects only buyer-seller trade economics. Premium never affects:

- Required collateral.
- Settlement price.
- Buyer redemption payout.
- Writer residual payout.
- Vault solvency accounting.

## Definitions

```text
writerAskPremium        quote amount requested by seller for optionAmount
buyerMaxTotalPremium    maximum all-in quote cost the buyer allows
grossPremium            quote amount paid to the seller across fills
kuruTakerFee            venue fee paid by the taker
kuruMakerAdjustment     maker-side venue adjustment; either fee or rebate
allInCost               grossPremium + kuruTakerFee
netProceeds             grossPremium +/- kuruMakerAdjustment
hardMaxGross            current-reference route-safety ceiling, before Optara fees
hardMaxPremium          hardMaxGross net of the Optara exercise fee
acceptableMinPremium    lower safety bound, a total for optionAmount
acceptableMaxPremium    upper safety bound, a total for optionAmount
marketReferencePremium  depth-aware executable premium estimate
```

All premium quantities are totals in quote raw units for the whole `optionAmount`, never per-option figures.

## Fees Are Part of the Price

Kuru charges taker fees and may apply a maker-side fee or rebate. Optara receives none of this venue value, but every bound in this file compares against **fee-inclusive totals**:

```text
buyer side:  allInCost   = grossPremium + kuruTakerFee
seller side:
    if makerFeeIsRebate:
        netProceeds = grossPremium + kuruMakerAdjustment
    else:
        netProceeds = grossPremium - kuruMakerAdjustment
```

Comparing a bound against `grossPremium` instead is a defect: on a market with a high taker fee, a quote can pass every range check while the buyer's actual cost lands above the acceptable maximum they were shown. Fee formulas and the unverified-convention handling are in [fee-spec.md](./fee-spec.md).

Per-option figures may be derived for display:

```text
effectivePremiumPerOption  = allInCost / optionAmountReceived
effectiveProceedsPerOption = netProceeds / optionAmountSold
```

These are for showing a user a comparable unit price. They are never compared against the acceptable-range bounds, which are totals.

## Writer Ask Rule

Writers may specify ask premiums.

Official helpers must not treat writer asks as automatically fair. They must classify the ask against effective, fee-inclusive figures.

Every bound and every figure compared against it is a **total** for `optionAmount`, in quote raw units:

```text
if netProceeds < acceptableMinPremium(optionAmount):
    warn or block protocol-controlled listing helper

if allInCost > acceptableMaxPremium(optionAmount):
    block simplified buyer routing
```

The seller-side check uses proceeds after Kuru's maker-side fee or rebate adjustment, because a seller giving away value cares about what they actually receive, not the headline ask. Until FD-17 is verified, official helpers must assume the maker-side adjustment is a fee.

Per-option figures are for display only. Comparing one against a total bound is wrong by a factor of the option amount and fails open, since a per-option cost sits below a total bound for any size above one whole option.

Direct manual Kuru limit orders may still exist outside official helper UX. The protocol should not claim those are safe routed trades.

## Buyer Protection Rule

Buyer protection has two layers with different strengths. Conflating them is the mistake this section exists to prevent.

### Layer 1: Hard execution bounds, enforced onchain by Kuru

```text
allInCost <= buyerMaxTotalPremium
optionAmountReceived >= buyerMinOptionAmount
```

These bind because Kuru itself enforces limit price and minimum output on the order. Optara's obligation is to ensure every official buy path sets them, and sets the cost limit on `allInCost` rather than `grossPremium`.

`deadline` is still required for official routes, but it is an official-route submission constraint unless FD-17 verifies that Kuru enforces an onchain deadline or expiry for the exact order type being used. If Kuru does not enforce deadlines, the frontend/backend must refuse to submit after the deadline and must not present deadline protection as a Kuru guarantee. Resting limit orders may remain open until cancelled unless Kuru's deployed contracts prove otherwise.

### Layer 2: Advisory, enforced by the official frontend

```text
market == registry canonical Kuru market
allInCost   <= acceptableMaxPremium(optionAmount)
netProceeds >= acceptableMinPremium(optionAmount)
spread, depth, quote age, price impact within configured bounds
```

Layer 2 cannot bind a user who trades directly against Kuru. Its purpose is to stop the official path from routing users into bad executions, not to make bad executions impossible. If a protocol-owned router is added later, it must enforce both layers atomically and revert on any failure.

If any Layer 1 condition cannot be satisfied, the transaction must not be submitted. If the route deadline has passed, the official path must not submit the transaction. If any Layer 2 condition fails, the official UI must refuse to offer the simplified route and fall back to manual limit-order UX with warnings.

## Hard Economic Bounds

Using oracle reference price `R`, strike `K`, and underlying exposure `E(a)`. All are totals in quote raw units for the whole amount `a`, and all use the same `UQ_SCALE` conversion the collateral math uses. Normative definitions are in [math-of-core-invariants.md](./math-of-core-invariants.md):

```text
callIntrinsicQuote(a) = mulDivUp(E_up(a),     max(R - K, 0), UQ_SCALE)
putIntrinsicQuote(a)  = mulDivUp(E_up(a),     max(K - R, 0), UQ_SCALE)

callHardMaxGross(a)   = mulDivDown(E_down(a), R,             UQ_SCALE)
putHardMaxGross(a)    = mulDivDown(E_down(a), K,             UQ_SCALE)

hardMaxPremium(a)     = mulDivDown(hardMaxGross(a), BPS_SCALE - exerciseFeeBps, BPS_SCALE)
```

Two things to note in those formulas.

**Rounding direction is chosen to tighten each rail.** Minimum bounds round up, maximum bounds round down. Both move toward rejection, so the repeated division in these expressions can only make a rail marginally stricter, never looser. Use `Math.mulDiv` with an explicit rounding mode at every step, and do not share one rounded `E(a)` between the two bounds, since they need it rounded in opposite directions.

**The buyer ceiling is net of the Optara exercise fee.** A holder receives the gross payout minus the exercise fee from [fee-spec.md](./fee-spec.md), so the route-safety ceiling should use the net figure. This is a conservative current-reference bound, not a statement that the option cannot ever become profitable. For calls, quote-denominated payoff can exceed the current quote value of the collateral if the underlying rallies after entry.

The seller floor takes no such adjustment. The exercise fee is paid by the holder at redemption, never by the writer, so it has no bearing on whether a writer is underpricing.

Interpretation:

- Call premium above the net current reference value of the underlying collateral is economically suspicious for a simplified routed buy, but it is not impossible for that call to become profitable if the underlying later rallies.
- Put premium above the net max strike payout is economically suspicious.
- Premium below intrinsic value may harm the seller.

These are safety rails, not a full option-pricing model.

## Acceptable Range Formula

Recommended. Both are totals for `optionAmount`:

```text
acceptableMinPremium(a) =
    mulDivUp(intrinsicQuote(a), BPS_SCALE - sellerDiscountToleranceBps, BPS_SCALE)

acceptableMaxPremium(a) =
    min(
        hardMaxPremium(a),
        mulDivDown(marketReferencePremium(a), BPS_SCALE + buyerOverpayToleranceBps, BPS_SCALE)
    )
```

`hardMaxPremium(a)` is already net of the exercise fee. `marketReferencePremium(a)` is an observed market figure rather than a theoretical bound, so it takes no fee adjustment.

### Empty Range Fails Closed

If `acceptableMinPremium(a) > acceptableMaxPremium(a)`, no price is acceptable and the range is empty. This can happen on deep in-the-money options when `sellerDiscountToleranceBps` is smaller than the series' `exerciseFeeBps`, because the seller floor is taken from gross intrinsic value while the buyer ceiling is net of the exercise fee. An empty range is treated as "no acceptable price": the official simplified route is disabled for that series and size, and the frontend falls back to manual limit-order UX with a warning. It must never be resolved by picking one bound over the other.

To keep this rare, launch configuration should set `sellerDiscountToleranceBps >= MAX_EXERCISE_FEE_BPS`; see FD-08.

If `marketReferencePremium` is unavailable or unsafe:

```text
official routed buy = disabled
manual limit-order UX = allowed with warnings
```

## Market Reference Premium

Must be computed from canonical Kuru order-book depth for the intended size.

Must not be:

- A single last-traded price.
- A writer-provided ask alone.
- An offchain API result without canonical market verification.
- A Kuru option-market price used for settlement.

Depth-aware estimate, fee-inclusive:

```text
grossEstimate          = sum(fillSize_i * askPrice_i)
marketReferencePremium = grossEstimate + ceilDiv(grossEstimate * takerFeeBps, BPS_SCALE)
```

Walking the book must stop at the requested size. If available depth is less than the requested option amount, the estimate is invalid and the route fails closed rather than extrapolating from the last available level.

Requirements:

- Market is linked in `SeriesRegistry`.
- Base asset is official option token.
- Quote asset is series quote.
- Quote age <= maxQuoteAge.
- Spread <= maxSpreadBps.
- Price impact <= maxPriceImpactBps.
- Available depth >= requested optionAmount.
- Market is active, not soft/hard paused.

## Slippage and Min Output

For Kuru market buys, route must enforce a minimum option output:

```text
minOptionAmountOut = quotedOptionAmountOut * (BPS_SCALE - slippageBps) / BPS_SCALE
```

Buyer max premium and min output both matter:

- Max premium prevents overpaying quote.
- Min output prevents receiving too few option tokens.

## Onchain vs Offchain Enforcement

**Resolved for V1: no protocol-owned trade router.**

- Optara vaults never execute Kuru trades.
- `PremiumExecutionGuard` is deployed as a validation-only contract. It holds no funds and cannot intercept trades.
- The frontend/backend computes the route and submits the Kuru transaction with Kuru's native limit price and minimum output.
- Hard price protection is therefore delivered by Kuru's order semantics, not by Optara code.
- If a protocol-owned router is added in a later version, it must call `checkPremium` as an atomic precondition and revert on failure.

Every added router increases attack surface, and a router is the only component that would need approval over a buyer's quote balance. V1 deliberately avoids that.

The consequence must be stated plainly in user-facing copy and in any security claim: Optara guarantees collateral and settlement, and Kuru guarantees limit-order execution bounds. Optara does not guarantee that a user gets a good premium.

## Premium Failure Cases

Fail closed if:

- Buyer all-in cost limit exceeded.
- Deadline expired.
- Market is not canonical.
- Effective premium above acceptable max.
- Effective proceeds below acceptable min in a protocol-controlled listing helper.
- Spread too wide.
- Depth too low for the requested size.
- Quote too old.
- Price impact too high.
- Market paused.
- Market's venue fees exceed the configured maximum linkable fee.
- Kuru SDK estimate and onchain result disagree beyond tolerance.

## Needs Founder Decision

- FD-08: seller discount tolerance bps.
- FD-08: buyer overpay tolerance bps.
- FD-08: max spread bps.
- FD-08: max price impact bps.
- FD-08: min depth per launch market.
- FD-17: maximum acceptable Kuru venue fee for a market to be routable.
- FD-08: whether below-intrinsic listings are blocked or only warned.
- FD-08: whether official UI supports manual override after warning.
