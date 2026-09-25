# Optara V2 — Deployment Specification

**Document type:** Normative build, release, deployment, configuration, verification, and rollout specification  
**Protocol:** Optara  
**Target:** Monad V2 solvency-first MVP  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Deployment runbook; exact chain addresses and production parameters must be verified at deployment time

> Canonical V2 uses immutable versioned financial cores (`ACCESS_CONTROL.md` sections 40–45). Conditional upgrade guidance/tests below apply only to a separately specified future variant; V2 instead tests sealed peers, fixed code, and non-reassignable internal authority.

---

# 1. Purpose

This document defines how Optara V2 is safely built and deployed.

It covers:

```text
repository preparation
contract compilation
test gates
package builds
deployment configuration
contract deployment order
role assignment
oracle configuration
pair activation
series creation
SDK deployment metadata
Kuru integration metadata
testnet validation
production rollout
post-deployment verification
rollback / pause strategy
```

No engineer or AI agent should invent production values not defined by approved configuration.

---

# 2. Deployment philosophy

Deployment is not:

```text
deploy bytecode
-> announce launch
```

It is:

```text
freeze source
-> prove tests
-> deploy core
-> verify bytecode
-> configure roles
-> configure safe assets/oracles
-> run smoke/invariant checks
-> publish SDK metadata
-> activate risk gradually
```

---

# 3. Deployment layers

Optara has four release layers:

```text
1. Solidity protocol
2. Shared deployment metadata
3. @optara/math / @optara/sdk / @optara/kuru
4. Applications/indexers
```

The Solidity layer is authoritative.

Packages and applications must reference the deployed authoritative contracts.

---

# 4. Environments

Required environments:

```text
LOCAL
LOCAL_FORK / SIMULATION
MONAD TESTNET / APPROVED STAGING NETWORK
PRODUCTION / MONAD MAINNET
```

If a testnet naming/configuration changes, use current verified chain metadata.

Do not copy example chain IDs/addresses blindly from documentation.

---

# 5. Configuration files

Recommended:

```text
deploy/
├── local.json
├── staging.json
└── production.json
```

Each configuration must explicitly define:

```text
chainId
RPC environment variable names
deployer address
governance address
pauser address
upgrade/timelock addresses if applicable
approved settlement assets
approved underlyings
approved pairs
oracle providers/config IDs
position limits
aggregate exposure caps (series, pair, oracle config, asset)
oracle maxFinalizationDelay and fallback eligibility
safety buffer
fee config
series-creation policy
Kuru integration metadata
```

No secret keys belong in configuration files committed to source control.

---

# 6. Secrets

Use secure environment/secrets management.

Never commit:

```text
private keys
mnemonics
API secrets
registry publish tokens
multisig signer secrets
```

Deployment scripts should accept signer access through secure tooling.

---

# 7. Deterministic deployment

Where useful, prefer deterministic addresses for stable components.

Benefits:

```text
easier SDK metadata
reproducibility
cross-environment parity
verification
```

But do not force deterministic deployment at the cost of unsafe complexity.

---

# Part I — Pre-deployment source freeze

## 8. Release commit

Production deploys must reference one exact source-control commit.

Record:

```text
git commit
tag
compiler version
Foundry version/profile
optimizer settings
package lock hash
```

---

# 9. No dirty tree

Deployment from a dirty working tree is prohibited.

---

# 10. Dependency lock

All Solidity and package dependencies must be locked/pinned according to project tooling.

---

# Part II — Mandatory pre-deployment gates

## 11. Formatting/build

Required:

```text
forge fmt --check
forge build
package typecheck/build
lint where configured
```

---

# 12. Solidity coverage gate

Must satisfy:

```text
100% function
100% line
100% branch
```

for Optara-owned deployed production code, subject only to reviewed documented exclusions.

---

# 13. Test gate

All:

```text
unit
fuzz
stateful invariants
differential tests
integration tests
access-control tests
oracle tests
settlement tests
SDK tests
Kuru package tests
```

must pass.

---

# 14. Gas gate

Maximum allowed account/group state must still permit:

```text
risk evaluation
withdraw
unlock
sync
redeem
```

within practical block constraints.

---

# 15. Audit gate

Before production:

```text
independent review/audit complete
critical findings fixed
high findings fixed or formally accepted with documented rationale
regression tests added for every fixed finding
```

---

# 16. Deployment rehearsal

Run the complete production deployment script against:

```text
local clean chain
then staging/testnet
```

using production-like role topology.

---

# Part III — Build artifacts

## 17. Contract artifacts

Archive:

```text
bytecode
deployed bytecode
ABI
storage layout if upgradeable
compiler metadata
source commit
```

---

# 18. Package artifacts

Build:

```text
@optara/math
@optara/sdk
@optara/kuru
shared ABIs/types/deployment metadata
```

Packages should use explicit semantic versions.

---

# 19. Deployment manifest

Generate machine-readable manifest:

```json
{
  "chainId": "...",
  "release": "...",
  "commit": "...",
  "contracts": {},
  "pairs": {},
  "oracleConfigs": {},
  "limits": {},
  "fees": {}
}
```

Actual schema may differ.

Manifest must not contain secrets.

---

# Part IV — Contract deployment order

## 20. Recommended order

Conceptually:

```text
1. libraries
2. AccessController / governance plumbing
3. MarginVault
4. OptionToken implementation/factory
5. SeriesFactory
6. OracleAdapter(s)
7. RiskEngine
8. SettlementEngine
9. ClearingHouse
10. connect internal authorities
11. revoke temporary deployer privileges
```

Exact constructor dependencies may require a different order.

The final dependency graph must be explicit.

---

# 21. Circular dependency handling

Avoid deployment-time circular trust where possible.

Use:

```text
constructor immutables
one-time initialization
governance-controlled dependency registration
```

with strict initialization guards.

---

# 22. Libraries

If external-linked libraries are used, verify exact library addresses and compiler linkage.

Prefer internal libraries where practical for simpler deployment.

---

# Part V — Initialization

## 23. Initialize exactly once

Upgradeable contracts must:

```text
initialize once
disable implementation initializer
```

and tests must prove replay is impossible.

---

# 24. Initial safe mode

Deploy contracts initially with:

```text
new risk paused
or
no approved pairs
```

so no user can create risk before full configuration verification.

---

# 25. Temporary deployer privilege

If deployer temporarily receives admin power:

```text
configure
verify
transfer role
revoke deployer
```

must occur in the same controlled deployment process.

---

# Part VI — Access-control setup

## 26. Governance

Set production governance to approved high-security address/multisig.

Do not leave deployer as governance unintentionally.

---

# 27. Pauser

Assign narrow pauser role.

Verify:

```text
can pause intended functions
cannot transfer vault collateral
cannot mint
cannot change settlement price
```

---

# 28. Internal roles

Assign:

```text
OptionToken minter
OptionToken burner
MarginVault operator
SettlementEngine/ClearingHouse peer permissions
```

only to canonical contracts.

---

# 29. Upgrader

If upgradeable:

```text
UPGRADER
=
approved governance/timelock architecture
```

not deployer EOA.

---

# 30. Revoke stale roles

After setup, enumerate all role members and prove no unexpected address remains.

---

# Part VII — Settlement asset onboarding

## 31. Settlement token checklist

For each stablecoin verify:

```text
contract address
network
decimals
symbol for display
exact transfer behavior
non-rebasing behavior
fee behavior
pause/freeze properties
issuer/upgrader risk
```

---

# 32. Runtime token test

On staging/testnet or fork:

```text
transfer
transferFrom
balance delta
approval
failed transfer behavior
```

must match assumptions.

---

# 33. Approve no token by symbol

Approval/configuration uses exact contract address.

---

# Part VIII — Underlying/pair onboarding

## 34. Pair config

Each pair defines:

```text
underlying
settlementAsset
allowed oracle configs
series parameter bounds
```

---

# 35. Pair starts disabled

Recommended:

```text
configure
test
then enable
```

---

# Part IX — Oracle configuration deployment

## 36. Verify provider deployment

For each oracle source verify current:

```text
provider contract
feed/source ID
network
decimals
timestamp semantics
update/finalization semantics
```

at deployment time.

Do not rely on stale addresses embedded in old docs.

---

# 37. Direct/derived pair verification

For direct:

```text
UNDERLYING / STABLECOIN
```

verify denomination.

For derived:

```text
UNDERLYING/USD
/
STABLECOIN/USD
```

verify both legs and timestamps.

---

# 38. Configure observation rules

Set:

```text
observation window
min finalization delay
max/fallback policy
staleness
confidence threshold if used
rounding
```

according to approved oracle design.

---

# 39. Oracle dry-run

