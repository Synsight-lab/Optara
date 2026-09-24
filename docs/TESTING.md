# Optara V2 — Testing Specification

**Document type:** Normative testing strategy, quality gate, and coverage specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Required implementation/testing specification

---

# 1. Purpose

This document defines the testing system required for Optara V2.

It is written so that an engineer or AI coding agent can implement the complete test suite without having to invent what must be tested.

The suite must validate the whole Optara system:

```text
Solidity contracts
@optara/math
@optara/sdk
@optara/kuru
deployment/configuration
oracle adapters
accounting invariants
integration boundaries
```

The primary goal is not merely high code coverage.

The primary goal is:

```text
every economic rule
every state transition
every invariant
every privilege boundary
every failure path
```

must have an executable test.

---

# 2. Definition of "100% coverage"

For Optara-owned Solidity production code, release acceptance requires:

```text
100% function coverage
100% line coverage
100% branch coverage
```

for code that is reachable in the deployed architecture.

Additionally:

```text
100% named invariant coverage
100% externally callable state-transition coverage
100% role/authorization matrix coverage
100% documented revert-condition coverage
```

must be demonstrated.

A coverage number alone is insufficient.

---

# 3. Coverage exclusions

Exclusions must be explicit and documented.

Potential exclusions:

```text
generated interfaces
third-party libraries
unreachable defensive assertions proven unreachable
mock contracts
test helpers
deployment-only tooling
```

Do not exclude:

```text
revert branches
emergency branches
zero-payoff settlement
rounding branches
pause branches
role checks
fallback oracle branches
```

merely because they are difficult to reach.

---

# 4. Coverage philosophy

Every production function must be tested through:

```text
success path
boundary path
revert path
state-effects assertions
event assertions where important
post-state invariant assertions
```

Every economic formula must be tested through:

```text
hand-calculated examples
boundaries
property tests
fuzz tests
independent reference model
```

---

# 5. Testing layers

The complete suite has nine layers:

```text
1. Pure unit tests
2. Contract unit tests
3. State-transition tests
4. Property/fuzz tests
5. Stateful invariant tests
6. Differential/reference-model tests
7. Integration tests
8. SDK/package tests
9. Deployment/fork/smoke tests
```

All nine are required before production.

---

# 6. Repository test layout

Recommended:

```text
optara/
├── contracts/
│   ├── src/
│   ├── test/
│   │   ├── unit/
│   │   ├── fuzz/
│   │   ├── invariant/
│   │   ├── integration/
│   │   ├── access/
│   │   ├── oracle/
│   │   ├── settlement/
│   │   ├── mocks/
│   │   ├── fixtures/
│   │   └── utils/
│   └── script/
│
├── packages/
│   ├── math/
│   │   └── test/
│   ├── sdk/
│   │   └── test/
│   └── kuru/
│       └── test/
│
└── test-vectors/
```

---

# Part I — Test sources of truth

## 7. Required specification inputs

Tests must be derived from:

```text
OPTION_SPEC.md
MATH.md
INVARIANTS.md
PROTOCOL_SPEC.md
MARGIN_AND_RISK.md
LIQUIDATION.md
STATE_MACHINE.md
ORACLE_AND_SETTLEMENT.md
COMPOSABILITY.md
SECURITY.md
ACCESS_CONTROL.md
FEES.md
DESIGN_DECISIONS.md
```

`TEST_CASES.md` enumerates concrete required cases.

---

# 8. Invariant mapping requirement

Every named invariant must appear in a test registry.

Example:

```text
INV-PAYOFF-01
-> test_callPayoff_piecewise()
-> fuzz_callPayoff_matchesReference()

INV-MARGIN-03
-> invariant_postActionAccountSafety()

AC-INV-06
-> test_finalizedPriceCannotBeChanged()
```

No named invariant may have:

```text
test mapping = NONE
```

---

# 9. State-machine mapping requirement

Every allowed transition must have:

```text
at least one successful test
```

Every forbidden transition must have:

```text
at least one reverting/no-op test
```

---

# 10. Revert-condition mapping

Each public/external mutating function must have a documented revert matrix.

Example:

```text
write()
- zero quantity
- unknown series
- expired series
- paused new risk
- account-position limit reached
- insufficient settlement-asset margin
- invalid recipient
```

