# Optara V2 — Complete Test Cases

**Document type:** Normative test-case catalog  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Required test inventory for full-system implementation

---

# 1. Purpose

This document is the concrete test inventory for Optara V2.

Every test ID below must be:

```text
implemented
or
explicitly marked NOT-APPLICABLE with engineering justification
```

before production.

The goal is that an AI agent or engineer can implement the complete test suite systematically.

Recommended naming convention:

```text
TC_<AREA>_<NUMBER>_<DESCRIPTION>
```

---

# 2. Required result format

Each implemented test should define:

```text
ID
preconditions
action
expected state
expected balances
expected events
expected revert if negative case
invariants checked
```

---

# Part I — PayoffMath

## PAY-001 — Call below strike

```text
K=10 C=5 S=9
expected payoff=0
```

## PAY-002 — Call at strike

```text
S=10
expected=0
```

## PAY-003 — Call linear region

```text
S=12
expected=2
```

## PAY-004 — Call one unit below cap

```text
S=14
expected=4
```

## PAY-005 — Call at cap boundary

```text
S=15
expected=5
```

## PAY-006 — Call above cap

```text
S=20
expected=5
```

## PAY-007 — Call extreme S

Use largest supported safe price.

Expected payout remains capped.

## PAY-008 — Put above strike

```text
K=10 C=4 S=12
expected=0
```

## PAY-009 — Put at strike

```text
expected=0
```

## PAY-010 — Put linear region

```text
S=8
expected=2
```

## PAY-011 — Put cap boundary

```text
S=6
expected=4
```

## PAY-012 — Put below cap boundary

```text
S=1
expected=4
```

## PAY-013 — Put at zero

```text
S=0
expected=4
```

## PAY-014 — Call cap property fuzz

## PAY-015 — Put cap property fuzz

## PAY-016 — Call monotonicity fuzz

## PAY-017 — Put monotonicity fuzz

## PAY-018 — Call spread-equivalence fuzz

## PAY-019 — Put spread-equivalence fuzz

## PAY-020 — Contract-size scaling

## PAY-021 — Quantity scaling

## PAY-022 — Zero quantity handling

According to implementation, reject or produce zero only in pure math; state-changing quantity must reject zero.

---

# Part II — FixedPointMath

## FIX-001 — mulDivDown exact

## FIX-002 — mulDivDown remainder

## FIX-003 — mulDivUp exact

## FIX-004 — mulDivUp remainder

## FIX-005 — denominator zero revert

## FIX-006 — high operands without overflow

## FIX-007 — WAD to 6 decimals down

## FIX-008 — WAD to 6 decimals up

## FIX-009 — WAD to 18 decimals

## FIX-010 — arbitrary supported token decimals

## FIX-011 — payout down never exceeds exact

## FIX-012 — debit up never understates exact

## FIX-013 — margin up never understates exact

## FIX-014 — split rounding attack fuzz

---

# Part III — SeriesFactory

## SER-001 — Create valid call MON/USDT

## SER-002 — Create valid put MON/USDT

## SER-003 — Create ETH/USDC

## SER-004 — Create BTC/USDe

## SER-005 — Reject zero underlying

## SER-006 — Reject zero settlement asset

## SER-007 — Reject unapproved pair

## SER-008 — Reject zero strike

## SER-009 — Reject zero cap

## SER-010 — Reject zero contract size

## SER-011 — Reject invalid/past expiry

## SER-012 — Reject put cap > strike

## SER-013 — Reject unknown oracle config

## SER-014 — Reject incompatible oracle config pair

## SER-015 — Duplicate tuple returns/rejects duplicate canonical series

## SER-016 — Different strike -> different ID

## SER-017 — Different cap -> different ID

## SER-018 — Different expiry -> different ID

## SER-019 — Different settlement asset -> different ID

## SER-020 — Different oracle config -> different ID

## SER-021 — Economic fields cannot mutate after create

---

# Part IV — OptionToken

## TOK-001 — Correct metadata binding

## TOK-002 — Authorized mint succeeds

## TOK-003 — Unauthorized mint reverts

## TOK-004 — Authorized burn close succeeds

## TOK-005 — Authorized burn redemption succeeds

## TOK-006 — Unauthorized burn reverts

## TOK-007 — Transfer works

## TOK-008 — transferFrom allowance works

## TOK-009 — insufficient allowance reverts

## TOK-010 — supply changes exactly on write

## TOK-011 — supply changes exactly on close

## TOK-012 — supply changes exactly on redemption

## TOK-013 — supply changes exactly on internal hedge settlement

---

# Part V — Risk-group identity

## RGI-001 — Same tuple -> same group

## RGI-002 — Different underlying -> different group

## RGI-003 — Different expiry -> different group

## RGI-004 — Different settlement asset -> different group

## RGI-005 — Different oracleConfigId -> different group

## RGI-006 — Different strike still same group when four group fields match

## RGI-007 — Different cap still same group when group fields match

## RGI-008 — Call and put can share group when four group fields match

---

