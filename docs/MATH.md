# Optara V2 Mathematical Specification

**Document type:** Normative protocol mathematics
**Protocol:** Optara
**Target:** V2 solvency-first MVP on Monad
**Version:** 0.2.0-draft
**Date:** 2026-09-24
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document is the mathematical source of truth for Optara V2.

It defines the formulas required to implement and test:

- capped European call and put payoffs;
- contract size and option quantity;
- maximum contractual liability;
- premium and economic PnL;
- exact portfolio margin;
- hedge recognition and portfolio netting;
- settlement-stablecoin isolation;
- free collateral and withdrawal capacity;
- settlement-price normalization;
- atomic matured-risk-group settlement;
- long redemption;
- fixed-point scaling and rounding;
- issuance, supply, and settlement conservation identities;
- solvency conditions and mathematical invariants.

This document must be read together with:

- `OPTION_SPEC.md` — option-series semantics;
- `PROTOCOL_SPEC.md` — runtime state transitions;
- `ARCHITECTURE.md` — component boundaries;
- `PRD.md` — product requirements.

If a document appears to conflict with this file on a numerical formula or rounding rule, `MATH.md` is authoritative for **mathematical behavior**. `OPTION_SPEC.md` remains authoritative for the immutable economic meaning of an option series, and `PROTOCOL_SPEC.md` remains authoritative for state-transition ordering.

---

## 2. Core mathematical principles

Optara V2 is built around six mathematical rules:

1. Every option has a finite contractual payout.
2. Every risk group is margined against its exact worst-case expiry loss, not a statistical estimate.
3. Only locked long options controlled by Optara may reduce a writer's margin.
4. Positions may net only inside the same risk group.
5. Margin and settlement are denominated in the option pair's own approved settlement stablecoin.
6. Core V2 does not rely on price-driven liquidation to remain solvent.

The central solvency condition is:

```text
cashBalance(account, settlementAsset)
    >= requiredMargin(account, settlementAsset)
```

after every risk-increasing or collateral-decreasing operation.

---

## 3. Pair and denomination model

Every option series belongs to an approved pair:

```text
UNDERLYING / SETTLEMENT_STABLECOIN
```

Examples:

```text
MON / USDT
ETH / USDC
BTC / USDe
```

For a given series, the right-hand stablecoin is simultaneously the:

```text
quote asset
strike denomination
payout-cap denomination
canonical premium quote asset
writer cash-margin asset
cash-settlement asset
```

Optara is therefore **not USDC-based**.

For example:

```text
MON/USDT options -> all strike, margin, payout and settlement math is in USDT
ETH/USDC options -> all strike, margin, payout and settlement math is in USDC
```

A USDT balance is not mathematically interchangeable with a USDC balance in core V2.

---

## 4. Notation

For one option series `i`:

| Symbol | Meaning |
|---|---|
| `S` | Final settlement price of one underlying unit, denominated in the series settlement stablecoin |
| `K_i` | Strike price per underlying unit |
| `C_i` | Maximum payout cap per underlying unit |
| `CS_i` | Contract size: underlying units represented by one whole option token |
| `Q_i` | Quantity of option tokens |
| `P_i` | Market premium per whole option token |
| `phi_i(S)` | Capped payoff per underlying unit |
| `Payoff_i(S,Q_i)` | Total settlement payoff for quantity `Q_i` |
| `q_i^-` | Account short quantity for series `i` |
| `q_i^+` | Account locked-long quantity for series `i` |
| `W_g` | Worst-case loss of risk group `g` |
| `M_g` | Required margin of risk group `g` |
| `B_{a,A}` | Cash balance of account `a` in settlement asset `A` |

All economic prices are non-negative in core V2:

```text
S >= 0
K > 0
C > 0
CS > 0
Q >= 0
```

For puts, core V2 uses the canonical constraint:

```text
0 < C <= K
```

because the underlying settlement price cannot be negative.

---

## 5. Internal fixed-point scale

Optara SHOULD use:

```text
WAD = 1e18
```

for normalized internal economic math.

Recommended meanings:

```text
strikeWad
    = settlement-stablecoin units per underlying unit, scaled by 1e18

maxPayoutWad
    = settlement-stablecoin units per underlying unit, scaled by 1e18

contractSizeWad
    = underlying units per whole option token, scaled by 1e18

quantityWad
    = option-token quantity, where 1 whole option = 1e18

settlementPriceWad
    = settlement-stablecoin units per underlying unit, scaled by 1e18
```

The conceptual formulas in this document are real-number formulas. Solidity implementations MUST use full-precision integer arithmetic and the rounding rules defined later in this document.

---

# Part I — Option payoff mathematics

## 6. Capped call payoff

For a call option:

```text
intrinsicCall(S) = max(S - K, 0)
```

The capped payoff per underlying unit is:

```text
phi_call(S) = min(max(S - K, 0), C)
```

Piecewise:

```text
                 0                         if S <= K
phi_call(S) =    S - K                     if K < S < K + C
                 C                         if S >= K + C
```

The call has two breakpoints:

```text
K
K + C
```

The call payout can never exceed `C` per underlying unit.

---

## 7. Capped put payoff

For a put option:

```text
intrinsicPut(S) = max(K - S, 0)
```

The capped payoff per underlying unit is:

```text
phi_put(S) = min(max(K - S, 0), C)
```

When `C <= K`, the piecewise form is:

```text
                 C                         if 0 <= S <= K - C
phi_put(S) =     K - S                     if K - C < S < K
                 0                         if S >= K
```

The put has two breakpoints:

```text
K - C
K
```

The put payout can never exceed `C` per underlying unit.

---

## 8. Capped-option spread identities

These identities are useful for testing and reasoning.

### Capped call

```text
min(max(S-K,0), C)
=
max(S-K,0) - max(S-(K+C),0)
```

Therefore a capped call has the same expiry payoff as:

```text
long call at K
-
long call at K + C
```

or equivalently a call spread of width `C`.

### Capped put

For `C <= K`:

```text
min(max(K-S,0), C)
=
max(K-S,0) - max((K-C)-S,0)
```

Therefore a capped put has the same expiry payoff as a put spread of width `C`.

Optara implements the bounded payoff directly as one option series rather than requiring two option legs.

---

## 9. Contract size and quantity

`CS` defines the underlying exposure of one whole option token.

Examples:

```text
CS = 1.0  -> one option represents 1 MON
CS = 0.1  -> one option represents 0.1 ETH
```

For quantity `Q`, total underlying exposure is:

```text
Exposure = CS * Q
```

The total option payoff is:

```text
Payoff(S,Q) = phi(S) * CS * Q
```

