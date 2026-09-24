# Optara V2 — Security Specification

**Document type:** Normative security architecture and threat-model specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Engineering security specification; not a substitute for independent audit

> Canonical V2 uses immutable versioned financial cores (`ACCESS_CONTROL.md` sections 40–45). Conditional upgrade guidance/tests below apply only to a separately specified future variant; V2 instead tests sealed peers, fixed code, and non-reassignable internal authority.

---

## 1. Purpose

This document defines the security model for Optara V2.

It covers:

- security objectives;
- trust boundaries;
- smart-contract threats;
- economic/solvency threats;
- oracle threats;
- settlement threats;
- stablecoin/custody threats;
- Kuru integration threats;
- SDK/package/frontend threats;
- access-control threats;
- denial-of-service and bounded-computation threats;
- token and approval threats;
- upgrade/migration threats;
- monitoring, incident response, testing, and audit requirements.

The canonical Optara architecture contains:

```text
ON-CHAIN AUTHORITATIVE LAYER
    SeriesFactory
    OptionTokenFactory
    OptionToken
    ClearingHouse
    MarginVault
    RiskEngine
    SettlementEngine
    OracleAdapter
    AccessController
    PayoffMath / RiskMath

OFF-CHAIN NON-AUTHORITATIVE LAYER
    @optara/math
    @optara/sdk
    @optara/kuru
    frontend
    indexer
    bots / keepers / market makers
```

The security model is based on a strict principle:

> **No off-chain component may be trusted to prove financial safety. Every safety-critical state transition must be independently validated by Optara contracts.**

This document must be read with:

- `ARCHITECTURE.md`
- `PROTOCOL_SPEC.md`
- `OPTION_SPEC.md`
- `MATH.md`
- `INVARIANTS.md`
- `MARGIN_AND_RISK.md`
- `LIQUIDATION.md`
- `ORACLE_AND_SETTLEMENT.md`
- `COMPOSABILITY.md`
- `KURU_INTEGRATION.md`
- `STATE_MACHINE.md`
- `ACCESS_CONTROL.md`

If a conflict exists:

1. `MATH.md` controls numerical behavior;
2. `INVARIANTS.md` controls mandatory safety properties;
3. `PROTOCOL_SPEC.md` controls runtime state transitions;
4. `ACCESS_CONTROL.md` controls privilege boundaries;
5. this document controls threat-model and security policy.

---

# 2. Security goals

Optara V2 MUST protect the following properties.

## 2.1 Solvency

For each account `a` and settlement asset `A`:

```text
CashBalance(a,A)
>=
RequiredMargin(a,A)
```

after every risk-increasing or collateral-decreasing operation.

For any actual expiry prices:

```text
ActualNetLiability(a,A)
<=
ExactWorstCaseLoss(a,A)
<=
RequiredMargin(a,A)
<=
CashBalance(a,A)
```

subject to correct custody, oracle, arithmetic, and token behavior.

---

## 2.2 Claim integrity

Every long token must correspond to a real short obligation at issuance.

No long claim may be:

```text
minted without matching short
redeemed twice
credited as hedge and redeemed
used to close and later redeemed
```

---

## 2.3 Collateral integrity

Internal cash balances must reconcile to actual matching stablecoin custody.

No accounting entry may represent collateral that Optara does not control.

---

## 2.4 Settlement integrity

Each risk group receives exactly one valid settlement price according to its precommitted oracle methodology.

The final price and resulting payoff become immutable.

---

## 2.5 Stablecoin isolation

USDT obligations are backed and settled in USDT.

USDC obligations are backed and settled in USDC.

No implicit cross-stablecoin substitution exists.

---

## 2.6 Authorization integrity

No role, SDK, router, keeper, or external venue may bypass:

```text
margin checks
custody checks
series immutability
settlement rules
burn requirements
```

---

## 2.7 Liveness

An individual user must not be able to construct state that makes:

```text
withdrawal
risk-group synchronization
settlement
redemption
```

permanently unexecutable because of unbounded iteration.

---

# 3. Assets requiring protection

The primary assets are:

```text
settlement stablecoins held by MarginVault
long option-token supply
short-position accounting
locked long-option custody
series economic terms
finalized settlement prices
oracle configuration
role assignments
upgrade authority if deployed
```

Secondary assets include:

```text
SDK package integrity
deployment metadata
ABI/address registry
frontend transaction construction
indexer correctness
keeper keys
market-maker automation
```

Loss of a secondary asset must not directly override on-chain safety.

---

# 4. Trust assumptions

Core V2 assumes:

1. Monad execution behaves according to chain consensus.
2. approved settlement ERC-20s satisfy the behavior explicitly approved by governance;
3. approved oracle providers/configurations meet their documented security assumptions;
4. deployed Optara contracts execute their audited logic;
5. privileged roles operate within `ACCESS_CONTROL.md`;
6. cryptographic primitives and compiler/runtime behavior are sound.

Core V2 does **not** assume:

```text
Kuru is always available
Kuru is always liquid
the frontend is honest
the SDK is bug-free
the indexer is current
a market maker exists
current spot is continuously available
all stablecoins equal $1
```

---

# 5. Trust boundaries

Canonical security boundaries:

```text
USER / APP
    |
    v
@optara/sdk / @optara/kuru / frontend
    |
    | untrusted transaction input
    v
OPTARA CONTRACTS
    |
    +--> settlement stablecoin contracts
    |
    +--> oracle provider contracts
    |
    +--> optional external router integrations
```

Every crossing must assume the external party may be:

```text
buggy
stale
malicious
compromised
misconfigured
```

---

# Part I — Core economic-security model

## 6. Capped liability is the first security boundary

For every option:

```text
0 <= Payoff(S,Q)
<= C * CS * Q
```

This property must hold for every valid `S`.

Without it, core V2's deterministic margin model fails for naked calls.

---

## 7. Exact worst-case margin

The RiskEngine must compute:

```text
WorstCaseLoss
=
max over valid S
max(
    ShortLiability(S)
    -
    LockedLongCredit(S),
    0
)
```

using the complete risk group.

No approximation may understate the result.

---

## 8. RiskEngine compromise impact

A RiskEngine bug is critical because it may allow:

```text
under-margined write
unsafe hedge unlock
unsafe withdrawal
```

Therefore RiskEngine and its math libraries are among the highest-audit-priority components.

---

## 9. Risk/settlement consistency

The same economic payoff semantics must be used by:

```text
RiskEngine
SettlementEngine
@optara/math reference implementation
tests
```

The on-chain source of truth is the Solidity implementation.

Security invariant:

```text
maximum settlement debit
<=
margin bound calculated before expiry
```

---

# Part II — Arithmetic security

## 10. Fixed-point model

Recommended internal economic scale:

```text
WAD = 1e18
```

Cash balances remain in native stablecoin units.

---

## 11. Overflow/underflow

Use Solidity compiler checked arithmetic plus audited full-precision multiplication/division for values where intermediate products may exceed 256 bits.

Forbidden:

```text
x * y / d
```

when `x*y` may overflow despite final quotient fitting.

---

## 12. Conservative rounding

Security directions:

```text
required margin             -> UP
writer matured debit        -> UP
positive locked-long credit -> DOWN
external long payout        -> DOWN
withdrawable collateral     -> DOWN
```

Rounding must never create uncovered liability.

---

## 13. Decimal mismatch threat

Potential attack/failure:

```text
6-decimal stablecoin
18-decimal WAD
8-decimal oracle
```

incorrectly scaled, creating huge over/under-payments.

Every adapter/config must explicitly define source and destination decimals.

---

## 14. Rounding amplification

Repeated partial operations must not let users gain value through rounding.

Test:

```text
one large redemption
vs
many split redemptions
```

A user must not receive more by splitting claims.

---

# Part III — Series and token security

## 15. Immutable series economics

After creation, no role may alter:

```text
underlying
option type
strike
cap
contract size
expiry
settlementAsset
oracleConfigId
```

---

## 16. Canonical series identity

Duplicate or ambiguous series definitions can break integrations.

Prefer deterministic `seriesId` from immutable terms.

A token symbol is never authoritative.

---

## 17. Mint authorization

Only the authorized Optara issuance path may mint long tokens.

Minting must occur only after:

```text
post-write margin validation
matching short recording
```

---

## 18. Burn authorization

Authorized burn paths include:

```text
short close (EXTERNAL or LOCKED source)
expired-unfinalized cancellation
external redemption
locked-long settlement consumption
```

The implementation must prevent arbitrary third-party burns unless explicitly owner-approved.

---

## 19. Supply conservation