# Part VI — RiskEngine exactness

## RSK-001 — One unhedged call

Expected max liability.

## RSK-002 — One unhedged put

## RSK-003 — Two shorts same series

## RSK-004 — Multiple strikes calls

## RSK-005 — Multiple strikes puts

## RSK-006 — Mixed calls and puts

## RSK-007 — Short call + higher-strike locked call

Expected exact value.

## RSK-008 — Short put + lower-strike locked put

## RSK-009 — Hedge with zero risk reduction

## RSK-010 — Hedge completely eliminates loss

If constructible under capped terms.

## RSK-011 — Multiple contract sizes

## RSK-012 — Fractional quantities

## RSK-013 — Duplicate critical points

## RSK-014 — Critical point at zero

## RSK-015 — Put K-C zero boundary

## RSK-016 — Add short monotonicity fuzz

## RSK-017 — Close short monotonicity fuzz

## RSK-018 — Add locked long monotonicity fuzz

## RSK-019 — Remove locked long monotonicity fuzz

## RSK-020 — Solidity/reference differential fuzz

## RSK-021 — Dense-grid dominance fuzz

## RSK-022 — Worst case native rounding never below exact

## RSK-023 — Max configured series/group remains executable

---

# Part VII — Margin per asset

## MAR-001 — Single group required margin

## MAR-002 — Two groups same stablecoin sum

## MAR-003 — Different stablecoins isolated

## MAR-004 — USDT surplus cannot cover USDC

## MAR-005 — Free collateral exact

## MAR-006 — Additional collateral exact

## MAR-007 — Coverage ratio monitoring only

## MAR-008 — Zero active risk => zero required margin

## MAR-009 — Safety buffer zero configuration

## MAR-010 — Non-zero safety buffer if feature implemented

---

# Part VIII — Deposit

## DEP-001 — Deposit approved USDT

## DEP-002 — Deposit approved USDC

## DEP-003 — Deposit approved USDe

## DEP-004 — Reject zero amount

## DEP-005 — Reject unsupported asset

## DEP-006 — Exact ledger increase

## DEP-007 — Exact vault balance increase

## DEP-008 — Deposit for one asset does not affect another

## DEP-009 — Reentrant token attempt fails safely

## DEP-010 — Fee-on-transfer token rejected

## DEP-011 — False-return token fails safely

## DEP-012 — Token transfer revert leaves ledger unchanged

---

# Part IX — Write

## WRT-001 — Valid unhedged call write

## WRT-002 — Valid unhedged put write

## WRT-003 — Valid hedged post-write portfolio

## WRT-004 — Reject zero quantity

## WRT-005 — Reject unknown series

## WRT-006 — Reject expired series

## WRT-007 — Reject paused new risk

## WRT-008 — Reject invalid recipient

## WRT-009 — Reject insufficient same-asset cash

## WRT-010 — Ignore huge different-stablecoin balance

## WRT-011 — Reject group-position limit + 1

## WRT-012 — Short quantity increases exactly

## WRT-013 — Long supply increases exactly

## WRT-014 — Mint recipient receives exact quantity

## WRT-015 — Account remains safe after write

## WRT-016 — Revert leaves all state unchanged

## WRT-017 — External expected premium not counted

## WRT-018 — SDK preview stale cannot bypass execution check

---

# Part X — Lock long

## LCK-001 — Lock compatible long

## LCK-002 — Custody balance increases

## LCK-003 — lockedLongQty increases

## LCK-004 — Required margin decreases where expected

## LCK-005 — Required margin unchanged if hedge irrelevant

## LCK-006 — Reject zero quantity

## LCK-007 — Reject insufficient ownership/allowance

## LCK-008 — External Kuru balance alone gets no credit

## LCK-009 — Wallet-held long alone gets no credit

## LCK-010 — Same token cannot be locked twice

---

# Part XI — Unlock long

## ULK-001 — Safe unlock

## ULK-002 — Unsafe unlock reverts

## ULK-003 — Token not transferred before safety check

## ULK-004 — Deposit then unlock succeeds

## ULK-005 — Partial unlock

## ULK-006 — Reject amount > locked

## ULK-007 — Matured hedge uses settlement path instead

## ULK-008 — Required margin monotonic after removal

---

# Part XII — Close short

## CLS-001 — Partial close

## CLS-002 — Full close

## CLS-003 — Same-series long required

## CLS-004 — Wrong strike series rejected

## CLS-005 — Wrong cap series rejected

## CLS-006 — Wrong expiry series rejected

## CLS-007 — Quantity > short rejected

## CLS-008 — Zero quantity rejected

## CLS-009 — Long burned exactly

## CLS-010 — Short reduced exactly

## CLS-011 — Margin does not increase

## CLS-012 — Released cash becomes free

## CLS-013 — Kuru fill alone changes nothing

## CLS-014 — Bought long then actual close succeeds

---

# Part XIII — Withdrawal

## WDW-001 — Withdraw free collateral

## WDW-002 — Withdraw exact max free collateral

## WDW-003 — Withdraw 1 unit above free reverts

