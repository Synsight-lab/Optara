# Optara V2 Liquidation and Emergency Close-Out Specification

**Document type:** Normative liquidation, forced-risk-reduction, and emergency close-out specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document defines what **liquidation means — and does not mean — in Optara V2**.

Optara V2 is not designed like a perpetual-futures protocol where a user's position becomes unsafe when the market moves against them and a liquidator must race to close it.

Core V2 instead uses:

```text
capped contractual option payouts
+
exact worst-case portfolio margin
+
pair-specific settlement-stablecoin collateral
+
Optara-controlled locked long hedges
```

so that a valid account is already collateralized against its maximum possible contractual expiry loss.

This specification therefore defines:

- why ordinary price-driven liquidation is not part of core V2;
- the difference between liquidation, voluntary close, expiry settlement, and emergency close-out;
- which actions reduce risk during normal operation;
- what the protocol must do if an account appears undercollateralized despite core-V2 rules;
- how stablecoin, oracle, integration, accounting, or implementation incidents affect liquidation policy;
- which actions may be paused and which should remain available;
- how long-holder claims are protected during incidents;
- what governance may and may not do;
- how any future undercollateralized leverage mode must be separated from core V2.

This document must be read together with:

- `MARGIN_AND_RISK.md` — margin and risk policy;
- `MATH.md` — authoritative numerical formulas;
- `INVARIANTS.md` — system properties that must always hold;
- `PROTOCOL_SPEC.md` — runtime state transitions;
- `OPTION_SPEC.md` — immutable option economics;
- `ARCHITECTURE.md` — component boundaries.

If there is a conflict:

1. `MATH.md` controls numerical formulas and rounding;
2. `INVARIANTS.md` controls required system safety properties;
3. `PROTOCOL_SPEC.md` controls ordinary runtime transition ordering;
4. this document controls liquidation and emergency close-out policy.

---

# 2. Core conclusion

## 2.1 Core V2 does not require ordinary price-driven liquidation

For account `a`, settlement asset `A`, and active risk groups `g`:

```text
ActualLoss_g(S_g)
    <= ExactWorstCaseLoss_g
```

for every valid final settlement price `S_g`.

Core V2 requires:

```text
GroupRequiredMargin_g
    >= ExactWorstCaseLoss_g
```

and:

```text
CashBalance(a,A)
    >= RequiredMargin(a,A)
```

where:

```text
RequiredMargin(a,A)
    =
    sum of GroupRequiredMargin_g
    for groups settled in A
```

Therefore:

```text
ActualNetLiability(a,A)
    <= RequiredMargin(a,A)
    <= CashBalance(a,A)
```

for every combination of valid final prices, subject to correct contract behavior, custody, arithmetic, oracle finalization, and token behavior.

This means:

> A normal adverse move in MON, ETH, BTC, or another underlying must not make a previously valid core-V2 account insolvent.

---

## 2.2 Core V2 liquidation must not be modeled like perpetual liquidation

Core V2 MUST NOT introduce an ordinary rule such as:

```text
if markPrice moves
and healthFactor < 1
then liquidate writer
```

because core V2 does not intentionally allow:

```text
posted settlement-stablecoin cash
<
exact worst-case contractual net liability
```

A spot-price-triggered liquidation system would add:

```text
oracle dependency
liquidator dependency
close-out liquidity dependency
MEV exposure
auction complexity
gap risk
insurance-fund complexity
```

without being necessary for the core solvency model.

---

# 3. Terminology

## 3.1 Voluntary close

The writer acquires the exact same-series long token and returns it to Optara.

For quantity `Q`:

```text
shortQty -= Q
long token supply -= Q
```

through long-token burn.

This is **not liquidation**.

---

## 3.2 Hedge lock

The account deposits and locks a compatible long option.

If the long reduces exact worst-case portfolio loss:

```text
RequiredMarginAfter
<
RequiredMarginBefore
```

This is **not liquidation**.

---

## 3.3 Margin deposit

The account deposits more of the exact pair settlement stablecoin.

This raises:

```text
CashBalance(account, asset)
```

This is **not liquidation**.

---

## 3.4 Expiry synchronization

After a risk group is finalized, the account's matured short liabilities and matured locked-long credits are netted and applied atomically.

This is **deterministic settlement**, not liquidation.

---

## 3.5 Ordinary liquidation

A forced reduction or seizure of a user's open position because a market-price-based maintenance threshold has been breached.

Core V2 does **not** use this mechanism for normal option-risk management.

---

## 3.6 Emergency close-out

An exceptional protocol action taken because a non-market invariant or infrastructure assumption has failed, such as:

```text
critical accounting bug
unsupported token behavior
corrupted custody state
severe contract exploit
invalid oracle infrastructure
migration required after a critical incident
```

Emergency close-out is not an ordinary user-risk mechanism.

---

## 3.7 Deficit state

For settlement asset `A`:

```text
Deficit(a,A)
    =
    max(
        RequiredMargin(a,A)
        - SafeEffectiveCash(a,A),
        0
    )
```

In a valid core-V2 system under normal assumptions:

```text
Deficit(a,A) = 0
```

A positive deficit is an **exceptional invariant breach or incident state**, not an expected market condition.

---

# Part I — Normal core-V2 operation

## 4. Healthy-account rule

An active account is healthy for settlement asset `A` when:

```text
SafeEffectiveCash(a,A)
    >= RequiredMargin(a,A)
```

where `SafeEffectiveCash` must include required treatment of finalized-but-unsynchronized matured groups.

For a fully synchronized active account:

```text
SafeEffectiveCash(a,A)
    = CashBalance(a,A)
```

---

## 5. Market movement alone must not make an account liquidatable

Suppose Carol writes a capped call:

```text
MON/USDT
Strike K = 12
Cap C = 5
Contract size = 1
Quantity = 1
```

Her maximum contractual liability is:

```text
5 USDT
```

If she has no locked hedge, core V2 requires approximately:

```text
5 USDT
+ safety buffer
+ rounding guard
```

before the write succeeds.

Whether MON later trades at:

```text
13
20
100
1000
```

does not increase the contractual option payout above:

```text
5 USDT
```

Therefore Carol does not become liquidatable simply because MON moons.

---

## 6. Normal risk-reducing actions

The following are the primary normal risk-management tools.

### 6.1 Deposit more pair stablecoin

```text
deposit(settlementAsset, amount)
```

increases cash coverage.

### 6.2 Lock a compatible long hedge

```text
lockLong(seriesId, quantity)
```

may reduce exact worst-case loss.

### 6.3 Close the short

```text
closeShort(seriesId, quantity)
```

consumes matching same-series long tokens and reduces short quantity.

### 6.4 Reduce future risk creation

A user may simply stop writing new shorts.

### 6.5 Allow expiry to settle

Because maximum loss is already funded, the writer may hold the position to expiry.

None of these require a third-party liquidator.

---

# Part II — Actions that are explicitly not liquidation

## 7. Buying back the option on Kuru

If Carol is short a particular Optara series, she may buy the same long token on Kuru.

Example:

```text
Carol Optara short:
oMON-USDT-12C-C5-EXP

Carol buys:
the exact same oMON-USDT-12C-C5-EXP long token
```

The Kuru trade alone does not close the Optara short.

The close occurs only when the token is returned to Optara and consumed.

This is a voluntary close.

---

## 8. Settlement debit at expiry

Suppose final payout is:

```text
3 USDT
```

and Carol has:

```text
5 USDT
```

encumbered in Optara.

At synchronization:

```text
CashBalance' = CashBalance - 3
```

and the short obligation is cleared.

That debit is contract settlement, not liquidation.

---

## 9. Atomic hedged settlement

Suppose Alice has:

```text
Cash = 2 USDT

Short liability at expiry = 5 USDT
Locked-long credit         = 3 USDT
```

Correct group settlement:

```text
Delta = 3 - 5 = -2 USDT

Cash' = 2 - 2 = 0
```

This is deterministic portfolio settlement.

Optara MUST NOT:

```text
debit 5 first
declare liquidation
then credit 3 later
```

because that would create a false insolvency.

---

# Part III — Liquidation eligibility in core V2

## 10. Normal liquidatability predicate

For ordinary market risk, core V2 should conceptually satisfy:

```text
isPriceLiquidatable(account) = false
```

provided all core invariants hold.

There is no normal price threshold:

```text
spot price
mark price
option mark price
Kuru trade price
```

that by itself makes an account liquidatable.

---

## 11. Coverage ratio is not a maintenance-margin trigger

Core V2 may expose:

```text
CoverageRatio
=
CashBalance / RequiredMargin
```

for monitoring.

But:

```text
CoverageRatio >= 1
```

is the required valid state.

The protocol must not intentionally allow:

```text
CoverageRatio < 1
```

as a routine operating region and then depend on liquidation.

Therefore no ordinary rule should say:

```text
liquidate when CoverageRatio < 0.8
```

or similar.

---

## 12. When a deficit can exist

A positive deficit may occur only because an assumption or invariant failed.

Examples:

```text
RiskEngine undercalculated margin
rounding undercharged writer
token balance changed unexpectedly
fee-on-transfer token bypassed approval checks
reentrancy corrupted state
custody tokens were lost/stolen/frozen
upgrade corrupted accounting
settlement calculation differs from risk calculation
incorrect active-position index omitted risk
malicious or broken oracle finalization
manual/admin state corruption
```

These are protocol incidents.

They are not ordinary liquidation opportunities.

---

# Part IV — Deficit detection

## 13. Active-account deficit

For active groups:

```text
ActiveDeficit(a,A)
=
max(
    RequiredMargin(a,A)
    - SafeEffectiveCash(a,A),
    0
)
```

If:

```text
ActiveDeficit > 0
```

the system has entered an abnormal state.

---

## 14. Matured-account deficit

After a risk group is finalized, define its deterministic account delta:

```text
Delta_g
=
LockedLongCredit_g
-
ShortLiability_g
```

For all finalized-but-unsynchronized groups in stablecoin `A`:

```text
SafeEffectiveCash(a,A)
=
RawCashBalance(a,A)
+
sum(Delta_g)
```

A matured deficit exists if:

```text
SafeEffectiveCash(a,A) < 0
```

In normal core V2 this should be mathematically impossible.

---

## 15. Never diagnose insolvency from stale raw balance

The protocol MUST NOT declare an account insolvent using:

```text
RawCashBalance
```

while ignoring matured locked-long credits.

All relevant matured positions must be included atomically.

---

# Part V — Core-V2 response to an abnormal deficit

## 16. First response: contain risk

If the protocol detects a real deficit or cannot safely prove account health, it SHOULD immediately block risk-increasing actions for the affected scope.

At minimum:

```text
new short writes        -> blocked
collateral withdrawals  -> blocked
hedge unlocks           -> blocked
risk-increasing adapter actions -> blocked
```

---

## 17. Preserve risk-reducing actions when safe

Subject to the nature of the incident, the protocol SHOULD keep available:

```text
deposit exact settlement stablecoin
lock compatible long
close short with exact matching long
synchronize valid matured group
```

These actions cannot normally worsen the account's contractual risk.

---

## 18. No automatic seizure of unrelated accounts

If account `a` has a deficit:

```text
cash of unrelated account b
```

MUST NOT be automatically seized to repair it.

Core V2 does not define ordinary socialized loss.

---

## 19. No cross-stablecoin rescue

If there is a USDT deficit:

```text
USDC
USDe
DAI
```

held by the same or other accounts must not automatically be converted or seized to cover it.

Core V2 keeps settlement-asset domains isolated.

---

## 20. No retroactive buyer payout haircut

An emergency deficit does not authorize the protocol to rewrite:

```text
strike
cap
contract size
expiry
settlement stablecoin
final settlement price
```

or to impose a lower cap after the fact.

The buyer's contractual claim must remain defined by the immutable option series.

---

# Part VI — Voluntary cure before any emergency close-out

## 21. Account cure by deposit

If the exact settlement stablecoin remains functional, the account owner may restore:

```text
SafeEffectiveCash
>=
RequiredMargin
```

by depositing more collateral.

---

## 22. Account cure by locking a long

The account may lock an additional compatible long.

If:

```text
RequiredMarginAfterLock
<
RequiredMarginBeforeLock
```

and health is restored, the account returns to a valid state.

---

## 23. Account cure by closing shorts

The account may acquire and return exact same-series long tokens.

For close quantity `Q`:

```text
shortQty -= Q
matching long burned
```

Required margin is recomputed.

---

## 24. Cure priority

Where multiple cure actions are available, core contracts do not need to choose a trading strategy for the user.

The protocol only needs to verify the resulting state.

Conceptually:

```text
perform risk-reducing action
        ->
recompute exact risk
        ->
if Cash >= RequiredMargin
    healthy
else
    remain restricted
```

---

# Part VII — Why core V2 should not force-sell options on Kuru

## 25. Kuru liquidity cannot be assumed

Kuru is an external secondary market.

A forced liquidation that depends on selling or buying there would introduce:

```text
order-book depth risk
slippage
market outage risk
MEV/front-running
temporary illiquidity
token-listing dependency
```

The core solvency model intentionally avoids these dependencies.

---

## 26. Kuru price is not a liquidation oracle

The option's Kuru market price is the market value of a transferable long token.

It is not the contractual maximum liability.

Therefore Optara MUST NOT use:

```text
last Kuru trade
best bid/ask
option mark price
```

as the ordinary liquidation trigger in core V2.

---

## 27. Kuru may facilitate voluntary recovery

A user may use Kuru to:

```text
buy matching long token
sell an unlocked long
raise stablecoin liquidity
rebalance externally
```

but the core contracts should not depend on Kuru execution for solvency.

