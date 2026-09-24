# Optara V2 — Access Control Specification

**Document type:** Normative authorization, role, privilege, and administrative-security specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Engineering specification; exact production signers/multisig thresholds remain deployment parameters

---

## 1. Purpose

This document defines who may perform privileged actions in Optara V2 and, equally importantly, who must **not** have authority.

It covers:

- user authority;
- contract-to-contract authority;
- governance authority;
- pauser/guardian authority;
- series/pair/oracle configuration authority;
- keeper permissions;
- token mint/burn permissions;
- vault transfer permissions;
- upgrade authority if the deployment is upgradeable;
- SDK/package authority boundaries;
- Kuru integration authority;
- role administration;
- multisig/timelock expectations;
- emergency privilege restrictions;
- access-control tests and invariants.

The central rule is:

> **Off-chain software does not become a privileged protocol actor merely because it orchestrates Optara.**

Therefore:

```text
@optara/math
@optara/sdk
@optara/kuru
frontend
indexer
market maker bot
```

have **zero implicit on-chain privilege**.

They act only through:

```text
user signatures
permissionless functions
explicitly assigned on-chain roles
```

This document must be read with:

- `ARCHITECTURE.md`
- `PROTOCOL_SPEC.md`
- `SECURITY.md`
- `INVARIANTS.md`
- `STATE_MACHINE.md`
- `ORACLE_AND_SETTLEMENT.md`
- `COMPOSABILITY.md`
- `LIQUIDATION.md`

---

# 2. Access-control objectives

The access-control system must guarantee:

1. users control their own ordinary account actions;
2. contracts receive only the internal permissions they need;
3. governance cannot rewrite existing option economics;
4. emergency roles cannot become permanent super-admins;
5. keepers cannot choose economic outcomes;
6. SDKs cannot bypass on-chain authorization;
7. Kuru cannot mutate Optara accounting directly;
8. upgrade authority, if present, is explicitly treated as the highest-risk privilege;
9. role changes are observable and testable;
10. no role hierarchy permits unintended privilege escalation.

---

# 3. Authority classes

Optara distinguishes five classes.

```text
A. USER AUTHORITY
B. PERMISSIONLESS MAINTENANCE
C. INTERNAL CONTRACT AUTHORITY
D. OPERATIONAL ADMIN AUTHORITY
E. GOVERNANCE / UPGRADE AUTHORITY
```

These should not be conflated.

---

# Part I — User authority

## 4. Account owner authority

A user/account owner may ordinarily:

```text
deposit their assets
write against their account
lock their long tokens
unlock if post-state safe
close their own shorts
withdraw their own free collateral
redeem long tokens they own/control
```

subject to protocol checks.

---

## 5. User authority is not absolute

An account owner cannot override:

```text
margin requirement
series state
expiry
settlement price
stablecoin isolation
position limits
pause restrictions
```

Ownership does not authorize insolvency.

---

## 6. Recipient delegation

Functions may allow recipient parameters:

```text
write(..., longRecipient)
withdraw(..., recipient)
redeem(..., recipient)
```

The calling account must authorize the economic action.

A recipient does not automatically gain authority over the source account.

---

## 7. ERC-20 allowance authority

A user may authorize:

```text
ClearingHouse
router
```

to transfer settlement stablecoins or option tokens via standard allowance/permit mechanisms.

Allowance does not grant:

```text
admin rights
margin override
settlement override
```

---

# Part II — SDK and client authority

## 8. `@optara/sdk`

`@optara/sdk` is code executed on behalf of an application/user.

It has no protocol role.

It may:

```text
read contracts
build calldata
estimate/precompute
request user signature
submit signed transaction
```

It may not:

```text
grant itself role
bypass role check
supply trusted margin result
supply trusted settlement result
move user funds without authorization
```

---

## 9. SDK keys

A public SDK package SHOULD NOT require a shared privileged private key.

If an application backend uses a service key for:

```text
relaying
sponsored transactions
keeper calls
```

that key's authority is limited to the explicit account/role assigned to it.

---

## 10. `@optara/math`

No role.

Pure/advisory.

---

## 11. `@optara/kuru`

No Optara privilege merely from package use.

It may orchestrate user-authorized Kuru and Optara transactions.