## WDW-004 — Reject zero if implementation disallows zero

## WDW-005 — Wrong asset balance cannot help

## WDW-006 — Recipient gets exact token amount

## WDW-007 — Ledger reduces exactly

## WDW-008 — Reentrancy attempt blocked

## WDW-009 — Token transfer revert restores state

## WDW-010 — Matured debt synchronized first

## WDW-011 — Matured locked credit synchronized first

## WDW-012 — Caller cannot omit matured position

## WDW-013 — Post-withdraw invariant holds

---

# Part XIV — Oracle config

## ORC-001 — Register valid direct config

## ORC-002 — Register valid derived config

## ORC-003 — Reject zero/invalid source

## ORC-004 — Reject mismatched underlying

## ORC-005 — Reject mismatched settlement asset

## ORC-006 — Suspend config for new series

## ORC-007 — Existing series remains bound

## ORC-008 — Config semantics immutable for existing series

---

# Part XV — Oracle normalization

## ORN-001 — Direct 8 decimals to WAD

## ORN-002 — Direct 18 decimals to WAD

## ORN-003 — Derived stablecoin at 1.00

## ORN-004 — Derived stablecoin depeg 0.96

## ORN-005 — Derived stablecoin > 1

## ORN-006 — Zero stablecoin price rejected

## ORN-007 — Negative provider price rejected

## ORN-008 — Stale source rejected

## ORN-009 — Wrong observation time rejected

## ORN-010 — Confidence too wide rejected

## ORN-011 — Compatible timestamps accepted

## ORN-012 — Incompatible derived timestamps rejected

---

# Part XVI — Risk-group finalization

## FIN-001 — Before expiry revert

## FIN-002 — At expiry but before finality delay revert

## FIN-003 — Earliest valid finalization succeeds

## FIN-004 — Invalid oracle data reverts

## FIN-005 — Correct S stored

## FIN-006 — group finalizedAt stored

## FIN-007 — second finalization cannot change S

## FIN-008 — different caller same valid data cannot change economics

## FIN-009 — all series share S

## FIN-010 — fallback primary fail/secondary valid

## FIN-011 — both invalid stays unsettled

## FIN-012 — governance cannot set ad hoc S

---

# Part XVII — Redemption

## RED-001 — ITM call redeem

## RED-002 — capped call redeem

## RED-003 — OTM call zero payout burn

## RED-004 — ITM put redeem

## RED-005 — capped put redeem

## RED-006 — OTM put zero payout burn

## RED-007 — before finalization revert

## RED-008 — quantity > balance revert

## RED-009 — unauthorized spender revert

## RED-010 — burn exact quantity

## RED-011 — pay exact settlement asset

## RED-012 — payout rounded down

## RED-013 — double redemption impossible

## RED-014 — transfer settled token then new owner redeems

## RED-015 — prior owner cannot redeem after transfer

## RED-016 — Kuru-held internal balance not synthetically redeemable

---

# Part XVIII — Account group sync

## SYN-001 — Short-only group

## SYN-002 — Locked-long-only group if valid account state exists

## SYN-003 — Short + locked long atomic net

## SYN-004 — cash=2 short=5 long=3 -> cash=0

## SYN-005 — positive delta rounds down

## SYN-006 — negative delta rounds up

## SYN-007 — before finalization revert

## SYN-008 — complete group enumeration

## SYN-009 — partial caller list cannot alter result

## SYN-010 — locked longs consumed

## SYN-011 — shorts cleared

## SYN-012 — indexes updated

## SYN-013 — second sync no economic effect

## SYN-014 — permissionless caller cannot redirect value

---

# Part XIX — Asynchronous settlement ordering

## ASY-001 — Redeem then writer sync

## ASY-002 — Writer sync then redeem

## ASY-003 — Two redeemers then writer sync

## ASY-004 — Writer1 sync, redeem, writer2 sync

## ASY-005 — Arbitrary permutation property

For equivalent initial/final claim set, resulting economic state must match modulo rounding reserve.

## ASY-006 — Outstanding claims decreases on redemption

## ASY-007 — Effective account claims reconcile before sync

## ASY-008 — Writer cannot withdraw around unsynced debt

---

# Part XX — Supply identities

## SUP-001 — Cumulative minted equals cumulative short created

## SUP-002 — Pre-expiry supply equals open short qty

## SUP-003 — Lock does not change long supply

## SUP-004 — Transfer does not change supply

## SUP-005 — Close reduces supply and short equally

## SUP-006 — Redemption reduces supply only

## SUP-007 — Internal locked settlement reduces supply

## SUP-008 — Post-expiry cumulative long identity

## SUP-009 — Post-expiry cumulative short identity

## SUP-010 — Fully settled terminal identity

---

# Part XXI — Vault accounting

## VLT-001 — Deposit identity

## VLT-002 — Withdrawal identity

## VLT-003 — Redemption identity

## VLT-004 — Writer sync identity

## VLT-005 — Fee-free protocolOwnedBalance=0

