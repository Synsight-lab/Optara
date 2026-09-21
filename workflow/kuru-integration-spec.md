# Kuru Integration Spec

## Purpose

This file defines how the protocol integrates with Kuru without giving Kuru authority over settlement or collateral.

Kuru's venue fees interact with premium bounds; see [fee-spec.md](./fee-spec.md) for how they combine with Optara's own fees, and [premium-pricing-spec.md](./premium-pricing-spec.md) for how the combined figure feeds buyer limits.

## Kuru Role

Kuru is used for:

- Secondary trading of ERC-20 option tokens.
- Premium discovery.
- Order-book depth checks.
- Execution sanity for buyer routes.

Kuru is not used for:

- Settlement price.
- Collateral requirements.
- Buyer payout calculation.
- Writer residual calculation.
- Canonical series identity.

## Market Pair

For each option series:

```text
base asset  = option token
quote asset = series quote asset
```

For ERC-20/ERC-20 markets, expected Kuru type:

```text
NO_NATIVE
```

## Market Deployment

Kuru market deployment may be performed by:

- Direct Kuru Router `deployProxy`.
- Kuru SDK helper around market deployment.
- Manual external deployment later linked to registry after validation.

The protocol must record:

```text
market address
base asset
quote asset
sizePrecision
pricePrecision
tickSize
minSize
maxSize
makerFeeBps
makerFeeIsRebate
takerFeeBps
kuruAmmSpread
linkedAt
linkedBy
```

## Validation

Before linking a market:

```text
market.baseAsset == optionToken
market.quoteAsset == series.quote
market type matches asset pair
sizePrecision > 0
pricePrecision > 0
tickSize > 0
minSize >= series.minOptionAmount or explicitly justified
maxSize >= minSize
makerFeeBps <= maxLinkableMakerFeeBps    // absolute maker-side adjustment
takerFeeBps <= maxLinkableTakerFeeBps
```

Reject if:

- Market base is not the option token.
- Market quote is not the series quote.
- Market precision would round normal orders to zero.
- Market min size is incompatible with option token decimals.
- Market is not discoverable or not owned/configured as expected.

## Kuru Fee Calculation

Kuru charges taker fees and may apply maker-side fees or rebates on trades. Optara never receives this venue value and must never attempt to capture or rebate it, but every quote, bound, and UI figure must account for it.

### Fee Inputs

Recorded per market in `KuruMarketConfig`:

```text
makerFeeBps        maker-side adjustment in bps
makerFeeIsRebate   false if adjustment is a fee; true if adjustment is a rebate
takerFeeBps        charged to the order that crosses the spread
kuruAmmSpread      additional effective cost when filling against integrated AMM liquidity
```

These must be read from the deployed market at link time rather than assumed, and re-validated whenever a market is re-linked.

### Buyer Cost

```text
grossPremium = sum(fillSize_i * fillPrice_i)
kuruTakerFee = ceilDiv(grossPremium * takerFeeBps, BPS_SCALE)    // estimate rounds UP; see fee-spec.md
allInCost    = grossPremium + kuruTakerFee
```

There is no Optara trade surcharge, because V1 has no protocol-owned router.

### Seller Proceeds

```text
grossPremium        = sum(fillSize_i * fillPrice_i)
if makerFeeIsRebate:
    makerAdjustment = floor(grossPremium * makerFeeBps / BPS_SCALE)    // rebate rounds DOWN
    netProceeds     = grossPremium + makerAdjustment
else:
    makerAdjustment = ceilDiv(grossPremium * makerFeeBps, BPS_SCALE)   // fee rounds UP
    netProceeds     = grossPremium - makerAdjustment
```

A writer posting a resting ask receives or pays the maker-side adjustment according to the deployed market's convention. A writer crossing the spread to sell pays the taker-side cost instead. The UI must use whichever applies to the order type the user is actually submitting. Until FD-17 is verified, seller-protection checks assume the maker-side adjustment is a fee, not a rebate.