where all multiplication uses consistent fixed-point scaling.

For a series `i`:

```text
Payoff_i(S,Q_i)
    = phi_i(S) * CS_i * Q_i
```

---

## 10. Maximum contractual payout

Because:

```text
0 <= phi_i(S) <= C_i
```

for every valid settlement price:

```text
0 <= Payoff_i(S,Q_i)
   <= C_i * CS_i * Q_i
```

Therefore:

```text
MaxContractualLiability_i(Q_i)
    = C_i * CS_i * Q_i
```

This bound is independent of how high or low the underlying moves after the cap is reached.

For a capped call, a price move from 20 to 2000 does not increase liability once the cap is already reached.

---

## 11. Call and put boundary invariants

For calls:

```text
S = K       -> payoff = 0
S = K + C   -> payoff = C per underlying
S > K + C   -> payoff remains C per underlying
```

For puts:

```text
S = K       -> payoff = 0
S = K - C   -> payoff = C per underlying
S < K - C   -> payoff remains C per underlying
```

At `S = 0`, a put remains bounded by `C`.

Negative settlement prices are unsupported in core V2.

---

# Part II — Premium and economic PnL

## 12. Premium is not part of the option payoff

The premium is market-discovered consideration for acquiring the long token.

It is not an immutable series parameter and it does not change the contractual payoff function.

If the market premium per whole option is `P` and quantity is `Q`:

```text
TotalPremium = P * Q
```

The option payoff remains:

```text
Payoff(S,Q) = phi(S) * CS * Q
```

regardless of what premium was paid.

---

## 13. Buyer and writer expiry PnL

Ignoring fees:

```text
BuyerPnL = Payoff(S,Q) - TotalPremiumPaid
```

```text
WriterPnL = TotalPremiumReceived - Payoff(S,Q)
```

Maximum buyer gross payoff is:

```text
C * CS * Q
```

Maximum writer **contractual liability** is also:

```text
C * CS * Q
```

Maximum writer **economic loss after premium** is:

```text
C * CS * Q - TotalPremiumReceived
```

but Optara MUST NOT reduce required margin merely because a premium is expected or was earned externally.

---

## 14. Premium and margin accounting

The correct relationship is:

```text
RequiredMargin = contractual worst-case portfolio loss
```

and:

```text
AdditionalDepositNeeded
    = max(RequiredMargin - ExistingOptaraCashBalance, 0)
```

A premium helps margin only if the relevant settlement stablecoin has actually entered the writer's Optara margin account.

Example:

```text
Required margin = 5 USDT
Writer already has 0 USDT in Optara
Writer earns 0.50 USDT on Kuru
```

Until that `0.50 USDT` is deposited into Optara:

```text
AdditionalDepositNeeded = 5 USDT
```

After the writer transfers and deposits the `0.50 USDT` into Optara:

```text
ExistingOptaraCashBalance = 0.50 USDT
AdditionalDepositNeeded   = 4.50 USDT
```

This is mathematically different from subtracting an unpaid or externally held premium from the liability.

---

# Part III — Risk groups and portfolio netting

## 15. Risk-group definition

Core V2 permits payoff netting only within a risk group:

```text
riskGroup = (
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

Two positions may offset only if all four fields match.

Strike, cap, option type, and contract size may differ.

The RiskEngine determines the actual offset from the payoff functions, not from labels such as "spread" or "hedge".

---

## 16. Positions included in margin math

For account `a` and risk group `g`, the RiskEngine includes:

```text
shortQty[a][series]
lockedLongQty[a][series]
```

Only long tokens physically controlled by Optara and recorded as locked longs count as margin offsets.

The following do not count:

```text
wallet-held longs
Kuru-held longs
longs in another DeFi protocol
unconfirmed trades
external receivables
positions in another expiry
positions in another underlying
positions in another settlement stablecoin
positions in another oracle domain
```

---

## 17. Short liability function

For account `a`, group `g`, and settlement price `S`:

```text
ShortLiability_{a,g}(S)
    = sum over short series i in g of
      Payoff_i(S, q_i^-)
```

or explicitly:

```text
ShortLiability_{a,g}(S)
    = Σ_i [ phi_i(S) * CS_i * q_i^- ]
```

This is the amount the account would owe if the group settled at `S`.

---

## 18. Locked-long credit function

For the same account and group:

```text
LockedLongCredit_{a,g}(S)
    = sum over locked-long series j in g of
      Payoff_j(S, q_j^+)
```

or:

```text
LockedLongCredit_{a,g}(S)
    = Σ_j [ phi_j(S) * CS_j * q_j^+ ]
```

These long claims are valid margin offsets because Optara controls the tokens and can consume them during settlement.

---

## 19. Net portfolio liability

Define signed group liability:

```text
NetLiability_{a,g}(S)
    = ShortLiability_{a,g}(S)
      - LockedLongCredit_{a,g}(S)
```

If this value is negative, the account would be net owed stablecoin at that settlement price.

Margin only needs to cover positive liability:

```text
Loss_{a,g}(S)
    = max(NetLiability_{a,g}(S), 0)
```

---

## 20. Exact worst-case loss

The group's exact worst-case contractual loss is:

```text
W_{a,g}
    = max over S >= 0 of Loss_{a,g}(S)
```

Equivalently:

```text
W_{a,g}
    = max(
        0,
        max over S >= 0 of
        [ShortLiability_{a,g}(S) - LockedLongCredit_{a,g}(S)]
      )
```

This is the fundamental portfolio-margin quantity in core V2.

No probability distribution is required.

No volatility estimate is required.

No FHS model is required.

No SPAN scenario grid is required.

The engine asks only:

> What is the largest contractual net amount this risk group can owe at any valid expiry price?

---

# Part IV — Exact finite-point risk evaluation

## 21. Why the maximum can be found exactly

Every capped option payoff is continuous and piecewise linear in `S`.

Therefore, between any two adjacent payoff breakpoints, every series payoff is affine:

```text
phi_i(S) = a_i * S + b_i
```

The portfolio net liability is therefore also affine on that interval:

```text
NetLiability(S) = A * S + B
```

A linear function on a closed interval reaches its maximum at one of the interval's endpoints.

Therefore the global maximum occurs at a payoff breakpoint or at the lower domain boundary `S = 0`.

Because capped calls are flat after their upper cap boundaries and puts are zero above their strikes, no search to infinity is needed.

---

## 22. Critical prices

For each call series:

```text
K_i
K_i + C_i
```

For each put series:

```text
K_i - C_i
K_i
```

where core V2 guarantees `C_i <= K_i` for puts.

The complete candidate set for risk group `g` is:

```text
Critical(g)
    = {0}
      union {K_i, K_i + C_i for every call i in g}
      union {K_j - C_j, K_j for every put j in g}
