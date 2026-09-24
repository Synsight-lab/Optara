# Optara V2 Margin and Risk Specification

**Document type:** Normative margin and risk specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document defines the margin model, risk model, collateral rules, portfolio-netting rules, solvency conditions, and risk controls for Optara V2.

It answers:

- what asset backs a writer's obligation;
- how much margin an account must maintain;
- which long positions may reduce margin;
- which positions may and may not be netted;
- how the RiskEngine computes exact worst-case loss;
- how premiums interact with collateral;
- when collateral becomes withdrawable;
- how expiry changes risk accounting;
- why core V2 does not depend on price-driven liquidation;
- how stablecoin, oracle, custody, rounding, integration, and operational risk are constrained;
- which leveraged-margin features are explicitly outside core V2.

Read this together with:

- `MATH.md` — authoritative numerical formulas and rounding;
- `INVARIANTS.md` — system properties that must always hold;
- `PROTOCOL_SPEC.md` — runtime state transitions;
- `OPTION_SPEC.md` — option-series semantics;
- `ARCHITECTURE.md` — component boundaries;
- `PRD.md` — product requirements.

If there is a conflict:

1. `MATH.md` controls numerical formulas and rounding;
2. `INVARIANTS.md` controls required safety properties;
3. `PROTOCOL_SPEC.md` controls state-transition ordering;
4. this file controls margin/risk policy.

---

# 2. Core risk model

Optara V2 is a **bounded-risk, exact-loss-margined** options protocol.

Core V2 does not use:

```text
FHS
SPAN
Monte Carlo VaR
volatility-based maintenance margin
mark-to-market liquidation margin
undercollateralized naked option selling
cross-stablecoin collateral conversion
```

Instead:

```text
Capped option payoff
        +
Exact worst-case portfolio loss
        +
Pair-specific stablecoin collateral
        +
Locked long-option hedge recognition
        =
Solvency-first deterministic margin
```

The central account safety condition is:

```text
CashBalance(account, settlementAsset)
    >= RequiredMargin(account, settlementAsset)
```

after every risk-increasing or collateral-decreasing operation.

---

# 3. Pair-specific settlement-stablecoin model

Optara is not USDC-based.

Every option series belongs to an approved pair:

```text
UNDERLYING / APPROVED_STABLECOIN
```

The right-hand stablecoin is the series:

```text
quote asset
strike denomination
max-payout denomination
canonical premium quote asset
writer cash-collateral asset
cash-settlement asset
```

Examples:

```text
MON / USDT
-> strike in USDT
-> cap in USDT
-> margin in USDT
-> settlement in USDT

ETH / USDC
-> strike in USDC
-> cap in USDC
-> margin in USDC
-> settlement in USDC

BTC / USDe
-> strike in USDe
-> cap in USDe
-> margin in USDe
-> settlement in USDe
```

Core V2 MUST NOT silently route every pair through one universal stablecoin.

---

# 4. Why collateral matches the settlement stablecoin

If an option settles in asset `A`, the cleanest core collateral is also `A`.

Example:

```text
MON/USDT liability -> USDT
writer collateral  -> USDT
buyer settlement   -> USDT
```

This removes ordinary collateral-conversion risk from the solvency equation.

Optara does not need to sell MON, ETH, USDC, or another token at expiry merely to obtain the settlement asset.

This avoids introducing:

```text
DEX slippage
conversion execution risk
volatile-collateral haircuts
collateral FX assumptions
cross-asset oracle dependencies
forced liquidation of collateral
```

Multi-collateral margin is a future feature, not core V2.

---

# 5. Stablecoin isolation

Each approved settlement stablecoin is a separate accounting domain.

For account `a`:

```text
cashBalance[a][USDT]
cashBalance[a][USDC]
cashBalance[a][USDe]
```

are independent balances.

For different stablecoins `A != B`:

```text
surplus(A) MUST NOT cover deficit(B)
```

Core V2 has no ordinary margin formula such as:

```text
USDC * FX(USDC/USDT) -> USDT margin
```

and no assumption:

```text
1 USDT = 1 USDC = 1 USDe
```

A `MON/USDT` obligation remains a USDT obligation even if USDT depegs.

That provides same-asset contractual solvency, while users still bear the economic quality risk of the stablecoin they chose.

---

# 6. Terminology

## 6.1 Margin account

An account contains:

```text
cash balances by settlement stablecoin
short option obligations
locked long-option hedges
active risk-group indexes
matured but unsynchronized group state
```

## 6.2 Required margin

The amount of a specific settlement stablecoin that must remain encumbered to cover the account's active bounded option risk.

## 6.3 Free collateral

Cash not needed to secure active or matured obligations.

## 6.4 Locked long

A long option token placed under Optara control and unavailable for transfer, sale, close elsewhere, or redemption while recognized as a hedge.

## 6.5 Risk group

The domain within which exact payoff netting is permitted:

```text
riskGroup = (
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

## 6.6 Exact worst-case loss

The greatest positive contractual net liability that can occur across all valid non-negative settlement prices.

## 6.7 Safety buffer

Optional deterministic margin added above exact worst-case loss.

## 6.8 Exact rounding

Margin is computed from exact integer payoff numerators and rounded up once
(`MATH.md` section 24). Core V2 therefore has no rounding-guard term.

---

# Part I — Single-position risk

## 7. Capped call risk

For settlement price `S`, strike `K`, and payout cap `C`:

```text
CallPayoffPerUnderlying(S)
    = min(max(S - K, 0), C)