Before asynchronous post-expiry settlement:

```text
CurrentLongSupply
=
AggregateOpenShortQty
```

Post-expiry cumulative identities in `MATH.md`/`INVARIANTS.md` become authoritative.

---

# Part IV — MarginVault security

## 20. Vault role

MarginVault holds actual approved settlement stablecoins.

It should have minimal logic.

It must not calculate:

```text
option risk
margin
oracle price
```

---

## 21. Unauthorized transfer threat

No arbitrary caller or governance role may transfer accounted user collateral from the vault.

Token movement must be limited to authorized protocol flows.

---

## 22. Rescue-function threat

A generic:

```text
rescueToken(token, amount)
```

can become a collateral sweep backdoor.

Any rescue functionality must prove the amount is not required for:

```text
user effective cash claims
outstanding settled long claims
rounding reserve
other explicit protocol obligations
```

For approved settlement assets, safest MVP policy is no arbitrary rescue of accounted balances.

---

## 23. Token balance reconciliation

For each settlement asset:

```text
physical vault balance
```

must reconcile with protocol accounting identities.

Monitoring should alert on mismatch immediately.

---

# Part V — ERC-20 settlement-token threats

## 24. Fee-on-transfer

If:

```text
deposit 100
vault receives 99
ledger credits 100
```

protocol becomes insolvent.

The MVP MUST reject fee-on-transfer settlement assets (DD-040).

---

## 25. Rebasing

Rebase can alter vault balance without Optara transaction.

The MVP MUST reject rebasing settlement assets (DD-040).

---

## 26. Blacklist/freeze risk

Centralized stablecoin issuers may freeze Optara or users.

This can cause settlement liveness failure.

It must be disclosed and considered in asset approval.

It must not trigger automatic cross-stablecoin substitution.

---

## 27. Malicious token callbacks

Use safe ERC-20 interactions and reentrancy protection around token transfers.

Settlement assets should not rely on callback-heavy token standards in core MVP.

---

# Part VI — Reentrancy and state-ordering security

## 28. Reentrancy targets

High-risk functions include:

```text
deposit
withdraw
lockLong
unlockLong
closeShort
redeem
redeemToMargin if implemented
router-assisted workflows
```

---

## 29. Unsafe intermediate states

No external call may observe state where:

```text
cash debited but transfer outcome unresolved in exploitable form
cash released but margin still assumes it exists
locked hedge released but risk still counts it
long payout transferred but token not consumed
short reduced without matching long burn
```

---

## 30. Checks-effects-interactions

Use:

```text
checks
-> authoritative internal state effects
-> controlled external interactions
```

or another formally reviewed pattern.

Where external token failure should revert the entire operation, preserve atomicity.

---

# Part VII — Locked-hedge security

## 31. Real custody required

RiskEngine may recognize only:

```text
actual canonical long tokens
```

held by authorized Optara custody.

---

## 32. No external receipt recognition

Forbidden:

```text
Kuru says user owns token
vault share says token exposure
indexer says token balance
```

as hedge proof.

---

## 33. Unlock safety

Before releasing hedge:

```text
simulate without hedge
compute complete post-state margin
require cash >= requiredMargin
```

Then and only then release.

---

## 34. Matured locked hedge

At settlement, locked long must be:

```text
credited exactly once
consumed/burned exactly once
```

It must not later escape and redeem externally.

---

# Part VIII — Short-close security

## 35. Exact same series

Only the exact canonical same-series long can close a short.

Do not use approximate payoff equivalence.

---

## 36. Burn-before-or-atomically-with close

There must be no successful state where:

```text
short reduced
long remains externally spendable
```

---

## 37. Kuru fill is not close authorization

External trade events must never directly mutate Optara short state.

---

# Part IX — Oracle security

## 38. Oracle is critical only at finalization

Pre-expiry core margin does not require current spot.

This substantially reduces live-oracle attack surface.

---

## 39. Oracle configuration immutability

`oracleConfigId` must bind:

```text
provider/source
pair
normalization
observation rule
finality
fallback
rounding
```

for existing series.

---

## 40. Wrong-unit attack

Critical failure:

```text
MON/USD
used as
MON/USDT
```

especially during stablecoin depeg.

Adapter must output exact:

```text
settlementAsset per underlying
```

---

## 41. Stale-report attack