```

Duplicate prices may be removed.

If the group has no positions:

```text
W_{a,g} = 0
```

---

## 23. Exact worst-case algorithm

Conceptually:

```text
worst = 0

for S in uniqueSorted(Critical(group)):
    shortLiability = 0
    longCredit = 0

    for each short series i:
        shortLiability += Payoff_i(S, shortQty_i)

    for each locked long series j:
        longCredit += Payoff_j(S, lockedLongQty_j)

    loss = max(shortLiability - longCredit, 0)
    worst = max(worst, loss)

return worst
```

For `n` active series in the group:

```text
number of critical points <= 2n + 1
```

A direct implementation is therefore `O(n^2)` in the worst case.

This is acceptable only if Optara enforces a bounded maximum number of series per account risk group.

A later implementation may use a sorted slope-sweep algorithm to approach `O(n log n)`, but it MUST return the same mathematical result.

---

## 24. Fixed-point implementation requirement for exact risk

The real-number equations above are normative.

The Solidity RiskEngine MUST return a value that is **greater than or equal to** the exact mathematical worst-case loss after conversion to settlement-token units.

An implementation may achieve this by either:

1. exact/full-precision rational evaluation; or
2. conservative fixed-point evaluation plus a formally bounded rounding guard.

It MUST NOT use downward rounding in a way that can make required margin smaller than the true contractual worst-case loss.

If per-leg fixed-point rounding is used during risk evaluation, the implementation MUST prove and add a worst-case rounding-error bound before converting the group margin to native stablecoin units.

---

# Part V — Required margin

## 25. Risk buffer

Core economic solvency comes from exact worst-case loss.

An optional explicit safety buffer may be added for implementation/operational conservatism.

For group `g`, define:

```text
bufferBps_g >= 0
fixedBuffer_g >= 0
```

A recommended deterministic policy is:

```text
if W_g == 0:
    SafetyBuffer_g = 0
else:
    SafetyBuffer_g
        = ceil(W_g * bufferBps_g / 10_000)
          + fixedBuffer_g
```

The solvency-first MVP may configure:

```text
bufferBps_g = 0
fixedBuffer_g = 0
```

provided fixed-point rounding is independently handled conservatively.

A safety buffer is not a substitute for correct payoff or margin math.

---

## 26. Group required margin

Before conversion to native token units:

```text
GroupMargin_{a,g}
    = W_{a,g}
      + SafetyBuffer_g
      + RoundingGuard_g
```

where `RoundingGuard_g` is zero if the implementation proves exact arithmetic, otherwise it is a formally derived upper bound on numerical underestimation.

The final native settlement-token requirement MUST round upward.

---

## 27. Required margin per settlement stablecoin

Let `G(A)` be the account's active risk groups whose settlement asset is `A`.

Then:

```text
RequiredMargin_{a,A}
    = Σ_{g in G(A)} GroupMargin_{a,g}
```

with each group's requirement conservatively converted to native units according to the rounding rules later in this document.

Important:

```text
positions from different groups do not offset one another
```

but cash in the **same settlement stablecoin** may support the sum of those independent group requirements.

Example:

```text
MON/USDT December group margin = 5 USDT
ETH/USDT December group margin = 8 USDT

RequiredMargin(account, USDT) = 13 USDT
```

The MON and ETH payoff functions do not net, but the account's USDT balance secures both requirements.

---

## 28. Settlement-stablecoin isolation

For two different stablecoins `A` and `B`:

```text
RequiredMargin_{a,A}
```

must be satisfied using `A`, and:

```text
RequiredMargin_{a,B}
```

must be satisfied using `B`.

Core V2 forbids:

```text
surplus in B_{a,A} -> covers RequiredMargin_{a,B}
```

More explicitly:

```text
B_{a,USDT} cannot cover RequiredMargin_{a,USDC}
B_{a,USDC} cannot cover RequiredMargin_{a,USDe}
```

No implicit stablecoin exchange rate of `1:1` exists in the margin engine.

---

## 29. Account safety condition

For every settlement asset `A` affected by a state transition:

```text
B_{a,A} >= RequiredMargin_{a,A}
```

must hold after the operation.

A risk-increasing operation MUST revert if this inequality would fail.

A collateral-decreasing operation MUST revert if this inequality would fail.

---

## 30. Free collateral

After all required matured groups are synchronized:

```text
FreeCollateral_{a,A}
    = B_{a,A} - RequiredMargin_{a,A}
```

for a valid account.

Therefore:

```text
MaxWithdrawable_{a,A}
    = FreeCollateral_{a,A}
```

subject to token transfer granularity, fees if later introduced, and any emergency restrictions.

If:

```text
B_{a,A} < RequiredMargin_{a,A}
```

then the account is mathematically invalid under core V2 and must not be allowed to perform ordinary withdrawals or risk-increasing actions.

---

## 31. Additional collateral required

After required synchronization of any matured groups affecting the asset, for a proposed post-action portfolio:

```text
AdditionalCollateralNeeded_{a,A}
    = max(
        RequiredMarginPost_{a,A} - B_{a,A},
        0
      )
```

This is the correct number to show a user before writing a position.

It naturally accounts for:

- existing cash;
- existing shorts;
- locked hedges;
- the proposed new short;
- other risk groups settled in the same stablecoin.

---

## 32. Coverage ratio

For UI and monitoring, Optara may expose:

```text
CoverageRatio_{a,A}
    = B_{a,A} / RequiredMargin_{a,A}
