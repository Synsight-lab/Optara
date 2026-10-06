# Math

Every formula the contracts use. If another document disagrees with this one on a formula or a rounding
direction, this one wins.

## 1. Notation and units

| Symbol | Meaning | Unit |
|---|---|---|
| `S` | Live spot price | WAD (settlement asset per underlying) |
| `S*` | Final settlement price | WAD |
| `K` | Strike | WAD |
| `CS` | Contract size | WAD (underlying per option) |
| `q` | Signed balance (+ long, − short) | 18 decimals |
| `σ` | Implied volatility | WAD (`1e18` = 100%) |
| `T` | Time to expiry | WAD years (`seconds × 1e18 / 31_536_000`) |
| `w` | Total variance `σ²·T` | WAD |
| `d` | Settlement-asset decimals (0–18) | — |
| cash | Account cash | native units |

Conversions:

```text
toWad(native)        = native × 10^(18−d)                        // exact
toNativeDown(xWad)   = floor(xWad / 10^(18−d))
toNativeUp(xWad)     = ceil (xWad / 10^(18−d))
mulWadDown(a, b)     = floor(a × b / 1e18)      mulWadUp = ceil(...)
```

All products use full-precision `mulDiv` (no intermediate overflow).

## 2. Rounding directions

Rounding must always favor solvency.

| Quantity | Direction |
|---|---|
| Value of a **short** position (liability) | Up |
| Value of a **long** position (asset) | Down |
| Scenario loss, IM, MM | Up |
| Fees, liquidation penalty | Up |
| Cash paid **to** a liquidator from the account | Up (account pays more) |
| Cash paid **by** a liquidator to the account | Down |
| Settlement debt collected from a short | Up |
| Settlement credit to a long account | Down |
| Wrapper redemption payout | Down |
| Recovery ratio | Down |

## 3. Payoff at expiry

```text
intrinsic(CALL, S) = max(S − K, 0)
intrinsic(PUT,  S) = max(K − S, 0)
payoffPerOption    = intrinsic(S*) × CS / 1e18                    // WAD of settlement asset
```

## 4. Time to expiry

```text
T(now) = max(expiry − now, 0) × 1e18 / 31_536_000
```

A year is fixed at 365 days.

## 5. Implied volatility of a series

The surface for a product is a grid of **total variance** `w(tenor, k)`, with `k = ln(K / F)` and `F = S` (zero rates,
no carry in v1). The signed report gives:

- `tenorTimestamps[0..n−1]` (n ≤ 4, increasing, absolute expiry times);
- `kNodes[0..m−1]`: log-moneyness grid points (same for every tenor);
- leaves `w(i, j)` for tenor `i`, node `j`, proven against `surfaceRoot`;
- `reportTime` (= `validAfter`).

Steps for series with expiry `τ`, strike `K`, at current spot `S`:

```text
1. k = ln(K / S)
2. pick tenors a, b with tenorTimestamps[a] ≤ τ ≤ tenorTimestamps[b]   (a = b if τ equals a tenor)
   if τ is outside [first, last] tenor: the series is not priceable -> product close-only for it
3. pick nodes j, j+1 with kNodes[j] ≤ k ≤ kNodes[j+1]
   if k < kNodes[0]: use node 0 only;  if k > kNodes[m−1]: use node m−1 only   (flat extrapolation)
4. moneyness interpolation at each tenor (linear in k):
      w_a = w(a,j) + (w(a,j+1) − w(a,j)) × (k − k_j) / (k_{j+1} − k_j)      same for w_b
5. tenor interpolation (linear in time, on total variance):
      T_a = (t_a − reportTime) in years,  T_b likewise,  T_τ = (τ − reportTime) in years
      w_τ = w_a + (w_b − w_a) × (T_τ − T_a) / (T_b − T_a)
6. σ = sqrt(w_τ / T_τ)
7. clamp: σ = min(max(σ, minIv), maxIv)          // per risk parameter set and report bounds
```

This needs at most 4 grid leaves per series (2 tenors × 2 nodes). Proven leaves are cached per
`(productId, surfaceSeq, tenorIndex, nodeIndex)`.

**Sticky strike in scenarios.** The IV of each position is computed once at current spot. Scenarios then shift spot
and multiply IV. They do not re-look-up the surface at the shocked spot, so a check needs no extra leaves.

### 5.1 Staleness adjustment (direction-aware)

If the surface is older than `surfaceStaleAfter` but younger than `maxSurfaceStale`:

```text
staleSeconds = max(now − reportTime − surfaceStaleAfter, 0)
penalty      = ceil(staleIvPenaltyBpsPerHour × staleSeconds × 1e18 / (10_000 × 3600))   // absolute IV, WAD
                                                   // accrues per second, rounded up

σ_short = min(σ + penalty, maxIv)          // used for short legs
σ_long  = max(σ − penalty, minIv)          // used for long legs
if now − reportTime > maxLongTimeValueStale: long legs are valued at intrinsic only
```

Fresh surface: `σ_short = σ_long = σ`.

## 6. Option price (Black-76, zero rates)

For one option (per unit of underlying), with `F = S`, volatility `σ`, time `T`:

```text
if T == 0 or σ == 0:  price = intrinsic(S)
else:
    v  = σ × sqrt(T)
    d1 = (ln(F / K) + v²/2) / v
    d2 = d1 − v
    CALL = F·N(d1) − K·N(d2)
    PUT  = K·N(−d2) − F·N(−d1)
price is floored at intrinsic(S) and capped: CALL ≤ F, PUT ≤ K
```

`N` is the standard normal CDF. The implementation must have absolute error ≤ `1e-7` (relative to 1.0) for all
inputs. Use audited `lnWad`, `expWad` and `sqrt` (Solady) and the Numerical Recipes `erfcc` Chebyshev fit for erfc:

```text
z = |x| / √2,  t = 1 / (1 + z/2)
erfc(z) = t·exp(−z² − 1.26551223 + t·(1.00002368 + t·(0.37409196 + t·(0.09678418 + t·(−0.18628806
          + t·(0.27886807 + t·(−1.13520398 + t·(1.48851587 + t·(−0.82215223 + t·0.17087277)))))))))
N(x) = 1 − erfc(z)/2 for x > 0;  erfc(z)/2 for x < 0;  exactly 1/2 for x = 0
```

Its **relative** error is below 1.2e-7 everywhere, so the CDF's absolute error is below 6e-8 (measured 4.2e-8) and
the tails stay accurate. Don't use Abramowitz & Stegun 7.1.26: its absolute error passes, but its relative error in
the tails reaches 100%, so deep out-of-the-money prices (a difference of two tiny terms) become meaningless.
`N(−x) = 1 − N(x)` holds exactly, so put-call parity holds up to rounding. The independent Python reference model
([TESTING.md](TESTING.md) §3) and the Solidity differential tests check this.

## 7. Position value

```text
legValue(q, price) = q × CS × price           // signed, WAD of settlement asset

for q > 0 (long):  round down,  use σ_long
for q < 0 (short): round up (more negative), use σ_short
```

## 8. Equity

For subaccount `a` with settlement asset of `d` decimals:

```text
equity(a) = toWad(cash(a))
          + Σ over open series i of legValue(q_i, price_i(S_now, σ_i, T_now))
          + Σ over finalized-unsettled series i of q_i × payoffPerOption_i      (exact, no scenarios)
```

Fees are debited from cash immediately, so there are no accrued fees. Pending settlement credits are not counted until
claimed (see [SETTLEMENT.md](SETTLEMENT.md) §6).

Series that have **expired but are not finalized** use `T = 0` (intrinsic at live spot) and still receive spot shocks
in scenarios.

## 9. Scenarios, IM and MM

A scenario is:

```solidity
struct Scenario {
    int32  spotShockBps;    // e.g. -5000 = -50%, +10000 = +100%
    int32  volShockBps;     // e.g. -3000 = -30%, +7500 = +75% (relative to the leg's IV)
    uint8  timeMode;        // 0 = now, 1 = near-expiry floor, 2 = shift by timeShiftSeconds
    uint32 timeShiftSeconds;
}
```

Applied to a leg:

```text
S_s = S × (10_000 + spotShockBps) / 10_000                    (≥ 0)
σ_s = clamp(σ_leg × (10_000 + volShockBps) / 10_000, minIv, maxIv)
T_s = T                               (timeMode 0)
    = min(T, nearExpiryFloorSeconds)  (timeMode 1)
    = max(T − timeShiftSeconds, 0)    (timeMode 2)
```

Margin is computed **per risk bucket** (one underlying) and summed. Cash is shared, but scenario losses of different
underlyings never offset each other:

```text
bucketValue(b, s) = Σ over legs of underlying b: legValue(q, price(S_s, σ_s, T_s))
bucketLoss(b, set) = max(0, max over s in set of (bucketValue(b, base) − bucketValue(b, s)))
                     // base = (0, 0, now). Round up.

maxLoss(a, set) = Σ over buckets b of bucketLoss(b, set)

shortMark(a)    = Σ over short legs of |legValue(q, price)|               // current mark of all shorts

IM(a) = maxLoss(a, initialStressSet ∪ maintenanceStressSet)
      + shortMark(a) × imBufferBps / 10_000                                  (round up)
MM(a) = maxLoss(a, maintenanceStressSet)                                     (round up)
```

The stress sets are lists of scenarios in the risk parameter set (defaults in [PARAMETERS.md](PARAMETERS.md) §3).
Losses are computed from per-leg values already rounded toward −∞ (§7); identities such as homogeneity therefore
hold to a few wei, far below one native unit.

Note: under a stale surface the short IV rises, which raises a short's current liability more than its liability in
a deep in-the-money scenario, so IM can fall slightly while health (`equity − IM`) still falls. Health, not IM, is
what INV-16 protects.

Two details are deliberate, and both were confirmed by `reference/verify_math.py`:

- **IM uses the union of both sets.** Then `MM ≤ IM` holds for every portfolio by construction. With separate sets,
  a mixed long/short-volatility portfolio can lose more in a milder scenario than in any harsher one (check M7b found
  such a portfolio).
- **The buffer is a percentage of the shorts' current mark, not of the loss.** A loss-based buffer makes risk-reducing
  actions able to lower `equity − IM` (check M6b found hundreds of cases). A short-mark buffer never rises when a long
  is added or a short is removed, so the health theorem in §9.1 holds exactly.

### 9.1 Health

```text
Healthy       equity ≥ IM
Close-only    MM ≤ equity < IM
Liquidatable  equity < MM
Insolvent     equity < 0 with no positions left to liquidate
```

`equity − maxLoss(set)` equals the smallest of current equity and every scenario equity in the set. So:

- **Adding a long never lowers health** (`equity − IM` or `equity − MM`). A long's value is ≥ 0 in every scenario,
  so it raises the current equity and every scenario equity, and the short-mark buffer is unchanged. That's why
  `unwrapLong` needs no margin check.
- **Removing a short never lowers health,** for the same reason, and the buffer can only fall
  (`closeShortWithWrapper`).
- **Depositing never lowers health.**

Proof sketch for adding a long with current value `v0 ≥ 0` and scenario values `v_s ≥ 0`: new equity = `e0 + v0`,
and each scenario loss changes by `v0 − v_s ≤ v0`. So `max loss` rises by at most `v0` while equity rises by exactly
`v0`. Verified numerically by check M6.

## 10. Worked examples (margin)

ETH = 4,000 USDC, 30 days to expiry, CS = 1, default stress sets, `imBufferBps = 500` (5% of short mark).

| Position | IV | Mark (USDC) | maxLoss (IM ∪ MM sets) | IM (+ 5% of short mark) | MM | Cash needed (`IM − mark`) |
|---|---|---|---|---|---|---|
| Short 1 × 4,500 call | 60% | −106.77 | 3,412.44 | 3,417.78 | 1,447.43 | **3,524.55** |
| Short 4,500 call + long 5,000 call | 60% / 62% | −67.12 | 432.88 | 438.22 | 413.06 | **505.34** |
| Short 1 × 3,500 put | 65% | −96.62 | 1,418.40 | 1,423.23 | 676.31 | **1,519.85** |

The naked call is dominated by the `+100%` spot shock. The spread's worst case is bounded by its width (500), so its
margin is far lower. These figures are reproduced exactly by `reference/verify_math.py` (check M5b).

## 11. Fees

```text
markWad      = |legValue(qty, price)| for the minted quantity     (σ = current mid IV, rounded down)
sellerFee    = toNativeUp(markWad × sellerOpenFeeBps / 10_000)
               then max(sellerFee, minSellerFeeNative)

buyerFee     = ceil(executedPremiumNative × buyerTradeFeeBps / 10_000)

split of every fee F:
  toInsurance = floor(F × insuranceShareBps / 10_000)
  toKeeper    = floor(F × keeperShareBps   / 10_000)
  toTreasury  = F − toInsurance − toKeeper            // remainder, so nothing is lost
```

The seller fee is charged **before** the IM check, so it can never consume required margin.

## 12. Liquidation

For risk bucket `b` of account `a` during an active auction:

```text
bonusBps   = startBonusBps + (maxBonusBps − startBonusBps) × min(elapsed, auctionDuration) / auctionDuration
sliceBps   in [minSliceBps, maxSliceBps]  (up to 10_000 once elapsed ≥ auctionDuration)
moved qty per unexpired leg = |q| × sliceBps / 10_000, rounded DOWN to a multiple of minPositionQty (sign of q)
sliceMark  = equity_before − equity_after_moves    // = Σ legValue(moved qty); < 0 when a net liability
sliceMM    = MM_before − MM_after                  // actual drop of the account's MM; must be > 0
discount   = sliceMM × bonusBps / 10_000           (round up)
penalty    = sliceMM × liquidationPenaltyBps / 10_000   (round up, to insurance)
```

When the slice is exactly pro-rata, `sliceMM = f × bucketLoss(b, maintenanceStressSet)` (§12.1 below). Rounding the
moved quantities can make it slightly different, so the contract always uses the actual MM drop.

Cash movement (account → liquidator is positive):

```text
if sliceMark < 0:   cashToLiquidator   = −sliceMark + discount
if sliceMark ≥ 0:   cashFromLiquidator = max(0, sliceMark − discount)
```

In native units: `cashToLiquidator` rounds **up**, `cashFromLiquidator` rounds **down**, the penalty rounds **up**
(INV-49). `equity_after_moves` is measured before any cash moves; both equities and MMs are LIQUIDATION-mode values
from the risk engine, so `sliceMark` uses the same (stale-direction) IVs as the account's equity.

If the account's cash can't pay `cashToLiquidator + penalty`, the liquidator is paid first and the penalty is
reduced (down to zero). If cash can't even cover `cashToLiquidator`, the account pays all its cash and the insurance
fund may top up the liquidator up to `maxInsurancePerLiquidation`. Any remainder is simply not paid: the liquidator
accepted the slice knowing the offered amount (see [LIQUIDATION.md](LIQUIDATION.md) §5).

**Why health always improves.** Scaling every position in a bucket by `(1 − f)` scales every scenario loss by
`(1 − f)` (margin is homogeneous; check M8), so MM falls by `sliceMM`. The slice moves at mark value, so the account's
equity changes by at most `−discount − penalty`. So:

```text
Δ(equity − MM) ≥ sliceMM × (1 − (bonusBps + liquidationPenaltyBps) / 10_000) > 0
```

as long as `maxBonusBps + liquidationPenaltyBps < 10_000`, which config enforces.

- **Equality** holds when the account pays in full and the slice is a net liability.
- **The gain is larger** when the penalty is reduced (cash ran out) or a net-asset slice's discount exceeds its mark.

Checks M9/M9b confirm both cases. The contract still requires a strict improvement after rounding to native units.
For a dust-sized slice (gain below ~2 native units) rounding can erase the gain, and the call simply reverts.

### 12.1 Worked example

ETH rallies to 6,200 with 20 days left. Account: cash 3,700 USDC, short 1 × 4,500 call, IV 60%.

| | Value |
|---|---|
| Mark of the short | −1,702.86 |
| Equity | 1,997.14 |
| MM | 3,097.15 → **liquidatable** |
| Slice 25%, bonus 5%, penalty 2% | sliceMark −425.71, sliceMM 774.29 |
| Discount / penalty | 38.71 / 15.49 |
| Cash to liquidator | 464.43 |
| Health (equity − MM) before → after | −1,100.01 → **−379.92** |

The liquidator now holds a short 0.25 call and 464.43 USDC, and must pass its own IM check.

### 12.2 Wrapper-burn liquidation

The liquidator burns `q` wrappers of series `i` that the account is short:

```text
ΔMM        = MM_before − MM_after        // must be > 0
discount   = ΔMM × bonusBps / 10_000
penalty    = ΔMM × liquidationPenaltyBps / 10_000
cashToLiquidator = q × CS × price_i(σ_short) + discount       // round up
```

Health again improves by `ΔMM × (1 − bonus − penalty)`.

## 13. Settlement

For group `g` with final price `S*`. Every number below is an exact integer numerator at scale `1e54`
(balance 1e18 × intrinsic 1e18 × CS 1e18), with `D = 10^(54 − d)`. This avoids rounding per leg.

```text
n_i(q) = q × intrinsic_i(S*) × CS_i                         // signed numerator

account net:   N_a = Σ over series i in g of n_i(q_a,i)

if N_a < 0:   debt       = ceil(−N_a / D)                    // native
              collected  = min(cash_a, debt);  cash_a −= collected
              deficit_g += debt − collected                  // unpaid
if N_a > 0:   creditN[a][g] = N_a;   netCreditN_g += N_a     // claim, paid later × ratio
```