## VLT-006 — RoundingReserve nonnegative

## VLT-007 — USDT identity independent from USDC

## VLT-008 — Interleaving settlement identity invariant

## VLT-009 — Unauthorized rescue cannot sweep user claims

---

# Part XXII — Fees

## FEE-001 — All MVP Optara fees zero

## FEE-002 — Kuru fee does not change Optara payout

## FEE-003 — Oracle update fee not deducted from payout

If optional issuance fee code exists:

## FEE-004 — Gross max payout fee base

## FEE-005 — Same settlement asset

## FEE-006 — Round up

## FEE-007 — Cannot consume required margin

## FEE-008 — maxFee protection

## FEE-009 — protocolOwnedBalance segregation

## FEE-010 — treasury cannot withdraw above owned balance

---

# Part XXIII — Pause and emergency

## PAU-001 — Pause new writes

## PAU-002 — Deposit remains available when safe

## PAU-003 — Close remains available when safe

## PAU-004 — Lock remains available when safe

## PAU-005 — Unsafe withdrawal blocked

## PAU-006 — Settlement pause blocks finalization

## PAU-007 — Unaffected pair remains operational under scoped pause

## PAU-008 — Pauser cannot change strike/cap

## PAU-009 — Pauser cannot transfer collateral

---

# Part XXIV — Access control

## ACL-001 — User cannot mint directly

## ACL-002 — User cannot vault-transfer directly

## ACL-003 — User cannot upgrade

## ACL-004 — Keeper cannot mint

## ACL-005 — Keeper cannot set price

## ACL-006 — Pauser cannot mint

## ACL-007 — Config admin cannot move collateral

## ACL-008 — Series creator cannot bypass approved pair

## ACL-009 — Series creator cannot bypass oracle approval

## ACL-010 — Governance cannot mutate existing series through ordinary API

## ACL-011 — Governance cannot overwrite final settlement

## ACL-012 — SDK has no role

## ACL-013 — Kuru has no role

## ACL-014 — Frontend has no role

## ACL-015 — Operational role cannot self-escalate

## ACL-016 — Role revoke effective immediately according to transaction ordering

## ACL-017 — Unpause authorization correct

## ACL-018 — Internal role only assigned to canonical contracts

---

# Part XXV — Upgradeability, if used

## UPG-001 — Unauthorized upgrade reverts

## UPG-002 — Authorized timelocked upgrade succeeds

## UPG-003 — Double initialize reverts

## UPG-004 — Implementation cannot initialize proxy state incorrectly

## UPG-005 — Storage balances preserved

## UPG-006 — shortQty preserved

## UPG-007 — lockedLongQty preserved

## UPG-008 — final settlements preserved

## UPG-009 — roles preserved

## UPG-010 — economic semantics regression test

If immutable deployment, mark this section N/A with rationale.

---

# Part XXVI — Kuru package

## KUR-001 — Correct market base

## KUR-002 — Correct market quote

## KUR-003 — Wrong base rejected

## KUR-004 — Wrong quote rejected

## KUR-005 — Wrong chain rejected

## KUR-006 — Buy option workflow

## KUR-007 — Sell option workflow

## KUR-008 — Buy-to-close workflow

## KUR-009 — Slippage max input enforced

## KUR-010 — Kuru fill does not imply close until Optara confirms

## KUR-011 — Kuru outage handled cleanly

## KUR-012 — Kuru balance excluded from Optara margin preview

---

# Part XXVII — SDK package

## SDK-001 — getSeries parity

## SDK-002 — getAccountCash parity

## SDK-003 — requiredMargin parity

## SDK-004 — freeCollateral parity

## SDK-005 — previewWrite exact against on-chain read/reference state

## SDK-006 — write calldata exact

## SDK-007 — deposit calldata exact

## SDK-008 — withdraw calldata exact

## SDK-009 — lock calldata exact

## SDK-010 — unlock calldata exact

## SDK-011 — close calldata exact

## SDK-012 — redeem calldata exact

## SDK-013 — finalize builder exact

## SDK-014 — sync builder exact

## SDK-015 — wrong chain fails

## SDK-016 — unknown deployment fails

## SDK-017 — stale preview does not claim guaranteed success

## SDK-018 — recipient is explicit/correct

## SDK-019 — settlement asset read from series, not global USDC

## SDK-020 — event decoding exact

---

# Part XXVIII — @optara/math package

## MTH-001 — Call vectors

## MTH-002 — Put vectors

## MTH-003 — critical points

## MTH-004 — portfolio loss

## MTH-005 — worst-case loss

## MTH-006 — margin

## MTH-007 — derived pair conversion

## MTH-008 — native conversion

## MTH-009 — settlement preview

## MTH-010 — shared vector parity with Solidity

---

# Part XXIX — State machine

## STM-001 — NOT_CREATED -> ACTIVE

## STM-002 — ACTIVE -> EXPIRED_UNSETTLED

## STM-003 — EXPIRED_UNSETTLED -> FINALIZED

## STM-004 — FINALIZED cannot return ACTIVE

