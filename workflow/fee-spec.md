# Fee Spec

## Purpose

This file defines every fee in the Optara protocol: what is charged, who pays it, when it is collected, how it is rounded, and which invariants constrain it.

Two independent fee systems exist:

- **Optara protocol fees**, charged by this protocol at mint, redemption, and optionally at writer residual claim.
- **Kuru venue fees**, charged by Kuru on secondary-market trades. Optara never receives these, but every premium calculation must account for them.

See [math-of-core-invariants.md](./math-of-core-invariants.md) for the collateral math these fees must never violate, and [premium-pricing-spec.md](./premium-pricing-spec.md) for fee-inclusive premium bounds.

## The One Rule That Cannot Be Broken

```text
Protocol fees are never taken from collateral backing outstanding option claims.
```

Concretely:

- Mint fees are charged **on top of** required collateral, not deducted from it.
- Exercise and residual fees are charged **out of an already-computed gross payout**, and the total outflow from `collateralLocked` is unchanged by the fee.
- `collateralLocked` must never decrease because a fee was charged.

Any implementation where a fee reduces the collateral backing a live series is incorrect, regardless of how small the fee is.

## Fee Accrual Model

Optara uses **accrue-and-pull**, not push-on-collection.

```text
fee collected  -> accruedFees += feeAmount        (in the vault, in the collateral asset)
governance     -> sweepFees() transfers out       (to ProtocolConfig.feeRecipient())
```

`sweepFees` takes no receiver argument. The recipient is read live from `ProtocolConfig` at call time, so a fee admin can move fees but cannot choose where they go.

Rationale:

- No external transfer to a fee recipient in the mint, redeem, or claim hot path.
- A misconfigured, paused, or malicious fee recipient cannot brick minting or redemption.
- Reentrancy surface is reduced to a single governance-only function.

The vault balance invariant becomes:

```text
vaultBalance(collateralAsset) >= collateralLocked + accruedFees
```

`accruedFees` is strictly segregated from `collateralLocked`. Sweeping fees may only transfer `accruedFees`, never collateral.

## Optara Fee Types

### 1. Mint Fee

Charged when a writer mints options. Paid in the collateral asset, on top of required collateral.

```text
mintFee(a)   = ceilDiv(requiredCollateral(a) * mintFeeBps, BPS_SCALE)
writer pays  = requiredCollateral(a) + mintFee(a)

collateralLocked += requiredCollateral(a)
accruedFees      += mintFee(a)
```

Rounding: **up**, toward the protocol. This cannot affect solvency because the fee is additive to collateral rather than drawn from it.

### 2. Exercise Fee

Charged when a holder redeems an in-the-money option. Paid in the payout asset, deducted from gross payout.

```text
grossPayout(a)  = floor(a * buyerPayoutRate / OPTION_SCALE)
exerciseFee(a)  = floor(grossPayout(a) * exerciseFeeBps / BPS_SCALE)
netPayout(a)    = grossPayout(a) - exerciseFee(a)

collateralLocked -= grossPayout(a)
accruedFees      += exerciseFee(a)
transfer netPayout(a) to receiver
```

Rounding: **down**, toward the user. Total outflow from `collateralLocked` equals `grossPayout(a)` either way, so solvency is untouched by this rounding direction.

Out-of-the-money redemptions produce `grossPayout == 0` and therefore charge no fee. Only profitable exercises pay.

Because this fee reduces what a holder can ever realize, it also tightens the buyer-side premium ceiling: `hardMaxPremium` is computed net of `exerciseFeeBps`, so a rail is never set above a price that is provably unprofitable. See [premium-pricing-spec.md](./premium-pricing-spec.md). The seller-side floor is unaffected, since the writer never pays this fee.

### 3. Residual Fee

Charged when a writer claims residual collateral after settlement.

```text
grossResidual(a) = floor(a * writerResidualRate / OPTION_SCALE)
residualFee(a)   = floor(grossResidual(a) * residualFeeBps / BPS_SCALE)
netResidual(a)   = grossResidual(a) - residualFee(a)

collateralLocked -= grossResidual(a)
accruedFees      += residualFee(a)
transfer netResidual(a) to receiver
```

**V1 default: `residualFeeBps = 0`.** Writers already pay the mint fee. Charging both is double-charging the same position. The mechanism exists so the parameter can be enabled later without a contract change, but the launch value should be zero unless the founder decides otherwise. See [founder-decisions.md](./founder-decisions.md) FD-06.

### 4. Route Fee

Charged only if a protocol-owned router executes Kuru trades on a buyer's behalf.

```text
routeFee = floor(grossPremium * routeFeeBps / BPS_SCALE)
```

**V1 default: not applicable.** The preferred V1 design has no protocol-owned trade router; buyers transact with Kuru directly. If a router is added later, the route fee must be included in the buyer's all-in cost check defined in [premium-pricing-spec.md](./premium-pricing-spec.md).

## Fee Immutability

Fee rates are **snapshotted into the series at creation and immutable for that series' entire life.**

```text
at createSeries:  series.feeConfig = copy of ProtocolConfig defaults, validated against hard caps
after creation:   series.feeConfig can never change, by any role
```

Rationale: [design-decisions.md](./design-decisions.md) DD-03 guarantees that an option token's economic meaning cannot mutate after buyers and writers enter. A governable fee on a live series would break that guarantee — governance could raise the exercise fee after buyers have already paid a premium, retroactively reducing their payoff. Snapshotting makes the full economics of a series knowable at entry.

Governance parameter changes therefore apply **only to series created after the change**.

### Fee Recipient Is Not Snapshotted

The fee *recipient* is read live from `ProtocolConfig` at sweep time, not snapshotted per series.

