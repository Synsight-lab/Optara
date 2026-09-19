# Math of Core Invariants

## Purpose

This document defines the accounting rules that keep the protocol solvent. The formulas are implementation guidance and security-review targets. The exact Solidity implementation must handle token decimals, oracle decimals, and fixed-point scaling explicitly.

See [architectural.md](./architectural.md) for contract roles and [PRD.md](./PRD.md) for product requirements. Fee arithmetic is defined in [fee-spec.md](./fee-spec.md); fees are layered on top of the math here and never alter it.

## Notation

```text
U      underlying asset
Q      quote asset
K      strike price
S      settlement oracle price
R      current reference price for premium safety
P      premium paid for an option before settlement, denominated in Q
C      contract size
a      option amount being minted, redeemed, or measured
```

### Units Are Not Optional

Most implementation bugs in a protocol like this are unit bugs, so every quantity below states its unit exactly. There are two kinds of number in this system and they must never be mixed:

```text
raw units    integer token amounts as the ERC-20 stores them (balanceOf units)
human value  the number a person would say out loud ("5.25 USDC")
```

Definitive unit assignments:

```text
K, S, R    human price of 1 whole U in whole Q, multiplied by PRICE_SCALE
C          raw units of U per ONE WHOLE option token
a          raw units of the option token
```

Worked reading of `K`: if one whole MON is worth 10.00 whole USDC, then `K = 10 * PRICE_SCALE = 10e18`, regardless of how many decimals MON or USDC have. This matches the oracle normalization in [oracle-spec.md](./oracle-spec.md).

### Scales

```text
PRICE_SCALE   = 1e18
BPS_SCALE     = 10000
OPTION_SCALE  = 10 ** optionDecimals
UQ_SCALE      = PRICE_SCALE * (10 ** underlyingDecimals) / (10 ** quoteDecimals)
```

`OPTION_SCALE` and `UQ_SCALE` are computed once at series creation and stored as immutable series values. Both `underlyingDecimals` and `quoteDecimals` are capped at 18, so `UQ_SCALE` is always an exact integer and always at least 1.

### The Conversion Helper

Converting an underlying amount into a quote amount at a price is the single most error-prone operation in the protocol. It has exactly one correct form:

```text
quoteRaw(underlyingRaw, price) = underlyingRaw * price / UQ_SCALE
```

Every place the implementation needs "what is this much underlying worth in quote" must go through one helper implementing this expression. No ad hoc decimal juggling anywhere else.

The helper takes an explicit rounding mode, because the correct direction differs by caller:

```text
quoteRawUp(x, p)    used where rounding must favor the protocol or tighten a rail
quoteRawDown(x, p)  used where rounding must favor solvency or tighten a ceiling
```

Each call site below states which it uses. There is one expression and two rounding modes, never a second expression.

Sanity check, MON (18 dp) against USDC (6 dp), price 5.25:

```text
UQ_SCALE = 1e18 * 1e18 / 1e6 = 1e30
quoteRaw(1e18, 5.25e18) = 1e18 * 5.25e18 / 1e30 = 5.25e6 = 5.25 USDC
```

Sanity check with the decimals reversed, underlying 6 dp against quote 18 dp:

```text
UQ_SCALE = 1e18 * 1e6 / 1e18 = 1e6
quoteRaw(1e6, 5.25e18) = 1e6 * 5.25e18 / 1e6 = 5.25e18 = 5.25 whole quote
```

### Exposure

Underlying exposure represented by an option amount:

```text
E(a) = a * C / OPTION_SCALE        // raw units of U
E(OPTION_SCALE) = C                // one whole option
```

`E(a)` appears in derivations below for readability.

For **payouts**, the implementation must not materialize `E(a)` and then scale again: that rounds twice in a place where a wrong-direction rounding breaks solvency. Use the per-option rate forms under Settlement Rates.

For **premium bounds**, materializing a rounded exposure is fine and is what the spec prescribes, because every rounding step there is chosen to tighten the rail. See Premium Formation.