The adapter must verify report timing against the precommitted settlement observation rule.

Generic current-time staleness checks are insufficient for expiry settlement.

---

## 42. Caller-choice/MEV attack

If finalizer may choose among multiple valid observations:

```text
settlement becomes MEV-extractable
```

Minimize caller discretion.

---

## 43. Oracle replay

Provider data must be authenticated and constrained to:

```text
correct source
correct observation
correct chain/config
```

where provider semantics require it.

---

## 44. Derived-feed manipulation

For:

```text
underlying/USD
/
stablecoin/USD
```

both legs must satisfy compatible timing and validity rules.

---

## 45. Oracle fallback

Fallback must be precommitted.

Forbidden:

```text
governance chooses a "fair" price after expiry
```

---

# Part X — Settlement security

## 46. Single group finalization

One risk group may be finalized once.

All contained series share the same `S*`.

---

## 47. Finalization race

Multiple callers may race to finalize.

Only the first valid transition succeeds.

The winner must not influence economics.

---

## 48. Atomic matured-group sync

All matured shorts and locked longs in an account/group must settle together.

Partial group settlement is forbidden where portfolio netting determined pre-expiry margin.

---

## 49. Complete position enumeration

A caller must not omit an unfavorable short from `syncRiskGroup`.

Use protocol-maintained bounded canonical indexes.

---

## 50. Double-sync protection

A matured account/group cash delta may be applied once.

---

## 51. Double-redemption protection

Redemption burns long quantity.

Burned quantity cannot redeem again.

---

## 52. Redemption-before-writer-sync

Must remain safe through per-asset pooled accounting and encumbered matured writer debt.

Writer withdrawal cannot bypass unsynchronized debt.

---

# Part XI — Withdrawal security

## 53. Withdrawal is safety-critical

Before transfer:

```text
synchronize relevant finalized groups
simulate post-withdraw cash
recompute canonical margin
require safe state
```

---

## 54. Partial-position omission attack

Never trust user-supplied position list for safety unless completeness is cryptographically/state-proven.

---

## 55. Recipient handling

Withdrawal recipient may differ from account owner only if explicitly authorized by the account owner/calling account.

No privileged role should redirect ordinary user withdrawal.

---

# Part XII — Denial-of-service and gas security

## 56. Unbounded position spam

An attacker may try to create many tiny positions so future margin/sync exceeds gas limits.

Deployment must bound:

```text
active series/account
active groups/account
series/account/group
batch sizes
```

---

## 57. Self-DoS is still protocol risk

Even if only the user's own account becomes stuck, funds may become inaccessible.

The protocol must prevent entering unexecutable states.

---

## 58. Protocol-wide loops forbidden

No:

```text
for every writer
for every long holder
for every account
```

inside ordinary settlement.

---

# Part XIII — Kuru integration security

## 59. Kuru is external

Assume Kuru may be:

```text
illiquid
paused
upgraded
misconfigured
unavailable
```

Optara solvency must remain intact.

---

## 60. Kuru balance separation

Kuru balances are never Optara collateral or locked hedges.

---

## 61. Wrong market attack

`@optara/kuru` and official frontend must verify:

```text
base = exact series optionToken
quote = exact series settlementAsset
network/deployment = expected Kuru deployment
```

before presenting canonical workflows.

---

## 62. Slippage and order manipulation

Buy/sell helpers must expose:

```text
maximum input
minimum output
limit price
deadline where appropriate
```

Do not build buy-to-close workflows without slippage protection.

---

## 63. Buy-to-close atomicity

If a future on-chain router is used:

```text
obtain exact long
-> validate amount
-> close short
```

should be atomic where possible.

Router must not mark short closed based only on expected Kuru output.

---

# Part XIV — SDK and package security

## 64. SDK is untrusted by contracts

`@optara/sdk` cannot provide:

```text
trusted margin
trusted settlement price
trusted account health
trusted Kuru fill
trusted authorization
```

to core contracts.

---

## 65. SDK compromise impact goal

If the SDK package is compromised, it may attempt to construct malicious transactions.

Core contracts must still reject transactions violating protocol invariants.

The SDK compromise may still cause user-level harms such as:

```text
sending assets to attacker recipient
excessive approval
bad Kuru price
wrong transaction intent
```

so client security still matters.

---

## 66. SDK recipient validation

High-level SDK functions should make recipient fields explicit and display/return transaction targets before signing where practical.