---

# Part VIII — Emergency close-out policy

## 28. Emergency close-out is not ordinary liquidation

An emergency close-out is allowed only under an explicitly declared incident process.

Possible incident categories include:

```text
critical protocol exploit
accounting corruption
broken settlement token behavior
custody compromise
unsafe upgrade
irrecoverable oracle configuration issue
migration after critical vulnerability
```

It is not triggered merely because an underlying price moved.

---

## 29. Emergency state machine

Recommended conceptual states:

```text
NORMAL
  |
  | critical incident
  v
RISK_PAUSED
  |
  +--> RECOVERED
  |
  +--> ASSET_RESTRICTED
  |
  +--> MIGRATION_REQUIRED
```

A deployment MAY use more granular scopes.

---

## 30. Risk pause

A risk pause SHOULD block:

```text
new writes
unsafe withdrawals
hedge unlocks that increase risk
new series for affected asset/oracle
unsafe adapters
```

and SHOULD preserve, when technically safe:

```text
deposits
hedge locks
same-series short closes
valid settlement finalization
matured group synchronization
valid long redemption
```

If the incident itself affects settlement correctness, finalization/redemption may also need to pause.

---

## 31. Scope the pause narrowly

Pause scope SHOULD be as small as safely possible.

Examples:

```text
one oracleConfigId
one settlement stablecoin
one underlying/stablecoin pair
one contract component
all new writes protocol-wide
```

Do not block unaffected assets unnecessarily.

---

# Part IX — Incident-specific handling

## 32. Stablecoin depeg without token malfunction

Suppose USDT trades externally below one U.S. dollar but ERC-20 transfers and balances remain correct.

For a USDT-settled option:

```text
liability = USDT
collateral = USDT
```

The account is not unit-insolvent merely because USDT depegs.

Therefore a stablecoin market-price depeg alone does not trigger writer liquidation.

Governance may stop **new** USDT-denominated risk while preserving existing USDT contracts.

---

## 33. Stablecoin transfer/freeze incident

If the settlement token cannot reliably transfer because of:

```text
global pause
blacklisting
contract malfunction
unexpected fee/rebase
```

the issue is settlement infrastructure risk.

Potential actions:

```text
disable new writes
disable new series
allow accounting synchronization where safe
delay external transfer until token functionality returns
```

The protocol must not silently convert existing claims to another stablecoin.

---

## 34. Oracle outage before expiry

Core pre-expiry margin does not require current spot.

Therefore an oracle outage does not create an ordinary liquidation condition.

Actions may include:

```text
disable new series using oracle
disable new writes if settlement reliability is uncertain
```

Existing funded risk remains bounded.

---

## 35. Oracle failure at expiry

If the precommitted settlement oracle cannot produce a valid final price:

```text
group remains EXPIRED_UNSETTLED
```

The group must not be liquidated using an arbitrary substitute price.

Use only precommitted fallback logic.

---

## 36. Kuru outage

Kuru outage:

```text
does not make account undercollateralized
does not trigger liquidation
does not change payoff
```

It only reduces secondary-market liquidity and the user's ability to voluntarily close through external trading.

---

## 37. RiskEngine incident

If RiskEngine correctness is in doubt:

```text
new writes -> pause
withdrawals depending on suspect risk result -> pause
hedge unlocks -> pause
```

Risk-reducing deposits and exact same-series closes should remain available if their implementation path is independently safe.

---

## 38. SettlementEngine incident

If SettlementEngine is suspect:

```text
finalization -> pause
redemption -> pause if payout cannot be trusted
matured sync -> pause if debit/credit cannot be trusted
```

Active pre-expiry risk remains bounded by the already-required margin if RiskEngine and custody are intact.

---

## 39. Vault/custody incident

If actual token custody is below accounted custody:

```text
VaultBalance(A)
<
required physical backing
```

this is a protocol insolvency incident, not a user liquidation event.

Do not attempt to disguise it by liquidating healthy users.

---

# Part X — Deterministic expiry settlement

## 40. Expiry settlement supersedes active margin

Before finalization:

```text
risk = worst-case possible liability
```

After finalization:

```text
risk = deterministic actual liability
```

Once a group is validly finalized, active worst-case margin for that group is replaced by settlement accounting.

---

## 41. Account group settlement

For account `a`, finalized group `g`:

```text
Short_g*
    = sum of finalized short payouts

LockedLong_g*
    = sum of finalized locked-long payouts

Delta_g
    = LockedLong_g* - Short_g*
```

Then atomically:

```text
CashBalance'
    = CashBalance + Delta_g
```

with conservative rounding.

---

## 42. A negative raw intermediate is not allowed