## Collateral Rules

Collateral is defined through a single per-option constant, fixed at series creation. Everything else derives from it.

### Collateral Per Option

```text
CALL: collateralPerOption = C                              // raw units of U
PUT:  collateralPerOption = ceilDiv(C * K, UQ_SCALE)       // raw units of Q
```

This is the maximum liability of one whole option token. The put form rounds **up**, so the stored constant is never less than the true strike value of the contract.

`collateralPerOption` is computed once at creation and stored immutably. It must never be recomputed at mint, settlement, or claim time.

### Required Collateral

For both option types:

```text
requiredCollateral(a) = ceilDiv(a * collateralPerOption, OPTION_SCALE)
```

Rounding **up** guarantees the vault never accepts an option amount whose maximum liability exceeds the collateral received.

Calls are collateralized in `U`. Puts are collateralized in `Q`. The mint fee defined in [fee-spec.md](./fee-spec.md) is charged on top of this amount and is not part of `collateralLocked`.

## Premium Formation

Premium is the quote-denominated amount a buyer pays a seller to acquire option tokens before settlement.

```text
premiumPaid = executionPrice * optionAmount
```

If execution spans multiple fills:

```text
premiumPaid = sum(fillOptionAmount_i * fillPrice_i)
realizedPremiumPerOption = premiumPaid / sum(fillOptionAmount_i)
```

Premium alone is not what the buyer actually pays. Kuru charges a venue fee on top, so every bound and every user-facing quote must use the fee-inclusive cost:

```text
allInCost = premiumPaid + kuruTakerFee
```

and symmetrically for the seller:

```text
netProceeds = premiumPaid - kuruMakerFee
```

Per-option figures may be derived for display:

```text
effectivePremiumPerOption  = allInCost / optionAmountReceived
effectiveProceedsPerOption = netProceeds / optionAmountSold
```

Fee formulas are in [fee-spec.md](./fee-spec.md). Every comparison below uses fee-inclusive **totals**. The per-option figures above exist only to show a user a comparable unit price and are never compared against a bound.

Premium is not part of the collateral invariant:

```text
requiredCollateral(a) is independent of P
settlementPayout(a) is independent of P
writerResidual(a) is independent of P
```

A writer can choose an ask price. A buyer can choose a bid or maximum acceptable premium. The writer's ask is an input to market execution, but it does not by itself define the acceptable maximum premium for official routed execution.

Writer asks should be checked against an acceptable range before official routed execution. For amount `a`, using current reference price `R`:

```text
callIntrinsicQuote(a) = mulDivUp(E_up(a),     max(R - K, 0), UQ_SCALE)
putIntrinsicQuote(a)  = mulDivUp(E_up(a),     max(K - R, 0), UQ_SCALE)

callHardMaxGross(a)   = mulDivDown(E_down(a), R,             UQ_SCALE)
putHardMaxGross(a)    = mulDivDown(E_down(a), K,             UQ_SCALE)
```

where the exposure term is itself rounded in the matching direction:

```text
E_up(a)   = mulDivUp(a, C, OPTION_SCALE)
E_down(a) = mulDivDown(a, C, OPTION_SCALE)
```

All four are **totals** in quote raw units for the whole amount `a`, not per-option figures. They use the same `UQ_SCALE` conversion the collateral math uses, because they answer the same question: what is this much underlying worth in quote.

### Rounding Direction Makes Multi-Step Division Safe

These expressions divide twice, so they round twice. That is harmless here provided every step rounds in the direction that **tightens** the rail:

```text
intrinsic / minimum bound   round UP    -> a higher seller floor, rejects more
hard max / maximum bound    round DOWN  -> a lower buyer ceiling, rejects more
```

Both directions move toward rejection, so accumulated rounding can only make a rail marginally stricter, never looser. This is why these formulas do not need the single-rounding treatment the settlement rates require: for settlement, a rounding error in the wrong direction breaks solvency, whereas here it costs at most a few wei of rail precision.

