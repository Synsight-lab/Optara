# Optara V2 — State Machine Specification

**Document type:** Normative lifecycle and state-transition specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document defines the state machines required to implement Optara V2 safely.

It covers:

- protocol operational state;
- pair approval state;
- oracle-configuration state;
- option-series lifecycle;
- risk-group lifecycle;
- per-account matured-group synchronization;
- short-position lifecycle;
- long-token lifecycle;
- locked-hedge lifecycle;
- per-stablecoin margin-account state;
- withdrawal gating;
- Kuru integration state boundaries;
- emergency/restricted states.

The goal is that every state-changing function has:

```text
allowed source state
preconditions
state effects
allowed destination state
forbidden transitions
```

No implementation agent should infer lifecycle behavior from UI assumptions.

---

# 2. General principles

State transitions MUST preserve:

```text
solvency
series immutability
settlement-stablecoin isolation
supply/short conservation
locked-hedge custody
single settlement finalization
single redemption
atomic matured-group settlement
bounded execution
```

Optara is not USDC-based.

Every series and risk group is bound to its own approved settlement stablecoin.

---

## 2.1 Off-chain packages do not create protocol state

The following may maintain local/cache/UI state:

```text
@optara/math
@optara/sdk
@optara/kuru
frontend
indexer
bots
```

but none of that state is part of the Optara protocol state machine.

For example:

```text
SDK preview says SAFE
```

does not transition an account from one on-chain state to another.

Only successful canonical contract transactions can transition:

```text
series state
short quantity
locked-long quantity
cash ledger
risk-group settlement state
redemption state
```

Applications must treat SDK previews as snapshots that can become stale before execution.

# Part I — Protocol operational state

## 3. Prefer orthogonal safety gates

A single global enum is often too coarse.

Recommended implementation uses independent gates such as:

```text
newRiskEnabled
withdrawalsEnabled
settlementFinalizationEnabled
redemptionEnabled
pairEnabled[pairId]
oracleConfigEnabledForNewRisk[oracleConfigId]
```

This allows the protocol to pause unsafe operations without blocking safe settlement unnecessarily.

---

## 4. Conceptual protocol modes

For documentation, these gates can be understood as:

```text
NORMAL
RISK_PAUSED
SETTLEMENT_PAUSED
ASSET_RESTRICTED
MIGRATION_REQUIRED
```

These modes may overlap in implementation.

---

## 5. NORMAL

Allowed:

```text
deposit
write
lockLong
unlockLong if safe
closeShort
withdraw if safe
finalize valid expired groups
sync finalized groups
redeem
```

---

## 6. RISK_PAUSED

Purpose:

```text
stop creation/removal of risk
while preserving safe reduction
```

Expected:

```text
write                -> blocked
unsafe withdraw      -> blocked
unsafe unlockLong    -> blocked

deposit              -> allowed if token safe
lockLong             -> allowed if path safe
closeShort           -> allowed if path safe
finalize             -> allowed if oracle trusted
sync                  -> allowed if settlement trusted
redeem                -> allowed if settlement/custody trusted
```

---

## 7. SETTLEMENT_PAUSED

Used when settlement correctness is uncertain.

Expected:

```text
finalize             -> blocked
sync affected group  -> blocked
redeem affected series -> blocked
```

New risk using affected oracle SHOULD also be blocked.

Existing active risk remains bounded if RiskEngine/custody remain correct.

---

## 8. MIGRATION_REQUIRED

Used only for exceptional protocol incidents.

No ordinary risk creation.

Migration behavior must be separately specified.

Existing immutable option economics must not be rewritten.

---

# Part II — Pair state

## 9. Pair identity

Conceptually:

```text
pairId
=
(underlying, settlementAsset)
```

Examples:

```text
MON / USDT
ETH / USDC
BTC / USDe
```

---

## 10. Pair states

Recommended:

```text
UNAPPROVED
ENABLED
NEW_RISK_DISABLED
RETIRED
```

---

## 11. UNAPPROVED -> ENABLED

Requires governance approval of:

```text
underlying
settlement stablecoin
token behavior
oracle support
deployment limits
```

Effect:

```text
new series may be created
```

subject to oracle config and factory permissions.

---

## 12. ENABLED -> NEW_RISK_DISABLED

Triggered by:

```text
stablecoin concern
oracle concern
risk-policy change
operational pause
```

Effect:

```text
no new series / new writes as configured
existing series remain economically unchanged
risk-reducing actions remain where safe
```

---

## 13. NEW_RISK_DISABLED -> ENABLED

May occur after remediation.

Must affect future risk only.

No historical option term changes.

---

## 14. -> RETIRED

`RETIRED` means:

```text
no future pair risk
```

Existing series still proceed to settlement/redemption.

Pair retirement must never burn or invalidate outstanding long claims.

---

# Part III — Oracle configuration state

## 15. Oracle config identity

`oracleConfigId` binds:

```text
underlying
settlement stablecoin
provider/feed path
decimal normalization
staleness rules
expiry observation rule
finality rule
fallback rule
rounding
```

---

## 16. Oracle config states

Recommended:

```text
UNAPPROVED
APPROVED_FOR_NEW_SERIES
SUSPENDED_FOR_NEW_SERIES
RETIRED
```

---

## 17. Existing-series immutability

Once a series references:

```text
oracleConfigId = X
```

its settlement contract remains bound to X's precommitted semantics.

Suspending X for future series does not substitute another config into existing options.

---

# Part IV — Series lifecycle

## 18. Series states

Canonical lifecycle:

```text
NOT_CREATED
    |
    | createSeries
    v
ACTIVE
    |
    | block.timestamp >= expiry
    v
EXPIRED_UNSETTLED
    |
    | finalizeRiskGroup / valid settlement
    v
SETTLED
    |
    | all longs consumed and all shorts synced
    v
CLEARED   [derived/optional terminal state]
```

`CLEARED` may be derived rather than stored.

---

## 19. NOT_CREATED

No series/token exists.

No write possible.

---

## 20. NOT_CREATED -> ACTIVE

Requires:

```text
approved pair
approved oracle config
valid type
K > 0
C > 0
put: C <= K
contractSize > 0
future valid expiry
unique economic terms
```

Effects:

```text
series metadata frozen
option token created/bound
seriesId canonicalized
```

---

## 21. ACTIVE

Allowed protocol behavior:

```text
write
transfer long
trade long externally
lock long
unlock long if safe
close short
deposit collateral
withdraw free collateral
```

No settlement redemption yet.

---

## 22. ACTIVE -> EXPIRED_UNSETTLED

Condition:

```text
block.timestamp >= expiry
```

This transition is conceptually time-derived.

Effects:

```text
new writes forbidden
active short close semantics stop unless explicitly supported as matured sync
settlement awaits oracle finalization
long tokens may remain transferable
```

No final payoff exists yet.

---

## 23. EXPIRED_UNSETTLED

Allowed:

```text
finalize according to immutable oracle rule
transfer long if ERC-20 remains transferable
deposit cash
```

Must not:

```text
write new short
invent settlement price
redeem before finalization
mutate strike/cap/expiry
```

---

## 24. EXPIRED_UNSETTLED -> SETTLED

Requires valid finalization of the containing risk group.

Effects:

```text
settlementPrice fixed
payoffPerUnderlying fixed
payoffPerOption derivable/fixed
redemption enabled
writer groups become synchronizable
```

Finalization is one-way.

---

## 25. SETTLED

Allowed:

```text
redeem surviving external longs
sync writer matured groups
transfer long if token design allows
```

No new risk creation.

---

## 26. SETTLED -> CLEARED

Derived condition:

```text
outstandingLongSupply == 0
and
aggregateUnsyncedShortQty == 0
```

Optional state for archival/indexing.

No economic claim remains.

---

## 27. Forbidden series transitions

Never:

```text
SETTLED -> ACTIVE
EXPIRED_UNSETTLED -> ACTIVE
SETTLED -> EXPIRED_UNSETTLED
change settlement asset
change strike
change cap
change expiry
change contract size
change option type
replace oracle semantics
```

---

# Part V — Risk-group lifecycle

## 28. Risk group identity