A Kuru trading API key, if any, is not an Optara admin key.

---

## 12. Frontend/indexer

No on-chain role.

A compromised frontend/indexer must not gain governance or protocol custody authority by design.

---

# Part III — Permissionless maintenance

## 13. Keeper principle

Prefer permissionless deterministic functions where callers cannot choose economics.

Examples:

```text
finalizeRiskGroup
syncRiskGroup
```

if fully deterministic and safely implemented.

---

## 14. Permissionless finalization

Any caller MAY finalize when:

```text
group expired
config permits finalization
oracle data is valid
group not finalized
```

The caller cannot choose:

```text
settlement methodology
strike
cap
acceptable observation window
arbitrary settlement price
```

---

## 15. Permissionless synchronization

Any caller MAY synchronize another account's finalized risk group if:

```text
cash delta is fully deterministic
recipient cannot be changed
no caller reward is taken from account unless separately specified
```

---

## 16. Keeper role only if necessary

If a provider/infrastructure constraint requires a `KEEPER_ROLE`, its power should be no greater than:

```text
trigger deterministic maintenance
```

It should not have custody or economic discretion.

---

# Part IV — Internal contract authority

## 17. Internal roles

Recommended internal roles may include:

```text
MINTER_ROLE
BURNER_ROLE
VAULT_OPERATOR_ROLE
SETTLEMENT_ENGINE_ROLE
CLEARINGHOUSE_ROLE
FACTORY_ROLE
```

Exact implementation may use:

```text
role-based access
immutable trusted contract addresses
direct caller checks
```

Choose the simplest auditable design.

---

## 18. OptionToken mint authority

Only the canonical issuance path may mint.

Recommended:

```text
OptionToken
    mint()
only callable by
ClearingHouse or dedicated authorized minter
```

Mint authorization must not be granted to:

```text
SDK
Kuru
frontend
EOA operator
market maker
keeper
```

---

## 19. OptionToken burn authority

Burn may be authorized to the canonical components that consume claims:

```text
ClearingHouse
SettlementEngine
```

or centralized through one canonical component.

Avoid unnecessarily broad burn roles.

---

## 20. MarginVault operator

Only canonical protocol components may move accounted vault assets.

Recommended:

```text
ClearingHouse
SettlementEngine
```

through narrowly scoped functions.

Do not expose a generic:

```text
transferAnyToken(anyRecipient, anyAmount)
```

to a routine role.

---

## 21. SettlementEngine authority

SettlementEngine may:

```text
read finalized group prices
calculate/consume claims
request authorized settlement transfers
```

It may not:

```text
invent settlement price
change series terms
mint unsecured longs
```

---

## 22. OracleAdapter authority

OracleAdapter validates data.

It need not hold user funds.

It should not have:

```text
vault sweep
token mint
margin override
```

permissions.

---

# Part V — Governance authority

## 23. Governance role

Conceptually:

```text
GOVERNANCE_ROLE
```

may control future protocol configuration, subject to timelocks and immutable-economic constraints.

---

## 24. Governance may approve future assets

Governance may:

```text
approve underlying
approve settlement stablecoin
approve pair
disable pair for new risk
retire pair for future risk
```

---

## 25. Governance may approve oracle configs

Governance may register/suspend oracle configurations for **future** series.

It may not silently replace an existing series' oracle semantics.

---

## 26. Governance may configure limits

Governance may set prospective limits such as:

```text
max series/account
max groups/account
max series/group
quantity bounds
future safety buffer
future creation permissions
```

Changes apply prospectively only. They must never invalidate already valid economic claims or block processing of existing positions (INV-POLICY-01).

---

## 27. Governance may manage operational roles

Governance may grant/revoke:

```text
PAUSER_ROLE
CONFIG_ROLE
SERIES_CREATOR_ROLE
```

subject to role-admin hierarchy.

---

## 28. Governance forbidden actions

Ordinary governance MUST NOT directly:

```text
rewrite strike
rewrite cap
rewrite expiry
rewrite option type
rewrite contract size
rewrite settlement asset
rewrite existing oracleConfigId
rewrite finalized settlement price
seize user cash
burn user long claims without valid protocol path
forgive selected writer debt
```

---