```

For contract size `CS` and quantity `Q`:

```text
CallPayoff(S,Q)
    = CallPayoffPerUnderlying(S) * CS * Q
```

Therefore:

```text
0 <= CallPayoff(S,Q)
   <= C * CS * Q
```

The maximum contractual liability of an unhedged capped-call writer is:

```text
MaxCallLiability = C * CS * Q
```

Even if the underlying goes far above `K + C`, liability does not increase.

---

## 8. Capped put risk

For a put:

```text
PutPayoffPerUnderlying(S)
    = min(max(K - S, 0), C)
```

and:

```text
PutPayoff(S,Q)
    = PutPayoffPerUnderlying(S) * CS * Q
```

Therefore:

```text
0 <= PutPayoff(S,Q)
   <= C * CS * Q
```

Core V2 uses:

```text
0 < C <= K
```

for puts.

The maximum contractual liability of an unhedged capped-put writer is:

```text
MaxPutLiability = C * CS * Q
```

---

## 9. Why the cap matters

Without a capped call:

```text
S -> infinity
```

can cause contractual liability to continue increasing.

With the cap:

```text
Payoff <= C * CS * Q
```

so the protocol knows the maximum possible obligation when the position is created.

That lets Optara remain solvent without forecasting prices or racing a liquidation engine against sudden moves.

The cap is an immutable contract term, not a post-loss haircut imposed on the buyer.

---

## 10. Long-option risk

A normal long holder has no additional margin requirement simply from owning the option.

Their protocol payoff is bounded:

```text
0 <= LongPayoff <= C * CS * Q
```

Their economic acquisition loss is the premium they paid externally.

A long affects writer margin only when it is:

```text
compatible
+
deposited/escrowed
+
locked
+
controlled by Optara
```

---

# Part II — Recognized collateral and hedge value

## 11. Recognized cash collateral

For settlement asset `A`:

```text
CashCollateral(a,A)
    = cashBalance[a][A]