## STM-005 — ACTIVE account position -> closed

## STM-006 — ACTIVE account position -> matured

## STM-007 — finalized unsynced -> synced

## STM-008 — synced cannot reapply delta

## STM-009 — external long -> locked

## STM-010 — locked -> external safe unlock

## STM-011 — locked -> consumed settlement

## STM-012 — external -> consumed close

## STM-013 — external settled -> redeemed

## STM-014 — redeemed terminal

## STM-015 — close-consumed terminal

## STM-016 — settled-consumed terminal

---

# Part XXX — Limits / DoS

## DOS-001 — Max series/group accepted

## DOS-002 — Max+1 rejected

## DOS-003 — Max groups/account accepted

## DOS-004 — Max+1 rejected

## DOS-005 — Max active series/account accepted

## DOS-006 — Max+1 rejected

## DOS-007 — risk calculation at max fits gas target

## DOS-008 — sync at max fits gas target

## DOS-009 — withdraw at max after sync fits gas target

---

# Part XXXI — Reentrancy / malicious callbacks

## REE-001 — Deposit reentrancy

## REE-002 — Withdrawal reentrancy

## REE-003 — lockLong reentrancy

## REE-004 — unlockLong reentrancy

## REE-005 — closeShort reentrancy

## REE-006 — redeem reentrancy

## REE-007 — optional router reentrancy

Each must preserve accounting and prevent double effect.

---

# Part XXXII — Stablecoin edge cases

## STB-001 — 6 decimal asset

## STB-002 — 18 decimal asset

## STB-003 — supported unusual decimal count if allowed

## STB-004 — depeg affects derived oracle units, not same-asset accounting

## STB-005 — token pause causes safe failure

## STB-006 — blacklist transfer failure leaves state atomic

## STB-007 — rebasing token rejected

## STB-008 — fee-on-transfer token rejected

---

# Part XXXIII — Full user-flow integration

## FLW-001 — Writer deposit -> write -> hold -> expiry -> sync

## FLW-002 — Writer deposit -> write -> Kuru sell -> buyer redeem

## FLW-003 — Writer write -> Kuru sell -> premium deposit -> withdraw free premium

## FLW-004 — Writer write -> Kuru buyback -> close

## FLW-005 — Writer write -> acquire hedge -> lock -> margin release -> expiry atomic sync

## FLW-006 — Buyer buy -> resell -> final holder redeem

## FLW-007 — Long remains external until after finalization -> transfer -> redeem

## FLW-008 — Kuru outage -> direct Optara settlement still succeeds

## FLW-009 — Two stablecoins in one account remain isolated

## FLW-010 — Multiple risk groups same stablecoin sum correctly

---

# Part XXXIV — Global stateful invariants

## INV-001 — All active healthy accounts satisfy cash >= required margin

## INV-002 — Long mint equals short creation cumulative

## INV-003 — Pre-expiry supply equals open short quantity

## INV-004 — Locked custody equals locked accounting

## INV-005 — No double long consumption

## INV-006 — No double short settlement

## INV-007 — Settlement price immutable

## INV-008 — All group series share settlement price

## INV-009 — Per-asset vault conservation

## INV-010 — Rounding reserve nonnegative

## INV-011 — Protocol-owned balance nonnegative

## INV-012 — Cross-stablecoin margin impossible

## INV-013 — External Kuru balances never appear as Optara cash

## INV-014 — SDK state cannot alter contracts without signed/on-chain transition

## INV-015 — No active state exceeds configured bounds

## INV-016 — No withdrawal below required margin

## INV-017 — No unlock below required margin

## INV-018 — No post-expiry write

## INV-019 — No refinalization

## INV-020 — No redeemed token supply resurrection

---

# Part XXXV — Coverage audit checklist

Before claiming 100%:

- [ ] every contract function appears in a test;
- [ ] every branch appears in a test;
- [ ] every custom error/revert reason appears in a negative test where reachable;
- [ ] every event emitted by production contracts is tested;
- [ ] every role restriction is tested;
- [ ] every state transition is tested;
- [ ] every forbidden transition is tested;
- [ ] every invariant from `INVARIANTS.md` is mapped;
- [ ] every security invariant from `SECURITY.md` is mapped;
- [ ] every access invariant from `ACCESS_CONTROL.md` is mapped;
- [ ] every fee invariant from `FEES.md` is mapped;
- [ ] all off-chain packages have their own unit/integration tests;
- [ ] shared differential vectors are executed by both Solidity and TypeScript;
- [ ] no coverage exclusion hides a financial branch.

---

# 201. Final test-case principle

The required test suite is not complete because:

```text
forge coverage = 100%
```

alone.

It is complete when:

```text
code coverage
+
spec coverage
+
invariant coverage
+
state-transition coverage
+
negative-path coverage
+
integration coverage
```

are all complete.


---

# Appendix A — Invariant-to-test traceability matrix

This appendix is mandatory.

Every invariant listed below must remain mapped to at least one implemented test. If a test is renamed, this table must be updated in the same pull request.