# Part VI — Configuration authority

## 29. CONFIG_ROLE

A separate configuration role MAY manage low/medium-risk prospective settings.

Examples:

```text
new-pair enablement after governance approval
new-series parameter bounds
operational position caps
supported oracle config activation
```

---

## 30. Config role limitations

`CONFIG_ROLE` must not have:

```text
upgrade authority
user collateral transfer authority
existing-series mutation authority
finalized-price mutation authority
role-admin authority
```

---

## 31. Series creator role

If series creation is not permissionless:

```text
SERIES_CREATOR_ROLE
```

may create only series satisfying factory validation and approved pair/oracle rules.

The role cannot bypass:

```text
strike/cap constraints
expiry rules
pair approval
oracle approval
duplicate checks
```

---

# Part VII — Pauser / guardian authority

## 32. PAUSER_ROLE

A narrowly scoped emergency role.

Goal:

```text
stop damage quickly
without gaining financial discretion
```

---

## 33. Pauser may block new risk

Typical permitted actions:

```text
pause write
pause new series
pause affected pair/oracle config
pause unsafe withdrawal if health cannot be trusted
pause unsafe unlock
```

---

## 34. Pauser should preserve safe reductions

Where the incident permits:

```text
deposit
lock hedge
close short
trusted sync
trusted redemption
```

should remain available.

---

## 35. Pauser cannot rewrite economics

Pauser cannot:

```text
change price
change cap
change strike
change settlement asset
transfer user collateral
mint/burn arbitrary claims
```

---

## 36. Unpause authority

Recommended:

```text
PAUSER_ROLE may pause
GOVERNANCE_ROLE or dedicated UNPAUSER_ROLE may unpause
```

This prevents a compromised fast pauser from repeatedly unpausing its own containment.

Exact design is deployment-specific.

---

# Part VIII — Oracle administrative authority

## 37. ORACLE_CONFIG_ROLE

If separated from general governance, this role may:

```text
register future oracle configs
suspend config for new series
register provider addresses for future configurations only; never replace an existing group binding
```

---

## 38. Existing-series protection

Existing series pin adapter address, immutable rule/version, sources and normalization.
Optara governance MUST NOT redirect them through a mutable provider registry.
Provider-owned upgrades remain disclosed external trust assumptions and must be
covered by source onboarding, monitoring and precommitted failure behavior.

---

## 39. Finalizer has no admin authority

A finalizer/keeper cannot:

```text
edit oracleConfig
select arbitrary source
select arbitrary timestamp
override validation
```

---

# Part IX — Upgrade authority

## 40. Core V2 immutable version policy

The canonical V2 financial core MUST be an immutable, versioned deployment.
ClearingHouse, MarginVault, RiskEngine, SettlementEngine, OptionToken logic and the
oracle adapter/rule bindings for issued series MUST NOT be upgradeable or replaceable
through proxies, mutable beacons, delegatecall targets, peer setters, role regrants,
or mutable registries. Internal mint/burn/vault privileges are pinned to canonical
contracts and cannot be reassigned after activation. Factory changes may affect
future versioned deployments only. Underlying oracle-provider/token issuer upgrades
remain explicit external assumptions; Optara does not control them.

Governance retains narrowly scoped pauses and prospective new-risk configuration.
Existing group buffer rules, series economics and settlement code remain fixed.
A replacement core accepts new obligations while the old core completes its existing
claims. Migration of free assets is user-authorized; encumbered shorts/hedges cannot
be forced across cores. A critical immutable-core defect may require containment
and separately designed recovery; this policy does not promise automatic repair.

## 41. Peripheral releases

SDKs, frontends, indexers and venue registries may be replaced without changing
existing claims or gaining custody authority. Users can call the pinned core directly.

## 42. Timelock limitations

A timelock is notice, not a guaranteed exit: writers may have encumbered collateral,
illiquid buybacks, or unresolved oracle observations. Documentation MUST NOT imply
that advance notice lets every account exit.

## 43. Future upgradeable variants

An upgradeable financial core is a different, explicitly disclosed trust model and
requires a separate approved specification. Conditional upgrade tests elsewhere
apply only to that future variant, not to canonical V2. No core `UPGRADER_ROLE`
is assigned in the MVP; the manifest records upgrade tests as not applicable and
instead proves no implementation or peer-replacement path exists.