```text
groupId
=
(
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

All series in one group share one final underlying settlement price.

---

## 29. Risk-group states

```text
ACTIVE_GROUP
EXPIRED_UNSETTLED_GROUP
FINALIZED_GROUP
```

Per-account synchronization is tracked separately.

---

## 30. ACTIVE_GROUP

RiskEngine uses:

```text
exact worst-case loss
```

over all valid settlement prices.

---

## 31. ACTIVE_GROUP -> EXPIRED_UNSETTLED_GROUP

Condition:

```text
timestamp >= expiry
```

No new short positions in any series of the group.

---

## 32. EXPIRED_UNSETTLED_GROUP -> FINALIZED_GROUP

Requires valid immutable oracle rule.

Effect:

```text
one settlementPrice for entire group
```

All series calculate payoff from the same `S*`.

---

## 33. Single finalization invariant

A finalized group must satisfy:

```text
settlementPrice[g] written once
```

No refinalization.

---

# Part VI — Per-account group synchronization

## 34. Account-group states

For each:

```text
(account, groupId)
```

recommended derived states:

```text
NO_POSITION
ACTIVE_POSITION
MATURED_UNFINALIZED
FINALIZED_UNSYNCED
SYNCED
```

---

## 35. NO_POSITION -> ACTIVE_POSITION

Occurs when account:

```text
writes short in group
or
locks long in group
```

---

## 36. ACTIVE_POSITION -> NO_POSITION

Before expiry if all:

```text
short quantities = 0
locked long quantities = 0
```

after valid close/unlock.

---

## 37. ACTIVE_POSITION -> MATURED_UNFINALIZED

When group expires.

No ordinary write/close mutation should bypass settlement rules.

---

## 38. MATURED_UNFINALIZED -> FINALIZED_UNSYNCED

When group finalizes.

The account now has deterministic:

```text
Short*
LockedLong*
Delta = LockedLong* - Short*
```

but ledger quantities may not yet be cleared.

---

## 39. FINALIZED_UNSYNCED -> SYNCED

`syncRiskGroup(account, groupId)` atomically:

```text
compute all short debit
compute all locked-long credit
net in normalized precision
apply one stablecoin cash delta
consume/burn locked longs
clear matured shorts
remove account-group indexes
```

---

## 40. SYNCED terminality

The same account/group must not be synchronized twice.

A no-op idempotent second call MAY return cleanly, but it must never reapply cash delta.

---

# Part VII — Short position lifecycle

## 41. Short states

Per `(account, seriesId)`:

```text
NONE
OPEN
PARTIALLY_OPEN
MATURED_UNSYNCED
CLOSED
SETTLED
```

`PARTIALLY_OPEN` can simply be `OPEN` with quantity > 0.

---

## 42. NONE -> OPEN

Via:

```text
write(seriesId, Q)
```

only when series ACTIVE and post-write margin is safe.

Effects:

```text
shortQty += Q
long supply += Q
```

---

## 43. OPEN -> OPEN with lower quantity

Via:

```text
closeShort(seriesId, q)
```

where:

```text
0 < q < shortQty
```

Requires matching long-token burn.

---

## 44. OPEN -> CLOSED

If:

```text
q == shortQty
```

before expiry.

Matching long quantity burned.

Position removed from active index if no locked long remains in group.

---

## 45. OPEN -> MATURED_UNSYNCED

When series/risk group expires and later finalizes.

The obligation is no longer an uncertain active short.

It becomes deterministic settlement debt.

---

## 46. MATURED_UNSYNCED -> SETTLED

Through account-level `syncRiskGroup`.

Short quantity cleared exactly once.

---

# Part VIII — Long-token lifecycle

## 47. Long economic states

A long token unit may be:

```text
EXTERNAL
LOCKED_IN_OPTARA
CONSUMED_FOR_CLOSE
CONSUMED_AT_INTERNAL_SETTLEMENT
REDEEMED
```

`EXTERNAL` includes:

```text
wallet
Kuru
other compatible external custody
```

Optara does not subdivide external ownership economically.

---

## 48. Mint -> EXTERNAL

On write:

```text
mint Q to recipient
```

The long becomes externally owned unless recipient is an Optara locking adapter with explicit custody flow.

---

## 49. EXTERNAL -> EXTERNAL

Normal ERC-20 transfer:

```text
wallet -> wallet
wallet -> Kuru
Kuru -> wallet
wallet -> other DeFi
```

No Optara margin impact.

---

## 50. EXTERNAL -> LOCKED_IN_OPTARA

Via:

```text
lockLong(seriesId, Q)
```

Requires actual token transfer into Optara-controlled custody.

---

## 51. LOCKED_IN_OPTARA -> EXTERNAL

Via safe unlock.

Precondition:

```text
postUnlock CashBalance >= postUnlock RequiredMargin
```

Token release happens only after successful risk validation.

---

## 52. EXTERNAL -> CONSUMED_FOR_CLOSE

Via:

```text
closeShort
```

Token burned.

Terminal.

---

## 53. LOCKED_IN_OPTARA -> CONSUMED_AT_INTERNAL_SETTLEMENT

When finalized risk group is synchronized.

Long credit is included atomically.

Token quantity burned/consumed.

Terminal.

---

## 54. EXTERNAL -> REDEEMED

After settlement:

```text
redeem(seriesId, Q)
```

burns long and pays settlement stablecoin.

Terminal.

---

## 55. Forbidden long transitions

Never:

```text
LOCKED_IN_OPTARA -> Kuru directly without unlock check
REDEEMED -> EXTERNAL
CONSUMED_FOR_CLOSE -> REDEEMED
CONSUMED_AT_INTERNAL_SETTLEMENT -> REDEEMED
same token quantity locked for two accounts
```

---

# Part IX — Locked hedge lifecycle

## 56. Hedge states

```text
UNLOCKED
LOCKED_ACTIVE
LOCKED_MATURED
CONSUMED
```

---

## 57. UNLOCKED -> LOCKED_ACTIVE

Requires:

```text
actual long token custody
compatible risk group
```

RiskEngine recomputes margin.

---

## 58. LOCKED_ACTIVE -> UNLOCKED

Only before expiry and only when post-unlock account remains safe.

---

## 59. LOCKED_ACTIVE -> LOCKED_MATURED

When group expires/finalizes.

It must no longer be freely unlockable outside matured settlement logic.

---

## 60. LOCKED_MATURED -> CONSUMED

During atomic `syncRiskGroup`.

Its fixed payout contributes to account cash delta.

---

# Part X — Margin-account state per stablecoin

## 61. Why state is per settlement asset

One account may simultaneously have:

```text
USDT obligations
USDC obligations
USDe obligations
```

Health must be determined separately.

---

## 62. Account-asset states

Recommended derived states:

```text
EMPTY
HEALTHY
HAS_MATURED_UNSYNCED
RESTRICTED
```

No routine `UNDERCOLLATERALIZED_BUT_LIQUIDATABLE` state exists in core V2.

---

## 63. EMPTY

```text
cash = 0
requiredMargin = 0
no matured debt
```

---

## 64. HEALTHY

```text
cash >= requiredMargin
```

and all required matured groups are synchronized for safety-sensitive operations.

---

## 65. HAS_MATURED_UNSYNCED

At least one finalized risk group affects the stablecoin ledger but has not yet been applied.

Before withdrawal:

```text
must sync
```

Raw balance alone is not authoritative for free collateral.

---

## 66. RESTRICTED

Exceptional state triggered by:

```text
invariant failure
unprovable health
token/custody incident
risk-engine incident
```

Expected blocks:

```text
write
withdraw
risk-increasing unlock
```

Safe cure actions MAY remain.

---

## 67. RESTRICTED -> HEALTHY

Requires canonical proof:

```text
SafeEffectiveCash >= RequiredMargin
```

after all necessary reconciliation.

---

# Part XI — Deposit state transition

## 68. deposit(asset, amount)

Preconditions:

```text
asset approved/accepted for deposit
amount > 0
token path safe
```

Effects:

```text
vault physical balance += received
account cash balance += received
```

Must use actual supported token semantics.

Deposit cannot create option risk.

---

# Part XII — Write state transition

## 69. write(seriesId, quantity, recipient)

Optional client step:

```text
@optara/sdk.previewWrite(...)
```

This is advisory only. The transaction re-evaluates canonical state on-chain.

Source state:

```text
series ACTIVE
account-asset HEALTHY
new risk enabled
```

Preconditions:

```text
Q > 0
within quantity limits
recipient != zero
position indexes within bounds
```

Simulation:

```text
shortQty' = shortQty + Q
RequiredMargin' = canonical RiskEngine result
```

Require:

```text
CashBalance >= RequiredMargin'
```

Effects:

```text
record short
mint exact long quantity
update indexes
```

---

# Part XIII — Close state transition

## 70. closeShort(seriesId, quantity)

Source:

```text
series ACTIVE
shortQty >= Q
```

Requires actual exact-series long custody/transfer.

Effects atomically:

```text
burn long Q
shortQty -= Q
recompute risk
```

Closing cannot increase exact risk with all else unchanged.

---

# Part XIV — Lock state transition

## 71. lockLong(seriesId, quantity)

Source:

```text
long EXTERNAL
group active
```

Effects:

```text
receive token
lockedLongQty += Q
recompute margin
```

No heuristic hedge credit.

---

# Part XV — Unlock state transition

## 72. unlockLong(seriesId, quantity)

Source:

```text
LOCKED_ACTIVE
```

Simulation:

```text
lockedLongQty' = lockedLongQty - Q
```

Require:

```text
CashBalance >= RequiredMargin'
```

Then:

```text
update state
release token
```

---

# Part XVI — Withdrawal state transition

## 73. withdraw(asset, amount)

Optional client step:

```text
@optara.sdk.previewWithdraw(...)
```

The preview does not reserve collateral or authorize the withdrawal.

Before margin simulation:

```text
sync all relevant finalized-unsynced groups
```

Then:

```text
cash' = cash - amount
```

Require:

```text
cash' >= RequiredMargin
```

Then transfer.

Never transfer first.

---

# Part XVII — Expiry/finalization state transition

## 74. finalizeRiskGroup(groupId)

Source:

```text
EXPIRED_UNSETTLED_GROUP
```

Requires:

```text
valid precommitted oracle/fallback data
finality conditions satisfied
```

Effects:

```text
settlementPrice fixed once
group -> FINALIZED_GROUP
series -> SETTLED
```

No user chooses `S`.

---

# Part XVIII — Synchronization state transition

## 75. syncRiskGroup(account, groupId)

Source:

```text
FINALIZED_UNSYNCED
```

Calculate:

```text
Short*
LockedLong*
Delta = LockedLong* - Short*
```

Apply:

```text
if Delta > 0:
    credit down-converted amount