## A.1 `INVARIANTS.md`

### Series invariants

| Invariant | Required test IDs |
|---|---|
| INV-SERIES-01 | SER-001, SER-003, SER-004, MAR-003, MAR-004 |
| INV-SERIES-02 | SER-021, ACL-010 |
| INV-SERIES-03 | SER-015, SER-016, SER-017, SER-018, SER-019, SER-020 |
| INV-SERIES-04 | SER-005 through SER-012 |
| INV-SERIES-05 | RGI-001 through RGI-008 |

### Payoff invariants

| Invariant | Required test IDs |
|---|---|
| INV-PAYOFF-01 | PAY-001 through PAY-007 |
| INV-PAYOFF-02 | PAY-008 through PAY-013 |
| INV-PAYOFF-03 | PAY-014, PAY-015 |
| INV-PAYOFF-04 | PAY-016 |
| INV-PAYOFF-05 | PAY-017 |
| INV-PAYOFF-06 | PAY-002, PAY-005, PAY-009, PAY-011 |
| INV-PAYOFF-07 | PAY-018, PAY-019 |
| INV-PAYOFF-08 | PAY-020, PAY-021, FIX-014 |

### Premium invariants

| Invariant | Required test IDs |
|---|---|
| INV-PREMIUM-01 | FEE-002, FLW-002, FLW-006 |
| INV-PREMIUM-02 | WRT-017, FLW-003, KUR-012 |

### Risk invariants

| Invariant | Required test IDs |
|---|---|
| INV-RISK-01 | RSK-001 through RSK-006 |
| INV-RISK-02 | RSK-007, RSK-008, LCK-001 |
| INV-RISK-03 | RSK-006 through RSK-010 |
| INV-RISK-04 | RSK-020, RSK-021 |
| INV-RISK-05 | RSK-013, RSK-014, RSK-015, RSK-020 |
| INV-RISK-06 | RSK-022, FIX-011 through FIX-013 |
| INV-RISK-07 | RSK-016, WRT-015 |
| INV-RISK-08 | RSK-017, CLS-011 |
| INV-RISK-09 | RSK-018, LCK-004, LCK-005 |
| INV-RISK-10 | RSK-019, ULK-008 |

### Margin invariants

| Invariant | Required test IDs |
|---|---|
| INV-MARGIN-01 | MAR-001, MAR-009, MAR-010 |
| INV-MARGIN-02 | MAR-002, MAR-003 |
| INV-MARGIN-03 | WRT-015, WDW-013, ULK-002, INV-001 |
| INV-MARGIN-04 | MAR-003, MAR-004, WRT-010, INV-012 |
| INV-MARGIN-05 | MAR-005, WDW-001, WDW-002 |
| INV-MARGIN-06 | WDW-002, WDW-003, WDW-013 |
| INV-MARGIN-07 | RSK-020, FLW-001, FLW-005, INV-001 |
| INV-MARGIN-08 | MAR-004, PAU-001, INV-001 |

### Hedge invariants

| Invariant | Required test IDs |
|---|---|
| INV-HEDGE-01 | LCK-008, LCK-009, KUR-012 |
| INV-HEDGE-02 | LCK-002, LCK-003, INV-004 |
| INV-HEDGE-03 | LCK-010, SYN-010, INV-005 |
| INV-HEDGE-04 | ULK-002, ULK-003 |
| INV-HEDGE-05 | SYN-010, SUP-007, INV-005 |

### Supply invariants

| Invariant | Required test IDs |
|---|---|
| INV-SUPPLY-01 | WRT-012, WRT-013, SUP-001 |
| INV-SUPPLY-02 | CLS-009, CLS-010, SUP-005 |
| INV-SUPPLY-03 | SUP-002, SUP-003, SUP-004 |
| INV-SUPPLY-04 | SUP-008 |
| INV-SUPPLY-05 | SUP-009 |
| INV-SUPPLY-06 | SUP-006 through SUP-010 |

### Oracle invariants

| Invariant | Required test IDs |
|---|---|
| INV-ORACLE-01 | ORN-001 through ORN-005 |
| INV-ORACLE-02 | ORN-004, STB-004 |
| INV-ORACLE-03 | ORN-003 through ORN-006 |
| INV-ORACLE-04 | FIN-005, FIN-007, FIN-009 |
| INV-ORACLE-05 | FIN-004, FIN-011 |

### Lifecycle invariants

| Invariant | Required test IDs |
|---|---|
| INV-LIFE-01 | STM-001 through STM-016 |
| INV-LIFE-02 | WRT-006, INV-018 |
| INV-LIFE-03 | RED-007 |
| INV-LIFE-04 | FIN-007, ACL-011, INV-007 |

### Settlement invariants

| Invariant | Required test IDs |
|---|---|
| INV-SETTLE-01 | SYN-003, SYN-004 |
| INV-SETTLE-02 | SYN-004, INV-001 |
| INV-SETTLE-03 | ASY-007, WDW-010 |
| INV-SETTLE-04 | SYN-013, ASY-001 through ASY-005 |
| INV-SETTLE-05 | VLT-003, VLT-004, ASY-005 |
| INV-SETTLE-06 | FIX-011 through FIX-014, VLT-006 |