### AMM Spread

When a fill is served by Kuru's integrated AMM liquidity rather than a resting limit order, `kuruAmmSpread` widens the effective price beyond the quoted level. Depth-walking estimates must include it, or the estimate will be optimistic precisely when the book is thin — the case where accuracy matters most.

### Fee Convention Must Be Verified

Order-book venues differ in how a taker fee applies to a buy:

```text
Convention A: fee increases quote spent      -> more quote in, quoted base out
Convention B: fee deducted from base received -> quoted quote in, less base out
```

**Do not assume which Kuru uses.** Until verified against deployed Monad contracts:

- Compute `allInCost` under Convention A, the conservative assumption for the buyer's quote budget.
- Independently enforce `minOptionAmountOut`, which covers Convention B.
- Treat the maker-side adjustment as a fee for seller-protection checks until it is proven to be a rebate.
- Include `kuruAmmSpread` in depth-walked estimates whenever a route can touch Kuru AMM liquidity.

Enforcing the conservative taker and maker assumptions is safe until the exact deployed behavior is verified. Verification is a launch blocker tracked in [founder-decisions.md](./founder-decisions.md) FD-17.

### Maximum Linkable Fee

A market whose fees are set abusively high should not be linkable as the canonical market for a series:

```text
makerFeeBps <= maxLinkableMakerFeeBps       // absolute maker-side adjustment
takerFeeBps <= maxLinkableTakerFeeBps
```

Reject with `KuruFeeTooHigh`. Threshold values are FD-17.

## Precision Guidance

Needs per-asset calibration before launch.

General rule:

```text
sizePrecision should support minOptionAmount without rounding to zero
pricePrecision should support realistic option premiums
tickSize should not force huge premium jumps
minSize should prevent dust and rounding attacks
```

Do not copy Kuru parameters blindly across assets.

## Trading Flow

```text
writer mints option tokens
writer deposits/transfers option token for Kuru trading
writer posts ask or liquidity
buyer submits limit-protected buy
Kuru transfers option token
buyer later redeems from OptionSeriesVault after settlement
```

The vault does not need to know how the buyer acquired the token.

## Route Safety

Official one-click buy flows must:

- Verify registry canonical series.
- Verify linked Kuru market.
- Estimate executable output from depth.
- Enforce `buyerMaxTotalPremium` on the fee-inclusive all-in cost.
- Enforce `minOptionAmountOut`.
- Enforce deadline in the official route submission path, and use Kuru's onchain deadline/expiry only if FD-17 verifies that the deployed order type supports it.
- Check spread, depth, quote age, and price impact.
- Reject out-of-range writer asks.

## Kuru Failure Behavior

If Kuru is unavailable:

- Minting can continue before expiry.
- Settlement can continue after expiry.
- Redemption can continue after settlement.
- Writer residual claims can continue after settlement.
- Only secondary trading and routed premium execution are affected.

If Kuru market is manipulated:

- Settlement remains unaffected.
- Premium routing should fail closed.
- Manual limit-order users bear market execution risk.

## Source References

Kuru docs describe the OrderBook as a central limit order book with integrated AMM liquidity, and expose order-book functions such as `bestBidAsk` and `getL2Book`. Kuru WebSocket docs expose order-book depth by Monad state. Kuru SDK examples derive `minAmountOut` for market buys. These are useful for trading safety but not sufficient for settlement.

## Needs Founder Decision

- FD-13: whether official UI deploys Kuru market automatically at series creation.
- FD-13: whether every series must have a Kuru market before minting.
- FD-14: default market parameters for each launch pair.
- FD-17: maximum linkable taker fee and maker-side adjustment thresholds.
- FD-17: confirmation of Kuru's taker-fee convention, maker fee or rebate convention, and AMM-spread behavior on the deployed Monad contracts.
- FD-18: whether the protocol UI supports non-Kuru OTC transfers.
- FD-18: whether Kuru market metadata can be updated after linking.