```

when `RequiredMargin > 0`.

Interpretation:

```text
CoverageRatio >= 1 -> satisfies core margin requirement
CoverageRatio < 1  -> invariant violation / emergency state
```

If required margin is zero, the ratio may be represented as infinity or omitted.

This ratio is **not** a maintenance-margin liquidation trigger in core V2.

---

# Part VI — State-transition math

## 33. Writing a new short

Suppose account `a` writes additional quantity `ΔQ` of series `i`.

Simulated post-write short quantity:

```text
q_i^-' = q_i^- + ΔQ
```

Recalculate the affected group's worst-case loss:

```text
W_g' = WorstCaseLoss(group after proposed write)
```

Then recalculate:

```text
RequiredMargin_{a,A}'
```

Writing is permitted only if:

```text
B_{a,A} >= RequiredMargin_{a,A}'
```

No premium assumption is used in this check.

---

## 34. Closing a short

If an account returns quantity `ΔQ` of the same series long token:

```text
q_i^-' = q_i^- - ΔQ
```

with:

```text
0 < ΔQ <= q_i^-
```

The matching long quantity is burned.

Required margin is then recalculated from the reduced portfolio.

The reduction in required margin becomes additional free collateral.

---

## 35. Locking a long hedge

When compatible long quantity `ΔQ` is locked:

```text
q_i^+' = q_i^+ + ΔQ
```

The risk engine recomputes:

```text
W_g'
```

The margin saving is:

```text
MarginSaving
    = max(M_g - M_g', 0)
```

The protocol MUST NOT assume the long is useful merely because it is called a hedge.

If the payoff does not reduce worst-case portfolio loss:

```text
MarginSaving = 0
```

---

## 36. Unlocking a long hedge

For requested unlock `ΔQ`:

```text
q_i^+' = q_i^+ - ΔQ
```

The protocol computes post-unlock required margin.

Unlock is allowed only if:

```text
B_{a,A} >= RequiredMarginPostUnlock_{a,A}
```

A locked long may never be released first and checked afterward.

---

## 37. Withdrawal

For requested withdrawal `X` native units of settlement asset `A`:

```text
B_{a,A}' = B_{a,A} - X
```

After mandatory synchronization of relevant matured risk groups, withdrawal is valid only if:

```text
B_{a,A}' >= RequiredMargin_{a,A}
```

Equivalently:

```text
X <= FreeCollateral_{a,A}
```

---

# Part VII — Oracle and pair-price mathematics

## 38. Settlement price unit

The finalized settlement price must always mean:

```text
settlement stablecoin units per 1 underlying unit
```

Examples:

```text
MON/USDT -> USDT per MON
ETH/USDC -> USDC per ETH
```

`S`, `K`, and `C` must therefore share the same stablecoin-per-underlying unit system.

---

## 39. Direct pair feed

If the oracle directly provides the required pair:

```text
UNDERLYING / SETTLEMENT_STABLECOIN
```

then the adapter normalizes that price to WAD:

```text
S_wad = normalizeToWad(rawPrice, oracleDecimals)
```

subject to staleness, finality, and validity checks.

---

## 40. Derived pair feed

If a direct pair feed is unavailable, an approved derived path may be used.

For example:

```text
MON/USDT = (MON/USD) / (USDT/USD)
```

In real-number form:

```text
S_MON_USDT
    = P_MON_USD / P_USDT_USD
```

If both normalized inputs are WAD:

```text
S_wad
    = roundNearest(
        P_underlying_usd_wad * WAD
        / P_stablecoin_usd_wad
      )
```

with:

```text
P_stablecoin_usd_wad > 0
```

The oracle configuration MUST precommit to the exact feeds and rounding convention.

The protocol MUST NOT substitute:

```text
MON/USD
```

for:

```text
MON/USDT
```

by assuming USDT equals exactly one U.S. dollar.

---

## 41. Oracle conversion rounding

Derived settlement-price conversion SHOULD use deterministic nearest rounding to reduce systematic bias between calls and puts.

Recommended rule:

```text
roundNearest(x / d)
```

with an explicitly documented tie-breaking rule such as half-up.

Whatever rule is selected MUST be:

- deterministic;
- identical for all users in the risk group;
- immutable through `oracleConfigId` for that group;
- applied before call/put payoff calculation.

Risk margin before expiry does not depend on current spot price, so oracle rounding cannot reduce the exact worst-case margin requirement.

---

# Part VIII — Expiry and settlement mathematics

## 42. Finalized group settlement price

All series in one risk group share one immutable finalized settlement price:

```text
S_g^*
```

Once finalized:

```text
S_g^*(t_after) = constant
```

No series in that group may use another expiry price.

---

## 43. Series settlement payoff

For each series `i` in finalized group `g`:

```text
phi_i^* = phi_i(S_g^*)
```

For quantity `Q`:

```text
SettlementPayoff_i(Q)
    = phi_i^* * CS_i * Q
```

This value is deterministic after group finalization.

---

## 44. Atomic account risk-group settlement

For account `a` and finalized group `g`:

```text
Short^*_{a,g}
    = Σ_i Payoff_i(S_g^*, q_i^-)
```

```text
LockedLong^*_{a,g}
    = Σ_j Payoff_j(S_g^*, q_j^+)
```

Define the signed cash delta owed **to the account**:

```text
Delta_{a,g}
    = LockedLong^*_{a,g} - Short^*_{a,g}
```

Therefore:

```text
Delta > 0 -> account receives stablecoin credit
Delta = 0 -> no cash change
Delta < 0 -> account is debited
```

The whole group MUST settle atomically.

The protocol must not separately debit a short and later credit the long hedge that was used to justify reduced margin.

---

## 45. Why atomic group settlement is required

Suppose:

```text
cash balance          = 2 USDT
short expiry liability = 5 USDT
locked-long credit     = 3 USDT
```

Correct net settlement:

```text
Delta = 3 - 5 = -2 USDT
```

The account has exactly enough cash.

If Optara debited `5 USDT` before recognizing the `3 USDT` hedge, it would falsely report insolvency.

Therefore settlement must apply:

```text
cashBalance' = cashBalance + Delta
```

as one risk-group accounting operation, with conservative native-unit rounding.

---

## 46. Unsynchronized matured-group effective balance

A finalized but unsynchronized risk group already has a deterministic economic effect even if its raw account ledger has not yet been updated.

For settlement asset `A`, define:

```text
EffectiveBalance_{a,A}
    = RawCashBalance_{a,A}
      + Σ finalized-unsynced groups g settled in A of Delta_{a,g}
```

A withdrawal must never use `RawCashBalance` alone when finalized unsynchronized groups exist.

Core V2 therefore requires synchronization before withdrawal so that:

```text
RawCashBalance after sync = EffectiveBalance before sync
```

subject to deterministic rounding.

---

## 47. Long-holder redemption

For settled series `i` and redeem quantity `Q`:

```text
RedeemEconomicValue
    = phi_i^* * CS_i * Q
```

The external token transfer is:

```text
RedeemNative
    = toNativeDown(RedeemEconomicValue)
```

The redeemed option-token quantity MUST be burned.

A holder can never receive more than the contractual payout because of integer rounding.

---

## 48. Locked-long settlement

A locked long is a genuine long claim.

When its account risk group synchronizes:

1. compute its settlement value using the same `phi_i^*`;
2. include that value in `LockedLong^*_{a,g}`;
3. burn/consume the locked option quantity;
4. include the credit in the atomic `Delta_{a,g}`.

The same long quantity must not subsequently be redeemable externally.

---

# Part IX — Fixed-point and rounding mathematics

## 49. Full-precision multiplication and division

Implementations SHOULD use audited full-precision `mulDiv` operations rather than naïve multiplication followed by division.

Conceptually:

```text
mulDivDown(x,y,d) = floor(x*y/d)
```

```text
mulDivUp(x,y,d) = ceil(x*y/d)
```

where:

```text
ceil(n/d) = floor((n + d - 1)/d)
```

only when that addition cannot overflow; production Solidity should use an overflow-safe implementation.

---

## 50. Normalized total payoff

With all fields WAD-scaled:

```text
PayoffWad
    = phiWad * contractSizeWad * quantityWad / WAD^2
```

The mathematical expression is normative.

Recommended settlement computation:

```text
longPayoffWad
    = mulDivDown(
        mulDivDown(phiWad, contractSizeWad, WAD),
        quantityWad,
        WAD
      )
```

For risk calculations, the implementation MUST avoid any downward bias that can understate loss. It may use higher precision or conservative upward bounds.

---

## 51. Settlement-token native units

Let settlement token `A` have `d_A` decimals.

The general conversion from normalized WAD stablecoin value to native token units is:

```text
toNativeDown(xWad, d)
    = floor(xWad * 10^d / WAD)
```

```text
toNativeUp(xWad, d)
    = ceil(xWad * 10^d / WAD)
```

For common `d <= 18`:

```text
scale = 10^(18-d)

toNativeDown(xWad,d) = floor(xWad / scale)
toNativeUp(xWad,d)   = ceil(xWad / scale)
```

Approved settlement assets with unusual decimal counts require explicit adapter tests.

For MVP simplicity, settlement assets with `d <= 18` are strongly preferred.

---

## 52. Native collateral to normalized value

If a native balance must be represented in WAD:

```text
toWad(nativeAmount,d)
    = nativeAmount * WAD / 10^d
```

For `d <= 18`, this is exact multiplication:

```text
toWad(nativeAmount,d)
    = nativeAmount * 10^(18-d)
```

The canonical cash ledger SHOULD remain in native token units so internal balances reconcile exactly with ERC-20 custody.

The RiskEngine may calculate normalized WAD requirements and convert the final required margin upward to native units for comparison against the cash ledger.

---

## 53. Mandatory rounding directions

To preserve solvency:

```text
long external payout        -> round DOWN
positive internal long credit -> round DOWN
required margin             -> round UP
writer/net matured debit    -> round UP
withdrawable collateral     -> round DOWN implicitly through native units
```

This means rounding may create small protocol dust but must never create an uncovered obligation.

---

## 54. Group-net rounding at maturity

Matured positions in a risk group SHOULD be netted in normalized precision before converting to native settlement-token units.

Compute:

```text
DeltaWad = LockedLongWad - ShortWad
```

Then:

```text
if DeltaWad > 0:
    accountCreditNative = toNativeDown(DeltaWad)

if DeltaWad < 0:
    accountDebitNative = toNativeUp(-DeltaWad)
```

This is preferable to separately converting every leg to native units before netting because it minimizes rounding distortion while preserving solvency.

---

## 55. Rounding reserve

Because writer debits round up and external/positive credits round down, the protocol may accumulate small residual token amounts.

For each settlement asset `A`, define conceptually:

```text
RoundingReserve_A >= 0
```

The reserve is not user free collateral.

Any implementation that accumulates rounding dust MUST account for it explicitly and MUST NOT allow it to be withdrawn as though it belonged to a margin account while user claims remain outstanding.

---

# Part X — Conservation mathematics

## 56. Write conservation

Every successful write of quantity `Q` creates:

```text
+Q long option-token supply
+Q short obligation
```

Therefore cumulative issuance obeys:

```text
CumulativeLongMinted_i
    = CumulativeShortCreated_i
```

for every series `i`.

---

## 57. Pre-expiry close conservation

Closing quantity `Q` consumes the same-series long token and short obligation:

```text
-Q long token supply
-Q open short quantity
```

Before expiry, ignoring no other burn path:

```text
CurrentLongSupply_i
    = AggregateOpenShortQty_i
```

Locked longs remain part of current long supply because custody does not burn them.

---

## 58. Post-settlement cumulative quantity identities

After settlement, writer synchronization and long redemption may happen at different times.

Let:

```text
M_i = cumulative quantity minted by writes
C_i = cumulative quantity burned in pre-expiry closes
R_i = cumulative quantity burned by external long redemption
H_i = cumulative locked-long quantity burned/consumed during account settlement
L_i = current outstanding long-token supply
S_i = cumulative short quantity synchronized/cleared after expiry
O_i = current unsynchronized/open short quantity
```

Then long-token conservation requires:

```text
M_i = C_i + R_i + H_i + L_i
```

Short-side conservation requires:

```text
M_i = C_i + S_i + O_i
```

After every long and short is fully settled:

```text
L_i = 0
O_i = 0
```

and:

```text
M_i - C_i = R_i + H_i = S_i
```

subject only to valid protocol migration/emergency procedures explicitly outside normal settlement.

---

## 59. Settlement-value conservation before rounding

For one finalized series `i`, issuance conservation implies that the total short quantity equals the total surviving long quantity before post-expiry consumption.

Therefore, at the same finalized payoff per unit:

```text
TotalShortLiability_i
    = TotalLongClaim_i
```

before rounding and after excluding quantities already closed pre-expiry.

Across a risk group:

```text
Σ_accounts ShortLiability_{a,g}
    = TotalLongClaims_g
```

Partition long claims into:

```text
locked longs held by Optara
+
external/unlocked longs
```

Then:

```text
Σ_accounts ShortLiability_{a,g}
    = Σ_accounts LockedLongCredit_{a,g}
      + ExternalLongClaims_g
```

Therefore:

```text
Σ_accounts [ShortLiability_{a,g} - LockedLongCredit_{a,g}]
    = ExternalLongClaims_g
```

This identity explains why atomic writer-group settlement and locked-long consumption correctly fund the remaining external long holders.

---

## 60. Settlement-value conservation after rounding

With conservative rounding:

```text
aggregate writer/native debits
    >= aggregate internal locked-long credits
       + aggregate external long payouts
```

The non-negative difference is attributable to rounding reserve and any explicitly configured protocol fees.

Ordinary settlement MUST never require taking funds from unrelated settlement assets or unrelated healthy accounts.

---

# Part XI — Vault and per-asset solvency

## 61. Physical vault balance

For settlement asset `A`, let:

```text
VaultBalance_A
```

be the actual ERC-20 token balance held by the MarginVault and any formally included settlement custody contract.

All internal accounting for `A` must ultimately reconcile to this physical quantity.

No balance of another stablecoin is included.

---

## 62. Active-option encumbrance

Before expiry, an account's margin balance is not entirely withdrawable because part of it is encumbered by:

```text
RequiredMargin_{a,A}
```

Thus the account's immediately withdrawable claim is only:

```text
FreeCollateral_{a,A}
```

not the entire cash balance.

This prevents double-counting the same stablecoin as both writer collateral and freely withdrawable user cash.

---

## 63. Matured but unsynchronized encumbrance

After a risk group is finalized but before writer synchronization, its deterministic net debt remains encumbered.

For a group with:

```text
Delta_{a,g} < 0
```

the account must be treated as owing:

```text
-Delta_{a,g}
```

before any withdrawal is considered.

The protocol therefore synchronizes matured groups before withdrawal rather than trusting stale raw cash balances.

---

## 64. Global pooled-custody identity

For a settlement asset `A`, define:

```text
EffectiveCashClaims_A
    = Σ_accounts EffectiveBalance_{a,A}
```

for accounts after including deterministic finalized-but-unsynchronized group deltas, and define:

```text
OutstandingExternalSettledClaims_A
```

as the settlement-token amount still owed to settled long tokens that remain externally redeemable rather than locked for internal account credit.

Ignoring explicitly separated protocol fees, the pooled vault should satisfy the accounting identity:

```text
VaultBalance_A
    = EffectiveCashClaims_A
      + OutstandingExternalSettledClaims_A
      + RoundingReserve_A
      + ProtocolOwnedVaultBalance_A
```

For the fee-free MVP:

```text
ProtocolOwnedVaultBalance_A = 0
```

This identity explains why an external long holder may redeem before every writer has explicitly synchronized. The physical settlement tokens are already in the vault, while the corresponding matured writer debt has reduced the writer's **effective** claim even if the raw account ledger has not yet been updated.

After an external redemption of `R` units:

```text
VaultBalance_A' = VaultBalance_A - R
OutstandingExternalSettledClaims_A'
    = OutstandingExternalSettledClaims_A - R
```

so the identity remains unchanged.

After a writer synchronizes, raw account state moves toward the already-defined effective state; synchronization must not create a second economic debit for a claim already reflected in the pooled accounting.

This is primarily an invariant-testing identity. Production contracts need not iterate across all accounts to calculate it on-chain.

---

## 65. No cross-stablecoin reserve substitution

For any two settlement assets `A != B`:

```text
VaultBalance_A
```

does not increase the protocol's ability to settle claims denominated in `B`.

Core V2 contains no formula of the form:

```text
Value(A) * FX(A/B)
```

inside ordinary margin or settlement accounting.

Such a formula belongs only to a future multi-collateral system with explicit FX oracles, haircuts, depeg logic, and liquidation rules.

---

# Part XII — Worked examples

## 66. Example A — Carol writes one capped MON/USDT call

Assume:

```text
Pair          = MON/USDT
Type          = CALL
Strike K      = 12 USDT/MON
Cap C         = 5 USDT/MON
Contract size = 1 MON
Quantity      = 1 option
```

Carol has no locked hedge.

The call payoff is:

```text
phi(S) = min(max(S-12,0),5)
```

Critical prices:

```text
0, 12, 17
```

Liability:

```text
S <= 12   -> 0
S = 15    -> 3 USDT
S >= 17   -> 5 USDT
```

Therefore:

```text
WorstCaseLoss = 5 USDT
```

With zero safety buffer:

```text
RequiredMargin = 5 USDT
```

If Carol has `0 USDT` in Optara:

```text
AdditionalDepositNeeded = 5 USDT
```

If Carol sold the option on Kuru for `0.50 USDT`, that does not change the Optara requirement until the `0.50 USDT` is deposited into Optara.

After depositing that premium:

```text
Optara cash balance = 0.50 USDT
Required margin     = 5.00 USDT
Additional deposit  = 4.50 USDT
```

Even if MON later settles at `1000 USDT`, Carol's contractual option liability remains `5 USDT`.

---

## 67. Example B — Alice uses a long call to reduce margin

Assume one risk group:

```text
Pair   = MON/USDT
Expiry = same for both series
Oracle = same settlement domain
```

Alice has:

```text
SHORT 1 x call: K=10, C=5, CS=1
LONG  1 x call: K=12, C=3, CS=1, locked in Optara
```

Short payoff:

```text
short(S) = min(max(S-10,0),5)
```

Locked-long payoff:

```text
long(S) = min(max(S-12,0),3)
```

Critical prices:

```text
0
10
12
15
```

Evaluate net liability:

| `S` | Short | Locked long | Net liability |
|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 |
| 10 | 0 | 0 | 0 |
| 12 | 2 | 0 | 2 |
| 15 | 5 | 3 | 2 |

Above `15`, both payoffs are flat, so net liability remains `2`.

Therefore:

```text
WorstCaseLoss = 2 USDT
```

Alice needs `2 USDT` of margin rather than the `5 USDT` required by the short call alone.

This is exact portfolio netting.

If the long call leaves Optara custody, the hedge credit disappears and the requirement returns to `5 USDT`.

---

## 68. Example C — Capped MON/USDT put

Assume:

```text
Type          = PUT
Strike K      = 10 USDT/MON
Cap C         = 4 USDT/MON
Contract size = 1 MON
Quantity      = 1
```

Payoff:

```text
phi(S) = min(max(10-S,0),4)
```

Critical prices:

```text
0, 6, 10
```

Expected payoff:

```text
S = 15 -> 0
S = 10 -> 0
S = 9  -> 1
S = 7  -> 3
S <= 6 -> 4
```

An unhedged writer's worst-case loss is:

```text
4 USDT
```

not `10 USDT`, because the option itself was contractually created with a `4 USDT` payout cap.

---

## 69. Example D — Contract size and fractional quantity

Assume:

```text
Pair          = ETH/USDC
Call strike   = 4,000 USDC/ETH
Cap           = 500 USDC/ETH
Contract size = 0.1 ETH per option
Quantity      = 3 options
Settlement    = 4,800 USDC/ETH
```

Per-underlying payoff:

```text
min(4,800 - 4,000, 500)
= 500 USDC/ETH
```

Underlying exposure:

```text
0.1 * 3 = 0.3 ETH
```

Total payoff:

```text
500 * 0.3 = 150 USDC
```

If quantity were instead `0.25` option:

```text
Exposure = 0.1 * 0.25 = 0.025 ETH
Payoff   = 500 * 0.025 = 12.5 USDC
```

before native-token rounding.

---

## 70. Example E — Two risk groups using the same stablecoin

Account has:

```text
MON/USDT group worst-case margin = 5 USDT
ETH/USDT group worst-case margin = 8 USDT
```

Because underlying differs, the option payoffs do not net.

Required USDT margin is:

```text
5 + 8 = 13 USDT
```

If account USDT cash is `15 USDT`:

```text
FreeCollateral_USDT = 15 - 13 = 2 USDT
```

---

## 71. Example F — Different stablecoins never cross-margin

Account has:

```text
20 USDT cash
0 USDC cash

MON/USDT required margin = 5 USDT
ETH/USDC required margin = 4 USDC
```

Then:

```text
USDT domain: 20 >= 5 -> safe
USDC domain: 0  < 4 -> unsafe
```

The extra `15 USDT` does not satisfy the `4 USDC` requirement.

The account must deposit USDC or reduce/hedge the ETH/USDC obligation.

---

## 72. Example G — Atomic maturity settlement

Alice has:

```text
2 USDT cash
short liability at final price = 5 USDT
locked long credit             = 3 USDT
```

Then:

```text
Delta = 3 - 5 = -2 USDT
```

After group synchronization:

```text
cash' = 2 - 2 = 0 USDT
```

The account is solvent.

The incorrect sequence:

```text
debit 5 first
then credit 3
```

would falsely require Alice to hold `5 USDT` even though the portfolio was correctly margined at `2 USDT`.

---

# Part XIII — Mathematical invariants

## 73. Payout bound

For every series `i`, quantity `Q >= 0`, and settlement price `S >= 0`:

```text
0 <= Payoff_i(S,Q)
   <= C_i * CS_i * Q
```

---

## 74. Non-negative required margin

```text
W_{a,g} >= 0
M_{a,g} >= 0
RequiredMargin_{a,A} >= 0
```

---

## 75. Margin monotonicity for added naked shorts

Adding a short position without adding collateral or a hedge MUST NOT reduce the exact contractual loss merely because of arithmetic sign mistakes.

More precisely, a newly added short may economically offset another short in rare mixed call/put shapes only if the actual payoff algebra proves it; the implementation must not assume monotonicity by position label.

Therefore the canonical invariant is:

```text
RequiredMarginPost = recompute(full portfolio)
```

not an unsafe local heuristic such as:

```text
RequiredMargin += maxPayout(newShort)
```

unless used only as a conservative upper bound.

---

## 76. Hedge custody invariant

Every long quantity included in:

```text
LockedLongCredit_{a,g}(S)
```

must be held under Optara control and unavailable for simultaneous external use.

---

## 77. No hedge double counting

For every long token unit, at a given instant it may contribute to at most one of:

```text
external transferable balance
short close
locked margin hedge
settlement redemption / internal settlement credit
```

It may not create two claims or two margin offsets simultaneously.

---

## 78. Post-action safety

After every risk-increasing or collateral-decreasing operation:

```text
B_{a,A} >= RequiredMargin_{a,A}
```

for every affected settlement asset `A`.

---

## 79. No cross-stablecoin substitution

For `A != B`:

```text
B_{a,A}
```

must not appear on the left-hand side of the safety condition for `RequiredMargin_{a,B}`.

---

## 80. Single settlement price

For finalized risk group `g`:

```text
S_g^* = constant
```

for all subsequent calculations.

---

## 81. Atomic settlement invariant

For matured group `g`:

```text
cashDelta_{a,g}
    = total locked-long credit
      - total short liability
```

must be applied as one group-level economic result.

---

## 82. Redemption bound

For every redemption quantity `Q`:

```text
RedeemNative
    <= contractual economic payoff converted to native units
```

because long payout rounds down.

---

## 83. Writer debit bound

For every matured net liability:

```text
WriterDebitNative
    >= contractual net liability converted to native units
```

because writer debit rounds up.

---

## 84. Splitting redemption cannot increase payout

Because each redemption rounds down:

```text
floor(x) + floor(y) <= floor(x + y)
```

Therefore splitting one claim into multiple redemption transactions cannot extract more settlement stablecoin than redeeming the combined quantity.

It may create additional dust, so frontends SHOULD encourage economically sensible redemption sizes.

---

## 85. Stablecoin-depeg interpretation

If a settlement stablecoin deviates from one U.S. dollar, Optara's token-denominated obligations do not change retroactively.

For a USDT-settled series:

```text
1 settlement unit = 1 USDT token unit
```

not one abstract U.S. dollar.

The underlying settlement price must still be expressed in USDT units through the configured direct or derived oracle path.

---

# Part XIV — What core V2 deliberately does not calculate

## 86. No volatility-based margin

Core V2 does not require:

```text
implied volatility
historical volatility
VaR
Expected Shortfall
FHS
SPAN
Monte Carlo price scenarios
```

for solvency.

These may be useful for market pricing or future leveraged-margin systems but are not part of the core margin requirement.

---

## 87. No price-driven maintenance margin

Core V2 does not define:

```text
initial margin < worst-case loss
maintenance margin
mark-to-market liquidation threshold
liquidation penalty
insurance-fund loss waterfall
```

because the core account must already cover exact worst-case contractual expiry loss.

A future undercollateralized leverage mode requires a separate mathematical specification and MUST NOT be created by simply lowering the core V2 margin requirement.

---

## 88. No cross-stablecoin FX margining

Core V2 does not calculate collateral value using:

```text
USDT/USD
USDC/USD
USDe/USD
haircuts
FX conversion between collateral types
```

for ordinary margin coverage.

These prices may be used only to derive the underlying's exact pair settlement price when the oracle configuration requires it.

Multi-collateral cross-margining is a separate future design.

---

# Part XV — Reference pseudocode

## 89. Payoff function

```text
function payoffPerUnderlying(series, S):
    if series.type == CALL:
        return min(max(S - K, 0), C)

    if series.type == PUT:
        return min(max(K - S, 0), C)
```

---

## 90. Total economic payoff

```text
function totalPayoff(series, S, quantity):
    p = payoffPerUnderlying(series, S)
    return p * series.contractSize * quantity
```

Production code must apply fixed-point scaling and explicit rounding.

---

## 91. Critical-point builder

```text
function criticalPoints(group):
    points = {0}

    for series in group.activeSeries:
        if series.type == CALL:
            points.add(series.strike)
            points.add(series.strike + series.maxPayout)
        else:
            points.add(series.strike - series.maxPayout)
            points.add(series.strike)

    return uniqueSorted(points)
```

---

## 92. Worst-case group loss

```text
function worstCaseLoss(account, group):
    worst = 0

    for S in criticalPoints(group):
        shorts = 0
        longs  = 0

        for series in account.shortSeries(group):
            shorts += totalPayoff(series, S, shortQty[series])

        for series in account.lockedLongSeries(group):
            longs += totalPayoff(series, S, lockedLongQty[series])

        loss = max(shorts - longs, 0)
        worst = max(worst, loss)

    return conservativeUpperBound(worst)
```

`conservativeUpperBound` includes any proven fixed-point rounding guard required by the implementation.

---

## 93. Required margin by asset

```text
function requiredMargin(account, settlementAsset):
    total = 0

    for group in account.activeGroups(settlementAsset):
        W = worstCaseLoss(account, group)
        buffer = safetyBuffer(group, W)
        total += toNativeUp(W + buffer + roundingGuard(group))

    return total
```

---

## 94. Write validation

```text
simulate shortQty[series] += quantity

required = requiredMargin(account, series.settlementAsset)

require(
    cashBalance[account][series.settlementAsset] >= required
)
```

Only after this condition passes may the protocol record the short and mint the matching long token.

---

## 95. Unlock validation

```text
simulate lockedLongQty[series] -= quantity

required = requiredMargin(account, series.settlementAsset)

require(
    cashBalance[account][series.settlementAsset] >= required
)
```

Only then may Optara release the long token.

---

## 96. Withdrawal validation

```text
sync all relevant finalized risk groups first

postBalance = cashBalance[account][asset] - withdrawAmount
required    = requiredMargin(account, asset)

require(postBalance >= required)
```

---

## 97. Matured risk-group synchronization

```text
function syncRiskGroup(account, group):
    require(group.finalized)

    shortWad = 0
    longWad  = 0

    for each short series i in group:
        shortWad += settlementPayoff(i, shortQty[i])

    for each locked long series j in group:
        longWad += settlementPayoff(j, lockedLongQty[j])

    if shortWad >= longWad:
        debitNative = toNativeUp(shortWad - longWad)
        require(cashBalance[account][asset] >= debitNative)
        cashBalance[account][asset] -= debitNative
    else:
        creditNative = toNativeDown(longWad - shortWad)
        cashBalance[account][asset] += creditNative

    burn all consumed locked-long quantities
    clear all group short and locked-long quantities
```

The production implementation must also update aggregate quantities, indexes, settlement accounting, and rounding reserve.

---

# Part XVI — Required numerical tests

## 98. Payoff tests

For every call/put implementation, test:

```text
below strike
at strike
between strike and cap boundary
at cap boundary
far beyond cap boundary
S = 0
very large S for calls
fractional contract size
fractional quantity
```

---

## 99. Margin tests

Test at least:

```text
unhedged capped call
unhedged capped put
call spread
put spread
mixed call/put portfolio
long that does not reduce worst-case loss
partial hedge quantity
multiple strikes
multiple caps
multiple contract sizes
same stablecoin but different risk groups
different settlement stablecoins
```

For small fuzzed portfolios, compare the on-chain RiskEngine result against an independent high-precision reference implementation of the same breakpoint algorithm.

The on-chain result MUST never be below the reference requirement after native-unit conversion.

---

## 100. Rounding tests

Test settlement assets with different supported decimals, including at minimum representative 6-decimal and 18-decimal assets.

Test values immediately around:

```text
one native token unit
one WAD conversion boundary
strike boundary
cap boundary
fractional option quantity boundary
```

Required assertions:

```text
margin never rounds down
long payout never rounds up
writer net debit never rounds down
no arithmetic overflow
no negative value represented by unsigned underflow
```

---

## 101. Conservation tests

Invariant/fuzz tests MUST verify:

```text
cumulative long mint == cumulative short creation

pre-expiry current long supply == aggregate open short quantity

minted quantity
== closed + redeemed + locked-consumed + current long supply

minted quantity
== closed + synchronized shorts + current unsynchronized shorts
```

The tests must separately account for post-expiry asynchronous redemption and writer synchronization.

---

## 102. Settlement tests

Test:

```text
atomic group debit/credit
locked long consumed exactly once
external long redeemed exactly once
writer cannot withdraw around matured debt
same finalized group price used by all series
split redemption cannot increase payout
settlement in USDT does not spend USDC
settlement in USDC does not spend USDT
```

---

# Part XVII — Compact formula reference

## 103. Call

```text
phi_call(S) = min(max(S-K,0), C)
```

## 104. Put

```text
phi_put(S) = min(max(K-S,0), C)
```

## 105. Total payoff

```text
Payoff_i(S,Q) = phi_i(S) * CS_i * Q
```

## 106. Maximum liability

```text
MaxLiability_i(Q) = C_i * CS_i * Q
```

## 107. Group short liability

```text
Short_g(S) = Σ short Payoff_i(S,q_i^-)
```

## 108. Group locked-long credit

```text
Long_g(S) = Σ locked-long Payoff_j(S,q_j^+)
```

## 109. Group loss

```text
Loss_g(S) = max(Short_g(S) - Long_g(S), 0)
```

## 110. Worst-case loss

```text
W_g = max_{S>=0} Loss_g(S)
```

## 111. Group margin

```text
M_g = W_g + SafetyBuffer_g + RoundingGuard_g
```

## 112. Margin by settlement asset

```text
RequiredMargin_A = Σ groups settled in A of M_g
```

## 113. Free collateral

```text
FreeCollateral_A = CashBalance_A - RequiredMargin_A
```

## 114. Additional deposit

```text
AdditionalDeposit_A
    = max(RequiredMargin_A - CashBalance_A, 0)
```

## 115. Matured group cash delta

```text
Delta_g = LockedLongSettlement_g - ShortSettlement_g
```

## 116. Derived pair price

```text
Underlying/Stablecoin
    = (Underlying/USD) / (Stablecoin/USD)
```

when that exact derived path is preapproved by the oracle configuration.

---

## 117. Final engineering rule

An engineer or AI agent implementing Optara V2 must preserve the following hierarchy:

```text
1. use the exact capped payoff contract;
2. group only mathematically compatible positions;
3. calculate the entire group's worst-case net loss;
4. round required collateral conservatively upward;
5. satisfy that requirement only with the exact settlement stablecoin;
6. count a long hedge only while Optara controls it;
7. settle a matured netted group atomically;
8. round buyer/positive credits downward and writer debits upward;
9. never rely on current market price or liquidation to cover a loss larger than posted core margin;
10. never treat one stablecoin as another stablecoin without a separately specified future collateral model.
```

The defining mathematical property of Optara V2 is therefore:

> **Every supported short portfolio has a finite, exactly computable contractual worst-case loss, and Optara requires that loss to be covered in the same stablecoin in which the option promises settlement.**
