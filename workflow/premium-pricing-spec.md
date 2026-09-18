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
kuruMakerFee            venue fee paid by the maker
optaraRouteFee          protocol route fee, 0 in V1
allInCost               grossPremium + kuruTakerFee + optaraRouteFee
netProceeds             grossPremium - kuruMakerFee
acceptableMinPremium    lower safety bound
acceptableMaxPremium    upper safety bound
marketReferencePremium  depth-aware executable premium estimate
```

## Fees Are Part of the Price

Kuru charges maker and taker fees. Optara receives none of them, but every bound in this file compares against **fee-inclusive** figures:

```text
buyer side:  effectivePremiumPerOption  = allInCost / optionAmountReceived
seller side: effectiveProceedsPerOption = netProceeds / optionAmountSold
```

Comparing a bound against `grossPremium` instead is a defect: on a market with a high taker fee, a quote can pass every range check while the buyer's actual cost lands above the acceptable maximum they were shown. Fee formulas and the unverified-convention handling are in [fee-spec.md](./fee-spec.md).

## Writer Ask Rule

Writers may specify ask premiums.

Official helpers must not treat writer asks as automatically fair. They must classify the ask against effective, fee-inclusive figures:

```text
if effectiveProceedsPerOption < acceptableMinPremium:
    warn or block protocol-controlled listing helper

if effectivePremiumPerOption > acceptableMaxPremium:
    block simplified buyer routing
```

The seller-side check uses proceeds net of the Kuru maker fee, because a seller giving away value cares about what they actually receive, not the headline ask.

Direct manual Kuru limit orders may still exist outside official helper UX. The protocol should not claim those are safe routed trades.

## Buyer Protection Rule

Buyer protection has two layers with different strengths. Conflating them is the mistake this section exists to prevent.

### Layer 1: Hard, enforced onchain by Kuru

```text
allInCost <= buyerMaxTotalPremium
optionAmountReceived >= buyerMinOptionAmount
block.timestamp <= deadline
```

These bind because Kuru itself enforces limit price and minimum output on the order. Optara's obligation is to ensure every official buy path sets them, and sets the cost limit on `allInCost` rather than `grossPremium`.

### Layer 2: Advisory, enforced by the official frontend

```text
market == registry canonical Kuru market
effectivePremiumPerOption within acceptable range
spread, depth, quote age, price impact within configured bounds
```

Layer 2 cannot bind a user who trades directly against Kuru. Its purpose is to stop the official path from routing users into bad executions, not to make bad executions impossible. If a protocol-owned router is added later, it must enforce both layers atomically and revert on any failure.

If any Layer 1 condition cannot be satisfied, the transaction must not be submitted. If any Layer 2 condition fails, the official UI must refuse to offer the simplified route and fall back to manual limit-order UX with warnings.

## Hard Economic Bounds

Using oracle reference price `R`, strike `K`, and underlying exposure `E(a)`:

```text
callIntrinsicQuote(a) = max(R - K, 0) * E(a)
putIntrinsicQuote(a) = max(K - R, 0) * E(a)

callHardMaxPremium(a) = R * E(a)
putHardMaxPremium(a) = K * E(a)
```

Interpretation:

- Call premium above current underlying value is economically suspicious for a fully collateralized covered call.
- Put premium above max strike payout is economically suspicious.
- Premium below intrinsic value may harm the seller.

These are safety rails, not a full option-pricing model.

## Acceptable Range Formula

Recommended:

```text
acceptableMinPremium =
    intrinsicQuote * (BPS_SCALE - sellerDiscountToleranceBps) / BPS_SCALE

acceptableMaxPremium =
    min(
        hardMaxPremium,
        marketReferencePremium * (BPS_SCALE + buyerOverpayToleranceBps) / BPS_SCALE
    )
```

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
marketReferencePremium = grossEstimate + floor(grossEstimate * takerFeeBps / BPS_SCALE)
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

- Seller discount tolerance bps.
- Buyer overpay tolerance bps.
- Max spread bps.
- Max price impact bps.
- Min depth per launch market.
- Maximum acceptable Kuru venue fee for a market to be routable.
- Whether below-intrinsic listings are blocked or only warned.
- Whether official UI supports manual override after warning.