Before enabling pair risk:

```text
read current source
normalize
compare expected unit
simulate expiry observation
simulate invalid/stale report
simulate fallback
```

---

# Part X — Core risk parameter deployment

## 40. Position limits

Explicitly configure:

```text
MAX_SERIES_PER_GROUP_PER_ACCOUNT
MAX_ACTIVE_GROUPS_PER_ACCOUNT
MAX_ACTIVE_SERIES_PER_ACCOUNT
quantity bounds
```

based on worst-case gas tests.

---

# 41. Safety buffer

Configure approved:

```text
bufferBps (default for new groups; snapshotted per group)
fixedBufferNative (default for new groups; snapshotted per group)
```

The canonical MVP uses a zero safety buffer. This is safe because margin uses exact
payoff numerators rounded up once (`MATH.md` sections 24–26); there is no separate
rounding-guard parameter to configure.

---

# 42. Fees

Canonical MVP:

```text
Optara fee configuration = zero
```

If optional fee code exists, verify zero in production manifest unless governance explicitly approved activation.

---

# Part XI — Series deployment/creation

## 43. Initial series

Do not create a huge catalog at genesis.

Start with a small verified set.

For each:

```text
underlying
settlementAsset
type
strike
cap
contract size
expiry
oracleConfigId
```

must be human-reviewed.

---

# 44. Series sanity checks

Before creation:

```text
K > 0
C > 0
CS > 0
future expiry
put C <= K
approved pair
approved oracle
```

---

# 45. Series ID verification

Compute expected `seriesId` independently through SDK/reference tooling and compare with on-chain result.

---

# Part XII — SDK deployment metadata

## 46. Shared manifest

`@optara/sdk` must obtain:

```text
chainId
contract addresses
deployment version
supported settlement assets
```

from versioned trusted deployment metadata.

---

# 47. No hardcoded global USDC

SDK must read:

```text
series.settlementAsset
```

for each series.

---

# 48. SDK release order

The SDK packages are published from their separate repository after this repository publishes the verified
`deployments/<network>.json` manifest and `deployments/abi/` (generated by `contract/script/export_abis.py`).

Recommended:

```text
deploy contracts
verify contracts
publish manifest
publish @optara/math
publish @optara/sdk
publish @optara/kuru
update applications
```

Do not publish SDK production addresses before contract verification is complete.

---

# 49. SDK version compatibility

Document:

```text
contract release -> compatible SDK versions
```

SDK should reject unknown/incompatible deployments where possible.

---

# Part XIII — Kuru integration deployment

## 50. Kuru is optional to core launch

Optara core can launch/settle without a Kuru market.

---

# 51. Market setup

For each officially supported series market:

```text
Base = exact option token
Quote = exact settlement stablecoin
```

Verify:

```text
network
market address
precision
tick size
minimum size
external Kuru fee configuration
```

---

# 52. Official market registry

Publish verified market metadata to `@optara/kuru` / frontend.

Do not make Kuru market address part of immutable series economics.

---

# 53. Kuru smoke test

Execute small:

```text
long transfer/deposit
buy
sell
withdraw
writer buy-to-close
```

on staging before production listing.

---

# Part XIV — Staging rollout

## 54. Staging goal

Reproduce production topology:

```text
same contract architecture
same role model
same package paths
representative stablecoin decimals
realistic oracle behavior
Kuru integration where available
```

---

# 55. Staging scenarios

Complete at minimum:

```text
unhedged call lifecycle
unhedged put lifecycle
hedged spread lifecycle
same stablecoin multiple groups
different stablecoins
Kuru buy/sell
buy-to-close
expiry finalization
redemption before writer sync
writer sync
withdraw matured account
oracle failure
pause/unpause
```

---

# 56. Staging soak

Run bots/keepers/indexers for a meaningful period or high simulated activity.

Monitor:

```text
event correctness
gas
state growth
indexer parity
oracle handling
```

---

# Part XV — Production deployment

## 57. Production deployment window

Use a controlled deployment window with:

```text
governance signers available
pauser available
engineers monitoring
RPC/provider redundancy
oracle provider availability confirmed
```

---

# 58. Deploy core paused

No new economic risk until verification completes.

---

# 59. Verify bytecode

Verify deployed source/bytecode using the chain's supported explorer/tooling where possible.

Locally compare:

```text
deployed runtime bytecode
expected artifact runtime bytecode
```

accounting for metadata/immutable handling.

