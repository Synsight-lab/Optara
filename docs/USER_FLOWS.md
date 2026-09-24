# Optara V2 — User Flows

**Document type:** Normative product and protocol interaction flows  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Engineering specification; examples are illustrative unless marked normative

---

## 1. Purpose

This document explains Optara V2 through end-to-end user flows.

It is intended for:

```text
smart-contract engineers
frontend engineers
indexer engineers
AI coding agents
auditors
market makers
product designers
```

Each flow identifies:

```text
actors
preconditions
assets
protocol calls
state changes
margin effects
Kuru effects
settlement effects
failure conditions
```

The examples preserve the core rule:

> Each option pair defines its own approved stablecoin as quote, collateral, premium denomination, and settlement asset.

Optara is not USDC-based.

---

## 1.1 Interaction-layer convention

The flows below describe economic/protocol actions. The recommended application implementation is:

```text
Optara-only action:
User -> @optara/sdk -> Optara contract

Risk/margin preview:
User/App -> @optara/sdk -> @optara/math and/or on-chain reads
                         -> advisory result

Kuru action:
User -> @optara/kuru -> Kuru

Kuru + Optara workflow:
User -> @optara/kuru -> Kuru
                     -> actual asset custody
                     -> @optara/sdk -> Optara contract
```

At every safety-critical step, the contract recomputes/validates canonical state. SDK previews do not reserve margin and may become stale.

# 2. Core actors

## Alice — writer / seller

Alice may:

```text
deposit pair stablecoin
write options
sell long tokens
lock hedge longs
close shorts
withdraw free collateral
```

---

## Bob — buyer

Bob may:

```text
buy long option
hold it
resell it
lock it as hedge for his own short
redeem it after settlement
```

---

## Carol — second writer / hedge provider

Carol may write another series that Alice buys as a hedge.

---

## Dave — secondary buyer

Dave may buy Bob's long before expiry and become the final holder.

---

## Market maker

A market maker provides:

```text
option-token inventory
settlement-stablecoin inventory
Kuru bids/asks
```

Their Kuru balances remain outside Optara margin.

---

## Keeper

A keeper may trigger deterministic:

```text
risk-group finalization
account-group synchronization
```

where permissionless.

The keeper does not choose settlement economics.

---

## Governance / series creator

For MVP:

```text
approves pair
approves oracle config
creates/allows series
controls scoped pauses
```

Cannot rewrite existing series economics.

---

## SDK / integration layers

These are software layers, not financial counterparties.

### `@optara/sdk`

Used for:

```text
series/account reads
margin previews
transaction construction
write/close/lock/unlock/withdraw/sync/redeem helpers
event decoding
```

### `@optara/math`

Used for deterministic off-chain/reference calculations and testing.

### `@optara/kuru`

Used for Kuru-specific:

```text
market discovery/validation
buy/sell
inventory movement
buy-to-close orchestration
market-maker helpers
```

None of these packages can create authoritative margin, collateral, settlement, or position state by themselves.

# Part I — Series and market creation

## 3. Flow A — Approve MON/USDT pair

Assume Optara wants:

```text
MON / USDT
```

Governance validates:

```text
MON supported as underlying
USDT approved settlement stablecoin
USDT token behavior acceptable
MON/USDT oracle path available
position/series limits configured
```

State:

```text
Pair MON/USDT:
UNAPPROVED -> ENABLED
```

No USDC is involved.

---

## 4. Flow B — Approve oracle configuration

Example:

```text
oracleConfigId = MON_USDT_EXPIRY_V1
```

It commits to:

```text
MON priced in USDT units
feed path
decimals
staleness rules
expiry observation rule
fallback
finality
rounding
```

State:

```text
UNAPPROVED
->
APPROVED_FOR_NEW_SERIES
```

---

## 5. Flow C — Create capped call series

Create:

```text
Pair          = MON/USDT
Type          = CALL
Strike        = 10 USDT/MON
Cap           = 5 USDT/MON
Contract size = 1 MON per option
Expiry        = T
Oracle config = MON_USDT_EXPIRY_V1
```

Series identity becomes immutable.

Long token:

```text
oMON-USDT-10C-C5-T
```

Series state:

```text
NOT_CREATED -> ACTIVE
```

---

## 6. Flow D — Create Kuru secondary market

After the long token exists, the application may use `@optara/kuru` to validate/discover or create the venue market using the current Kuru interfaces:

```text
Kuru Base  = oMON-USDT-10C-C5-T
Kuru Quote = USDT
```

Market parameters are configured for:

```text
token decimals
premium precision
tick size
min order
max order
```

This Kuru market is integration metadata.

Changing/replacing it does not change the Optara series.

---

# Part II — Writer creates and sells an option

## 7. Flow E — Alice writes one unhedged call

Series:

```text
MON/USDT
K = 10
C = 5
CS = 1
Q = 1
```

Maximum liability:

```text
5 USDT
```

Assume zero safety buffer for example simplicity.

Alice deposits:

```text
5 USDT
```

Optara:

```text
Alice cash[USDT] = 5
```

Alice's application may first call an SDK preview:

```text
@optara/sdk.previewWrite(seriesId, 1)
```

Then Alice submits the actual contract transaction:

```text
write(seriesId, 1, Alice)
```

The preview is advisory; the contract recomputes the exact post-write margin from current state.

RiskEngine evaluates:

```text
WorstCaseLoss = 5 USDT
RequiredMargin = 5 USDT
```

Check:

```text
5 >= 5
```

Write succeeds.

State:

```text
Alice shortQty[series] = 1
Long supply = 1
Alice owns 1 long token
```

---

## 8. Flow F — Alice lists the long on Kuru

Alice's application may use `@optara/kuru` to move the long token through the required Kuru trading path and submit the sale. The package is only a client/orchestration layer; the token must actually enter the Kuru custody/trading path.

She lists:

```text
1 option @ 0.70 USDT
```

Bob buys it.

After Kuru trade:

```text
Bob owns economic long claim
Alice receives 0.70 USDT in Kuru trading/accounting domain
```

Optara remains:

```text
Alice short = 1
Alice Optara cash = 5 USDT
RequiredMargin = 5 USDT
```

The Kuru premium is not automatically Optara collateral.

---

## 9. Flow G — Alice deposits her Kuru proceeds into Optara

Alice obtains the 0.70 USDT from Kuru and deposits it into Optara.

Now:

```text
Alice cash[USDT] = 5.70
RequiredMargin   = 5.00
FreeCollateral   = 0.70
```

Alice may withdraw the 0.70 again if no other obligation requires it.

The option's required margin remains 5.

---

# Part III — Buyer lifecycle

## 10. Flow H — Bob holds to expiry

Bob buys:

```text
1 oMON-USDT-10C-C5-T
```

Bob needs no writer margin.

His maximum contractual gross payout:

```text
5 USDT
```

His economic max loss from acquisition:

```text
premium paid
```

If Bob paid:

```text
0.70 USDT
```

then:

```text
BuyerPnL
=
final option payout - 0.70
```

ignoring trading fees.

---

## 11. Flow I — Bob resells to Dave

Before expiry, Bob sells the same token to Dave on Kuru.

After trade:

```text
Bob no longer owns the token
Dave owns the token
```

Alice remains the writer.

At final settlement, Dave — not Bob — owns the surviving claim.

Optara does not care what price Bob or Dave traded at.

---

# Part IV — Writer closes before expiry

## 12. Flow J — Alice buys back her own series

Alice wants to exit early.

Her application may use `@optara/kuru.buyToClose`-style orchestration to buy:

```text
1 exact same-series long
```

on Kuru. The Kuru purchase is still an external trade; Optara state does not change until the actual long is available for `closeShort()`.

Kuru trade succeeds.

At this point:

```text
Alice still has Optara short = 1
```

because buying on Kuru is not an Optara close.

---

## 13. Flow K — Alice closes the short

Alice obtains custody of the long. `@optara/sdk` may build the close transaction, but the canonical call is:

```text
closeShort(seriesId, 1, EXTERNAL)
```

Optara:

```text
receives/controls the long
burns 1 long
decreases Alice short by 1
```

Result:

```text
shortQty = 0
long supply reduced by 1
RequiredMargin for this position = 0
```

Alice's previously encumbered collateral becomes free, subject to other positions.

---

# Part V — Hedged writer / portfolio margin

## 14. Flow L — Alice writes lower-strike call

Alice writes:

```text
SHORT:
MON/USDT call
K=10
C=5
CS=1
Q=1
```

Standalone worst-case:

```text
5 USDT
```

---

## 15. Flow M — Carol writes Alice a higher-strike hedge

Carol writes:

```text
MON/USDT call
K=12
C=3
same expiry
same oracleConfigId
CS=1
Q=1
```

Carol must separately satisfy her own Optara margin.