```

after required matured-group synchronization.

The internal balance must correspond to actual `A` held by approved Optara custody.

---

## 12. Assets that do not count as cash margin

Core V2 MUST NOT count:

```text
stablecoin in user wallet
stablecoin in Kuru
expected premium
unsettled trade proceeds
LP tokens
underlying tokens
another stablecoin
off-chain receivables
external lending balances
bridge receivables
```

as cash margin.

An asset having market value is insufficient.

Optara must control the exact settlement stablecoin.

---

## 13. Recognized locked-long hedge

A long may reduce margin only if:

1. it belongs to the same permitted risk group;
2. Optara controls the token;
3. the quantity is marked locked;
4. it cannot be transferred, sold, closed elsewhere, or redeemed while counted;
5. its exact payoff reduces portfolio worst-case loss.

The protocol does **not** assign a generic market-value haircut to the option.

Incorrect:

```text
hedgeCredit = Kuru market price of long
```

Correct:

```text
hedgeCredit depends on LongPayoff(S)
at each same settlement scenario S
```

---

## 14. External positions are not recognized hedges

These do not reduce core margin:

```text
wallet-held Optara long
Kuru-held Optara long
long in another DeFi protocol
off-chain option
CEX option
spot underlying held externally
```

because Optara cannot guarantee control of those assets at settlement.

---

# Part III — Risk-group model

## 15. Risk-group identity

Core V2 nets positions only when they have:

```text
same underlying
same expiry
same settlement stablecoin
same oracle/settlement domain
```

Thus:

```text
riskGroup = (
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

Strike, cap, option type, and contract size may differ inside the group.

---

## 16. Why expiry must match

A January long does not fully secure a February short.

After January expires, the underlying can move before February expiry.

Therefore:

```text
different expiry
-> different risk group
-> no core-V2 option-payoff offset
```

Cross-expiry margin would require a time/path-dependent model outside this design.

---

## 17. Why underlying must match

A MON option does not deterministically hedge an ETH option.

Even if both settle in USDT:

```text
MON payoff != ETH payoff
```

Their option payoffs do not net.

Their separate USDT margin requirements may still be backed by the same account USDT balance after summation.

---

## 18. Why settlement stablecoin must match

A USDT claim does not deterministically satisfy a USDC liability.

Therefore:

```text
MON/USDT
and
MON/USDC
```

belong to different risk and cash domains.

---

## 19. Why oracle domain must match

Two otherwise similar positions may use different:

```text
settlement timestamps
observation windows
oracle providers
fallback rules
price definitions
```

If those differ, the final prices can differ.

Therefore they cannot be treated as one deterministic payoff system.

---

# Part IV — Exact portfolio risk

## 20. Short liability

For account `a`, risk group `g`, and hypothetical final price `S`:

```text
ShortLiability(a,g,S)
    = Σ_i Payoff_i(S, shortQty[a][i])
```

---

## 21. Locked-long credit

For the same account and group:

```text
LockedLongCredit(a,g,S)
    = Σ_j Payoff_j(S, lockedLongQty[a][j])
```

Only Optara-controlled compatible longs are included.

---

## 22. Net contractual liability

Define:

```text
NetLiability(a,g,S)
    = ShortLiability(a,g,S)
      - LockedLongCredit(a,g,S)
```

Margin covers only positive net liability:

```text
Loss(a,g,S)
    = max(NetLiability(a,g,S), 0)
```

A negative value means the account would receive more from locked longs than it owes at that price.

Optara does not give the account pre-expiry cash credit for that hypothetical positive settlement outcome.

---

## 23. Exact worst-case loss

The core risk quantity is:

```text
WorstCaseLoss(a,g)
    = max over S >= 0 of Loss(a,g,S)
```

No probability distribution is needed.

No volatility estimate is needed.

No FHS is needed.

No SPAN scenario grid is needed.

The question is simply:

> What is the maximum contractual amount this group can owe at any valid expiry price?

---

# Part V — Exact critical-price evaluation

## 24. Why finite evaluation is exact

Each capped option payoff is continuous and piecewise linear.

Between adjacent breakpoints:

```text
Payoff_i(S) = a_i*S + b_i
```

Therefore the complete portfolio net liability is also linear inside each interval.

A linear function reaches its maximum on a closed interval at an endpoint.

So Optara only needs to evaluate the payoff breakpoints.

---

## 25. Critical prices

For every call:

```text
K
K + C
```

For every put:

```text
K - C
K
```

and always:

```text
S = 0
```

Therefore:

```text
Critical(a,g)
    = {0}
      U {K, K+C for calls the account holds in g}
      U {K-C, K for puts the account holds in g}
```

Only the account's own shorts and locked longs in the group contribute points,
which keeps evaluation bounded by per-account position limits. Duplicate values
may be removed.

---

## 26. Exact algorithm

Conceptually:

```text
worst = 0
points = criticalPrices(group)

for S in unique(points):
    shortLiability = 0
    lockedLongCredit = 0

    for each short:
        shortLiability += payoff(shortSeries, S, qty)

    for each locked long:
        lockedLongCredit += payoff(longSeries, S, qty)

    loss = max(shortLiability - lockedLongCredit, 0)
    worst = max(worst, loss)

return worst
```

This result is the exact bounded-payoff portfolio risk.

---

## 27. Computational bounds

For `n` active series in a risk group:

```text
critical points <= 2n + 1
```

A simple nested evaluator is approximately:

```text
O(n^2)
```

Therefore the protocol MUST bound:

```text
MAX_SERIES_PER_RISK_GROUP_PER_ACCOUNT
MAX_ACTIVE_RISK_GROUPS_PER_ACCOUNT
MAX_ACTIVE_SERIES_PER_ACCOUNT
```

A later optimized algorithm is allowed only if it gives exactly the same economic result.

---

# Part VI — Margin requirement

## 28. Group margin

Let:

```text
W_g = WorstCaseLoss(a,g)
```

Then:

```text
GroupRequiredMarginNative(a,g)
    = ceilDiv(WorstLossNumerator(a,g), D_A)
      + SafetyBufferNative_g
```

The exact worst-case numerator is rounded upward once (`MATH.md` sections 24 and 26).

---

## 29. Safety buffer

The safety buffer is optional deterministic conservatism. Its parameters
(`bufferBps_g`, `fixedBufferNative_g`) are snapshotted when the group is created;
governance changes affect only groups created afterward.

The policy, in native units:

```text
if BaseMarginNative == 0:
    SafetyBufferNative_g = 0
else:
    SafetyBufferNative_g
        = ceilDiv(BaseMarginNative * bufferBps_g, 10_000)
          + fixedBufferNative_g
```

The MVP sets both parameters to zero, which is safe because the base margin is exact.

A buffer never substitutes for correct risk math.

---

## 30. Exact arithmetic

Core V2 MUST use exact payoff numerators under `MATH.md` section 24. No intermediate
leg rounding is permitted, so there is no rounding-guard term. Margin performs one
upward native conversion and bounds actual integer settlement debits. A future approximation
requires a new reviewed specification and a proof covering interior rounding steps,
settlement debits and cross-account conservation, not only breakpoint values.

---

## 31. Required margin by stablecoin

Let `G(a,A)` be all active or expired-unfinalized groups for account `a` settled in asset `A`.

Then:

```text
RequiredMargin(a,A)
    = Σ_{g in G(a,A)} GroupRequiredMargin(a,g)
```

Different groups do not net.

But the same stablecoin balance can secure the sum of independent groups.

Example:

```text
MON/USDT margin = 5 USDT
ETH/USDT margin = 8 USDT

RequiredMargin(account, USDT)
    = 13 USDT
```

---

## 32. Account safety

For each settlement asset:

```text
CashBalance(a,A)
    >= RequiredMargin(a,A)
```

must hold after:

```text
new short write
hedge unlock
cash withdrawal
any other risk-increasing/collateral-reducing action
```

If it fails, the operation reverts.

---

## 33. Free collateral

After relevant finalized groups are synchronized (unfinalized groups remain reserved):

```text
FreeCollateral(a,A)
    = CashBalance(a,A)
      - RequiredMargin(a,A)
```

For a valid account:

```text
FreeCollateral >= 0
```

Maximum ordinary withdrawal:

```text
MaxWithdrawable(a,A)
    = FreeCollateral(a,A)
```

subject to native-unit rounding and operational pause state.

---

## 34. Additional collateral needed

For a proposed operation:

```text
AdditionalCollateralNeeded(a,A)
    = max(
        RequiredMarginPostAction(a,A)
        - CashBalance(a,A),
        0
      )
```

This is the value the frontend should display before a writer creates additional risk.

---

## 35. Coverage ratio

For monitoring:

```text
CoverageRatio(a,A)
    = CashBalance(a,A)
      / RequiredMargin(a,A)
```

when requirement is positive.

Interpretation:

```text
CoverageRatio >= 1
-> valid core V2 account

CoverageRatio < 1
-> invariant failure / emergency condition
```

It is not an ordinary maintenance-margin liquidation threshold.

---

# Part VII — Capital efficiency

## 36. Naïve per-leg margin

A naïve system may require:

```text
NaiveMargin
    = Σ MaxLiability(each short)
```

This ignores offsetting contractual protection.

---

## 37. Optara portfolio margin

Optara instead computes:

```text
PortfolioMargin
    = max_S(
        TotalShortPayoff(S)
        - TotalCompatibleLockedLongPayoff(S)
      )
```

with zero floor plus buffers.

Therefore valid locked hedges can make:

```text
PortfolioMargin < NaiveMargin
```

---

## 38. Capital efficiency is not leverage

This distinction must remain explicit.

### Capital efficiency

```text
short liability
+
provable locked hedge
->
lower exact worst-case net loss
->
lower required cash margin
```

### Undercollateralized leverage

```text
posted resources
<
exact worst-case net liability
```

Core V2 supports the first.

Core V2 does not support the second.

---

## 39. Example — unhedged capped call

Carol writes:

```text
Pair          = MON/USDT
Type          = CALL
Strike        = 12
Cap           = 5
Contract size = 1 MON
Quantity      = 1
```

Payoff:

```text
min(max(S - 12, 0), 5)
```

Worst-case loss:

```text
5 USDT
```

Ignoring buffer and rounding:

```text
RequiredMargin = 5 USDT
```

Carol does not need 1 MON.

She needs enough USDT to cover the capped contractual liability.

---

## 40. Example — call hedge

Alice holds:

```text
SHORT 1 x MON/USDT call
K=10
C=5

LOCKED LONG 1 x MON/USDT call
K=12
C=3

same expiry
same oracle domain
CS=1
```

Critical prices:

```text
0
10
12
15
```

Net liability:

```text
S=0:  short=0, long=0, net=0
S=10: short=0, long=0, net=0
S=12: short=2, long=0, net=2
S=15: short=5, long=3, net=2
```

Therefore:

```text
WorstCaseLoss = 2 USDT
```

instead of the unhedged short's `5 USDT`.

That is valid capital efficiency because the long contractually removes `3 USDT` of possible net loss.

---

## 41. Same stablecoin, different underlying

Suppose:

```text
MON/USDT group = 5 USDT
ETH/USDT group = 8 USDT
```

No payoff netting occurs.

Required account USDT margin:

```text
5 + 8 = 13 USDT
```

The same cash balance can back both because both obligations are USDT-denominated.

---

## 42. Same underlying, different stablecoin

Suppose:

```text
MON/USDT required = 5 USDT
MON/USDC required = 4 USDC
```

The account separately needs:

```text
USDT >= 5
USDC >= 4
```

`9 USDT` cannot substitute for the missing USDC.

---

# Part VIII — Premium treatment

## 43. Premium does not reduce contractual margin

Premium is a market price.

The liability is still:

```text
Payoff(S)
```

Therefore:

```text
RequiredMargin
!=
WorstCaseLoss - ExpectedPremium
```

---

## 44. Premium counts only after actual Optara deposit

Suppose:

```text
RequiredMargin = 5 USDT
Optara cash = 0
```

Carol sells the option on Kuru for:

```text
0.50 USDT
```

While that USDT remains on Kuru:

```text
Optara cash = 0
AdditionalDepositNeeded = 5
```

After Carol deposits it into Optara:

```text
Optara cash = 0.50
RequiredMargin = 5
AdditionalDepositNeeded = 4.50
```

The requirement did not fall.

The account cash increased.

---

## 45. Atomic premium routing

If a future adapter routes premium directly into Optara during issuance, safe ordering is:

```text
1. receive exact settlement stablecoin
2. credit Optara cash balance
3. simulate post-write portfolio
4. run margin check
5. create short
6. mint long
```

An external receivable must never be counted before receipt.

---

# Part IX — Margin lifecycle

## 46. Deposit

After valid deposit `X` of asset `A`:

```text
CashBalance(a,A)'
    = CashBalance(a,A) + X
```

Deposit is risk-reducing.

---

## 47. Write

For new short quantity `dQ`:

```text
ShortQty_i'
    = ShortQty_i + dQ
```

The complete post-write portfolio is evaluated.

Writing succeeds only if:

```text
CashBalance(a,A)
    >= RequiredMarginPostWrite(a,A)
```

The system must not rely on a premium that may be received later.

---

## 48. Lock long

After locking quantity `dQ`:

```text
LockedLongQty_i'
    = LockedLongQty_i + dQ
```

The engine recomputes exact worst-case loss.

Margin saving:

```text
MarginSaving
    = max(
        RequiredMarginBefore
        - RequiredMarginAfter,
        0
      )
```

A locked long is not assumed helpful automatically.

If it does not reduce the worst-case outcome:

```text
MarginSaving = 0
```

---

## 49. Unlock long

Before releasing a locked long:

```text
LockedLongQty_i'
    = LockedLongQty_i - dQ
```

Optara computes post-unlock margin.

Release is allowed only if:

```text
CashBalance(a,A)
    >= RequiredMarginPostUnlock(a,A)
```

The hedge must not leave custody before the check.

---

## 50. Close short

A short may be closed only by consuming the same series long token.

For quantity `dQ`:

```text
ShortQty_i'
    = ShortQty_i - dQ
```

and matching long quantity is burned. The long comes from an explicit source:
an external transfer by the caller, or (`LOCKED`) the caller's own locked hedge in
the identical series. A `LOCKED` close removes identical short and long legs together,
so it never increases risk; a locked hedge is never consumed implicitly.

The RiskEngine then recalculates the account.

Any margin reduction becomes free collateral.

---

## 51. Withdraw

Before withdrawing `X` units of settlement asset `A`:

1. synchronize all relevant finalized groups;
2. compute current required margin;
3. simulate:

```text
CashBalance(a,A)'
    = CashBalance(a,A) - X
```

4. require:

```text
CashBalance(a,A)'
    >= RequiredMargin(a,A)
```

Equivalent:

```text
X <= FreeCollateral(a,A)
```

---

# Part X — Expiry and settlement risk

## 52. Risk before expiry

Before expiry, final price is unknown.

The group is protected by:

```text
WorstCaseLoss across all valid S
```

not by the current spot price.

---

## 53. Risk after finalization

After valid settlement price `S*` is finalized:

```text
Short*
    = TotalShortPayoff(S*)

LockedLong*
    = TotalLockedLongPayoff(S*)

Delta
    = LockedLong* - Short*
```

Risk uncertainty disappears.

The group now has a deterministic cash effect.

---

## 54. Atomic matured-group settlement

The entire account risk group must settle atomically.

Correct:

```text
CashBalance'
    = CashBalance
      + LockedLongCredit
      - ShortLiability
```

Incorrect:

```text
debit short first
then credit locked hedge later
```

The incorrect sequence may temporarily or permanently report false insolvency.

---

## 55. Effective balance before synchronization

A finalized but unsynchronized group already has an economic cash effect.

For asset `A`:

```text
EffectiveBalance(a,A)
    = RawCashBalance(a,A)
      + Σ finalized-unsynchronized Delta_g
```

Withdrawal must not rely on stale raw balance.

Therefore relevant finalized groups are synchronized before withdrawal and other safety-sensitive actions.

---

## 56. Core solvency theorem

For every group:

```text
ActualLossAtExpiry(g)
    <= WorstCaseLoss(g)
```

and:

```text
WorstCaseLoss(g)
    <= GroupRequiredMargin(g)
```

Across all groups using stablecoin `A`:

```text
ActualNetLiability(a,A)
    <= RequiredMargin(a,A)
```

Account safety requires:

```text
RequiredMargin(a,A)
    <= CashBalance(a,A)
```

Therefore:

```text
ActualNetLiability(a,A)
    <= CashBalance(a,A)
```

subject to correct:

```text
custody
token behavior
oracle finalization
payoff implementation
rounding
state accounting
```

This is the mathematical basis of core-V2 solvency.

---

# Part XI — Liquidation policy

## 57. Core V2 does not depend on price-driven liquidation

Core V2 does not intentionally allow:

```text
CashBalance
<
ExactWorstCaseLoss
```

Therefore a sudden market move cannot create a larger contractual liability than the amount already modeled.

Core V2 does not need ordinary solvency logic based on:

```text
continuous mark price
maintenance margin
liquidation trigger
liquidator race
insurance fund for normal gap risk
```

---

## 58. Operational close-out is different

Incidents such as these still need handling:

```text
broken token
chain incident
critical defect in an immutable core
oracle-system incident
```

Canonical V2 handles them only with pauses, asset restriction and verified-shortfall
resolution (`LIQUIDATION.md` sections 101–102). No position is force-closed or
migrated. That is not ordinary option-risk liquidation.

It must not retroactively reduce the holder's contractual payout.

---

## 59. Future leveraged mode

A future version may intentionally permit:

```text
InitialMargin
<
ExactWorstCaseLoss
```

That is a different system.

It requires its own specification covering:

```text
mark price
initial margin
maintenance margin
liquidation threshold
partial/full liquidation
liquidator rewards
close-out liquidity
gap risk
insurance fund
bad-debt waterfall
maximum leverage
oracle latency
socialized loss policy
```

It MUST NOT be enabled simply by lowering a buffer parameter in core V2.

---

# Part XII — Oracle risk

## 60. Current spot is not needed for active core margin

Exact bounded worst-case margin depends on:

```text
immutable series terms
position quantities
locked hedge quantities
```

not the current market price.

Therefore a live spot feed outage does not make active margin unknowable.

---

## 61. Oracle is critical at settlement

Final settlement price must mean:

```text
settlement stablecoin units per underlying
```

Examples:

```text
MON/USDT -> USDT per MON
ETH/USDC -> USDC per ETH
```

The units of:

```text
S
K
C
```

must match.

---

## 62. Direct and derived feeds

Preferred:

```text
direct UNDERLYING / SETTLEMENT_STABLECOIN feed
```

Approved derived path example:

```text
MON/USDT
=
MON/USD
/
USDT/USD
```

The protocol must not treat:

```text
MON/USD
```

as:

```text
MON/USDT
```

by assuming the stablecoin is exactly worth one dollar.

---

## 63. Oracle configuration risk

`oracleConfigId` should precommit to:

```text
feeds
decimal normalization
staleness threshold
expiry observation rule
finality rule
fallback rule
derived-path formula
rounding rule
```

Changing those after option creation would alter the economic contract.

---

## 64. Oracle failure

If no valid final price exists:

```text
risk group remains EXPIRED_UNSETTLED
```

until the precommitted settlement/fallback rule yields a valid result.

Governance should not choose a discretionary price after observing who benefits.

---

# Part XIII — Stablecoin risk

## 65. Depeg behavior

If an option settles in USDT:

```text
contractual liability = USDT
collateral = USDT
settlement = USDT
```

A USDT depeg does not itself create a USDT unit deficit.

But users remain economically exposed to the stablecoin's external purchasing value.

This makes stablecoin approval a material protocol-risk decision.

---

## 66. Stablecoin approval factors

Before approval, evaluate at least:

```text
ERC-20 transfer behavior
token decimals
blacklist/freeze powers
upgradeability
issuer risk
pause controls
redemption model
Monad liquidity
oracle availability
fee-on-transfer/rebase behavior
contract risk
```

Core V2 should prefer predictable exact-transfer stablecoins.

---

## 67. Unsupported token behavior

The MVP MUST reject tokens with (DD-040):

```text
fee-on-transfer
rebasing
unexpected callbacks
balance changes without transfer
transfer amounts different from requested amount
```

Internal cash balances must reconcile to actual custody.

---

## 68. Stablecoin disablement

Disabling a stablecoin for new risk does not rewrite existing options.

Possible response:

```text
block new pairs/series
block new writes
allow protective deposits if operational
allow compatible hedge locks
allow short closes
allow valid settlement/synchronization
allow redemption if token remains functional
```

Existing USDT-settled options remain USDT-settled.

---

# Part XIV — Kuru and integration risk

## 69. Separate accounting domains

Always preserve:

```text
Kuru stablecoin balance
!=
Optara cash collateral

Kuru option balance
!=
Optara locked hedge

Kuru sale
!=
Optara short close
```

Kuru is the trading/liquidity layer.

Optara is the issuance, margin, risk, and settlement layer.

---

## 70. Closing after buying on Kuru

A writer can buy the matching long token on Kuru.

The Optara short remains open until:

```text
the token returns to Optara
+
closeShort(seriesId, qty)
+
token burn
```

---

## 71. Kuru outage

If Kuru has:

```text
no liquidity
market pause
frontend outage
trading outage
```

Optara still must be able to:

```text
hold collateral
calculate margin
finalize settlement
sync writers
redeem longs
```

Kuru is not a solvency dependency.

---

# Part XV — Fixed-point and rounding risk

## 72. Internal scale

Core V2 should normalize economic math to:

```text
WAD = 1e18
```

Cash balances should remain in native stablecoin token units.

---

## 73. Mandatory conservative rounding

Recommended directions:

```text
required margin             -> round UP
writer matured debit        -> round UP
external long payout        -> round DOWN
positive locked-long credit -> round DOWN
withdrawable collateral     -> round DOWN
```

Residual dust becomes a separately tracked rounding reserve.

---

## 74. Risk and settlement must share payoff semantics

For any series and quantity:

```text
RiskEngine payoff model
```

must economically equal:

```text
SettlementEngine payoff model
```

The RiskEngine must never understate what SettlementEngine can later charge.

Prefer a shared audited math library.

---

# Part XVI — Vault and system solvency

## 75. Per-asset vault isolation

For each settlement asset `A`:

```text
VaultBalance(A)
```

is reconciled independently.

USDT custody is not USDC custody.

---

## 76. Encumbered account cash

If account cash is `B` and required margin is `M`:

```text
FreeCollateral = B - M
```

The required `M` is not a second pile of tokens.

It is the encumbered portion of the same account cash balance.

---

## 77. External settled long claims

Long holders may redeem before all writers explicitly synchronize because:

1. writer collateral is already physically in the stablecoin vault;
2. finalized writer debt remains economically encumbered;
3. writers cannot withdraw around matured debt;
4. per-asset accounting remains conserved.

---

## 78. Global per-asset accounting identity

Conceptually:

```text
VaultBalance(A)
=
EffectiveAccountCashClaims(A)
+ OutstandingExternalSettledLongClaims(A)
+ RoundingReserve(A)
+ ProtocolOwnedBalance(A)
+ UnallocatedSurplus(A)
```

For a fee-free MVP:

```text
ProtocolOwnedBalance(A) = 0
```

This is mainly an invariant/audit identity, not something that must be recomputed globally on every transaction.

---

# Part XVII — Operational risk

## 79. Bounded account state

Every safety-critical operation must remain executable.

The protocol must bound:

```text
active series per account
active groups per account
series per risk group
batch synchronization size
```

Dust-position spam must not make withdrawal or settlement impossible.

---

## 80. No incomplete caller-supplied risk view

A withdrawal or hedge unlock cannot rely on a caller-provided partial position list unless the protocol proves it is complete.

The ClearingHouse must maintain bounded canonical indexes or equivalent completeness guarantees.

---

## 81. Risk-increasing operations

Examples:

```text
write short
unlock hedge
withdraw collateral
```

These require complete post-action margin validation.

---

## 82. Risk-reducing operations

Examples:

```text
deposit stablecoin
lock compatible long
close short
sync matured group
```

Emergency pause design should preserve these whenever safely possible.

---

## 83. Reentrancy and transfer ordering

No external callback should ever observe an exploitable intermediate state where:

```text
collateral has been released
but liability is still recorded incorrectly
```

or:

```text
hedge has been released
but margin has not been recomputed
```

Use:

```text
reentrancy protection
safe ERC-20 transfers
checks-effects-interactions or equivalent
canonical post-action risk checks
```

---

# Part XVIII — RiskEngine API requirements

## 84. Core reads/previews

The RiskEngine should expose or support equivalents of:

```text
worstCaseLoss(account, groupId)

requiredMargin(account, settlementAsset)

freeCollateral(account, settlementAsset)

additionalCollateralForWrite(
    account,
    seriesId,
    quantity
)

requiredMarginAfterLock(
    account,
    seriesId,
    quantity
)

requiredMarginAfterUnlock(
    account,
    seriesId,
    quantity
)

maxWithdrawable(
    account,
    settlementAsset
)
```

---

## 85. Preview/execution consistency

If no relevant state changes between preview and execution:

```text
preview math
```

must match:

```text
execution validation math
```

No simplified frontend margin formula may become the source of truth.

---

## 86. Recommended component boundaries

```text
PayoffMath
-> pure payoff and fixed-point math

RiskEngine
-> risk-group critical prices
-> exact worst-case loss
-> required margin

ClearingHouse
-> account state
-> action simulation
-> enforcement

MarginVault
-> stablecoin custody

SettlementEngine
-> final price application
-> matured group delta
-> long redemption
```

The RiskEngine should not move tokens.

The MarginVault should not decide portfolio risk.

---

# Part XIX — Core margin/risk invariants

## 87. Payout bound

For all valid `S`:

```text
0 <= Payoff(S,Q)
   <= C * CS * Q
```

---

## 88. Exact-loss margin floor

For every group:

```text
GroupRequiredMargin
    >= ExactWorstCaseLoss
```

after all numerical conversion.

---

## 89. Account safety

For every stablecoin:

```text
CashBalance
    >= RequiredMargin
```

after each risk-increasing or collateral-decreasing transition.

---

## 90. No cross-stablecoin substitution

For `A != B`:

```text
CashBalance(A)
```

must not reduce:

```text
RequiredMargin(B)
```

---

## 91. Hedge custody

Any quantity counted in locked-long credit must be physically under Optara control.

---

## 92. No hedge double-use

A long-token unit cannot simultaneously be:

```text
margin hedge
external transfer
short-close input
redemption claim
```

---

## 93. No unsafe cross-group netting

Different:

```text
underlying
expiry
settlement stablecoin
oracle domain
```

cannot reduce each other's option-risk requirement.

---

## 94. Premium non-recognition

Expected or externally held premium:

```text
does not reduce RequiredMargin
```

until the actual settlement stablecoin is deposited into Optara.

---

## 95. Withdrawal safety

After required synchronization:

```text
Withdrawal <= FreeCollateral
```

---

## 96. Expiry solvency

For actual final prices:

```text
ActualNetLiability
<=
ExactWorstCaseLoss
<=
RequiredMargin
<=
CashBalance
```

---

## 97. Safe hedge removal

A hedge cannot leave custody unless:

```text
CashBalance
>=
RequiredMarginAfterRemoval
```

---

## 98. Risk/settlement identity

The option terms used for margin and final settlement must be identical:

```text
same strike
same cap
same contract size
same option type
same settlement asset
same oracle domain
```

---

# Part XX — Failure domains

## 99. RiskEngine bug

A RiskEngine bug can directly create insolvency.

Required controls:

```text
isolated payoff library
independent reference implementation
unit tests
fuzz tests
invariant tests
exceptional review for upgrades
pause of new writes if risk math is suspect
```

---

## 100. Oracle incident

Because current spot is not needed for active core margin, an oracle incident should normally affect:

```text
final settlement
new series using that oracle
```

not retroactively rewrite active margin.

---

## 101. Stablecoin incident

Possible response:

```text
disable new risk
allow deposits if token functions
allow hedge locks
allow closes
preserve existing denomination
```

No silent stablecoin substitution.

---

## 102. Kuru incident

No core margin accounting should change.

Secondary-market liquidity may suffer, but Optara solvency rules remain unchanged.

---

## 103. Gas/DoS incident

Portfolio limits must stop state growth before the account becomes impossible to evaluate or settle within block gas limits.

---

# Part XXI — Forbidden implementation shortcuts

## 104. Do not margin from current intrinsic value

Forbidden:

```text
margin
=
current intrinsic value
+
small buffer
```

This reintroduces gap risk.

Use exact worst-case contractual loss.

---

## 105. Do not subtract expected premium

Forbidden:

```text
required margin
=
max liability
-
premium expected from future sale
```

Premium is cash only after Optara receives it.

---

## 106. Do not value hedge by market price

Forbidden hedge valuation:

```text
Kuru last price
Black-Scholes value
mark price
oracle option value
```

Core hedge recognition uses contractual payoff scenario-by-scenario.

---

## 107. Do not net different expiries

Calendar-spread margin requires a different risk model.

Core V2 does not do it.

---

## 108. Do not assume stablecoins equal one another

No:

```text
USDT = USDC = USDe
```

for margin.

---

## 109. Do not trust external custody

Kuru-held or wallet-held options do not reduce Optara margin.

---

## 110. Do not transfer before risk validation

For withdrawal/unlock:

```text
simulate
-> validate
-> update state
-> transfer
```

not the reverse.

---

## 111. Do not introduce hidden leverage

Any configuration that intentionally allows:

```text
CashBalance
<
ExactWorstCaseLoss
```

is outside core V2 and requires the separate leveraged-risk design.

---

# Part XXII — Minimum margin/risk test matrix

## 112. Single-position tests

Test:

```text
unhedged capped call
unhedged capped put
fractional quantities
multiple contract sizes
very large call settlement price
put settlement at zero
```

---

## 113. Portfolio tests

Test:

```text
short call + higher-strike locked call
short put + lower-strike locked put
mixed calls and puts in same group
multiple shorts and longs
hedge that reduces margin
hedge that does not reduce worst case
different quantities
different contract sizes
```

---

## 114. Isolation tests

Prove no offset across:

```text
different underlying
different expiry
different settlement asset
different oracleConfigId
wallet-held long
Kuru-held long
```

---

## 115. Lifecycle tests

Check required margin before and after:

```text
deposit
write
lock
unlock
close
withdraw
expiry
finalize
sync
redeem
```

---

## 116. Rounding tests

Across supported stablecoin decimals, prove:

```text
required margin never rounds below exact loss
external payout never exceeds contractual claim
writer debit never understates obligation
rounding dust never becomes free collateral
```

---

## 117. Fuzz/invariant tests

For arbitrary valid bounded portfolios, assert:

```text
onchainWorstCase
>=
independentReferenceWorstCase
```

and:

```text
for every tested valid S:
NetLiability(S)
<=
RequiredMargin
```

also:

```text
withdraw/unlock cannot create unsafe account
cross-stablecoin balance cannot cover another asset
locked hedge cannot be double-used
```

---

# Part XXIII — Launch parameters

## 118. Parameters that must be fixed before production

The deployment must explicitly define:

```text
approved stablecoins
approved underlying/stablecoin pairs
stablecoin token addresses
stablecoin decimals/adapters
maximum active series per account
maximum active groups per account
maximum series per group
minimum quantity increment
maximum quantity bounds
safety-buffer defaults for new groups
aggregate exposure caps
oracle configurations (including maxFinalizationDelay)
expiry schedules
strike/cap limits
contract-size conventions
pause scopes
```

Implementation agents must not invent them silently.

---

## 119. Governance and future parameters

Governance may alter rules for **future risk**, such as:

```text
new approved pairs
new-series bounds
future position limits
future safety-buffer settings
```

Governance must not retroactively rewrite an existing series':

```text
underlying
settlement asset
strike
cap
contract size
expiry
oracle domain
```

---

# Part XXIV — Engineering checklist

Before the margin/risk system is implementation-complete:

- [ ] every series uses its pair's approved stablecoin as quote/collateral/settlement asset;
- [ ] account cash is tracked per stablecoin;
- [ ] no cross-stablecoin margin conversion exists;
- [ ] call and put payouts are capped;
- [ ] puts enforce canonical cap rules;
- [ ] the RiskEngine computes exact worst-case portfolio loss;
- [ ] every critical price is evaluated;
- [ ] netting is restricted to same underlying/expiry/stablecoin/oracle domain;
- [ ] only Optara-controlled locked longs reduce margin;
- [ ] unlock performs post-removal margin simulation before release;
- [ ] premium is ignored until actual stablecoin deposit;
- [ ] write previews and execution use the same risk math;
- [ ] active margin does not depend on current spot;
- [ ] withdrawals synchronize relevant finalized groups;
- [ ] matured hedged groups settle atomically;
- [ ] required margin rounds up;
- [ ] external long payout rounds down;
- [ ] per-asset vault accounting reconciles;
- [ ] Kuru balances are treated as external;
- [ ] position counts are bounded;
- [ ] no hidden parameter permits undercollateralized naked risk;
- [ ] fuzz tests compare on-chain output against an independent exact evaluator.

---

# Part XXV — Canonical summary

## Option payoff

```text
CALL:
min(max(S-K,0), C) * CS * Q

PUT:
min(max(K-S,0), C) * CS * Q
```

## Risk group

```text
same underlying
+
same expiry
+
same settlement stablecoin
+
same oracle settlement domain
```

## Portfolio loss

```text
Loss(S)
=
max(
    TotalShortPayoff(S)
    -
    TotalLockedLongPayoff(S),
    0
)
```

## Exact worst-case loss

```text
WorstCaseLoss
=
max over all critical settlement prices of Loss(S)
```

## Group margin

```text
GroupMargin
=
ceilDiv(WorstCaseLossNumerator, D_A)
+
SafetyBufferNative   (snapshotted per group; zero in MVP)
```

## Stablecoin-level requirement

```text
RequiredMargin(account, asset)
=
sum of group margins settled in asset
```

## Safety condition

```text
CashBalance(account, asset)
>=
RequiredMargin(account, asset)
```

## Free collateral

```text
FreeCollateral
=
CashBalance
-
RequiredMargin
```

## Solvency theorem

```text
ActualNetLiability
<=
ExactWorstCaseLoss
<=
RequiredMargin
<=
CashBalance
```

## Core policy

```text
Capital efficiency
comes from provable contractual netting.

It does not come from
leaving worst-case losses unfunded.
```

That principle defines Optara V2 margin and risk.

---

## 120. Arithmetic, unresolved expiry, and prospective policy

`MATH.md` sections 24, 54 and 118 define the executable exact-numerator algorithm.
No intermediate payoff truncation is permitted. Core V2 restricts settlement decimals
to 0..18 and validates maximum numerator products/sums for writes and hedge locks.
No spot feed is needed for this calculation.

"Active groups" in margin sums includes expired-unfinalized groups until cancellation
or final settlement removes their quantities. Finalized groups are synchronized
before cash-spending actions. An unresolved oracle does not release margin or block
independently proven free cash. `PROTOCOL_SPEC.md` section 41 defines cancellation
and safe unfinalized hedge release.

Buffer policy, quantity granularity, and numerical domains are fixed for existing
groups/series. Lowering prospective count limits MUST NOT prevent existing portfolios
from evaluation, close, cancellation, sync or safe withdrawal. New position creation
is rejected while over the new limit; zero positions are removed from indexes.
Exact mathematical short risk is monotone; numerical product limits additionally
bound gross hedge quantities even for zero-risk portfolios.