Avoid hidden default recipients controlled by SDK infrastructure.

---

## 67. SDK approval safety

Avoid blanket unlimited approvals by default.

Prefer:

```text
exact amount
bounded amount
permit with explicit scope
```

where practical.

If unlimited approvals are offered, label them explicitly.

---

## 68. SDK network/address validation

Before building transactions, verify:

```text
chainId
contract deployment
settlement asset address
option token address
Kuru deployment
```

against trusted deployment metadata.

---

## 69. ABI/address supply-chain threat

A malicious package update could replace:

```text
ClearingHouse address
MarginVault address
token address
ABI semantics
```

Package releases must use reproducible/versioned deployment metadata and code review.

---

## 70. `@optara/math` security

`@optara/math` is advisory.

A bug can mislead users/frontends about:

```text
margin
payoff
free collateral
```

but must not create on-chain insolvency because contracts recompute.

Differential tests against Solidity are mandatory.

---

## 71. `@optara/kuru` security

Threats include:

```text
wrong market
wrong quote token
bad slippage
stale order book
malicious recipient
incorrect custody assumption
```

Package must never claim a short is closed until on-chain Optara state confirms it.

---

## 72. Package dependency risk

Minimize third-party dependencies for:

```text
transaction encoding
math
address handling
signing
```

Pin/audit important dependencies and use lockfiles.

---

## 73. Package release security

Recommended:

```text
protected release branch
reviewed CI
tagged versions
package integrity verification
2-person release approval
no long-lived registry tokens in developer machines
short-lived CI publishing credentials where possible
```

---

# Part XV — Frontend security

## 74. Frontend is not authoritative

A compromised frontend cannot be allowed to bypass contract safety.

Users may still be tricked into signing harmful but valid transactions, so frontend security matters.

---

## 75. Transaction transparency

Before signature, UI should clearly show:

```text
action
series
quantity
settlement asset
recipient
allowance
expected margin effect
Kuru limit/slippage
```

---

## 76. Phishing-resistant identifiers

Use canonical contract addresses and series metadata.

Do not trust token symbol/name alone.

---

## 77. Preview staleness

UI must communicate that:

```text
margin preview
Kuru quote
oracle preview
```

can change before inclusion.

Contract execution is final authority.

---

# Part XVI — Indexer security

## 78. Indexer is eventual-consistency infrastructure

Never gate safety-critical actions exclusively on indexer state.

---

## 79. Missing/reordered events

Indexer must handle:

```text
reorgs
duplicate events
event lag
failed transactions
```

and reconcile against on-chain state.

---

# Part XVII — Keeper/bot security

## 80. Keeper permissions

Prefer permissionless deterministic maintenance.

A keeper should not need privileged economic authority to:

```text
finalize valid group
sync finalized group
```

---

## 81. Keeper compromise

A compromised keeper should at most:

```text
submit valid deterministic maintenance early/late within allowed rules
waste its own gas
```

It should not:

```text
choose settlement price
redirect user funds
alter series
```

---

# Part XVIII — Access-control security

## 82. Least privilege

Roles must be narrowly scoped.

Avoid one omnipotent operator for routine operation.

See `ACCESS_CONTROL.md`.

---

## 83. Separation of duties

Recommended separation:

```text
governance
pauser/guardian
series/oracle configuration admin
upgrade executor if applicable
internal contract roles
```

---

## 84. Privilege escalation

Review every role-admin relationship.

No operational role should be able to grant itself governance.

---

## 85. Key compromise

Privileged keys should be multisig/timelock protected according to role impact.

Emergency pauser may require faster authority than governance but narrower powers.

---

# Part XIX — Upgradeability security

## 86. Upgradeability is high risk

If contracts are upgradeable, an upgrade can bypass every invariant.

Therefore upgrade authority is effectively custody authority over the protocol.

---

## 87. Upgrade controls

If upgradeable, require:

```text
multisig governance
timelock for ordinary upgrades
public upgrade payload
storage-layout checks
tests against current state
emergency procedure separately bounded
```

---

## 88. Immutable economics across upgrade

An upgrade must not reinterpret existing series in a way that changes:

```text
strike
cap
expiry
settlement asset
oracle settlement semantics
```

without an explicit migration approved under documented emergency policy.

---

## 89. Storage collision