The protocol should not execute:

```text
CashBalance - ShortLiability
```

first when a recognized matured hedge exists.

It should calculate the group net result first.

---

## 43. Post-settlement free collateral

After group synchronization:

```text
short quantities cleared
locked matured longs consumed
cash delta applied
group removed from active set
```

The account's remaining active margin is recomputed.

Any excess cash becomes free collateral.

---

# Part XI — If post-settlement cash would become negative

## 44. Negative result means core assumptions failed

If valid group synchronization would produce:

```text
CashBalance' < 0
```

that indicates at least one of the following:

```text
margin undercalculation
incorrect rounding
missing risk position
token/custody loss
incorrect hedge accounting
invalid settlement price
state corruption
implementation exploit
```

It must not be treated as an expected liquidation path.

---

## 45. Required response to negative settlement result

The affected settlement asset or protocol scope SHOULD enter emergency mode.

The implementation MUST NOT:

```text
silently set balance to zero
forgive writer debt
haircut long holders automatically
take unrelated user collateral
borrow another stablecoin automatically
```

The incident requires explicit recovery/reconciliation logic.

---

## 46. No hidden bad-debt socialization

Core V2 does not define:

```text
loss socialization
ADL
haircut waterfall
insurance fund exhaustion
```

as ordinary settlement mechanisms.

If the protocol later introduces any of these, they require their own governance and economic specification.

---

# Part XII — Optional emergency account restriction

## 47. Restricted account state

The implementation MAY expose a restricted state for an account when an invariant breach is detected.

While restricted:

```text
write                -> blocked
withdraw             -> blocked
unlockLong           -> blocked if risk-increasing
risk-increasing adapter operations -> blocked
```

Potentially allowed:

```text
deposit
lock compatible long
close exact short
sync trusted matured groups
```

---

## 48. Returning from restricted to healthy

After a permitted cure:

```text
SafeEffectiveCash(a,A)
>=
RequiredMargin(a,A)
```

must be proven using the canonical RiskEngine.

Only then may ordinary operations resume.

---

## 49. Restriction is not punishment

An account restriction exists to prevent state deterioration.

It must not:

```text
transfer account collateral to third parties
change option terms
confiscate free assets
award a liquidator bonus
```

unless a future separately specified leveraged-liquidation mode explicitly defines those rules.

---

# Part XIII — Governance restrictions

## 50. Governance may pause risk creation

Governance or an authorized guardian MAY, according to deployment governance rules:

```text
pause new writes
disable new series
disable affected pair/oracle for future risk
pause unsafe withdrawals
pause unsafe hedge unlocks
```

during a critical incident.

---

## 51. Governance must not rewrite economic terms

Governance MUST NOT change an existing series':

```text
underlying
settlement stablecoin
option type
strike
payout cap
contract size
expiry
oracle domain
finalized settlement price
```

to reduce protocol losses.

---

## 52. Governance must not arbitrarily seize collateral

Administrative rescue functions MUST NOT become generic paths for transferring accounted user collateral to governance.

Any recovery of accidentally sent unrelated tokens must exclude recognized user collateral and claims.

---

## 53. Governance must not pick winners in settlement

If an oracle fails, governance should not be able to choose an ad hoc settlement price after observing which writers or holders benefit.

Fallback logic should be committed before series creation.

---

# Part XIV — Liquidator role in core V2

## 54. No ordinary liquidator role is required

Core V2 does not require an economically incentivized actor who monitors accounts and calls:

```text
liquidate(account)
```

when market prices move.

This role SHOULD NOT exist in the MVP unless it is only an emergency/migration tool with tightly specified permissions.

---

## 55. Keepers are different from liquidators

A keeper MAY permissionlessly trigger deterministic maintenance such as:

```text
finalizeRiskGroup
syncRiskGroup
```

when conditions are objectively satisfied.

A keeper:

```text
does not choose the price
does not seize collateral
does not earn a liquidation spread
does not decide whether an account is economically distressed
```

Keeper activity is maintenance, not liquidation.

---

# Part XV — Fees and incentives

## 56. No liquidation penalty in core V2

Because there is no ordinary liquidation:

```text
liquidation penalty = not applicable
liquidator reward   = not applicable
```

for normal core-V2 option risk.

---

## 57. Keeper reimbursement

If Optara later reimburses keepers for deterministic settlement maintenance, that should be specified as:

```text
keeper execution fee
```

not a liquidation penalty.

Any such fee must not change the immutable buyer payout unless it was explicitly part of the contract terms.

---

# Part XVI — Interaction with pause logic

## 58. Pause matrix

Recommended baseline:

| Action | Normal | Risk pause | Oracle settlement incident | Vault/token incident |
|---|---|---|---|---|
| Deposit pair stablecoin | Yes | Yes if token safe | Yes if token safe | Maybe |
| Write new short | Yes | No | Usually No | No |
| Lock compatible long | Yes | Yes | Yes if token path safe | Maybe |
| Unlock hedge | Yes if safe | Usually No | Usually No | No |
| Close same-series short | Yes | Yes if safe | Yes if safe | Maybe |
| Withdraw free collateral | Yes | Restricted | Restricted | No/Restricted |
| Finalize risk group | After expiry | Yes if oracle trusted | No | Depends |
| Sync matured group | Yes | Yes if settlement trusted | No until valid finalization | Depends |
| Redeem long | After settlement | Yes if settlement/custody trusted | No until valid finalization | Depends |

The exact deployment pause implementation may be more granular.

---

# Part XVII — Core liquidation invariants

## 59. INV-LIQ-01 — No price-only liquidatability

For a healthy core-V2 account, changing current market spot price alone must not create an ordinary liquidation state.

---

## 60. INV-LIQ-02 — Worst-case funded before write

A short may be created only when:

```text
CashBalance
>=
PostWriteRequiredMargin
>=
PostWriteExactWorstCaseLoss
```

for the relevant settlement stablecoin.

---

## 61. INV-LIQ-03 — No maintenance-margin region

Core V2 must not intentionally define a routine operating interval where:

```text
CashBalance < ExactWorstCaseLoss
```

but the account is considered temporarily acceptable.

---

## 62. INV-LIQ-04 — No forced haircut to immutable option claim

Emergency handling must not retroactively reduce:

```text
Payoff(series, finalized S, Q)
```

by modifying series economics.

---

## 63. INV-LIQ-05 — No cross-account automatic loss transfer

A deficit in one account must not automatically decrease another healthy account's balance.

---

## 64. INV-LIQ-06 — No cross-stablecoin automatic rescue

A deficit in stablecoin `A` must not automatically consume stablecoin `B`.

---

## 65. INV-LIQ-07 — Risk-reducing cure must use canonical post-state checks

After deposit, hedge lock, or short close:

```text
SafeEffectiveCash
>=
RequiredMargin
```

must be evaluated using the same canonical RiskEngine.

---

## 66. INV-LIQ-08 — Matured group is evaluated atomically

Liquidation or insolvency status must never be determined from a short leg without simultaneously including every recognized matured locked-long leg in the same risk group.

---

## 67. INV-LIQ-09 — Kuru liquidity is not required for solvency

Optara settlement correctness must hold even if no option can be bought or sold on Kuru.

---

## 68. INV-LIQ-10 — Negative post-sync cash is an incident

A negative post-sync account cash result must be treated as invariant failure/emergency state, not an ordinary successful liquidation outcome.

---

## 69. INV-LIQ-11 — Emergency pause does not rewrite positions

Pausing risk cannot mutate existing strike, cap, quantity, expiry, or settlement asset.

---

## 70. INV-LIQ-12 — Restricted state cannot increase user risk

Any protocol-enforced restricted state must not itself remove recognized collateral or hedges in a way that increases the user's net contractual liability.

---

# Part XVIII — Future leveraged liquidation mode

## 71. Explicit separation

Any future mode where writers post less than exact worst-case loss is **not core V2**.

It should be placed in a separate specification such as:

```text
LEVERAGED_MARGIN.md
LIQUIDATION_V2X.md
```

and controlled by separate configuration or contracts.

---

## 72. Future leveraged-mode variables

Such a design would need at least:

```text
AccountEquity
InitialMargin
MaintenanceMargin
MarkPrice
LiquidationThreshold
CloseOutPrice
LiquidationPenalty
LiquidatorReward
InsuranceBalance
BadDebt
```

None of these are needed for ordinary core-V2 solvency.

---

## 73. Future health factor

A future leveraged design might define:

```text
HealthFactor
=
AccountEquity
/
MaintenanceMargin
```

with liquidation when:

```text
HealthFactor < 1
```

Core V2 MUST NOT implement this as its ordinary liquidation trigger.

---

## 74. Future gap risk

If:

```text
posted margin < exact worst-case loss
```

then price gaps can exceed collateral before liquidation executes.

That future system must explicitly handle:

```text
close-out slippage
oracle latency
MEV
liquidity failure
insurance
bad debt
potential socialized loss
```

The capped payoff alone does not eliminate these problems if the protocol intentionally leaves part of the capped liability unfunded.

---

## 75. Future liquidation venue

A leveraged version would need to decide whether liquidation closes risk through:

```text
Kuru
internal auction
RFQ
AMM
backstop vault
portfolio transfer
```

Core V2 deliberately avoids depending on this decision.

---

# Part XIX — Required tests

## 76. No-liquidation-on-price-move test

Create a valid unhedged capped call writer with exact required collateral.

Fuzz current/settlement candidate spot values from:

```text
0
to very large values
```

and prove that the account's contractual worst-case liability never exceeds required margin.

No spot move should independently create a liquidation condition.

---

## 77. Capped-call moon test

Example:

```text
K = 10
C = 5
CS = 1
Q = 1
RequiredMargin = 5
```

Test:

```text
S = 15
S = 20
S = 100
S = max safe oracle range
```

Expected maximum payout:

```text
5
```

---

## 78. Hedged atomic-settlement test

Create:

```text
cash = 2
short liability at settlement = 5
locked long credit = 3
```

Prove:

```text
net debit = 2
```

and no temporary insolvency/liquidation path occurs.

---

## 79. Withdrawal-prevention test

Attempt to withdraw below:

```text
RequiredMargin
```

Transaction must revert before token transfer.

---

## 80. Unlock-prevention test

Attempt to unlock a hedge that would make:

```text
CashBalance < RequiredMarginAfterUnlock
```

Transaction must revert before hedge release.

---

## 81. External-premium test

Give the user large Kuru stablecoin proceeds but no Optara deposit.

Prove Optara margin and liquidatability do not change.

---

## 82. Cross-stablecoin test

Create:

```text
USDT requirement = 5
USDT cash = 4
USDC cash = 1000
```

The USDC must not repair the USDT deficit.

The state should be considered invalid/restricted, not healthy.

---

## 83. Kuru-outage test

Model Kuru unavailable.

Prove Optara can still:

```text
finalize valid expiry
sync matured positions
redeem long claims
```

without Kuru calls.

---

## 84. Oracle-outage-before-expiry test

Disable current oracle access before expiry.

If pre-expiry RiskEngine does not require live spot, margin computation must remain deterministic from series terms and positions.

---

## 85. Oracle-failure-at-expiry test

No valid final price.

Prove:

```text
group remains EXPIRED_UNSETTLED
```

and no arbitrary liquidation price is used.

---

## 86. Negative-effective-balance emergency test

Using a deliberately corrupted test harness, force:

```text
SafeEffectiveCash < 0
```

Prove ordinary state-changing paths do not silently continue.

Expected behavior:

```text
revert and/or enter explicit emergency handling
```

according to implementation architecture.

---

## 87. No-socialized-loss test

Force an artificial account deficit in test harness.

Prove another healthy account's cash is unchanged.

---

## 88. No-economic-term-rewrite test

During pause/emergency, attempt to change:

```text
strike
cap
expiry
settlement asset
oracle domain
```

for an existing series.

All attempts must fail.

---

# Part XX — Implementation recommendations

## 89. Core contract surface

The MVP SHOULD avoid exposing a generic ordinary:

```solidity
liquidate(address account)
```

function.

If any emergency close-out function exists, its name, authorization, scope, and permitted state transitions should make its exceptional nature explicit.

Examples:

```text
restrictAccount(...)
pauseRisk(...)
disablePairForNewRisk(...)
emergencyMigrate(...)
```

only if their behavior is separately specified.

---

## 90. Account health view

A useful read function is:

```text
accountRiskState(account, settlementAsset)
```

which may return:

```text
cashBalance
requiredMargin
freeCollateral
hasUnsyncedMaturedGroups
isRestricted
```

It should not imply a conventional liquidation threshold that core V2 does not use.

---

## 91. Incident telemetry

Indexers/monitoring should alert on:

```text
CashBalance < RequiredMargin
negative effective balance
vault/accounting mismatch
unexpected stablecoin balance change
risk-engine preview/execution mismatch
failed matured-group synchronization
oracle finalization failure
```

Any of these warrants investigation.

---

## 92. Emergency events

If emergency controls are implemented, emit events such as:

```text
RiskPaused(scope, reasonCode)
AccountRestricted(account, asset, reasonCode)
PairDisabledForNewRisk(pairId, reasonCode)
OracleConfigSuspended(configId, reasonCode)
EmergencyModeCleared(scope)
```

Events must not be the on-chain source of truth for health.

---

# Part XXI — Forbidden designs

## 93. Do not liquidate because a capped call "moons"

If the call was correctly margined:

```text
maximum liability was already funded
```

So a large move alone is not a reason to liquidate.

---

## 94. Do not use spot-price maintenance margin in core V2

Forbidden ordinary model:

```text
CurrentOptionLoss
+
buffer
=
maintenance margin
```