if Delta < 0:
    debit up-converted amount
```

Consume all matured locked longs and clear all matured shorts in group.

One atomic transition.

---

# Part XIX — Redemption state transition

## 76. redeem(seriesId, quantity, recipient)

Source:

```text
series SETTLED
long EXTERNAL
```

Requires:

```text
Q > 0
holder/approval valid
```

Effects:

```text
calculate fixed payout
burn Q
transfer settlement stablecoin
```

Terminal for burned quantity.

---

# Part XX — Kuru external state boundary

## 77. Kuru is outside Optara state

Optara does not store authoritative Kuru order state. `@optara/kuru` may query/cache that external state for applications, but its local representation is not part of this state machine.

External lifecycle may be:

```text
wallet long
-> Kuru deposit/custody
-> open order
-> filled/cancelled
-> Kuru balance
-> withdrawal
```

Optara cares only when the ERC-20 enters/leaves an Optara-recognized custody path.

---

## 78. Kuru trade cannot transition Optara short

Forbidden shortcut:

```text
Kuru Trade event
-> decrement Optara short
```

A short only changes through Optara's own state transitions.

---

# Part XXI — Emergency/restricted state transitions

## 79. Detect incident -> restrict

If canonical checks discover:

```text
cash < requiredMargin
negative post-sync result
vault/accounting mismatch
risk engine inconsistency
```

the affected scope should transition to:

```text
RESTRICTED / RISK_PAUSED
```

rather than ordinary liquidation.

---

## 80. Restricted operations

Block:

```text
write
withdraw
unsafe unlock
```

Potentially allow:

```text
deposit
lock hedge
close short
trusted sync
```

depending on incident class.

---

## 81. No automatic economic-term mutation

Emergency state never transitions:

```text
Series(K=10,C=5)
->
Series(K=10,C=3)
```

or:

```text
USDT settlement
->
USDC settlement
```

Existing option economics remain immutable.

---

# Part XXII — State transition matrix

## 82. Series/action matrix

| Action | ACTIVE | EXPIRED_UNSETTLED | SETTLED |
|---|---:|---:|---:|
| Write | Yes | No | No |
| Transfer long | Yes | May | May |
| Lock active hedge | Yes | No new active recognition | No |
| Unlock active hedge | If safe | Use matured rules | No separate unlock after credited settlement |
| Close short pre-expiry | Yes | No | No |
| Finalize | No | Yes | No |
| Sync writer group | No | No | Yes |
| Redeem external long | No | No | Yes |

---

## 83. Account/action matrix

| Action | HEALTHY | HAS_MATURED_UNSYNCED | RESTRICTED |
|---|---:|---:|---:|
| Deposit | Yes | Yes | Usually yes if safe |
| Write | Yes | Sync/validate first | No |
| Withdraw | Yes if free | Must sync first | No |
| Lock long | Yes | Depends on group | Usually yes if safe |
| Unlock long | If post-state safe | Matured rules | Usually no |
| Close short | Yes | Active only | Usually yes if safe |
| Sync matured | N/A | Yes | Yes if settlement trusted |

---

# Part XXIII — Required transition invariants

## 84. SM-INV-01

No transition may create:

```text
CashBalance < RequiredMargin
```

for an active healthy account.

---

## 85. SM-INV-02

No transition may reduce:

```text
lockedLongQty
```

before proving post-removal safety.

---

## 86. SM-INV-03

No write without equal long issuance.

---

## 87. SM-INV-04

No pre-expiry short close without equal same-series long consumption.

---

## 88. SM-INV-05

No long redemption without burn.

---

## 89. SM-INV-06

No group finalization more than once.

---

## 90. SM-INV-07

No account/group synchronization more than once economically.

---

## 91. SM-INV-08

No cross-stablecoin state transition may use asset A to repair asset B.

---

## 92. SM-INV-09

No Kuru external state transition is accepted as an Optara accounting transition without actual asset movement/Optara call.

---

## 93. SM-INV-10

No emergency state transition may rewrite immutable series economics.

## 93A. SM-INV-11 — SDK non-authority

No SDK/math/integration preview or cached result can transition canonical protocol state without a successful contract call that independently validates the operation.

---

# Part XXIV — Testing requirements

## 94. Series lifecycle tests

Test:

```text
create -> active
active -> expired
expired -> finalized
finalized cannot refinalize
settled -> cleared derived condition
```

---

## 95. Position lifecycle tests

Test:

```text
write
partial close
full close
expire open short
finalize
sync
```

---

## 96. Long-token lifecycle tests

Test:

```text
mint -> transfer
transfer -> lock
lock -> unlock
external -> close burn
external settled -> redeem burn
locked matured -> internal settlement burn
```

Ensure terminal quantities cannot reappear.

---

## 97. Account state tests

Test:

```text
healthy
matured-unsynced
sync then withdraw
restricted
cure then healthy
```

---

## 98. Forbidden transition fuzzing

Attempt arbitrary action sequences and prove:

```text
no double settlement
no double redemption
no unsafe unlock
no unsafe withdraw
no post-expiry write
no refinalization
no cross-stablecoin repair
```

---

# 98A. Client-to-state-transition model

```text
User / App
    |
    v