Implement with `Math.mulDiv` and an explicit rounding mode at every step. Do not materialize a shared `E(a)` and reuse it across both bounds — the two bounds need it rounded in opposite directions.

### The Buyer Ceiling Is Net of the Exercise Fee

A holder does not receive the gross payout. The exercise fee in [fee-spec.md](./fee-spec.md) is deducted at redemption, so the most a buyer can ever realize is:

```text
hardMaxPremium(a) = mulDivDown(hardMaxGross(a), BPS_SCALE - exerciseFeeBps, BPS_SCALE)
```

Use `hardMaxPremium(a)`, the net figure, as the buyer-side ceiling. A premium above it cannot break even even in the best possible outcome, so a rail set at the gross figure would let through asks that are provably unprofitable.

The seller floor is **not** adjusted this way. The exercise fee is paid by the holder at redemption, never by the writer, so it has no bearing on whether a writer is underpricing. Applying the discount to `acceptableMinPremium` would wrongly lower the writer's protection.

The lower side protects sellers from accidental or manipulated underpricing. The upper side protects buyers from paying more than a conservative net-replacement bound. These are safety bounds, not settlement formulas and not full theoretical option pricing.

Recommended acceptable range, also totals for amount `a`:

```text
acceptableMinPremium(a) =
    mulDivUp(intrinsicQuote(a), BPS_SCALE - sellerDiscountToleranceBps, BPS_SCALE)

acceptableMaxPremium(a) =
    min(
        hardMaxPremium(a),
        mulDivDown(marketReferencePremium(a), BPS_SCALE + buyerOverpayToleranceBps, BPS_SCALE)
    )
```

`marketReferencePremium(a)` is an observed market figure, not a theoretical bound, so it takes no exercise-fee adjustment. Only the hard economic leg does.

`marketReferencePremium(a)` must not be a single last-traded price. It should require canonical market verification, minimum depth, acceptable spread, acceptable price impact, fresh quote data, and sufficient recent activity. If the market reference is unsafe or unavailable, simplified routing must fail closed or use manual limit-order UX.

### Compare Totals Against Totals

Every bound above is a total for amount `a`. Every buyer and seller figure it is compared against must therefore also be a total:

```text
allInCost                <= buyerMaxTotalPremium
allInCost                <= acceptableMaxPremium(optionAmount)
netProceeds              >= acceptableMinPremium(optionAmount)
optionAmountReceived     >= buyerMinOptionAmount
currentTimestamp         <= buyerDeadline
market                   == canonicalRegistryMarket(seriesId)
```

Per-option figures such as `effectivePremiumPerOption` exist only for display. Comparing a per-option value against one of these bounds is wrong by a factor of the option amount, and it fails in the dangerous direction: for any size above one whole option, a per-option cost will almost always sit below a total bound, so the check silently passes everything.

If any of these conditions fails, the buy route must not execute. See Invariant 13 for which are hard onchain guarantees and which are frontend-enforced.

## Settlement Preconditions

Settlement occurs once, at or after expiry, using a valid oracle price `S`.

The oracle price must satisfy:

```text
S > 0
S is the FIRST oracle observation at or after expiry, proven onchain
that observation is no later than expiry + maxSettlementLag
S is PRICE_SCALE-normalized by the adapter
S is not sourced from the Kuru option market
S passes Chainlink/Pyth quorum when both are configured
```

Anchoring is what makes `S` the expiry price rather than the price when `settle()` happened to be called. Pair identity is bound when the oracle config is approved at creation, not rechecked here. See [oracle-spec.md](./oracle-spec.md).

## Settlement Rates

Settlement computes two **rates** exactly once, stores them permanently, and never recomputes them. All later claims are linear in those rates. This is the canonical definition referenced by [state-machine.md](./state-machine.md) and [implementation-spec.md](./implementation-spec.md).

Both rates are denominated in **collateral raw units per one whole option token**, the same unit as `collateralPerOption`.

### Call Rates

Calls are collateralized and paid in underlying.