Alice buys/obtains this long.

---

## 16. Flow N — Alice locks the hedge

Alice may use the SDK to build the transaction, then the contract executes:

```text
lockLong(K12Series, 1)
```

Optara takes custody.

Alice's risk group:

```text
SHORT K10 C5
LOCKED LONG K12 C3
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
S=0  -> 0
S=10 -> 0
S=12 -> 2
S=15 -> 2
```

Exact worst-case:

```text
2 USDT
```

Required margin falls:

```text
5 -> 2 USDT
```

Alice may withdraw up to:

```text
3 USDT
```

from previously encumbered cash, subject to buffers/rounding.

---

## 17. Flow O — Alice wants to sell the hedge

Alice requests:

```text
unlockLong(K12Series, 1)
```

RiskEngine simulates without the hedge.

Post-unlock requirement returns to:

```text
5 USDT
```

If Alice only has:

```text
2 USDT
```

cash left:

```text
2 < 5
```

Unlock reverts.

If Alice first deposits 3 more USDT:

```text
cash = 5
```

then unlock may succeed.

After release, she can trade the token on Kuru.

---

# Part VI — Put example

## 18. Flow P — Carol writes a capped put

Series:

```text
MON/USDT
Type = PUT
K = 10
C = 4
CS = 1
Q = 1
```

Payoff:

```text
min(max(10-S,0),4)
```

Maximum liability:

```text
4 USDT
```

Carol needs approximately:

```text
4 USDT
```

of Optara USDT margin if unhedged.

If MON settles:

```text
S=9 -> 1 USDT
S=7 -> 3 USDT
S=6 -> 4 USDT
S=0 -> 4 USDT
```

No payout exceeds the cap.

---

# Part VII — Same stablecoin, different risk groups

## 19. Flow Q — Alice has MON/USDT and ETH/USDT shorts

Suppose:

```text
MON/USDT group margin = 5 USDT
ETH/USDT group margin = 8 USDT
```

These groups do not net option payoffs.

But both use the same cash asset.

Therefore:

```text
RequiredMargin(Alice, USDT)
=
5 + 8
=
13 USDT
```

Alice can hold one:

```text
13 USDT
```

Optara balance to secure both groups.

---

# Part VIII — Different stablecoins are isolated

## 20. Flow R — Alice has MON/USDT and ETH/USDC

Requirements:

```text
MON/USDT = 5 USDT
ETH/USDC = 20 USDC
```

Alice has:

```text
1000 USDT
10 USDC
```

The ETH/USDC side is still insufficient.

Optara must not say:

```text
1000 USDT is enough total value
```

Instead:

```text
USDT domain -> healthy
USDC domain -> insufficient for new risk / restricted if impossible legacy state
```

Core V2 performs no automatic conversion.

---

# Part IX — Expiry and settlement

## 21. Flow S — Call expires out of the money

Series:

```text
MON/USDT
K=10
C=5
```

Final:

```text
S*=8
```

Payoff:

```text
0
```

Alice writer group sync:

```text
short debit = 0
```

Bob/Dave long redemption:

```text
long burned
payout = 0
```

Writer's encumbered margin becomes free after synchronization/active-group removal.

---

## 22. Flow T — Call settles inside cap

Same series.

Final:

```text
S*=13
```

Payoff:

```text
13 - 10 = 3 USDT
```

Long holder redeems:

```text
3 USDT
```

Writer's group settlement charges:

```text
3 USDT
```

subject to rounding rules.

Remaining collateral becomes free.

---

## 23. Flow U — Call settles above cap

Final:

```text
S*=100
```

Uncapped intrinsic would be:

```text
90
```

but contractual payout is:

```text
min(90, 5) = 5 USDT
```

The holder receives:

```text
5 USDT
```

not 90.

The writer's maximum obligation was already funded.

No liquidation race is needed.

---

# Part X — Atomic hedged expiry

## 24. Flow V — Hedged writer reaches expiry

Alice:

```text
cash = 2 USDT

SHORT K10 C5
LOCKED LONG K12 C3
```

Final settlement:

```text
S*=20
```

Short payout:

```text
5
```

Locked long payout:

```text
3
```

Atomic account-group delta:

```text
Delta = 3 - 5 = -2
```

Apply once:

```text
cash' = 2 - 2 = 0
```

Consume:

```text
short position
locked long token
```

Alice is solvent.

Incorrect implementation:

```text
debit 5 first
-> report -3
-> attempt liquidation
-> credit hedge later
```

must never occur.

---

# Part XI — Holder redemption while writer is not yet synced

## 25. Flow W — Dave redeems before Alice calls sync

Assume group is finalized.

Dave holds external long.

Alice has not yet called:

```text
syncRiskGroup
```

Dave may still redeem because:

```text
writer collateral is already physically in vault
Alice's matured debt remains encumbered
Alice cannot withdraw around unsynchronized debt
```

Dave's redemption:

```text
burn long
transfer settlement stablecoin
```

Alice later syncing must update her internal account exactly once.

The system's per-stablecoin pooled accounting must conserve value.

---

# Part XII — Long remains on Kuru at expiry

## 26. Flow X — Bob's token is still in Kuru custody

Bob has a Kuru trading balance representing the option.

Optara cannot simply redeem:

```text
Bob's Kuru internal balance
```

as though Bob's wallet held the ERC-20.

Bob may use `@optara/kuru` to initiate the venue-specific withdrawal, but the required economic result is still:

```text
withdraw/transfer actual option token from Kuru
```

into a redeemable custody path.

Then:

```text
redeem()
```

burns the actual token.

`@optara/kuru` may automate the venue-specific withdrawal steps, and a future on-chain router may combine steps where supported, but neither may skip actual token custody or the burn required by Optara.

---

# Part XIII — Withdrawal with matured unsynchronized group

## 27. Flow Y — Alice tries to withdraw stale cash

Alice raw ledger shows:

```text
10 USDT
```

but a finalized unsynchronized group has:

```text
Delta = -4 USDT
```

Effective cash:

```text
6 USDT
```

Alice requests:

```text
withdraw 8 USDT
```

Optara must first synchronize the finalized group.

After sync:

```text
cash = 6
```

Withdrawal of 8 fails.

This prevents matured debt from being ignored.

---

# Part XIV — Oracle flows

## 28. Flow Z — Direct MON/USDT feed

At expiry, oracle adapter obtains a valid:

```text
MON price expressed directly in USDT
```

Normalizes decimals.

Risk group finalizes one:

```text
S*
```

Every series in the group uses the same value.

---

## 29. Flow AA — Derived MON/USDT feed

Suppose there is no direct feed.

Precommitted config uses:

```text
MON/USDT
=
MON/USD
/
USDT/USD
```

If:

```text
MON/USD = 12.00
USDT/USD = 0.96
```

then:

```text
MON/USDT = 12 / 0.96 = 12.5 USDT per MON
```

Optara must use the derived pair value.

It must not pretend:

```text
MON/USD = MON/USDT
```

---

## 30. Flow AB — Oracle unavailable at expiry

If no valid price can be finalized:

```text
EXPIRED_UNSETTLED
```

persists.

No arbitrary price.

No redemption yet.

No writer settlement yet.

Use only the precommitted fallback process. Meanwhile the recovery actions in
section 50 remain available (cancellation with an identical long, safe unlock,
free-cash withdrawal), and the group is flagged `ORACLE_STALLED` after the
configured escalation deadline.

---

# Part XV — Kuru outage

## 31. Flow AC — Kuru unavailable before expiry

Alice cannot easily buy back.

Bob cannot easily resell.

But:

```text
Alice collateral remains in Optara
option terms remain unchanged
RiskEngine remains deterministic
```

At expiry, Optara can still settle.

Kuru outage is a liquidity problem, not an Optara solvency failure.

---

# Part XVI — Stablecoin incident

## 32. Flow AD — USDT depegs externally

Existing:

```text
MON/USDT options
```

remain denominated in:

```text
USDT
```

If USDT transfers function correctly:

```text
USDT backs USDT obligation
```

so writer unit solvency is not automatically broken.

Governance may disable:

```text
new MON/USDT series
new USDT risk
```

but cannot silently convert outstanding claims to USDC.

---

## 33. Flow AE — settlement stablecoin transfer failure

If the settlement token itself becomes operationally unusable:

```text
new risk -> disable
unsafe withdrawals -> pause
```

Accounting may continue where safe.

Redemption transfers may need to wait for token functionality.

Do not substitute another stablecoin automatically.

---

# Part XVII — Abnormal account deficit

## 34. Flow AF — invariant breach detected

Suppose test/reconciliation finds:

```text
cash < requiredMargin
```

This should not occur from normal market movement.

Possible causes:

```text
bug
custody loss
rounding issue
corrupt state
unsupported token behavior
```