Each row requires a test.

---

# Part II — Pure math testing

## 11. PayoffMath

Test:

```text
callPayoff
putPayoff
mulDivDown
mulDivUp
toNativeDown
toNativeUp
normalization helpers
critical point helpers
```

---

# 12. Call payoff boundaries

For:

```text
K = 10
C = 5
```

test:

```text
S = 0      -> 0
S = 9      -> 0
S = 10     -> 0
S = 11     -> 1
S = 14     -> 4
S = 15     -> 5
S = 16     -> 5
S = huge   -> 5
```

---

# 13. Put payoff boundaries

For:

```text
K = 10
C = 4
```

test:

```text
S = 20 -> 0
S = 10 -> 0
S = 9  -> 1
S = 7  -> 3
S = 6  -> 4
S = 0  -> 4
```

---

# 14. Spread-equivalence tests

For calls:

```text
cappedCall(K,C)
=
longCall(K)
-
longCall(K+C)
```

for fuzzed `S`.

For puts:

```text
cappedPut(K,C)
=
longPut(K)
-
longPut(K-C)
```

where valid.

---

# 15. Payoff monotonicity

Fuzz:

```text
S1 <= S2
```

Call:

```text
payoff(S1) <= payoff(S2)
```

Put:

```text
payoff(S1) >= payoff(S2)
```

---

# 16. Payoff cap

Fuzz:

```text
payoff <= C * CS * Q
```

for arbitrary valid values.

---

# 17. Quantity linearity

Before final native conversion:

```text
payoff(Q1 + Q2)
=
payoff(Q1)
+
payoff(Q2)
```

subject to documented fixed-point rounding boundaries.

Where native conversion is involved, verify the documented inequality rather than incorrect strict equality.

---

# 18. Full-precision arithmetic

Test:

```text
very large safe operands
near uint256 bounds
zero denominators revert
ceil/floor exact divisibility
ceil/floor remainder
```

---

# Part III — RiskEngine testing

## 19. Independent reference model required

The Solidity RiskEngine must be compared against an independent model.

Preferred:

```text
@optara/math
```

plus optionally a high-precision Python/BigInt test oracle.

Do not use the Solidity implementation itself to generate expected values.

---

# 20. Exact critical points

For each portfolio:

```text
expected critical points
```

must be independently derived.

Verify:

```text
0
all K
all K+C calls
all K-C puts
```

with duplicates removed.

---

# 21. Exact worst-case comparison

For fuzzed portfolios:

```text
SolidityWorstCase
>=
ExactReferenceWorstCase
```

and, subject to documented rounding:

```text
SolidityWorstCase
<=
ExactReferenceWorstCase + maximum rounding guard
```

---

# 22. Dense-grid sanity check

Although dense grids are not authoritative, they are useful additional tests.

For randomly generated portfolios:

```text
onchain exact result
>=
loss(S)
```

for thousands of sampled `S`.

---

# 23. One-short call

Expected:

```text
WorstCase = C * CS * Q
```

---

# 24. One-short put

Expected:

```text
WorstCase = C * CS * Q
```

---

# 25. Hedged call spread

Example:

```text
short call K=10 C=5
locked long K=12 C=3
```

Expected worst case:

```text
2
```

---

# 26. Hedged put spread

Construct equivalent bounded put hedge and calculate exact expected result manually.

---

# 27. Mixed calls and puts

Same risk group:

```text
multiple calls
multiple puts
multiple strikes
multiple caps
```

Compare full exact reference model.

---

# 28. Hedge does not necessarily reduce margin

Construct a locked long whose payoff does not reduce the current maximum.

Expected:

```text
W_after == W_before
```

---

# 29. Risk monotonicity

Fuzz:

```text
add short -> W_after >= W_before
close short -> W_after <= W_before
lock compatible long -> W_after <= W_before
unlock compatible long -> W_after >= W_before
```

---

# Part IV — SeriesFactory testing

## 30. Valid series creation

Test calls and puts across multiple pair assets.

---

# 31. Invalid series

Revert:

```text
zero underlying
zero settlement asset
unapproved pair
zero strike
zero cap
zero contract size
past/invalid expiry
put cap > strike
unsupported oracle config
duplicate series
```

---