```text
if S <= K:
    buyerPayoutRate = 0
else:
    buyerPayoutRate = floor(C * (S - K) / S)

writerResidualRate = collateralPerOption - buyerPayoutRate      // = C - buyerPayoutRate
```

The call payoff converts the in-the-money quote value back into underlying units by dividing by `S`, which is why no `UQ_SCALE` appears: the quote units cancel.

### Put Rates

Puts are collateralized and paid in quote.

```text
if S >= K:
    buyerPayoutRate = 0
else:
    buyerPayoutRate = floor(C * (K - S) / UQ_SCALE)

writerResidualRate = collateralPerOption - buyerPayoutRate
```

### Rate Bounds

Both definitions keep the buyer rate strictly within collateral:

```text
CALL: (S - K) / S < 1        for all S > K > 0, so buyerPayoutRate < C
PUT:  C * (K - S) < C * K    for all S > 0, so buyerPayoutRate < ceilDiv(C * K, UQ_SCALE)
```

Therefore `writerResidualRate >= 0` always, and by construction:

```text
buyerPayoutRate + writerResidualRate == collateralPerOption
```

This exact identity is what makes the solvency proof below hold. An implementation that computes `writerResidualRate` independently rather than by subtraction breaks it.

## Claim Amounts

Both claim types are linear in the stored rate and round **down**:

```text
grossBuyerPayout(a)   = floor(a * buyerPayoutRate / OPTION_SCALE)
grossWriterResidual(a) = floor(a * writerResidualRate / OPTION_SCALE)
```

Protocol fees are then deducted from these gross amounts per [fee-spec.md](./fee-spec.md). The amount removed from `collateralLocked` is the **gross** amount in both cases; the fee merely splits where the gross amount goes.

## Solvency Proof

The property that must hold is: total claims can never exceed total collateral.

### Single Position

For one amount `a`:

```text
grossBuyerPayout(a) + grossWriterResidual(a)
    = floor(a * rb / OPTION_SCALE) + floor(a * rw / OPTION_SCALE)
   <= (a * rb / OPTION_SCALE) + (a * rw / OPTION_SCALE)
    = a * (rb + rw) / OPTION_SCALE
    = a * collateralPerOption / OPTION_SCALE
   <= ceilDiv(a * collateralPerOption, OPTION_SCALE)
    = requiredCollateral(a)
```

Two floors on the claim side and one ceiling on the collateral side. Every rounding step moves in the protocol's favor.

### Aggregate Across Many Writers and Holders

Let writers mint amounts `a_1 ... a_n`, holders redeem `b_1 ... b_m` with `sum(b_j) <= sum(a_i)`, and writers claim residual on `w_1 ... w_p` with `sum(w_k) = sum(a_i)`.

Collateral collected is superadditive under ceiling:

```text
sum_i ceilDiv(a_i * cpo, OPTION_SCALE) >= ceilDiv(sum_i a_i * cpo, OPTION_SCALE)
```

Claims are subadditive under floor:

```text
sum_j floor(b_j * rb / OS) <= (sum_j b_j) * rb / OS <= (sum_i a_i) * rb / OS
sum_k floor(w_k * rw / OS) <= (sum_i a_i) * rw / OS
```

Adding the two claim bounds gives `(sum_i a_i) * (rb + rw) / OS = (sum_i a_i) * cpo / OS`, which is bounded by the collateral collected. Fragmenting mints or claims into many small transactions therefore only increases leftover dust — it can never create a deficit.

This proof is the reason the required invariant tests in [testing-and-invariants.md](./testing-and-invariants.md) fuzz mint and claim fragmentation specifically.

## Worked Test Vectors

These are exact integer vectors. They are normative: the implementation must reproduce them bit-for-bit, and they should be written as unit tests before the vault is implemented.

### Vector 1: Call, 18 dp underlying, 6 dp quote, exact division