Protocol response:

```text
restrict the whole settlement asset (checkAndRestrict / restrictAsset)
block new risk, withdrawals, redemptions and ordinary deposits in that asset
preserve cure deposits, recapitalization, hedge locks, closes and sync
investigate/reconcile
then: clear the restriction if backing is intact, or
      resolve the verified shortfall with one uniform ratio (LIQUIDATION.md §102)
```

Do not liquidate at arbitrary market price.

---

# Part XVIII — Writer with multiple settlement assets

## 35. Flow AG — one wallet, several margin domains

Alice may have:

```text
cash[USDT] = 20
cash[USDC] = 50
cash[USDe] = 30
```

Her account is one logical user but three independent settlement-asset risk ledgers.

A USDT withdrawal only checks groups settled in USDT, after synchronizing finalized USDT groups.

A USDC deficit cannot be cured by her USDT unless a future explicitly specified cross-collateral feature exists.

---

# Part XIX — Market maker flow

## 36. Flow AH — market maker supplies Kuru option liquidity

MM first obtains:

```text
option-token inventory
+
settlement stablecoin
```

through valid sources.

MM deposits/trades them in Kuru.

The MM may place:

```text
bids
asks
```

If MM wrote the option tokens themselves:

```text
their Optara short remains margined independently
```

Kuru quote/base balances do not secure that short.

---

# Part XX — Primary-sale adapter flow

## 37. Flow AI — Payment against delivery

The MVP primary sale uses already minted inventory:

```text
writer funds its account and writes long tokens
-> writer offers actual inventory on a verified venue / atomic exchange
-> buyer payment and delivery of the exact long token execute atomically
```

The SDK MUST NOT describe payment to the writer followed by a separate write as a
safe or trustless sale. If the writer stops, expires, or fails its margin check,
a previous payment transaction cannot be rolled back by the SDK.

A future primary-sale contract MAY combine buyer payment, an authorized writer
account deposit/write, and delivery in one transaction. It MUST bind chain,
contract, writer, buyer/recipient, series, quantity, premium, maximum fee, deadline,
and nonce to the required user authorization. All legs revert on any failure.
ERC-20 allowance alone does not authorize writing against someone else's account.
Until such an account-authorization interface is specified and audited, this router
is not an MVP workflow. Escrow variants require explicit refunds and cancellation;
direct prepaid OTC transfers carry counterparty risk and are outside the safe flow.

---


# Part XXI — Covered economic intuition without underlying collateral

## 38. Flow AJ — why Carol does not deposit MON

Carol writes:

```text
MON/USDT call
K=12
C=5
```

Optara promises a maximum:

```text
5 USDT
```

not delivery of MON.

Therefore Carol secures:

```text
USDT-denominated liability
```

with USDT.

She may separately own MON or hedge on Kuru, but external MON does not become core Optara margin.

---

# Part XXII — User-facing summaries

## 39. Writer summary

```text
1. choose option series
2. deposit that pair's stablecoin
3. Optara computes exact worst-case portfolio margin
4. write option
5. receive long token
6. optionally sell long on Kuru
7. optionally deposit sale proceeds back into Optara
8. optionally lock hedge / buy back and close
9. at expiry, group settles
10. withdraw remaining free collateral
```

---

## 40. Buyer summary

```text
1. find series
2. inspect pair, strike, cap, expiry
3. buy long token on Kuru
4. hold / resell / transfer
5. at expiry, wait for oracle finalization
6. obtain actual token custody if held externally
7. redeem from Optara
```

---

## 41. Hedged-writer summary

```text
1. write short
2. acquire compatible long
3. lock long in Optara
4. RiskEngine recomputes exact worst case
5. margin may fall
6. withdraw only true free collateral
7. cannot sell locked hedge unless account remains safe after unlock
8. mature group settles atomically
```

---

## 41A. Developer/integrator summary

```text
Use @optara/math
    for deterministic reference calculations and local previews.

Use @optara/sdk
    for Optara reads and transaction construction.

Use @optara/kuru
    only for Kuru-specific market/trading workflows.

Never assume an SDK preview or Kuru fill changed Optara state
until the corresponding canonical Optara transaction succeeds.
```

# Part XXIII — Failure-condition summary

## 42. Write fails when

```text
series not ACTIVE
pair/new risk disabled
settlement asset restricted or in wind-down
quantity invalid
account position limits exceeded
aggregate exposure cap exceeded
cash < post-write required margin
```

