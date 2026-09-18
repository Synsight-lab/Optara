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
makerFeeBps <= maxLinkableMakerFeeBps
takerFeeBps <= maxLinkableTakerFeeBps
```

Reject if:

- Market base is not the option token.
- Market quote is not the series quote.
- Market precision would round normal orders to zero.
- Market min size is incompatible with option token decimals.
- Market is not discoverable or not owned/configured as expected.

## Kuru Fee Calculation

Kuru charges its own maker and taker fees on every trade. Optara never receives this revenue and must never attempt to capture or rebate it, but every quote, bound, and UI figure must account for it.

### Fee Inputs

Recorded per market in `KuruMarketConfig`:

```text
makerFeeBps        charged to the resting order
takerFeeBps        charged to the order that crosses the spread
kuruAmmSpread      additional effective cost when filling against integrated AMM liquidity
```

These must be read from the deployed market at link time rather than assumed, and re-validated whenever a market is re-linked.

### Buyer Cost

```text
grossPremium = sum(fillSize_i * fillPrice_i)
kuruTakerFee = floor(grossPremium * takerFeeBps / BPS_SCALE)
allInCost    = grossPremium + kuruTakerFee + optaraRouteFee
```

`optaraRouteFee` is zero in V1 because there is no protocol-owned router.

### Seller Proceeds

```text
grossPremium = sum(fillSize_i * fillPrice_i)
kuruMakerFee = floor(grossPremium * makerFeeBps / BPS_SCALE)
netProceeds  = grossPremium - kuruMakerFee
```

A writer posting a resting ask pays the maker fee. A writer crossing the spread to sell pays the taker fee instead. The UI must use whichever applies to the order type the user is actually submitting.

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

Enforcing both is safe under either convention. Verification is a launch blocker tracked in [founder-decisions.md](./founder-decisions.md) FD-17.

### Maximum Linkable Fee

A market whose fees are set abusively high should not be linkable as the canonical market for a series:

```text
makerFeeBps <= maxLinkableMakerFeeBps
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
- Enforce `buyerMaxPremium`.
- Enforce `minOptionAmountOut`.
- Enforce deadline.
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

- Whether official UI deploys Kuru market automatically at series creation.
- Whether every series must have a Kuru market before minting.
- Default market parameters for each launch pair.
- Maximum linkable maker and taker fee thresholds.
- Confirmation of Kuru's taker-fee convention on the deployed Monad contracts.
- Whether the protocol UI supports non-Kuru OTC transfers.
- Whether Kuru market metadata can be updated after linking.