Upgradeable deployments require automated storage-layout comparison.

A storage collision affecting balances or positions is critical.

---

# Part XX — External integration / composability security

## 90. External vaults

Vault shares are not canonical Optara claims.

Only actual long tokens can redeem or become locked hedges.

---

## 91. Lending protocols

Optara does not guarantee external LTV or liquidations.

Their failure must not mutate Optara accounting.

---

## 92. Routers

Routers are hostile boundaries.

They must not retain funds, fake custody, or bypass canonical checks.

---

## 93. Cross-chain wrappers

Not core V2.

Any bridge/wrapped option introduces:

```text
double-redemption
bridge compromise
canonical ownership
settlement timing
```

risks and requires separate design.

---

# Part XXI — MEV and transaction-ordering threats

## 94. Write/front-run

Because required margin is based on contractual terms rather than current price, spot-price front-running cannot make the position undercollateralized.

However external premium execution on Kuru remains price-sensitive.

---

## 95. Kuru trade MEV

Use limit prices/slippage bounds.

Never combine:

```text
unbounded Kuru market order
+
critical Optara state change
```

without user protection.

---

## 96. Settlement MEV

Finalizer must not choose among economically different observations.

Who calls finalization should not alter result.

---

## 97. Withdrawal ordering

Concurrent account transactions may invalidate SDK previews.

On-chain post-state checks prevent unsafe withdrawals.

---

# Part XXII — Pause and incident-security model

## 98. Pause philosophy

Pause the smallest unsafe surface.

Do not automatically freeze risk-reducing/settlement paths unless the incident affects those paths.

---

## 99. Typical risk pause

Block:

```text
new writes
withdrawals if health cannot be proven
unsafe hedge unlock
new affected series
```

Preserve where safe:

```text
deposits
hedge locks
same-series closes
trusted settlement
sync
redemption
```

---

## 100. Oracle incident

Pause affected finalizations and new risk using the bad config.

Do not invent a settlement price.

---

## 101. Vault/token incident

Pause token movement for affected asset if physical transfer/accounting cannot be trusted.

Do not use another stablecoin automatically.

---

## 102. RiskEngine incident

Pause:

```text
writes
withdrawals
unlock
```

that depend on suspect risk results.

Preserve independently safe reduction paths.

---

# Part XXIII — Security monitoring

## 103. High-priority alerts

Monitor:

```text
VaultBalance != expected accounting
CashBalance < RequiredMargin
negative effective account balance
unexpected OptionToken mint
unexpected OptionToken burn
finalization attempt failures
oracle config suspension
ORACLE_STALLED groups (escalation deadline passed)
large role changes
pause/unpause
AssetRestricted / Recapitalized / ShortfallResolved events
aggregate exposure near caps
rounding reserve anomalies
```

Direct token donations show up as unallocated surplus; they are logged, not treated as
an accounting mismatch (INV-VAULT-07). Canonical V2 has no upgrade events to watch.

---

## 104. Cross-layer monitoring

Monitor package/deployment consistency:

```text
SDK deployment addresses
frontend addresses
chainId
contract version
ABI version
Kuru market metadata
```

---

# Part XXIV — Testing strategy

## 105. Unit tests

Every pure calculation and transition branch.

---

## 106. Fuzz tests

At minimum fuzz:

```text
series terms
portfolio composition
quantities
stablecoin decimals
settlement prices
action order
redemption order
sync order
```

---

## 107. Stateful invariant tests

Handlers should attempt arbitrary valid sequences:

```text
deposit
write
lock
unlock
close
withdraw
expire
finalize
sync
redeem
```

Assert all `INVARIANTS.md` properties.

---

## 108. Differential tests

Compare:

```text
Solidity PayoffMath/RiskEngine/Settlement
vs
@optara/math
```

for independently generated reference cases.

---

## 109. Adversarial token tests

Use malicious mocks:

```text
fee-on-transfer
reentrant token
false-return ERC20
no-return ERC20
rebasing-like behavior
blacklist simulation
```

Ensure unsupported behavior cannot corrupt accounting.

---

## 110. Access-control tests

For every privileged function:

```text
authorized role succeeds
every unrelated role reverts
role renunciation/revocation works
admin hierarchy cannot self-escalate unexpectedly
```

---

## 111. SDK security tests

Test:

```text
wrong chain
wrong contract address
wrong Kuru market
slippage violation
stale preview
unexpected recipient
approval scope
```