# 32. Series immutability

After creation, prove no exposed function can modify immutable economic fields.

---

# 33. Canonical series ID

Same tuple:

```text
same seriesId
```

Different field:

```text
different seriesId
```

---

# Part V — OptionToken testing

## 34. Mint permissions

Only canonical issuer.

Unauthorized calls revert.

---

# 35. Burn permissions

Only approved canonical paths / holder-authorized paths according to implementation.

---

# 36. Transfer

Standard ERC-20 behavior.

---

# 37. Supply conservation

Track:

```text
mint
close burn
redemption burn
locked settlement burn
```

against cumulative identities.

---

# 38. No rebasing/tax behavior

OptionToken implementation itself must remain predictable ERC-20.

---

# Part VI — MarginVault testing

## 39. Deposit

Test:

```text
USDT
USDC
USDe
different decimals
```

Ledger increase equals actual supported token receipt.

---

# 40. Cross-asset isolation

Deposit USDT:

```text
USDC cash unchanged
```

---

# 41. Unauthorized vault transfer

All unauthorized callers revert.

---

# 42. Physical/accounting reconciliation

After every test sequence:

```text
vault physical balances
```

must match accounting identity.

---

# 43. Malicious token mocks

Test:

```text
fee-on-transfer
rebasing-like
reentrant
false-return
no-return
blacklisting/failure
```

Unsupported tokens must fail safely.

---

# Part VII — ClearingHouse tests

## 44. Write happy path

Test:

```text
sufficient cash
active series
valid quantity
```

Effects:

```text
short increases
long minted
margin remains safe
event emitted
```

---

# 45. Write insufficient margin

Must revert with all state unchanged.

---

# 46. Write wrong stablecoin balance

Example:

```text
USDT requirement = 5
USDT cash = 0
USDC cash = 1000
```

Write reverts.

---

# 47. Partial close

Burn exact same-series long and reduce short partially.

---

# 48. Full close

Short becomes zero and margin releases appropriately.

---

# 49. Wrong-series close

Revert.

---

# 50. Lock long

Actual custody increases and locked quantity increases.

---

# 51. Unlock safe

Releases token.

---

# 52. Unlock unsafe

Reverts before transfer.

---

# 53. Withdraw safe

After matured synchronization, withdrawal <= free collateral succeeds.

---

# 54. Withdraw unsafe

Reverts.

---

# Part VIII — Margin lifecycle tests

## 55. Deposit/write/withdraw sequence

Example:

```text
deposit 10
write margin 5
free = 5
withdraw 5 -> succeeds
withdraw 1 more -> fails
```

---

# 56. Hedge margin release

```text
unhedged margin 5
lock hedge
new margin 2
free collateral increases by 3
```

---

# 57. Hedge unlock requires refill

After withdrawing released collateral, unlock must revert until sufficient deposit.

---

# 58. Same stablecoin, different groups

Requirements add.

---

# 59. Different stablecoins

Requirements remain separate.

---

# Part IX — OracleAdapter tests

## 60. Direct feed

Verify:

```text
source identity
timestamp
decimals
normalization
price > 0
```

---

# 61. Derived feed

Test:

```text
underlying/USD
/
stablecoin/USD
```

including depeg.

---

# 62. Wrong denomination

Must not silently accept generic USD price as stablecoin pair.

---

# 63. Stale report

Revert.

---

# 64. Wrong observation window

Revert.

---

# 65. Excessive confidence/error

Revert when configured.

---

# 66. Zero denominator

Revert.

---

# 67. Fallback

Test only the precommitted fallback order.

---

# Part X — SettlementEngine tests

## 68. Finalize before expiry

Revert.

---

# 69. Finalize too early after expiry

If finalization delay applies, revert.

---

# 70. Valid finalization

Store exact normalized price.

---

# 71. Double finalization

Cannot alter price.

---

# 72. Same group price

Every series in group resolves from same `S*`.

---

# 73. Call settlement boundaries

Use exact boundary vectors.

---

# 74. Put settlement boundaries

Use exact boundary vectors.

---

# 75. Redemption

Burn quantity and transfer exact rounded-down settlement payout.

---

# 76. Zero-payoff redemption

Burn succeeds; no stablecoin transfer.

---

# 77. Double redemption