Core V2 uses exact worst-case contractual loss.

---

## 95. Do not liquidate based on Kuru option price

A low/high secondary-market option price does not define writer solvency.

---

## 96. Do not seize locked hedges away from the account

A locked hedge is part of the portfolio protection that justified lower cash margin.

Removing it without simultaneously reducing the associated risk may create insolvency.

---

## 97. Do not liquidate one leg of a margined spread in isolation

If margin was granted from portfolio netting:

```text
short leg
+
locked long hedge
```

cannot be treated independently for liquidation/settlement purposes.

Any forced mutation must preserve the post-state safety inequality.

---

## 98. Do not silently introduce an insurance-fund dependency

Core V2 solvency should not depend on an insurance fund for ordinary market movement.

If an insurance fund is later added for operational incidents, that requires a separate fund-policy specification.

---

## 99. Do not make governance the liquidation counterparty

Governance should not have discretionary ability to acquire user positions at a price it chooses.

---

## 100. Do not treat a stablecoin depeg as automatic unit insolvency

If:

```text
USDT backs USDT
```

external USD value changing does not itself mean fewer USDT units exist than promised.

---

# Part XXII — Engineering checklist

Before core-V2 liquidation/emergency logic is complete:

- [ ] no ordinary mark-price liquidation is required for a correctly margined account;
- [ ] no maintenance-margin region exists below exact worst-case liability;
- [ ] market-price movement alone cannot make a valid account liquidatable;
- [ ] capped payoff is enforced in settlement and risk math;
- [ ] withdrawals fail before collateral can fall below required margin;
- [ ] hedge unlock fails before protection can be removed unsafely;
- [ ] matured groups settle atomically;
- [ ] stale raw balances cannot trigger false insolvency;
- [ ] Kuru liquidity is not required for settlement;
- [ ] Kuru prices are not liquidation prices;
- [ ] external premiums are not margin;
- [ ] stablecoins are isolated;
- [ ] stablecoin depeg does not silently trigger cross-stablecoin conversion;
- [ ] oracle outage before expiry does not alter exact active margin;
- [ ] expiry oracle failure leaves group unsettled rather than inventing a price;
- [ ] negative post-sync cash is treated as an incident;
- [ ] unrelated healthy accounts cannot be seized;
- [ ] emergency pause cannot rewrite option economics;
- [ ] risk-reducing actions remain available where safely possible;
- [ ] any future undercollateralized leverage mode is technically and spec-wise separate.

---

# Part XXIII — Canonical core-V2 flow

Normal operation:

```text
WRITER DEPOSITS PAIR STABLECOIN
                |
                v
      WRITE CAPPED OPTION
                |
                v
 EXACT WORST-CASE MARGIN CHECK
                |
        +-------+-------+
        |               |
    sufficient      insufficient
        |               |
        v               v
    mint long          revert
    record short
        |
        v
  optional Kuru trade
        |
        v
 writer may deposit more /
 lock hedge /
 buy back and close
        |
        v
             EXPIRY
                |
                v
      FINAL SETTLEMENT PRICE
                |
                v
  ATOMIC RISK-GROUP SETTLEMENT
                |
                v
   RELEASE REMAINING FREE CASH
```

There is deliberately no normal stage:

```text
price moves
-> health factor falls
-> liquidator races market
```

because core V2 funds the bounded worst-case obligation before the short is created.

---

# Part XXIV — Canonical emergency flow

Exceptional incident:

```text
INVARIANT / INFRASTRUCTURE FAILURE DETECTED
                    |
                    v
             RESTRICT RISK
                    |
        +-----------+-----------+
        |                       |
        v                       v
 preserve safe             block unsafe
 risk reduction            risk increase
        |                       |
        +-----------+-----------+
                    |
                    v
       RECOMPUTE / RECONCILE STATE
                    |
          +---------+---------+
          |                   |
          v                   v
      health restored      unresolved
          |                   |
          v                   v
      clear restriction   scoped emergency /
                          migration / recovery
```

At no point should ordinary emergency handling automatically:

```text
rewrite buyer payoff
seize unrelated accounts
cross-convert stablecoins
invent a settlement price
```

---

# Part XXV — Final principle

Optara V2's liquidation design can be summarized in one sentence:

> **The protocol should prevent ordinary liquidations by requiring the writer's pair-specific stablecoin collateral and locked hedges to cover the exact worst-case capped liability before the position is allowed to exist.**

Therefore:

```text
Core V2 liquidation
=
exception handling

not
normal market-risk management
```

A future version may choose undercollateralized leverage and true liquidations, but that is a different risk architecture and must be specified, implemented, tested, and audited separately.