---

# Part XXV — Audit priorities

## 112. Critical audit areas

Highest priority:

```text
RiskEngine exactness
PayoffMath
fixed-point rounding
withdraw safety
hedge custody
short/long conservation
atomic matured settlement
redemption
oracle normalization/finalization
vault reconciliation
access control
upgrade path if any
```

---

## 113. Integration audit areas

Also review:

```text
@optara/math differential correctness
@optara/sdk transaction construction
@optara/kuru market verification/slippage
deployment metadata
oracle adapter/provider assumptions
```

Off-chain bugs may not create protocol insolvency directly but can still cause user losses.

---

# Part XXVI — Security invariants summary

## 114. SEC-INV-01

```text
no write succeeds below exact required margin
```

## 115. SEC-INV-02

```text
no withdrawal/unlock succeeds if post-state unsafe
```

## 116. SEC-INV-03

```text
no long mint without matching short
```

## 117. SEC-INV-04

```text
no short close without same-series long consumption
```

## 118. SEC-INV-05

```text
no locked hedge margin credit without custody
```

## 119. SEC-INV-06

```text
no long quantity consumed more than once
```

## 120. SEC-INV-07

```text
no short quantity settled more than once
```

## 121. SEC-INV-08

```text
no risk group finalized more than once
```

## 122. SEC-INV-09

```text
no USDT accounting uses USDC to satisfy it
```

## 123. SEC-INV-10

```text
SDK/Kuru/indexer output cannot bypass on-chain checks
```

## 124. SEC-INV-11

```text
no protocol-wide unbounded settlement loop
```

## 125. SEC-INV-12

```text
no privileged role may rewrite existing series economics
```

---

# 126. Pre-deployment security checklist

- [ ] exact payout math formally reviewed;
- [ ] RiskEngine reference model implemented independently;
- [ ] differential fuzz suite passing;
- [ ] all invariant tests passing;
- [ ] all account/group iteration bounded;
- [ ] all supported stablecoins exact-transfer tested;
- [ ] all oracle configs pair-denomination tested;
- [ ] finalization caller discretion minimized;
- [ ] withdrawal sync completeness proven;
- [ ] locked-long custody reconciliation tested;
- [ ] vault accounting reconciliation tested;
- [ ] access-control matrix tested;
- [ ] upgrade/storage review complete if upgradeable;
- [ ] emergency pause semantics tested;
- [ ] Kuru workflows include market identity + slippage validation;
- [ ] SDK rejects wrong network/deployment metadata;
- [ ] package publishing process secured;
- [ ] external independent audit complete;
- [ ] deployment bytecode/config verified;
- [ ] monitoring alerts live before enabling new risk.

---

# 127. Final security principle

Optara's strongest security property is not an emergency liquidator.

It is prevention:

```text
bounded claim
+
exact worst-case margin
+
real same-asset custody
+
locked hedge custody
+
deterministic settlement
+
strict trust boundaries
```

The SDK architecture must preserve that design:

```text
@optara/math
@optara/sdk
@optara/kuru
```

may improve usability and composability, but they must never become shortcuts around the authoritative contracts.

---

## 128. Required review regressions and trust boundaries

The exact numerator algorithm in `MATH.md` replaces intermediate payoff rounding.
Test fragmented writers, merged redeemers, mixed contract sizes, interior prices,
and overflow bounds. Donation surplus is neither margin nor an incident.

Primary-sale payment and delivery MUST be atomic; SDK sequencing cannot guarantee
seller delivery. `PROTOCOL_SPEC.md` section 41 preserves fully reserved unresolved
expiry and enables safe recovery without changing the payoff. Historical oracle
availability remains a disclosed settlement-liveness dependency.

`LIQUIDATION.md` section 101 defines persistent separate-transaction containment and
asset-wide payout gates. A failed financial transaction does not persist a pause.
Section 102 there defines the only exit when backing was lost: a timelocked,
evidence-backed uniform recovery ratio, never first-come-first-served payout.
`PROTOCOL_SPEC.md` section 42 defines Sybil-resistant aggregate issuance caps,
released per risk group at finalization.
`ACCESS_CONTROL.md` sections 40–45 require immutable core bindings for existing
obligations. Earlier conditional upgrade guidance applies only to separately
specified future variants, not canonical V2.