## 44. Deployment initialization

Bind peers and internal authorities atomically before risk activation. One-time
configuration MUST become permanently sealed; test takeover and resealing attempts.

## 45. Existing obligation protection

No ordinary or emergency role can change an issued claim's implementation, storage
interpretation, oracle binding, settlement price or internal custody authority.

---

# Part X — Role administration

## 46. Default admin risk

An unrestricted `DEFAULT_ADMIN_ROLE` controlling every role is extremely powerful.

If used, it should be held only by the highest-security governance mechanism.

---

## 47. Role-admin graph

Recommended conceptual hierarchy:

```text
GOVERNANCE
    |
    +--> CONFIG_ROLE
    +--> SERIES_CREATOR_ROLE
    +--> ORACLE_CONFIG_ROLE
    +--> PAUSER_ROLE
    +--> optional KEEPER_ROLE
    +--> no core UPGRADER_ROLE in canonical V2
```

Internal contract roles MUST be assigned and permanently sealed before activation; governance cannot grant or revoke these roles for an active core.

---

## 48. No self-escalation

A role must not be able to grant itself a stronger role unless it is intentionally that role's administrator.

Examples forbidden:

```text
PAUSER -> grants GOVERNANCE
KEEPER -> grants VAULT_OPERATOR
SERIES_CREATOR -> grants UPGRADER
```

---

## 49. Role revocation

Governance must be able to revoke compromised operational roles.

Revocation events must be emitted.

---

## 50. Role renunciation

Operational roles may support self-renunciation where safe.

Governance/admin renunciation must not accidentally make required administration impossible without a planned immutable-governance design.

---

# Part XI — Multisig and timelock policy

## 51. High-impact roles

Should not be single EOAs in production:

```text
GOVERNANCE
UPGRADER
high-impact CONFIG / ORACLE admin
```

---

## 52. Fast-response role

`PAUSER_ROLE` may be held by a faster-response signer or smaller multisig because it can only **reduce** available actions.

Its powers must remain narrow.

---

## 53. Timelock scope

Timelock required for:

```text
new high-risk asset approvals
material risk-limit increases
governance role changes
resolveShortfall (LIQUIDATION.md section 102)
```

Canonical V2 has no core upgrades to timelock (section 40).

Emergency pause need not be timelocked.

---

# Part XII — Access-control matrix

## 54. Role/action matrix

Legend:

```text
U = user/account authority
P = permissionless deterministic caller
I = internal contract only
C = config role
G = governance
E = emergency pauser
X = forbidden
```

| Action | U | P | I | C | G | E |
|---|---:|---:|---:|---:|---:|---:|
| Deposit own collateral | U | X | X | X | X | X |
| Write own short | U | X | X | X | X | X |
| Lock own long | U | X | X | X | X | X |
| Unlock own long if safe | U | X | X | X | X | X |
| Close own short | U | X | X | X | X | X |
| Withdraw own free collateral | U | X | X | X | X | X |
| Redeem owned long | U | X | X | X | X | X |
| Finalize valid group | X | P | optional I | X | X | X |
| Sync finalized account group | U | P | optional I | X | X | X |
| Mint long | X | X | I | X | X | X |
| Burn long in protocol path | X | X | I | X | X | X |
| Move vault collateral | X | X | I | X | X | X |
| Create approved series | X | optional P | I/role | C | G | X |
| Approve future pair | X | X | X | optional C | G | X |
| Approve future oracle config | X | X | X | C | G | X |
| Pause new writes | X | X | X | X | G | E |
| Unpause | X | X | X | X | G | optional separate role |
| Restrict asset (verified deficit) | X | P (`checkAndRestrict`) | X | X | G | E (`restrictAsset`) |
| Clear asset restriction | X | X | X | X | G | X |
| Resolve verified shortfall | X | X | X | X | G/timelock | X |
| Recapitalize (donate to surplus) | U | P | X | X | G | X |
| Rewrite existing series | X | X | X | X | X | X |
| Rewrite finalized price | X | X | X | X | X | X |
| Upgrade existing V2 core | X | X | X | X | X | X |