### Redemption invariants

| Invariant | Required test IDs |
|---|---|
| INV-REDEEM-01 | RED-001 through RED-006 |
| INV-REDEEM-02 | RED-010, RED-013 |
| INV-REDEEM-03 | SYN-010, RED-013, INV-005 |
| INV-REDEEM-04 | RED-014, RED-015 |

### Rounding invariants

| Invariant | Required test IDs |
|---|---|
| INV-ROUND-01 | FIX-007 through FIX-010 |
| INV-ROUND-02 | FIX-011, FIX-012, FIX-013, RED-012, SYN-005, SYN-006 |
| INV-ROUND-03 | RSK-022 |
| INV-ROUND-04 | SYN-003 through SYN-006 |
| INV-ROUND-05 | VLT-006, INV-010 |

### Vault invariants

| Invariant | Required test IDs |
|---|---|
| INV-VAULT-01 | VLT-007, MAR-003 |
| INV-VAULT-02 | DEP-006, DEP-007, DEP-010 |
| INV-VAULT-03 | WDW-006, WDW-007, VLT-002 |
| INV-VAULT-04 | VLT-001 through VLT-008, INV-009 |
| INV-VAULT-05 | VLT-003, ASY-001 through ASY-005 |
| INV-VAULT-06 | VLT-007, MAR-004 |

### Kuru invariants

| Invariant | Required test IDs |
|---|---|
| INV-KURU-01 | KUR-012, FLW-002, FLW-003 |
| INV-KURU-02 | CLS-013, KUR-010 |
| INV-KURU-03 | CLS-013, CLS-014, KUR-008 |
| INV-KURU-04 | KUR-011, FLW-008 |

### Admin invariants

| Invariant | Required test IDs |
|---|---|
| INV-ADMIN-01 | ACL-010, SER-021 |
| INV-ADMIN-02 | ACL-011, FIN-007 |
| INV-ADMIN-03 | VLT-009, ACL-002 |
| INV-ADMIN-04 | PAU-001 through PAU-009 |

### Gas/boundedness invariants

| Invariant | Required test IDs |
|---|---|
| INV-GAS-01 | DOS-007, DOS-008 |
| INV-GAS-02 | DOS-001 through DOS-006 |
| INV-GAS-03 | DOS-008, DOS-009 |

### Security/state invariants

| Invariant | Required test IDs |
|---|---|
| INV-STATE-01 | WRT-015, WRT-016 |
| INV-STATE-02 | ULK-003, WDW-013 |
| INV-STATE-03 | REE-001 through REE-007 |
| INV-STATE-04 | WRT-012, WRT-013, INV-002 |

---

## A.2 `SECURITY.md`

| Invariant | Required test IDs |
|---|---|
| SEC-INV-01 | WRT-009, WRT-015, INV-001 |
| SEC-INV-02 | WDW-003, ULK-002, INV-016, INV-017 |
| SEC-INV-03 | WRT-012, WRT-013, INV-002 |
| SEC-INV-04 | CLS-003 through CLS-010 |
| SEC-INV-05 | LCK-002, LCK-008, LCK-009 |
| SEC-INV-06 | RED-013, SYN-010, INV-005 |
| SEC-INV-07 | SYN-013, INV-006 |
| SEC-INV-08 | FIN-007, INV-007 |
| SEC-INV-09 | MAR-003, MAR-004, VLT-007 |
| SEC-INV-10 | SDK-015 through SDK-019, KUR-010, ACL-012, ACL-013 |
| SEC-INV-11 | DOS-001 through DOS-009 |
| SEC-INV-12 | ACL-010, ACL-011, PAU-008 |

---

## A.3 `ACCESS_CONTROL.md`

| Invariant | Required test IDs |
|---|---|
| AC-INV-01 | ACL-012 |
| AC-INV-02 | ACL-013, KUR-010 |
| AC-INV-03 | ACL-001, TOK-002, TOK-003 |
| AC-INV-04 | ACL-002, VLT-009 |
| AC-INV-05 | ACL-010 |
| AC-INV-06 | ACL-011, FIN-007 |
| AC-INV-07 | ACL-006, PAU-009 |
| AC-INV-08 | ACL-004, ACL-005, SYN-014 |
| AC-INV-09 | ACL-015 |
| AC-INV-10 | ACL-003, UPG-001 through UPG-010 |

---

## A.4 `FEES.md`

| Invariant | Required test IDs |
|---|---|
| FEE-INV-01 | FEE-001, FEE-002, RED-001 through RED-006 |
| FEE-INV-02 | MAR-001 through MAR-004, FEE-004 |
| FEE-INV-03 | FEE-007 |
| FEE-INV-04 | FEE-005 |
| FEE-INV-05 | LCK-001 through LCK-010 |
| FEE-INV-06 | FEE-001, RED-012 |
| FEE-INV-07 | FEE-002, KUR-006 through KUR-010 |
| FEE-INV-08 | FEE-003, FIN-003 |
| FEE-INV-09 | FEE-009, VLT-005 |
| FEE-INV-10 | FEE-010, VLT-009 |