Fails because claim no longer exists.

---

# 78. Atomic account-group sync

Test mixed matured short/locked long.

---

# 79. Double sync

No second economic effect.

---

# 80. Redemption before writer sync

Must preserve per-asset vault conservation.

---

# Part XI — Asynchronous accounting tests

## 81. Effective balance

Create finalized-unsynced debt.

Verify:

```text
effective != raw
```

as expected.

---

# 82. Withdrawal sync-first

Attempt withdrawal based on stale raw cash.

Must sync and reject unsafe amount.

---

# 83. Interleaving permutations

For same finalized group test arbitrary order:

```text
holder A redeems
holder B redeems
writer 1 syncs
writer 2 syncs
locked hedge settles
```

Accounting result must be order-independent except conservative rounding reserve.

---

# Part XII — Fee tests

## 84. Fee-free MVP

Every Optara protocol fee delta must be zero.

---

# 85. Optional future issuance fee

If code supports it, test even if configured zero in production.

Validate:

```text
gross max payout basis
same settlement asset
fee rounding up
post-fee margin safety
protocolOwnedBalance
maxFee protection
```

---

# Part XIII — Access-control tests

## 86. Role matrix

Every privileged function must be tested against every relevant role class:

```text
user
keeper
pauser
config
governance
internal contract
random attacker
```

---

# 87. No SDK/Kuru role

Prove no role identifier/function implicitly trusts SDK/Kuru caller.

---

# 88. Series immutability under governance

Governance cannot mutate existing terms.

---

# 89. Finalized price immutability under governance

Cannot overwrite.

---

# 90. Pauser restrictions

Can pause allowed scopes, cannot seize assets or alter economics.

---

# 91. Upgrade authorization

If upgradeable:

```text
unauthorized -> revert
authorized through expected path -> success
initializer replay -> revert
```

---

# Part XIV — Pause/emergency tests

## 92. Normal risk pause

Block:

```text
write
unsafe withdraw
unsafe unlock
```

Preserve safe:

```text
deposit
lock
close
```

as designed.

---

# 93. Settlement pause

Block affected finalization/sync/redemption.

---

# 94. Asset-specific restriction

Unaffected asset remains usable.

---

# 95. Restricted account cure

Test:

```text
restricted
-> deposit / valid hedge / close
-> health restored
-> restriction cleared according to policy
```

---

# Part XV — Kuru integration testing

## 96. Unit layer

Mock Kuru client/contracts for:

```text
market discovery
base/quote validation
slippage
buy/sell
withdraw custody
```

---

# 97. Wrong market

Reject:

```text
wrong base
wrong quote
wrong chain
wrong deployment
```

---

# 98. Buy-to-close

Workflow:

```text
buy exact long
obtain actual token
closeShort
```

Do not mark closed on Kuru fill alone.

---

# 99. Kuru outage

Optara settlement still works.

---

# 100. Kuru-held long

Cannot receive Optara hedge credit or direct redemption without actual token custody.

---

# Part XVI — SDK testing

## 101. SDK read parity

For each read helper:

```text
SDK decoded value
==
direct contract value
```

---

# 102. SDK transaction builder

Decode built calldata and verify exact:

```text
target
selector
arguments
value
chain
```

---

# 103. SDK stale preview

Create preview, mutate state, execute transaction.

Contract must reject if unsafe.

---

# 104. Wrong network

SDK must refuse or loudly error on mismatched chain/deployment configuration.

---

# 105. Recipient integrity

Verify explicit recipients.

---

# 106. Approval scope

Test bounded approvals and optional unlimited mode if offered.

---

# Part XVII — @optara/math tests

## 107. Deterministic unit tests

Every exported math function must have direct vectors.

---

# 108. Solidity differential tests

Generate shared JSON vectors.

Run identical vectors against:

```text
@optara/math
Solidity tests
```

---

# 109. Independent random generator

Do not derive expected values from Solidity.

---

# Part XVIII — Stateful invariant testing

## 110. Handler architecture

Build handlers for:

```text
createSeries
deposit
write
transferLong
lockLong
unlockLong
closeShort
withdraw
warpToExpiry
finalize
sync
redeem
pause/unpause
```

Use multiple actors and settlement assets.

---

# 111. Ghost state

Track independent shadow state for:

```text
cumulative minted
cumulative closed
cumulative redeemed
cumulative locked-consumed
cumulative synced shorts
vault inflows/outflows
protocol fees
rounding reserve
```

---

# 112. Core stateful invariants

At every invariant checkpoint assert at least:

```text
all active accounts safe
no cross-stablecoin margin
mint/short conservation
locked custody conservation
no double consumption
settlement immutability
vault per-asset conservation
bounded position indexes
role restrictions
```

---

# 113. Random action ordering

Fuzz hundreds/thousands of sequences with:

```text
different actors
same series
different series
different groups
different stablecoins
partial quantities
boundary timestamps
```

---

# 114. Time manipulation

Explicitly fuzz around:

```text
expiry - 1
expiry
expiry + 1
earliest finalization - 1
earliest finalization
```

---

# Part XIX — Formal / symbolic analysis targets

## 115. Recommended formal targets

Where tooling permits, prove:

```text
payoff bound
series immutability
single finalization
burn-before-double-redemption impossibility
post-withdraw margin safety
post-unlock margin safety
mint-short equality
```

Formal proof complements but does not replace testing.

---

# Part XX — Gas and boundedness tests

## 116. Maximum-size portfolio

Construct account at all configured limits.

Verify:

```text
requiredMargin executable
unlock executable
withdraw executable
syncRiskGroup executable
```

within target gas budget.

---

# 117. Limit + 1

Creating position beyond configured bound must revert before making state unserviceable.

---

# 118. Gas snapshots

Track gas for:

```text
write
lock
unlock
close
withdraw
finalize
sync
redeem
```

at:

```text
1 position
typical portfolio
maximum portfolio
```

---

# Part XXI — Event testing

## 119. Events

Important transitions should test:

```text
correct event
correct indexed IDs
correct amount
correct settlement asset
correct account
```

Events are not the source of truth but must support indexing.

---

# Part XXII — Coverage execution

## 120. Foundry commands

Recommended CI flow:

```bash
forge fmt --check
forge build
forge test -vvv
forge test --fuzz-runs <configured-high-run-count>
forge coverage
```

Use project-specific invariant/fuzz profiles for CI and nightly runs.

---

# 121. Coverage threshold gate

CI fails unless Optara-owned production contracts report:

```text
Functions: 100%
Lines:     100%
Branches:  100%
```

Any explicit exclusion must be reviewed and documented.

---

# 122. Mutation testing recommendation

Coverage can execute code without validating it.

Use mutation testing where tooling allows.

Mutations such as:

```text
<= -> <
+ -> -
roundUp -> roundDown
role check removed
burn removed
```

should cause tests to fail.

---

# Part XXIII — Test tiers

## 123. PR tier

Fast:

```text
unit
focused fuzz
access control
package unit tests
coverage
```

---

# 124. Main-branch tier

Adds:

```text
high-run fuzz
stateful invariants
integration
gas
shared reference vectors
```

---

# 125. Nightly/security tier

Adds:

```text
very high invariant depth
large fuzz corpus
fork tests
malicious token suite
mutation tests
long randomized sequences
```

---

# Part XXIV — Release gates

## 126. Test release gate

Production deployment is prohibited until:

- [ ] 100% function coverage;
- [ ] 100% line coverage;
- [ ] 100% branch coverage;
- [ ] every named invariant mapped and passing;
- [ ] every public/external transition mapped and passing;
- [ ] every documented revert condition tested;
- [ ] differential RiskEngine tests passing;
- [ ] stateful invariants passing;
- [ ] maximum-size gas tests passing;
- [ ] access-control matrix passing;
- [ ] oracle settlement vectors passing;
- [ ] asynchronous settlement interleavings passing;
- [ ] per-stablecoin vault reconciliation passing;
- [ ] SDK package tests passing;
- [ ] Kuru integration tests passing;
- [ ] deployment smoke tests passing;
- [ ] audit findings resolved or explicitly accepted.

---

# 127. Definition of complete testing

The Optara test suite is complete only when an engineer can answer:

```text
Which test proves this invariant?
Which test proves this transition?
Which test proves this revert?
Which test proves this role restriction?
Which test proves this accounting equation?
```

for every documented behavior.

A green coverage badge without those answers is not sufficient.