Exact implementation may split more narrowly.

---

# Part XIII — Kuru authority

## 55. Kuru has no Optara role

Kuru contracts must not receive:

```text
MINTER_ROLE
VAULT_OPERATOR_ROLE
GOVERNANCE_ROLE
MARGIN_OVERRIDE
```

simply because Optara integrates with Kuru.

---

## 56. Kuru market maker has no protocol privilege

A market maker is an ordinary user/integration actor.

Its large inventory does not grant special rights.

---

## 57. `@optara/kuru` has no shared privileged signer

The package should operate through:

```text
user wallet
user smart account
optional independent relayer
```

not a hidden protocol admin key.

---

# Part XIV — Router authority

## 58. Optional router

If a future on-chain router exists, it should have no privilege beyond:

```text
calling public functions
temporarily moving user-approved assets
```

unless strictly necessary.

---

## 59. Router must not receive margin override

Never grant a router authority to tell ClearingHouse:

```text
skip risk check
trust collateral
trust external fill
```

---

## 60. Router custody

If router temporarily holds assets during an atomic workflow:

```text
unused assets
```

must be returned according to explicit logic.

Persistent custody should be avoided.

---

# Part XV — Emergency authority

## 61. Restricted account

After a verified invariant failure the affected settlement asset is restricted
(`LIQUIDATION.md` section 101), by permissionless `checkAndRestrict` on a reproducible
deficit or by the guardian's `restrictAsset`.

Restriction only stops actions:

```text
new risk
withdrawals, redemptions and other outflows of the asset
hedge unlocks
ordinary deposits (cure deposits and recapitalize remain)
```

It never seizes, moves or re-prices assets.

---

## 62. Emergency settlement pause

A guardian may pause affected finalization if oracle/settlement correctness is uncertain.

They cannot provide substitute price.

---

## 63. Asset disablement

Emergency role may disable:

```text
new writes
new series
new deposits if token unsafe
```

for affected asset.

Existing claims remain denominated in the original asset.

---

# Part XVI — Access control and the SDK architecture

## 64. User signing flow

Canonical:

```text
@optara/sdk
    |
    | builds transaction
    v
user wallet / smart account
    |
    | signs
    v
Optara contract
    |
    | validates authorization + safety
    v
state transition
```

SDK never becomes the signer unless the user explicitly uses a delegated account architecture outside core protocol assumptions.

---

## 65. Relayer flow

A relayer may submit a user-authorized transaction.

Authentication must still come from:

```text
msg.sender account architecture
signature
permit
meta-transaction scheme
```

not relayer identity alone.

---

## 66. Read APIs

No authorization needed for public reads.

SDK/indexers may cache them.

---

## 67. Admin SDK

If an internal operational SDK is later built, it must not embed admin private keys in package source/config.

Admin signing occurs through secure wallet/multisig infrastructure.

---

# Part XVII — Function-level authorization recommendations

## 68. `deposit`

Authority:

```text
any user for self
optionally depositFor(account) if explicitly supported
```

If `depositFor` exists, it only increases another account's cash; it must not authorize withdrawal later.

While the asset is restricted, `deposit`/`depositFor` accept only a cure deposit into an
account below its requirement, up to its deficit; `recapitalize(asset, amount)` is
permissionless and credits no account (`PROTOCOL_SPEC.md` section 10).

---

## 69. `withdraw`

Authority:

```text
account owner / authorized account executor
```

No keeper/governance arbitrary withdrawal.

---

## 70. `write`

Authority:

```text
account owner / explicitly authorized account operator
```

If operator delegation exists, it must be deliberately specified.

MVP may omit delegated operators for simplicity.

---

## 71. `lockLong`

Authority:

```text
token owner / authorized account executor
```

Actual token transfer required.

---

## 72. `unlockLong`

Authority:

```text
account owner / authorized executor
```

subject to safety check.

---

## 73. `closeShort`

Authority:

```text
account owner / authorized executor
```

or potentially permissionless if another party voluntarily supplies exact same-series long **without gaining account assets**.

For MVP, account-authorized close is simplest. The `LOCKED` source always requires the
account owner's authorization, because it consumes that account's hedge.

---

## 74. `finalizeRiskGroup`

Preferred:

```text
permissionless
```

with deterministic oracle validation.

---

## 75. `syncRiskGroup`

Preferred:

```text
permissionless
```

if no caller-controlled recipient or economic parameter exists.

---

## 76. `redeem`

Authority:

```text
long-token owner / approved spender
```

Recipient flexibility must be owner-authorized.

---

# Part XVIII — Internal caller validation

## 77. Contract-address pinning

If one contract trusts another:

```text
ClearingHouse -> MarginVault
SettlementEngine -> MarginVault
```

caller checks must point to canonical deployed addresses.

---

## 78. Upgradeable peer contracts

If peer addresses are mutable:

```text
who may update them
timelock
compatibility
```

must be explicit.

Avoid arbitrary peer replacement by operational roles.

---

## 79. Initialization

Every upgradeable/access-controlled contract must prevent:

```text
uninitialized takeover
double initialization
```

Initialize role admins and dependencies atomically where possible.

---

# Part XIX — Role-change events

## 80. Required observability

Emit events for:

```text
RoleGranted
RoleRevoked
RoleAdminChanged
PairApproved
PairDisabled
OracleConfigApproved
OracleConfigSuspended
Pause
Unpause
UpgradeScheduled
UpgradeExecuted
```

as applicable.

---

## 81. Monitoring

Security monitoring should alert on:

```text
governance membership change
upgrader change
pauser change
vault-operator change
oracle-admin change
unexpected internal role assignment
```

---

# Part XX — Upgrade authorization sequence

## 82. Recommended ordinary upgrade

```text
proposal prepared
        |
        v
multisig/governance approval
        |
        v
timelock queued
        |
        v
public delay
        |
        v
execute upgrade
        |
        v
post-upgrade invariant checks
```

---

## 83. Upgrade cannot skip migration validation

Before execution:

```text
storage layout
role state
series state
cash balances
short balances
locked longs
finalized settlements
```

must remain interpretable.

---

# Part XXI — Threat scenarios

## 84. Compromised pauser

Worst intended power:

```text
temporarily deny selected operations
```

Not:

```text
steal collateral
change price
mint claims
upgrade code
```

---

## 85. Compromised config role

Worst intended power should be limited to future configuration.

Existing claims remain immutable.

---

## 86. Compromised keeper

Should not steal or alter economics.

---

## 87. Compromised SDK package

May trick user into a bad transaction, but cannot make contracts accept:

```text
under-margin write
fake hedge
fake settlement
```

---

## 88. Compromised governance/upgrader

This is the catastrophic privilege in an upgradeable system.

Mitigate with:

```text
multisig
timelock
monitoring
minimal upgrade surface
```

---

# Part XXII — Access-control invariants

## 89. AC-INV-01 — SDK non-privilege

```text
@optara/sdk has no implicit on-chain role
```

---

## 90. AC-INV-02 — Kuru non-privilege

```text
Kuru and @optara/kuru cannot mint, move vault funds, or alter shorts directly
```

---

## 91. AC-INV-03 — Mint restricted

```text
only canonical issuance contract can mint long
```

---

## 92. AC-INV-04 — Vault movement restricted

```text
only canonical settlement/clearing paths can move accounted collateral
```

---

## 93. AC-INV-05 — Admin cannot rewrite existing series

No privileged role has a normal function capable of changing existing economic terms.

---

## 94. AC-INV-06 — Finalized price immutable

No role can overwrite finalized price.

---

## 95. AC-INV-07 — Pauser cannot seize

Pause privilege gives zero ordinary collateral-transfer authority.

---

## 96. AC-INV-08 — Keeper has no discretion

Keeper cannot choose economic outcome.

---

## 97. AC-INV-09 — No role self-escalation

Operational roles cannot grant themselves stronger roles.

---

## 98. AC-INV-10 — Upgrade authority explicit

Canonical V2 exposes no financial implementation-changing path. Future upgradeable variants require a separate specification and designated governance path.

---

# Part XXIII — Testing requirements

## 99. Function-by-function authorization tests

For every external mutating function, test:

```text
allowed caller
disallowed caller
zero address
proxy/admin edge cases
```

---

## 100. Role escalation fuzzing