---

# 60. Verify addresses

Two independent people/processes should verify:

```text
chain
contract addresses
governance
pauser
stablecoins
oracle sources
```

before activation.

---

# 61. Publish manifest checksum

Record a hash/checksum of final deployment manifest.

---

# Part XVI — Post-deployment smoke tests before enabling risk

## 62. Read-only smoke tests

Verify:

```text
version
roles
pause state
approved assets
pair configs
oracle configs
limits
fee config
```

---

# 63. Minimal token smoke

With tiny amounts:

```text
deposit
withdraw
```

for each settlement asset.

---

# 64. Series smoke

Create/use a designated staging-like production series only if approved.

Test:

```text
write tiny quantity
transfer long
close
```

before broad activation.

---

# 65. Oracle smoke

Read/validate provider data through deployed adapter without necessarily finalizing live future series.

---

# Part XVII — Activation

## 66. Gradual activation

Recommended phases:

```text
Phase 0: deployed, risk paused
Phase 1: small set of assets/pairs
Phase 2: low aggregate gross exposure caps plus bounded per-account position counts
Phase 3: enable official Kuru markets
Phase 4: raise limits after monitoring
```

---

# 67. Do not activate all features at once

A progressive rollout reduces blast radius.

---

# Part XVIII — Post-launch monitoring

## 68. Core monitoring

Alert on:

```text
cash < required margin
vault mismatch
unexpected mint/burn
oracle finalization failures
negative effective cash
pause changes
role changes
asset restriction / recapitalization / shortfall resolution
ORACLE_STALLED groups
position-limit and aggregate exposure-cap pressure
```

---

# 69. Oracle monitoring

Per config:

```text
source liveness
update timing
price denomination
deviation
fallback usage
```

---

# 70. Package monitoring

Verify production frontend uses intended:

```text
SDK version
deployment manifest
chainId
Kuru metadata
```

---

# Part XIX — Emergency procedures

## 71. RiskEngine issue

Immediately consider:

```text
pause writes
pause withdrawals
pause unlocks
```

Preserve independently safe reductions.

---

# 72. Oracle issue

Pause:

```text
new affected risk
affected finalization
```

Do not invent price.

---

# 73. Stablecoin issue

Disable new affected risk.

Do not cross-convert existing claims.

---

# 74. Kuru issue

No core protocol pause required solely because Kuru is unavailable, unless an Optara-integrated router itself is unsafe.

---

# 75. SDK compromise

Actions may include:

```text
remove compromised package version
publish fixed version
disable affected frontend
warn users
```

Core contracts should remain safe if invariant checks hold.

If malicious approvals/transactions are possible, advise users through incident communication procedures.

---

# Part XX — Upgrade deployment

## 76. If immutable

No upgrade procedure.

New version requires new deployment/migration design.

---

# 77. If upgradeable

Before upgrade:

```text
full test suite
storage-layout diff
state migration simulation
fork rehearsal
governance proposal
timelock
```

---

# 78. Upgrade post-checks

Verify:

```text
cash balances unchanged
shorts unchanged
locked longs unchanged
settlements unchanged
roles unchanged
vault balances reconciled
```

unless migration explicitly changes an expected field.

---

# Part XXI — Rollback philosophy

## 79. Smart contracts do not have ordinary software rollback

After state-changing deployment:

```text
"rollback"
```

means:

```text
pause
upgrade if authorized
migrate if designed
deploy replacement
```

not restoring a database snapshot.

---

# 80. Never refinalize to fix deployment mistakes

Finalized option economics are immutable.

---

# Part XXII — Deployment scripts

## 81. Script requirements

Scripts must:

```text
validate chainId
validate signer
validate expected nonce/address where relevant
load explicit config
refuse missing config
emit/save deployed addresses
verify role assignments
verify peer dependencies
```

---

# 82. Idempotence

Configuration scripts should detect existing configuration and avoid unsafe duplicate actions.

---

# 83. Dry-run mode

Provide simulation/read-only output before sending production transactions where tooling permits.

---

# 84. No silent defaults

Critical values must not silently default:

```text
settlement token
oracle config
governance
pauser
position limits
```

Missing values should fail deployment.

---

# Part XXIII — Deployment test suite

## 85. DEPLOY-TEST-001

Fresh local deployment succeeds.

## 86. DEPLOY-TEST-002

Second accidental initializer fails.

## 87. DEPLOY-TEST-003