```text
inputs:
    optionType        = CALL
    underlyingDecimals = 18      quoteDecimals = 6
    optionDecimals    = 18   ->  OPTION_SCALE = 1e18
    UQ_SCALE          = 1e18 * 1e18 / 1e6 = 1e30
    C                 = 1e18     (1 whole MON per option)
    K                 = 10e18    (10.00 USDC)
    S                 = 12.5e18  (12.50 USDC)

derived:
    collateralPerOption = C = 1e18
    mint a = 5e18 (5 options)
    requiredCollateral  = ceilDiv(5e18 * 1e18, 1e18) = 5e18         (5 MON)

settlement (S > K):
    buyerPayoutRate     = floor(1e18 * 2.5e18 / 12.5e18) = 2e17     (0.2 MON per option)
    writerResidualRate  = 1e18 - 2e17 = 8e17

claims:
    holder redeems 5e18: grossPayout   = floor(5e18 * 2e17 / 1e18) = 1e18   (1 MON)
    writer claims  5e18: grossResidual = floor(5e18 * 8e17 / 1e18) = 4e18   (4 MON)
    total out = 5e18 = collateral, dust = 0
```

### Vector 2: Put, 8 dp underlying, 6 dp quote

```text
inputs:
    optionType        = PUT
    underlyingDecimals = 8       quoteDecimals = 6
    optionDecimals    = 18   ->  OPTION_SCALE = 1e18
    UQ_SCALE          = 1e18 * 1e8 / 1e6 = 1e20
    C                 = 1e6      (0.01 BTC per option)
    K                 = 60000e18
    S                 = 55000e18

derived:
    collateralPerOption = ceilDiv(1e6 * 60000e18, 1e20) = 6e8       (600 USDC)
    mint a = 3e18 (3 options)
    requiredCollateral  = ceilDiv(3e18 * 6e8, 1e18) = 1.8e9         (1800 USDC)

settlement (S < K):
    buyerPayoutRate     = floor(1e6 * 5000e18 / 1e20) = 5e7          (50 USDC per option)
    writerResidualRate  = 6e8 - 5e7 = 5.5e8                          (550 USDC)

claims:
    holder redeems 3e18: grossPayout   = floor(3e18 * 5e7 / 1e18)   = 1.5e8   (150 USDC)
    writer claims  3e18: grossResidual = floor(3e18 * 5.5e8 / 1e18) = 1.65e9  (1650 USDC)
    total out = 1.8e9 = collateral, dust = 0
```

### Vector 3: Call, non-terminating division, dust is produced

```text
inputs:
    optionType = CALL, C = 1e18, OPTION_SCALE = 1e18
    K = 3e18, S = 7e18

settlement:
    buyerPayoutRate    = floor(1e18 * 4e18 / 7e18) = 571428571428571428
    writerResidualRate = 1e18 - 571428571428571428 = 428571428571428572

claims, with the holder redeeming an odd amount:
    collateral for a = 1e18 is ceilDiv(1e18 * 1e18, 1e18) = 1e18
    holder redeems (1e18 - 1): floor((1e18 - 1) * 571428571428571428 / 1e18)
                              = 571428571428571427
    writer claims  1e18:        floor(1e18 * 428571428571428572 / 1e18)
                              = 428571428571428572
    total out = 999999999999999999
    dust remaining in vault = 1 wei
```

Vector 3 is the important one for review: it demonstrates that dust is produced, that it is always non-negative, and that the vault is never short.

### Vector 4: Out of the money, both types

```text
CALL with S <= K:  buyerPayoutRate = 0, writerResidualRate = collateralPerOption
PUT  with S >= K:  buyerPayoutRate = 0, writerResidualRate = collateralPerOption

holder redeeming any amount receives 0 and pays no exercise fee
holder must still be able to burn, so redeem() must succeed; skip the transfer
  entirely rather than transferring zero, since some tokens revert on zero transfers
writer reclaims collateralPerOption per option, less up to 1 unit of dust,
  because claims floor while collateral was collected by ceiling
```

### Vector 5: Fee interaction