---

## 43. Unlock fails when

```text
requested quantity not locked
group finalized (use atomic settlement)
settlement asset restricted
or
post-unlock cash < required margin
```

---

## 44. Withdraw fails when

```text
amount > cash
finalized groups not safely synchronizable (unfinalized groups remain fully reserved)
post-withdraw cash < required margin
settlement asset restricted (after wind-down, pays floor(rho_A * amount))
asset/token path unsafe
```

---

## 45. Close fails when

```text
no matching short
wrong series token
insufficient long quantity (EXTERNAL) or insufficient own locked quantity (LOCKED)
series no longer ACTIVE (use cancelUnfinalizedShort while expired-unfinalized)
```

---

## 46. Redeem fails when

```text
group not finalized
no actual token custody/approval
quantity invalid
token already burned
settlement asset restricted (after wind-down, pays floor(rho_A * payout))
settlement transfer unavailable
```

---

# Part XXIV — End-to-end canonical example

## 47. Full MON/USDT call lifecycle

### Terms

```text
Underlying    = MON
Stablecoin    = USDT
Type          = CALL
K             = 10
C             = 5
CS            = 1
Expiry        = T
```

### Alice writes

```text
Alice deposits 5 USDT
Alice writes 1
Optara short[Alice] = 1
Long supply = 1
```

### Alice sells

```text
Alice sells long on Kuru for 0.70 USDT
Bob buys
```

Optara:

```text
Alice cash still = 5
Alice short = 1
```

### Bob resells

```text
Bob sells to Dave for 1.20 USDT
Dave owns long
```

### Expiry

Suppose:

```text
MON/USDT final S* = 14
```

Payoff:

```text
min(14-10,5)
=
4 USDT
```

### Dave redeems

```text
burn 1 long
Dave receives 4 USDT
```

### Alice syncs

```text
Alice short debit = 4 USDT
short quantity cleared
```

Alice remaining cash:

```text
5 - 4 = 1 USDT
```

That 1 USDT becomes free, subject to other positions.

### Economics

If Alice received the 0.70 premium and ultimately deposited/kept it economically:

```text
writer trading PnL
=
0.70 - 4.00
=
-3.30 USDT
```

If Dave paid Bob 1.20:

```text
Dave PnL
=
4.00 - 1.20
=
+2.80 USDT
```

These trade PnLs do not change the protocol's contractual settlement accounting.

---

# 48. Canonical system flow diagram

```text
APPLICATION / USER
        |
        v
    @optara/sdk
        |
        v
PAIR + ORACLE APPROVED
        |
        v
SERIES CREATED
        |
        v
WRITER DEPOSITS SERIES STABLECOIN
        |
        v
EXACT POST-WRITE MARGIN CHECK
        |
        v
SHORT RECORDED + LONG ERC-20 MINTED
        |
        v
LONG MAY TRADE ON KURU
OPTION / SERIES-STABLECOIN
        |
        +--------------------------+
        |                          |
        v                          v
BUYER HOLDS/RESELLS        WRITER BUYS BACK
        |                          |
        |                          v
        |                    closeShort()
        |                    burn same long
        |                          |
        v                          v
      EXPIRY                 SHORT CLOSED
        |
        v
ORACLE FINALIZES RISK GROUP
        |
        +--------------------------+
        |                          |
        v                          v
HOLDER REDEEMS           WRITER GROUP SYNCS
burn long                short +/- locked hedge
receive stablecoin       atomic stablecoin delta
        |                          |
        +------------+-------------+
                     |
                     v
             REMAINING CASH FREE
```

---

# 49. Final user-flow principle

Every flow should preserve three separations:

```text
1. option market price
   != contractual payout

2. Kuru trading balance
   != Optara margin balance

3. long-token ownership
   != writer short liability
```

Those separations are fundamental to understanding and implementing Optara correctly.

---

## 50. Oracle-stalled user recovery

If finalization is delayed, display the observation rule, escalation deadline and
unresolved-claim risk. A writer holding the identical long (in its wallet, or as its
own locked hedge selected with the `LOCKED` source) may use `cancelUnfinalizedShort`
until finalization. A user may withdraw proven free cash
and unlock an unfinalized hedge only after the full post-removal risk check.
These operations do not require a guessed price. Once finalized, refresh the flow
to ordinary redemption and atomic group sync. If no approved historical observation
can ever be recovered, unmatched claims may remain unresolved indefinitely.