Wrong chain ID deployment script aborts.

## 88. DEPLOY-TEST-004

Missing governance config aborts.

## 89. DEPLOY-TEST-005

Missing oracle config aborts pair activation.

## 90. DEPLOY-TEST-006

Unknown settlement token aborts pair activation.

## 91. DEPLOY-TEST-007

Roles exactly match manifest.

## 92. DEPLOY-TEST-008

Temporary deployer roles revoked.

## 93. DEPLOY-TEST-009

Fee configuration matches manifest.

## 94. DEPLOY-TEST-010

Position limits match manifest.

## 95. DEPLOY-TEST-011

SDK manifest matches deployed addresses.

## 96. DEPLOY-TEST-012

Kuru market metadata base/quote match series.

## 97. DEPLOY-TEST-013

Tiny deposit/write/close smoke succeeds.

## 98. DEPLOY-TEST-014

Pause works immediately.

## 99. DEPLOY-TEST-015

Unauthorized admin calls revert.

---

# Part XXIV — Release artifacts

## 100. Archive

For every production release archive:

```text
source commit
contract addresses
ABI
deployment manifest
config
compiler metadata
coverage report
test report
gas report
audit reports
known-risk register
SDK versions
Kuru package version
```

---

# 101. Public documentation consistency

Before launch, verify user-facing docs do not contradict deployed:

```text
fees
settlement assets
limits
oracle rules
series terms
```

---

# Part XXV — Final production checklist

## 102. Pre-activation checklist

- [ ] clean tagged source commit;
- [ ] 100% Solidity function coverage;
- [ ] 100% Solidity line coverage;
- [ ] 100% Solidity branch coverage;
- [ ] all `TEST_CASES.md` required cases passing;
- [ ] all named invariants mapped and passing;
- [ ] high-depth invariant campaign passing;
- [ ] differential math campaign passing;
- [ ] maximum-state gas checks passing;
- [ ] independent audit completed;
- [ ] deployment rehearsal completed;
- [ ] contract bytecode verified;
- [ ] governance set correctly;
- [ ] pauser set correctly;
- [ ] temporary deployer privileges revoked;
- [ ] stablecoin addresses/decimals verified;
- [ ] pair configs verified;
- [ ] oracle source IDs/addresses verified at current deployment time;
- [ ] oracle direct/derived units verified;
- [ ] position limits verified;
- [ ] fee configuration verified;
- [ ] SDK manifest verified;
- [ ] Kuru market metadata verified if enabled;
- [ ] monitoring live;
- [ ] emergency pauser available;
- [ ] risk initially constrained for gradual rollout.

---

# 103. Final deployment principle

Optara should never move directly from:

```text
"tests pass on my machine"
```

to:

```text
"full production risk enabled"
```

The correct deployment lifecycle is:

```text
specification
-> exhaustive tests
-> independent review
-> deterministic deployment
-> role/config verification
-> smoke testing
-> gradual activation
-> continuous invariant monitoring
```

The deployment is complete only when the deployed system—not merely the source code—matches the protocol specification.

---

## 104. Economic exposure and policy activation gates

Before enabling risk, publish finite series/pair/oracle/asset gross exposure caps
from `PROTOCOL_SPEC.md` section 42, with native-unit human-readable equivalents.
Manifest/schema and smoke tests MUST include these caps. Missing, zero, overflowing,
or placeholder limits keep new risk disabled. Multi-account tests MUST demonstrate
that account splitting cannot exceed a shared cap. Tests MUST also show that finalization releases a
group's exposure from pair/oracle/asset caps, so abandoned zero-payoff tokens do not
consume them. Raising limits follows timelocked
governance; lowering below current exposure does not obstruct exit/settlement.

Group buffer snapshots, quantity granularity, arithmetic bounds, oracle signed
offsets, historical retrieval/retention, fallback eligibility, and the oracle-stalled
recovery policy MUST be verified. Do not publish a guaranteed oracle settlement
deadline. Provider/feed addresses and numeric parameters still require explicit
production verification; this specification does not invent them.

The `resolveShortfall` path (`LIQUIDATION.md` section 102) MUST be deployed behind the
governance timelock and covered by EMR-005..007 before activation.

Core V2 uses immutable versioned financial deployments under `ACCESS_CONTROL.md`
section 40. Existing series and token claims remain on their original core. A new
version takes new risk; there is no forced migration of open obligations.