```text
continuing Vector 1, with mintFeeBps = 10 and exerciseFeeBps = 25:

    mintFee    = ceilDiv(5e18 * 10, 10000) = 5e15        (0.005 MON)
    writer transfers 5e18 + 5e15 = 5.005e18
    collateralLocked += 5e18
    accruedFees      += 5e15

    grossPayout  = 1e18
    exerciseFee  = floor(1e18 * 25 / 10000) = 2.5e15     (0.0025 MON)
    netPayout    = 1e18 - 2.5e15 = 9.975e17
    collateralLocked -= 1e18
    accruedFees      += 2.5e15

    collateral outflow is unchanged by the fee; only its destination splits
```

## Core Invariants

### Invariant 1: Full Collateral Before Mint

Before options are minted:

```text
collateralReceived >= requiredCollateral(a)
```

After minting:

```text
collateralLocked >= requiredCollateral(totalShortAmount)
```

`collateralLocked` is the sum of per-mint `ceilDiv` results, and a sum of ceilings is at least the ceiling of the sum, so this holds with room to spare. The slack is dust.

No state path may mint option tokens before collateral is received and accounted for.

### Invariant 2: Long Supply Is Backed by Short Obligations

Before settlement:

```text
totalLongSupply <= totalShortAmount
```

In the simplest V1 without pre-expiry close flows:

```text
totalLongSupply == totalShortAmount
```

If a future close flow is added, it must burn long tokens and reduce short obligations atomically.

### Invariant 3: Settlement Is Final

Before settlement:

```text
settlementPrice is unset
buyerPayoutRate is unset
writerResidualRate is unset
```

After settlement:

```text
settlementPrice = S
buyerPayoutRate = fixed result from S
writerResidualRate = fixed result from S
```

These values cannot change after being set.

### Invariant 4: Kuru Cannot Affect Payout

For any Kuru state `M`:

```text
payout(series, S, a, M) == payout(series, S, a)
```

Kuru order-book depth, last traded price, AMM liquidity, market state, and trade history must have no effect on settlement payout.

### Invariant 4A: Premium Cannot Affect Collateral or Settlement

For any premium `P` paid by a buyer:

```text
collateralRequired(series, a, P) == collateralRequired(series, a)
settlementPayout(series, S, a, P) == settlementPayout(series, S, a)
writerResidual(series, S, a, P) == writerResidual(series, S, a)
```

Premium affects only the quote-asset transfer between buyer and seller during the trade.

### Invariant 5: Buyer Payout Plus Writer Residual Does Not Exceed Collateral

For any option amount `a`, and for both option types:

```text
grossBuyerPayout(a) + grossWriterResidual(a) <= requiredCollateral(a)
```

This follows from the identity `buyerPayoutRate + writerResidualRate == collateralPerOption` combined with floor-on-claims and ceiling-on-collateral. See the Solvency Proof above for the aggregate case.

Protocol fees do not appear in this invariant because they are deducted from the gross amounts rather than added to them. The total removed from `collateralLocked` is the gross amount either way. See [fee-spec.md](./fee-spec.md) Invariant F1.

At the vault level, including fee accrual:

```text
vaultBalance(collateralAsset) >= collateralLocked + accruedFees
```

### Invariant 5A: Dust Is Non-Negative and Trapped

Dust is whatever collateral remains after every claim is exhausted:

```text
dust = originalCollateralLocked
     - sum(all grossBuyerPayout)
     - sum(all grossWriterResidual)

dust >= 0 always
```

**V1 dust policy: dust stays in the vault permanently.** There is no sweep function.

Dust is bounded by roughly one unit of the collateral asset per claim, so the amount at stake is negligible. A sweep would need `totalSupply() == 0` to be provably safe, and holders of worthless out-of-the-money tokens have no reason to spend gas burning them — so that condition is rarely reached and the function would almost never be callable. An entry point that cannot run in practice is surface an implementer must build and an auditor must review for no benefit, so V1 omits it.

### Invariant 6: No Double Redemption

For each holder and amount:

```text
redeemableAmount <= currentOptionTokenBalance
```

During redemption:

```text
burn option tokens or mark redeemed amount
then transfer payout
```

The same option amount cannot be redeemed twice.

### Invariant 7: No Early Exercise

For all timestamps before expiry:

```text
redeem() reverts
settle() reverts
writerResidualClaim() reverts
```

Minting is allowed only while:

```text
currentTimestamp < expiry
state == ACTIVE
```

### Invariant 8: Oracle Validity

Settlement is valid only if:

```text
the series' oracle config was approved at creation
oracle pair identity was bound at that approval
oracle price > 0
the observation is anchored to expiry and the anchor proof verifies
the observation is no later than expiry + maxSettlementLag
the adapter returned a PRICE_SCALE-normalized value
oracle answer is final enough for the selected oracle design
```

Note that `chainlinkStaleAfter` and `pythStaleAfter` are **not** settlement conditions. They bound reference reads used for premium safety before expiry. Settlement uses the anchor instead; a now-relative freshness check at settlement is the timing vulnerability described in [oracle-spec.md](./oracle-spec.md).

If any condition fails, settlement must not write a final settlement result.

### Invariant 9: Conservative Rounding

Every rounding direction in the protocol is fixed and must not be changed without redoing the Solvency Proof:

```text
collateralPerOption (PUT)   ceil
requiredCollateral          ceil
buyerPayoutRate             floor
writerResidualRate          exact subtraction, never independently rounded
grossBuyerPayout            floor
grossWriterResidual         floor
mintFee                     ceil   (toward protocol; additive, cannot affect solvency)
exerciseFee                 floor  (toward user; outflow unchanged, cannot affect solvency)
```

The critical one is `writerResidualRate`. It is defined as `collateralPerOption - buyerPayoutRate` and must be computed that way. Deriving it from its own formula and rounding it independently breaks the exact identity the solvency proof depends on, and does so silently — the code will look correct and pass ordinary unit tests while over-allocating by one unit per option under specific prices.

### Invariant 10: Minimum Size Prevents Zero-Value Positions

`minOptionAmount` is a **mint-only** constraint:

```text
mint:    a >= minOptionAmount  and  requiredCollateral(a) > 0
redeem:  a > 0                 only
claim:   a > 0                 only
```

Applying a minimum to redemption or residual claim would permanently trap funds. A holder can end up below `minOptionAmount` through an ordinary partial fill on Kuru or a plain ERC-20 transfer, and neither path consults the series minimum. If `redeem` then rejected them, their claim would be unreachable forever with no recovery path.

The minimum exists to stop dust *positions being created*, which is a mint-time concern. Once a position exists, every holder of any size must be able to exit.

For Kuru market configuration:

```text
minSize must be compatible with option token decimals
sizePrecision must not round valid user sizes to zero
pricePrecision and tickSize must support realistic option quotes
```

### Invariant 11: Reentrancy Cannot Duplicate Claims

For every external function that transfers tokens:

```text
validate inputs
update internal accounting
emit event
perform external transfer
```

Reentrant calls must observe already-updated state.

### Invariant 12: Canonical Identity

A token is official only if the canonical registry says so:

```text
SeriesRegistry.isOptionToken(tokenAddress) == true
```

and that registry is the canonical deployment, which an integrator confirms once:

```text
SeriesRegistry.factory() == canonicalFactory
```

Because the vault **is** the option token, `isOptionToken` resolves the token address back to a `seriesId` through the registry's own mapping, which only the factory can write.

Name, symbol, decimals, and Kuru listing are not enough to establish authenticity.

### Invariant 13: Buyer Premium Limit

This is a **route-safety property, not a protocol invariant.** The distinction matters and V1 must not blur it.

Invariants 1 through 12 are enforced by Optara's own contracts and hold against any adversary. Premium protection is different: in V1 Optara does not execute trades, so there is no Optara code path a buyer's trade must pass through. Premium protection is delivered in two layers with very different strengths.

**Layer 1, hard and onchain, enforced by Kuru:**