---

## A.5 `COMPOSABILITY.md`

| Invariant | Required test IDs |
|---|---|
| COMP-INV-01 | TOK-001, RED-009 through RED-015 |
| COMP-INV-02 | LCK-008, LCK-009, KUR-012 |
| COMP-INV-03 | CLS-013, KUR-010 |
| COMP-INV-04 | FEE-002, FLW-002, FLW-006 |
| COMP-INV-05 | WRT-018, WDW-013, ULK-002 |
| COMP-INV-06 | SDK-019, MAR-003 |
| COMP-INV-07 | CLS-003 through CLS-006 |
| COMP-INV-08 | RED-010, SYN-010, CLS-009 |
| COMP-INV-09 | KUR-011, FLW-008 |
| COMP-INV-10 | ACL-012, SDK-015 through SDK-019 |
| COMP-INV-11 | FLW-006, TOK-007, RED-014 |
| COMP-INV-12 | SDK-001 through SDK-020 plus direct on-chain parity checks |

---

## A.6 `LIQUIDATION.md`

| Invariant | Required test IDs |
|---|---|
| INV-LIQ-01 | RSK-001, RSK-002, FLW-001 |
| INV-LIQ-02 | WRT-009, WRT-015 |
| INV-LIQ-03 | MAR-006, INV-001 |
| INV-LIQ-04 | ACL-010, ACL-011, PAU-008 |
| INV-LIQ-05 | ASY-001 through ASY-005, VLT-007 |
| INV-LIQ-06 | MAR-003, MAR-004 |
| INV-LIQ-07 | DEP-001, LCK-001, CLS-001, INV-001 |
| INV-LIQ-08 | SYN-003, SYN-004 |
| INV-LIQ-09 | KUR-011, FLW-008 |
| INV-LIQ-10 | SYN-004, emergency corrupted-state harness |
| INV-LIQ-11 | PAU-008, SER-021 |
| INV-LIQ-12 | PAU-001 through PAU-009 |

---

## A.7 `STATE_MACHINE.md`

| Invariant | Required test IDs |
|---|---|
| SM-INV-01 | WRT-015, WDW-013, ULK-002 |
| SM-INV-02 | ULK-002, ULK-003 |
| SM-INV-03 | WRT-012, WRT-013 |
| SM-INV-04 | CLS-003, CLS-009, CLS-010 |
| SM-INV-05 | RED-010, RED-013 |
| SM-INV-06 | FIN-007 |
| SM-INV-07 | SYN-013 |
| SM-INV-08 | MAR-003, MAR-004 |
| SM-INV-09 | CLS-013, KUR-010 |
| SM-INV-10 | ACL-010, ACL-011, PAU-008 |

---

## A.8 `KURU_INTEGRATION.md`

| Invariant | Required test IDs |
|---|---|
| KI-INV-01 | KUR-012, FLW-003 |
| KI-INV-02 | LCK-008, KUR-012 |
| KI-INV-03 | CLS-013, KUR-010 |
| KI-INV-04 | CLS-003 through CLS-010, KUR-008 |
| KI-INV-05 | FEE-002, FLW-002 |
| KI-INV-06 | KUR-011, FLW-008 |
| KI-INV-07 | ORN-001 through ORN-012 |
| KI-INV-08 | KUR-001, KUR-003 |
| KI-INV-09 | KUR-002, KUR-004 |
| KI-INV-10 | WRT-012, WRT-013, SUP-001 |

---

# Appendix B — Public-function test completeness rule

For every production public/external function `f`, the implementation PR must include a table:

```text
function
success tests
boundary tests
authorization tests
pause-state tests
revert tests
state invariants checked
```

A function is not considered covered merely because another integration test happened to execute it.

---

# Appendix C — Custom-error / revert traceability

Every custom error or explicit revert branch in Optara-owned production contracts must be referenced by at least one negative test.

CI should maintain a generated or reviewed map:

```text
ErrorName -> TestID(s)
```

Any production error with no mapped test fails the release gate unless formally proven unreachable and approved as a coverage exclusion.

---

# Appendix D — Event traceability

Every production event must have at least one test verifying:

```text
emitter
event signature
indexed identifiers
amounts
settlement asset
account/recipient where applicable
```

Events do not replace state assertions.

---

# Appendix E — 100% completion criterion

An AI agent or engineer may claim the Optara test suite is complete only when all of the following are true:

```text
all TEST_CASES IDs implemented
all invariant mappings implemented
all public/external functions mapped
all custom errors mapped
all production events mapped
100% function coverage
100% line coverage
100% branch coverage
stateful invariant campaign passing
differential reference-model campaign passing
integration/package/deployment tests passing
```

If any item is missing, "100% coverage" is not complete protocol coverage.