After **every** participant has settled (participant counter = 0):

```text
wrapperClaimN_g = Σ over series i in g of n_i(wrapperSupplyAtFinalization_i)
grossClaimN_g   = wrapperClaimN_g + netCreditN_g             // netted claims only
grossClaim_g    = ceil(grossClaimN_g / D)                    // native
collected_g     = Σ collected
shortfall_g     = max(0, grossClaim_g − collected_g)
insurance_g     = min(shortfall_g, insuranceBalance(asset))  // paid into the group pool
available_g     = collected_g + insurance_g
ratioWad_g      = grossClaimN_g == 0 ? 1e18
                : min(1e18, floor(available_g × D × 1e18 / grossClaimN_g))
```

Payouts:

```text
wrapper redemption of qty:   floor(qty × intrinsic_i × CS_i × ratioWad_g / (D × 1e18))
internal credit claim:       floor(creditN[a][g] × ratioWad_g / (D × 1e18))
```

Each payout is rounded down from its own exact numerator, so the total paid never exceeds `available_g`.

### 13.1 Why claims must be netted

When everyone is solvent, money owed by net debtors equals money owed to wrapper holders plus net creditors:

```text
Σ debts = wrapperClaims + Σ net credits
```

Counting **gross** internal longs as claims would count a long that already offset a short in the same account,
and would create a false shortfall. See the example below.

### 13.2 Worked example

ETH 4,500 call `X` and 5,000 call `Y`, `S* = 5,200`. Payoffs: X = 700, Y = 200.

- Account A: short 1 X, long 1 Y (internal, unwrapped). Net = −700 + 200 = **−500**.
- Account B: short 1 Y (it minted the Y wrapper A unwrapped). Net = **−200**.
- Wallet W: holds 1 X wrapper (minted by A). Claim = **700**.

| | Value |
|---|---|
| Collected | 500 + 200 = 700 |
| grossClaim (netted) | 700 (W) + 0 net creditors = 700 |
| Ratio | **1.0**; W redeems 700 |
| Wrong formula (gross longs: W + A's Y) | 900 → false ratio 0.78 |

If B had only 50 cash: collected = 550, shortfall = 150. With insurance 100: available = 650, ratio = 650 / 700 =
0.928571… (rounded down), and W receives **649.999999** USDC. Rounding the ratio and the payout down leaves 1 micro-USDC
of dust in the pool, which `sweepDust` later sends to insurance. Verified exactly by check M5e.

**Settlement identity.** At finalization INV-1 gives `Σ_accounts q + wrapperSupply = 0` per series. Multiplying by
each series' payoff and summing: `Σ_accounts N_a + wrapperClaimN = 0`. So the net debts owed exactly equal wrapper
claims plus net credits. If every debtor pays, the ratio is exactly 1 (checks M12a, M12b).

## 14. Checked bounds

- Every product `q × intrinsic × CS` and every per-account and per-group sum must fit in `int256`. The hard caps
  that guarantee it:

  | Cap | Value | Enforced by |
  |---|---|---|
  | `maxContractSizeWad × maxSettlementPriceWad` per product | ≤ 1e50 | `OptionSeriesRegistry.approveProduct` |
  | `maxSettlementPriceWad` | ≤ 1e36 | `approveProduct` |
  | Settlement price used for payoffs | `min(S*, min over the group's series of floor(1e50 / CS_i))` | `SettlementWindow` at finalization |
  | Strike | ≤ `maxSettlementPriceWad` | `approveProduct` |
  | Series per group | ≤ 256 | `createSeries` |
  | Open interest (total internal short) per series | ≤ 1e24 (1,000,000 options) | Risk parameters (hard cap) |

  Per series, wrapper supply + internal longs = internal shorts ≤ 1e24, and `intrinsic × CS ≤ 1e50` (a call's
  intrinsic ≤ the capped `S*` ≤ 1e50 / CS; a put's ≤ K ≤ `maxSettlementPrice` with `CS × maxSettlementPrice ≤ 1e50`
  at creation), so each series contributes at most 1e74 to a group sum; 256 series give at most 2.56e76 < `int256`
  max (5.79e76). The cap is computed per group from the series' own contract sizes, so later changes to product
  bounds can't break it.
- `spotShockBps ≥ −10_000` (spot never below 0).
- `maxBonusBps + liquidationPenaltyBps < 10_000`.
- `imBufferBps ≤ 5_000`.