```text
a Kuru limit buy cannot fill above its limit price
a Kuru order with minAmountOut cannot deliver less than that amount
```

These are real guarantees, but they are Kuru's guarantees, not Optara's. Optara's obligation is to make sure every official buy path sets them, and sets them on the **fee-inclusive** cost:

```text
allInCost = grossPremium + kuruTakerFee
allInCost <= buyerMaxTotalPremium
optionAmountReceived >= buyerMinOptionAmount
block.timestamp <= buyerDeadline
```

Enforcing the limit on `grossPremium` instead of `allInCost` is a defect: a high-taker-fee market would let a buyer's real cost exceed the limit they consented to. See [fee-spec.md](./fee-spec.md).

**Layer 2, advisory, enforced by the official frontend:**

```text
allInCost   <= acceptableMaxPremium(optionAmount)      // totals, not per option
netProceeds >= acceptableMinPremium(optionAmount)      // totals, not per option
market == canonicalRegistryMarket(seriesId)
spread       <= configuredMaxSpread
priceImpact  <= configuredMaxPriceImpact
quoteAge     <= configuredMaxQuoteAge
availableDepth >= buyerMinDepth
baseAsset  == optionToken
quoteAsset == series quoteAsset
```

Layer 2 checks cannot bind a user who chooses to trade directly against Kuru, and V1 must not claim otherwise in any user-facing copy. Their purpose is to stop the official path from routing users into bad executions, not to make bad executions impossible.

If a protocol-owned router is added in a later version, it must enforce both layers atomically and revert on any failure, at which point Layer 2 becomes a real onchain guarantee for users of that router only.

None of these checks are settlement inputs. No premium value of any kind reaches collateral, settlement, payout, or residual math.

## Edge Cases

### `S == K`

Both calls and puts expire at the money:

```text
buyerPayout = 0
writerResidual = full collateral
```

### `S` Very High

Call payout approaches the full underlying collateral but never exceeds it:

```text
lim S -> infinity callBuyerPayout(a) = E(a)
```

### `S` Very Low

Put payout approaches the full quote collateral as `S` approaches zero:

```text
lim S -> 0 putBuyerPayout(a) = E(a) * K
```

The oracle adapter should reject `S == 0` as invalid.

### Dust

Dust arises from token decimals, price decimals, fixed-point division, flooring claims, and ceiling collateral. It is bounded by roughly one unit of the collateral asset per claim transaction, so it is an accounting concern rather than an economic one.

The V1 policy is defined in Invariant 5A above: dust stays in the vault and is sweepable by governance only once `totalSupply == 0` and `totalUnclaimedShortAmount == 0`. Vector 3 in the worked test vectors demonstrates a 1 wei dust case end to end.

## Required Test Categories

- The five worked vectors above, asserted exactly, as the first tests written.
- Unit tests for call rates at `S < K`, `S == K`, and `S > K`.
- Unit tests for put rates at `S < K`, `S == K`, and `S > K`.
- `UQ_SCALE` correctness across every supported decimal pair, including underlying decimals below, equal to, and above quote decimals.
- Assertion that `buyerPayoutRate + writerResidualRate == collateralPerOption` exactly, as a fuzz target over all prices.
- Boundary tests for very small amounts, very large amounts, very high prices, and very low prices.
- Fuzz tests asserting total claims never exceed collateral, with **fragmented** mints and claims, since fragmentation is the case the aggregate proof covers.
- Fuzz test asserting that with all fee rates set to zero, results are bit-identical to a no-fee implementation.
- Fee tests asserting `collateralLocked` is never reduced by fee collection and that `sweepFees` cannot touch collateral.
- State-machine tests across active, expired, settled, redeemed, and claimed states.
- Reentrancy tests with malicious token contracts.
- Tests proving Kuru market price cannot affect settlement.
- Tests proving premium paid cannot affect collateral, settlement payout, or writer residual.
- Tests proving fee-inclusive buyer limits bind on `allInCost` rather than `grossPremium`.
- Tests for stale, zero, invalid, or wrong-pair oracle responses.