Randomly grant/revoke allowed roles in test harness and assert unauthorized role graph paths cannot reach stronger privileges.

---

## 101. Pause matrix tests

Verify exact behavior in:

```text
NORMAL
RISK_PAUSED
SETTLEMENT_PAUSED
ASSET_RESTRICTED
```

---

## 102. Internal-role tests

Attempt direct calls to:

```text
mint
vault transfer
internal burn
```

from:

```text
user
governance
pauser
keeper
SDK-simulated relayer
```

and ensure only intended canonical contract paths succeed.

---

## 103. Version and binding tests

Canonical V2 MUST prove no upgrade, peer-replacement or internal-role reassignment
path exists after activation (VER-001/002). Only a separately specified future
upgradeable variant may instead run:

```text
unauthorized upgrade reverts
timelock enforced
initializer cannot be replayed
storage preserved
roles preserved
```

---

# 104. Deployment checklist

- [ ] governance signer architecture selected;
- [ ] governance is not a single production EOA;
- [ ] pauser powers narrower than governance;
- [ ] unpause authority explicitly defined;
- [ ] role-admin graph reviewed;
- [ ] no self-escalation path;
- [ ] internal mint/burn roles assigned only to canonical contracts;
- [ ] vault operators assigned only to canonical contracts;
- [ ] SDK packages contain no admin private keys;
- [ ] Kuru contracts have no Optara protocol roles;
- [ ] permissionless finalization reviewed for caller non-discretion;
- [ ] permissionless sync reviewed for recipient/economic non-discretion;
- [ ] upgrade path/timelock tested if applicable;
- [ ] role-change monitoring enabled;
- [ ] all privileged function tests pass;
- [ ] existing-series mutation functions do not exist;
- [ ] finalized-price mutation functions do not exist.

---

# 105. Recommended MVP role set

For the simplest secure MVP:

```text
GOVERNANCE
    high-security multisig
    approves assets/oracles/config
    manages operational roles

PAUSER
    narrow emergency role
    pauses new/unsafe risk paths

SERIES_CREATOR
    optional
    creates only factory-validated approved series

INTERNAL_MINTER/BURNER
    canonical contract addresses only

VAULT_OPERATOR
    canonical ClearingHouse / SettlementEngine only

UPGRADER
    absent in canonical V2; existing financial code and peer bindings are immutable
```

Prefer:

```text
finalizeRiskGroup = permissionless
syncRiskGroup     = permissionless
```

when deterministic.

No ordinary:

```text
LIQUIDATOR_ROLE
```

is required in core V2.

No ordinary:

```text
SDK_ROLE
KURU_ROLE
FRONTEND_ROLE
```

should exist.

---

# 106. Final access-control principle

Optara access control should be designed so that:

```text
users control their accounts
contracts control protocol accounting
keepers only advance deterministic state
pausers only stop danger
governance controls future configuration
upgrade authority is exceptional
SDKs have no implicit privilege
```

The safest privilege is the one the protocol does not need.

---

## 107. Recovery and containment authorization

`closeShort` and `cancelUnfinalizedShort` require the account owner's authorization
and an identical long from an explicit source: an `EXTERNAL` transfer by the caller or
the caller's own `LOCKED` hedge. Permissionless keepers cannot redirect value or
consume another account's hedge.
Expired-unfinalized `unlockLong` retains owner authorization and complete risk checks.
`checkAndRestrict(account, asset)` is permissionless only for objectively verified
existing-state breaches under `LIQUIDATION.md` section 101. Arbitrary user reports,
failed proposed trades, and token donations cannot persist restrictions.
`restrictAsset` belongs to the narrow guardian/governance path; it can stop all
specified outflows but cannot move funds. Only governance may clear that restriction
after reconciliation. Operational roles cannot replace pinned peers or grant new
mint/burn/vault authority for existing obligations.

`resolveShortfall(asset, rho)` (`LIQUIDATION.md` section 102) is GOVERNANCE_ROLE only,
behind the governance timelock, with published reconciliation evidence. The contract
enforces: the asset is currently restricted, `0 < rho < 1`, and `rho` has never been set
for that asset on that core. It cannot move funds, change series terms, or target
individual accounts; it only sets the uniform outflow ratio and disables new deposits
and risk in that asset.