Rationale: rates affect user economics and must be frozen; the recipient affects only where protocol revenue lands. Keeping the recipient mutable allows rotation if a treasury address is compromised, with no effect on any user's payoff.

## Hard Fee Caps

Caps are compile-time constants, not governable values. Governance cannot exceed them even for new series.

```text
MAX_MINT_FEE_BPS     = 100    // 1.00%
MAX_EXERCISE_FEE_BPS = 100    // 1.00%
MAX_RESIDUAL_FEE_BPS = 100    // 1.00%
MAX_ROUTE_FEE_BPS    = 50     // 0.50%
```

`createSeries` must revert with `FeeExceedsCap` if any configured rate exceeds its cap. This bounds worst-case governance capture: even a fully compromised admin key cannot set a confiscatory fee on future series, and cannot touch existing ones at all.

Recommended launch values are in [founder-decisions.md](./founder-decisions.md) FD-06 and require founder approval before mainnet.

## Fee Invariants

### Invariant F1: Fees Never Reduce Collateral Backing

```text
after any fee collection:
    collateralLocked >= remaining buyer payout obligation
                      + remaining writer residual obligation
```

### Invariant F2: Fee Segregation

```text
vaultBalance(collateralAsset) >= collateralLocked + accruedFees
sweepFees can transfer at most accruedFees
```

### Invariant F3: Fee Rate Immutability

```text
series.feeConfig at block N == series.feeConfig at block N+k, for all k
```

### Invariant F4: Fees Are Capped

```text
series.mintFeeBps     <= MAX_MINT_FEE_BPS
series.exerciseFeeBps <= MAX_EXERCISE_FEE_BPS
series.residualFeeBps <= MAX_RESIDUAL_FEE_BPS
```

### Invariant F5: Zero-Fee Series Behave Identically

```text
with all fee rates = 0:
    all payouts, residuals, and collateral amounts are bit-identical
    to the protocol's behavior with no fee logic at all
```

This invariant exists so fee logic can be proven not to perturb the core math. It must be a fuzz target.

## Kuru Venue Fees

Kuru charges its own maker and taker fees. Optara receives none of this, but every premium bound, route check, and UI quote must account for it, or the buyer's stated limit will not be the buyer's actual cost.

`KuruMarketConfig` already records `makerFeeBps`, `takerFeeBps`, and `kuruAmmSpread`. See [contract-interfaces.md](./contract-interfaces.md).

### Buyer Cost

A buyer taking liquidity pays the premium plus Kuru's taker fee:

```text
grossPremium  = sum(fillSize_i * fillPrice_i)
kuruTakerFee  = floor(grossPremium * takerFeeBps / BPS_SCALE)
optaraRouteFee = 0 in V1
allInCost     = grossPremium + kuruTakerFee + optaraRouteFee
```

### Seller Proceeds

A writer posting a resting order pays Kuru's maker fee out of proceeds:

```text
grossPremium  = sum(fillSize_i * fillPrice_i)
kuruMakerFee  = floor(grossPremium * makerFeeBps / BPS_SCALE)
netProceeds   = grossPremium - kuruMakerFee
```

### Range Checks Use Fee-Inclusive Totals

All acceptable-range checks compare fee-inclusive **totals** for the whole order, never the raw quoted premium and never a per-option figure:

```text
buyer side:  allInCost   <= acceptableMaxPremium(optionAmount)
seller side: netProceeds >= acceptableMinPremium(optionAmount)
```

Using the raw premium instead lets a market with high taker fees pass a range check while the buyer's real cost sits above the acceptable maximum.

Per-option figures may be derived for display, so a user can compare unit prices across sizes:

```text
effectivePremiumPerOption  = allInCost / optionAmountReceived
effectiveProceedsPerOption = netProceeds / optionAmountSold
```

These are never compared against the bounds, which are totals. See [premium-pricing-spec.md](./premium-pricing-spec.md).

### Fee Convention Must Be Verified Before Launch

Order-book venues differ in how a taker fee is applied on a buy. Two conventions exist:

```text
Convention A: fee increases the quote spent   -> buyer pays more quote, receives quoted base
Convention B: fee is deducted from base received -> buyer spends quoted quote, receives less base
```

**Optara must not assume which convention Kuru uses.** Until verified against the deployed Monad contracts:

- Compute `allInCost` assuming Convention A, which is the conservative assumption for the buyer's quote budget.
- Always enforce `minOptionAmountOut` independently, which covers Convention B.

Enforcing both bounds simultaneously is safe under either convention. The verification task is tracked in [founder-decisions.md](./founder-decisions.md) FD-17 and [production-checklist.md](./production-checklist.md).

### Kuru Fees Are Not Optara Revenue

```text
Kuru fees are paid to Kuru.
Optara accruedFees never includes Kuru fees.
Optara must not attempt to rebate, capture, or route around Kuru fees in V1.
```

## Fee Display Requirements

Any official frontend must show, before a user signs:

- Required collateral and mint fee as separate line items, with the total the writer will pay.
- Gross payout, exercise fee, and net payout as separate line items before redemption.
- Gross premium, Kuru taker fee, and all-in cost as separate line items before a buy.
- Gross premium, Kuru maker fee, and net proceeds before posting an ask.

A single blended number is not acceptable. Users must be able to see which part of the cost is protocol fee and which is venue fee.

## Needs Founder Decision

See [founder-decisions.md](./founder-decisions.md):

- FD-06: launch values for mint, exercise, and residual fee rates.
- FD-06a: fee recipient address.
- FD-06b: whether fee accrual is per-vault or swept to a central collector.
- FD-17: Kuru fee convention verification and maximum acceptable venue fee for a linkable market.