@optara/sdk preview/read
    |
    | build transaction
    v
Canonical Optara contract
    |
    | recompute + validate
    +------ revert ------> no state transition
    |
    +------ success -----> canonical state transition

Kuru workflow:
User/App -> @optara/kuru -> Kuru
                         -> actual ERC-20 / stablecoin movement
                         -> @optara/sdk -> Optara contract
                         -> canonical state transition
```

The SDK layer never inserts an additional trusted protocol state between the user and the contracts.

# 99. Canonical state diagram

```text
PAIR
UNAPPROVED
    |
    v
ENABLED <-------> NEW_RISK_DISABLED
    |
    v
RETIRED


SERIES
NOT_CREATED
    |
    v
ACTIVE
    |
    | expiry
    v
EXPIRED_UNSETTLED
    |
    | valid oracle finalization
    v
SETTLED
    |
    | all claims + obligations consumed
    v
CLEARED


ACCOUNT / RISK GROUP
NO_POSITION
    |
    | write / lock
    v
ACTIVE_POSITION
    |
    | expiry
    v
MATURED_UNFINALIZED
    |
    | group finalizes
    v
FINALIZED_UNSYNCED
    |
    | atomic sync
    v
SYNCED


LONG TOKEN
EXTERNAL
  |   \
  |    \ redeem after settlement
  |     -> REDEEMED
  |
  +-> LOCKED_IN_OPTARA
  |       |
  |       +-> UNLOCKED / EXTERNAL
  |       |
  |       +-> CONSUMED_AT_SETTLEMENT
  |
  +-> CONSUMED_FOR_CLOSE
```

---

# 100. Final principle

> **Every Optara state transition must either preserve or reduce contractual risk unless it performs a full post-state margin check before committing.**

The state machine is therefore built around:

```text
immutable claims
bounded liabilities
explicit custody
same-stablecoin accounting
one-way expiry settlement
```
