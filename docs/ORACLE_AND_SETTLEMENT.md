# Optara V2 — Oracle and Settlement Specification

**Document type:** Normative oracle, expiry-finalization, and settlement specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Engineering specification; production oracle parameters remain deployment-specific

---

## 1. Purpose

This document defines how Optara V2 converts an expired option risk group into one deterministic settlement price and how that price propagates into:

- capped option payoff;
- long-holder claims;
- writer liabilities;
- locked-long credits;
- account synchronization;
- vault accounting;
- redemption;
- final margin release.

It also defines the oracle trust boundary and failure behavior.

The design must preserve the following core rule:

> **Every Optara option settles in the approved stablecoin defined by its own pair.**

Examples:

```text
MON / USDT
-> settlement price is USDT per MON
-> margin is USDT
-> long payout is USDT

ETH / USDC
-> settlement price is USDC per ETH
-> margin is USDC
-> long payout is USDC

BTC / USDe
-> settlement price is USDe per BTC
-> margin is USDe
-> long payout is USDe
```

Optara is not USDC-based.

This document must be read together with:

- `OPTION_SPEC.md`
- `MATH.md`
- `INVARIANTS.md`
- `MARGIN_AND_RISK.md`
- `PROTOCOL_SPEC.md`
- `STATE_MACHINE.md`
- `LIQUIDATION.md`
- `ARCHITECTURE.md`
- `USER_FLOWS.md`

If there is a conflict:

1. `MATH.md` is authoritative for numerical payoff and rounding;
2. `INVARIANTS.md` is authoritative for required safety properties;
3. `PROTOCOL_SPEC.md` is authoritative for runtime transition ordering;
4. this document is authoritative for oracle selection, finalization, and settlement policy.

---

# 2. Design goals

The oracle/settlement system must provide:

```text
correct denomination
deterministic finalization
single final price per risk group
immutable post-finalization state
bounded execution
no protocol-wide writer loop
same-asset settlement
safe asynchronous redemption
safe lazy writer synchronization
explicit failure states
provider abstraction
```

The system must not depend on:

```text
Kuru option price
Kuru liquidity
current spot price for active core margin
one universal stablecoin
governance choosing a profitable settlement price
a keeper choosing between multiple acceptable prices
```

---

# 3. Oracle architecture

Recommended architecture:

```text
External Oracle Provider(s)
          |
          v
   OracleAdapter
          |
          | normalize + validate
          v
 SettlementEngine
          |
          | finalizeRiskGroup(groupId)
          v
 immutable settlementPrice[groupId]
          |
          +----------------------+
          |                      |
          v                      v
 series payoff              account sync
          |                      |
          v                      v
 long redemption          writer cash delta
```

The provider-specific logic belongs in adapters.

Core settlement logic must not parse provider-specific wire formats directly.

---

# 4. Provider-agnostic design

Optara must not hardcode one oracle vendor into its core economics.

A risk group references:

```text
oracleConfigId
```

The configuration binds the exact settlement methodology.

A production deployment may support multiple providers/configurations concurrently.

For example:

```text
MON/USDT expiry A
-> oracleConfigId X

ETH/USDC expiry B
-> oracleConfigId Y
```

Two otherwise similar positions with different oracle configurations do not belong to the same core-V2 risk group.

---

# 5. Current Monad deployment note

As of 2026-09-24, public oracle infrastructure available on Monad includes providers such as:

```text
Chainlink
Pyth
```

This is an operational availability note, not a protocol dependency.

Optara should select provider/configuration per approved pair only after verifying:

```text
feed availability
pair denomination
update semantics
historical/finalization semantics
latency
staleness controls
confidence/error information
contract addresses
provider upgrade behavior
Monad deployment status
```

Addresses and feed IDs belong in deployment configuration, not immutable protocol source code where avoidable.

---

# 6. Oracle configuration identity

Conceptually:

```solidity
struct OracleConfig {
    address underlying;
    address settlementAsset;

    OracleMode mode;

    bytes32 primarySourceId;
    bytes32 secondarySourceId;       // optional / zero if unused

    int64 observationStartOffset;
    int64 observationEndOffset;
    uint64 minFinalizationDelay;
    uint64 maxFinalizationDelay;

    uint32 maxStaleness;
    uint32 maxConfidenceBps;         // if supported; zero may mean unused

    uint8 normalizedDecimals;        // recommended 18/WAD

    bytes32 fallbackRuleId;
    bytes32 ruleVersion;
}
```

Exact storage may differ.

The economic meaning must not.

---

# 7. What `oracleConfigId` must bind

At minimum:

```text
underlying
settlement stablecoin
oracle/provider family
direct or derived price path
feed/stream/source identifiers
source decimals
normalized output decimals
observation rule
expiry timestamp interpretation
finality delay
staleness rule
confidence rule if applicable
source-selection/fallback retrieval rule
rounding rule
rule version
```

It must be impossible to silently swap these semantics after a series is created.

---

# 8. Series-to-group relationship

A core V2 risk group is:

```text
riskGroup = (
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

Therefore all series in a group share:

```text
same underlying
same expiry
same settlement stablecoin
same settlement methodology
```

They may differ in:

```text
call/put
strike
cap
contract size
```

---

# 9. Price-unit invariant

The finalized price must mean:

```text
settlement-stablecoin units
per
1 underlying unit
```

Examples:

```text
MON/USDT
S = USDT per MON

ETH/USDC
S = USDC per ETH

BTC/USDe
S = USDe per BTC
```

The normalized settlement price `S` must use the same economic quote unit as:

```text
strike K
max payout C
```

---

# 10. Direct pair source

Preferred when available:

```text
UNDERLYING / SETTLEMENT_STABLECOIN
```

Example:

```text
MON / USDT
```

If source price is:

```text
rawPrice
rawDecimals
```

the adapter normalizes it to protocol WAD:

```text
settlementPriceWad
=
normalize(rawPrice, rawDecimals, 18)
```

subject to validity checks.

---

# 11. Derived pair source

A derived pair is allowed only when explicitly precommitted in `oracleConfigId`.

Example:

```text
MON/USDT
=
MON/USD
/
USDT/USD
```

In real-number form:

```text
S_MON_USDT
=
P_MON_USD / P_USDT_USD
```

If both values are WAD:

```text
S_wad
=
roundConfigured(
    P_underlying_usd_wad * WAD
    /
    P_stablecoin_usd_wad
)
```

Require:

```text
P_stablecoin_usd_wad > 0
```

---

# 12. Do not assume stablecoin = USD

Forbidden shortcut:

```text
MON/USD
is treated as
MON/USDT
because "USDT is about $1"
```

The protocol must derive the exact pair or use a direct pair source.

This rule applies to:

```text
USDT
USDC
USDe
and every other approved stablecoin
```

---

# 13. Stablecoin depeg correctness

Suppose:

```text
MON/USD = 12
USDT/USD = 0.96
```

Then:

```text
MON/USDT
=
12 / 0.96
=
12.5 USDT per MON
```

A `MON/USDT` option must use the USDT-denominated value.

This keeps:

```text
strike
cap
margin
settlement
```

in a coherent unit system even during a depeg.

---

# 14. Oracle modes

The adapter framework MAY support deterministic modes such as:

```text
DIRECT_REFERENCE_REPORT

DERIVED_REFERENCE_REPORT

PROVIDER_WINDOW_AGGREGATE

PRECOMMITTED_TWAP

PRECOMMITTED_MEDIAN_WINDOW
```

The exact mode must be fixed before series creation.

A mode cannot be selected after expiry based on which result benefits one side.

---

# 15. Settlement observation rule

Every oracle configuration must define the observation interval relative to expiry.

Conceptually:

```text
observationStart
=
expiry + observationStartOffset

observationEnd
=
expiry + observationEndOffset
```

Offsets may be:

```text
negative
zero
positive
```

only if the chosen provider/methodology safely supports the intended historical observation.

---

# 16. Why the observation rule must be precommitted

Without a fixed rule, a finalizer could choose:

```text
the update just before expiry
the update just after expiry
the highest update
the lowest update
```

which changes payout.

Therefore:

```text
price-selection rule
```

is part of the economic contract.

---

# 17. Recommended MVP principle

For the MVP, choose **one simple, provider-supported, deterministic settlement rule** per approved oracle configuration.

Do not implement many settlement modes merely for flexibility.

The chosen rule must be testable on Monad and must provide an unambiguous answer to:

> Which provider observation belongs to this expiry?

The concrete provider rule is a deployment parameter and must be finalized before production launch.

---

# 18. Finalization delay

The protocol SHOULD separate:

```text
expiry time
```

from:

```text
earliest safe finalization time
```

Conceptually:

```text
earliestFinalize
=
expiry + minFinalizationDelay
```

This allows the configured oracle methodology to reach the required finality.

---

# 19. Settlement escalation deadline

Every config MUST define a finite `maxFinalizationDelay`, no smaller than its
earliest eligible finalization delay. At `expiry + maxFinalizationDelay`, derive
`ORACLE_STALLED` if still unfinalized. Checked timestamp arithmetic is mandatory.

This is a monitoring/recovery deadline, not a guaranteed payout deadline. Continue
to accept authentic reports for the exact historical observation under the immutable
rule, including eligible precommitted fallback reports. Never substitute the current
spot price. Missing caller data does not establish primary failure.

Use the recovery policy in `PROTOCOL_SPEC.md` section 41: reserve worst-case margin,
allow safe free-cash withdrawals and matching long/short cancellation, and preserve
unmatched claims. Permanent failure of every source can leave unmatched claims
unresolved indefinitely. This limitation MUST be disclosed before users enter risk.

---

# 20. Oracle report validity

A report is valid only if all applicable checks pass.

At minimum validate:

```text
source identity
price > 0 (unless the config explicitly supports zero, section 21)
expected decimals
publish/observation time
observation window
staleness
provider status
finality rule
confidence/error threshold if configured
no overflow during normalization
```

---

# 21. Negative and zero prices

Core V2 supports:

```text
S >= 0
```

economically.

However a provider report used as a live asset price SHOULD generally require:

```text
reported price > 0
```

unless the approved asset/config explicitly supports zero.

Negative prices are unsupported in core V2.

---

# 22. Confidence / uncertainty

Some oracle systems expose confidence or uncertainty information.

If used, `oracleConfigId` must define a deterministic maximum acceptable threshold.

Example concept:

```text
confidenceBps
=
confidence / abs(price) * 10_000
```

Require:

```text
confidenceBps <= maxConfidenceBps
```

Provider-specific implementation belongs in the adapter.

---

# 23. Staleness

A provider report used for finalization must satisfy the config's timestamp semantics.

Do not use a generic rule such as:

```text
block.timestamp - publishTime <= 60
```

without considering the fact that settlement intentionally references expiry.

The adapter must validate staleness relative to the **precommitted observation rule**, not blindly relative to current time.

---

# 24. Push-oracle considerations

For push/pull-update oracle systems, the finalizer may need to submit update data and pay an oracle update fee.

Rules:

```text
caller-provided update bytes are untrusted input
adapter verifies them through provider contract
caller cannot choose a different economic observation than config permits
oracle update fee is not deducted from long payout
```

The caller may pay provider update fees separately.

---

# 25. Pull-oracle considerations

If settlement uses caller-supplied signed oracle data:

```text
signature verification
source verification
timestamp verification
replay safety
```

must be enforced by the provider integration.

Optara must never trust SDK-decoded price data without on-chain verification.

---

# 26. SDK boundary

`@optara/sdk` MAY:

```text
fetch oracle metadata
preview whether a group is finalizable
prepare provider update payloads
estimate update fees
decode finalized settlement
preview payouts
```

but it MUST NOT be authoritative.

On-chain:

```text
OracleAdapter
+
SettlementEngine
```

perform the final validation.

---

# 27. `@optara/math` boundary

`@optara/math` MAY compute:

```text
derived pair conversion
capped payoff
redemption preview
writer settlement preview
```

for clients and tests.

It cannot decide:

```text
which oracle report is valid
whether finalization conditions are met
whether an on-chain claim may be paid
```

---

# 28. Settlement state machine

Canonical group lifecycle:

```text
ACTIVE
  |
  | expiry reached
  v
EXPIRED_UNSETTLED
  |
  | valid precommitted oracle observation finalized
  v
FINALIZED
```

No backwards transition.

---

# 29. `ACTIVE`

Before expiry:

```text
no settlement price exists
no redemption
no matured writer debit
```

Core margin uses exact worst-case payoff rather than live spot.

---

# 30. `EXPIRED_UNSETTLED`

After expiry and before finalization:

```text
no new writes
no final payoff yet
no redemption yet
no writer settlement yet
```

The long token may remain transferable. The group stays reserved at worst case;
`cancelUnfinalizedShort`, safe `unlockLong` and free-cash withdrawal remain
available (`PROTOCOL_SPEC.md` section 41).

---

# 31. `FINALIZED`

After valid finalization:

```text
settlementPrice immutable
series payoff deterministic
long redemption allowed
writer group synchronization allowed
```

---

# 32. Group-level finalization

Finalization occurs once per risk group, not independently per series.

Conceptual:

```solidity
function finalizeRiskGroup(
    bytes32 groupId,
    bytes calldata oracleData
) external payable;
```

Exact interface may differ.

---

# 33. Why group-level finalization

All series in the group share:

```text
underlying
expiry
settlementAsset
oracleConfigId
```

Therefore they must share exactly one:

```text
settlementPrice
```

This prevents:

```text
same expiry call using one price
same expiry put using another price
```

inside a portfolio that was margined as one group.

---

# 34. Finalization preconditions

At minimum:

```text
group exists
timestamp >= expiry
group not already finalized
settlement finalization not paused for this group/config
oracle config valid for existing group
required finality delay elapsed
oracle data passes adapter validation
price expressed in required settlement stablecoin
```

---

# 35. Finalization effects

Atomically:

```text
settlementPrice[groupId] = S*
finalizedAt[groupId] = block.timestamp
groupState = FINALIZED
release group exposure from pair/oracle/asset caps (PROTOCOL_SPEC.md section 42)
```

Series-level payoff may be:

```text
computed lazily from S*
```

or:

```text
cached per series
```

provided both approaches are mathematically identical. A cache must keep the exact
`phi*` per underlying unit; a rounded per-option amount is forbidden (`MATH.md` section 50).

---

# 36. Single-finalization invariant

Once:

```text
S_g*
```

is stored:

```text
S_g*(future) = constant
```

No:

```text
governance
keeper
SDK
oracle updater
writer
long holder
```

may refinalize it.

---

# 37. Series payoff after finalization

For series `i` in group `g`:

### Call

```text
phi_i*
=
min(max(S_g* - K_i, 0), C_i)
```

### Put

```text
phi_i*
=
min(max(K_i - S_g*, 0), C_i)
```

---

# 38. Total payoff

For quantity `Q_i` and contract size `CS_i`:

```text
Payoff_i*
=
phi_i*
* CS_i
* Q_i
```

with the exact fixed-point rules defined in `MATH.md`.

---

# 39. Long redemption

Conceptual:

```solidity
redeem(
    bytes32 seriesId,
    uint256 quantity,
    address recipient
)
```

Requires:

```text
series settled
quantity > 0
caller owns or is authorized for the long
actual long token not already consumed
settlement asset not ASSET_RESTRICTED; settlement execution not paused
```

In `ASSET_WIND_DOWN` the transfer is `floor(rho_A * payout)` (`LIQUIDATION.md` section 102).

Effects:

```text
calculate fixed payout
burn long quantity
transfer series settlementAsset
```

---

# 40. Redemption rounding

For exact numerator `N = phiWad * contractSizeWad * quantityWad`, transfer
`floorDiv(N, D_A)` where `D_A = 10^(54-d)`. No intermediate WAD truncation is allowed.
This same rational payoff is used in risk and account-group netting.

---

# 41. Zero-payoff redemption

If:

```text
payoff = 0
```

the token may still be burned through redemption/claim finalization.

No settlement token is transferred.

This removes the spent claim from outstanding supply.

---

# 42. `redeemToMargin`

Optara MAY expose:

```text
redeemToMargin(seriesId, quantity)
```

which:

```text
burns long
credits same settlement stablecoin to user's Optara cash balance
```

rather than transferring externally.

If implemented, the credit uses the same conservative payout rounding as normal redemption.

---

# 43. No double redemption

Every redeemed quantity must be burned.

A claim cannot be:

```text
redeemed externally
and
later used to close
or
credited as locked hedge
```

---

# 44. Locked-long settlement

A locked long is still a real long claim.

When its account-group is synchronized:

```text
lockedLongPayoff*
```

is included in the account group settlement.

The token quantity is then:

```text
burned / consumed
```

and cannot be externally redeemed later.

---

# 45. Writer account synchronization

After group finalization:

```text
short risk is deterministic
```

For account `a`:

```text
ShortDebitNumerator
=
sum_i exactPayoffNumerator(i, S*, shortQty_i)

LockedLongCreditNumerator
=
sum_j exactPayoffNumerator(j, S*, lockedLongQty_j)
```

Define:

```text
DeltaNumerator
=
LockedLongCreditNumerator
-
ShortDebitNumerator
```

---

# 46. Atomic group settlement

The account's matured group MUST be settled as one unit.

If:

```text
DeltaNumerator > 0
```

credit:

```text
floorDiv(DeltaNumerator, D_A)
```

If:

```text
DeltaNumerator < 0
```

debit:

```text
ceilDiv(-DeltaNumerator, D_A)
```

---

# 47. Why settlement must be atomic

Example:

```text
cash = 2 USDT
short debit = 5 USDT
locked long credit = 3 USDT
```

Correct:

```text
Delta = 3 - 5 = -2
cash' = 0
```

Incorrect:

```text
cash - 5
then later +3
```

The incorrect sequence creates false insolvency.

---

# 48. `syncRiskGroup`

Conceptual:

```solidity
function syncRiskGroup(
    address account,
    bytes32 groupId
) external;
```

It must:

```text
verify finalized group
enumerate complete bounded account positions in group
compute all short debits
compute all locked-long credits
net atomically
apply one settlement-asset cash delta
consume matured locked longs
clear matured shorts
update active indexes
mark account/group synchronized
emit reconstructable events
```

---

# 49. No global writer loop

Finalization MUST NOT execute:

```text
for every writer:
    settle(writer)
```

That is unbounded.

Instead:

```text
group finalization = O(1) / bounded oracle work
account synchronization = bounded by account/group position limits
```

---

# 50. Permissionless synchronization

`syncRiskGroup(account, groupId)` SHOULD be callable by:

```text
account owner
keeper
any address
```

provided the result is deterministic and cannot redirect account value.

If permissionless:

```text
recipient choices must not exist
price choices must not exist
economic choices must not exist
```

The caller merely advances deterministic state.

---

# 51. Synchronization idempotence

Economically:

```text
sync once = apply delta once
```

A second call must:

```text
revert
or
cleanly no-op
```

but must never debit/credit twice.

---

# 52. Matured effective balance

Before explicit sync, finalized positions already have deterministic economic value.

Define:

```text
EffectiveBalance(a,A)
=
RawCashBalance(a,A)
+
sum finalized-unsynced Delta_g
```

for groups settled in `A`.

---

# 53. Withdrawal synchronization

Before withdrawal of asset `A`:

```text
all finalized-unsynced groups affecting A
```

must be synchronized or otherwise provably included in the canonical effective-balance calculation.

Core V2 MUST synchronize before withdrawal (`MATH.md` section 93).

---

# 54. No stale-balance withdrawal

Forbidden:

```text
raw cash = 10
matured debt = 4
user withdraws 10
because debt was not synced
```

Correct:

```text
sync debt
cash = 6
then evaluate withdrawal
```

---

# 55. Redemption before writer sync

A long holder MAY redeem before the corresponding writer has called `syncRiskGroup`.

This is safe only if:

```text
writer collateral already exists in vault
matured writer debt remains encumbered
writer cannot withdraw around debt
per-asset pooled accounting remains conserved
```

---

# 56. Pooled vault accounting

For settlement asset `A`, conceptually:

```text
VaultBalance(A)
=
EffectiveAccountCashClaims(A)
+
OutstandingExternalSettledClaims(A)
+
RoundingReserve(A)
+
ProtocolOwnedBalance(A)
+
UnallocatedSurplus(A)
```

For fee-free MVP:

```text
ProtocolOwnedBalance(A) = 0
```

---

# 57. External settled claim

After finalization, an external surviving long represents:

```text
fixed claim
```

on the series settlement stablecoin.

Conceptually:

```text
OutstandingExternalSettledClaims(A)
=
sum remaining external long payout claims in A
```

---

# 58. Redemption accounting effect

If holder redeems `R` units of settlement token:

```text
VaultBalance(A)' = VaultBalance(A) - R

OutstandingExternalSettledClaims(A)'
=
OutstandingExternalSettledClaims(A) - exactValueOfBurnedQuantity

RoundingReserve(A)' = RoundingReserve(A) + exactValueOfBurnedQuantity - R
```

The pooled identity remains consistent.

---

# 59. Writer sync accounting effect

Writer synchronization moves:

```text
unsynchronized effective debt/credit
```

into raw account cash state.

It must not create a second claim or second debit.

---

# 60. Settlement asset isolation

All accounting above is per settlement asset.

Forbidden:

```text
USDT long redemption paid from USDC accounting
USDC writer credit applied to USDe
```

Physical custody contracts may hold multiple tokens, but accounting is independent per token.

---

# 61. Settlement reserve concept

The implementation MAY maintain explicit cached reserve counters.

For example:

```text
outstandingSettledExternalClaims[asset]
```

This can improve monitoring and reconciliation.

If cached, counters become invariant-sensitive and must reconcile exactly with claim creation/burn events. Because the external claim is an exact rational value (`MATH.md` section 118), a cached counter must hold numerators, not floored native amounts.

---

# 62. Settlement finalization does not transfer all funds

At group finalization:

```text
no protocol-wide writer loop
no protocol-wide holder loop
```

is performed.

Finalization records economic truth.

Subsequent:

```text
redeem
syncRiskGroup
```

realize it lazily.

---

# 63. Settlement price storage precision

Recommended:

```text
settlementPriceWad
```

with 18 decimals.

The stored normalized price must be sufficient to reproduce every series payoff deterministically.

Provider raw data may use another scale.

---

# 64. Provider raw data retention

The protocol SHOULD emit enough information to audit finalization:

```text
groupId
oracleConfigId
normalized settlement price
provider observation timestamp
provider/source identifier or report hash where possible
finalizer
finalizedAt
```

Provider-specific raw bytes need not all be stored if event/hash evidence is sufficient.

---

# 65. Settlement event

Recommended:

```text
RiskGroupFinalized(
    groupId,
    oracleConfigId,
    settlementAsset,
    settlementPriceWad,
    observationTimestamp,
    finalizer
)
```

Exact event design may differ.

---

# 66. Account sync event

Recommended:

```text
RiskGroupSynced(
    account,
    groupId,
    settlementAsset,
    shortDebitNumerator,
    lockedLongCreditNumerator,
    netCashDeltaNative,
    caller
)
```

Only the net delta is converted to native units (`MATH.md` section 54); per-leg
native amounts do not exist and must not be emitted as if they did. If the net is
stored signed, use a safe signed representation.

---

# 67. Redemption event

Recommended:

```text
LongRedeemed(
    account,
    recipient,
    seriesId,
    quantity,
    settlementAsset,
    payoutNative
)
```

---

# 68. Finalization access control

Preferred:

```text
permissionless finalization
```

when all economic checks are deterministic.

The caller may supply:

```text
oracle update data
provider fee
```

but cannot choose:

```text
strike
cap
settlement asset
price-selection rule
acceptable timestamp range
```

---

# 69. Governance role

Governance may approve future oracle configurations.

Governance MUST NOT:

```text
change existing series oracleConfigId
change finalized price
select ad hoc price after expiry
change strike/cap to repair oracle outcome
```

---

# 70. Oracle-config disablement

Disabling an oracle configuration for **new series** must not erase existing obligations.

Existing series remain bound to their configured settlement semantics.

If the provider is temporarily unavailable:

```text
existing groups remain unsettled
```

until approved precommitted fallback succeeds.

---

# 71. Fallback architecture

Fallback must be:

```text
precommitted
deterministic
bounded
auditable
```

Potential config:

```text
primary source
then secondary source
then remain unsettled
```

The order and conditions must be fixed before series creation.

---

# 72. Forbidden fallback

Forbidden:

```text
"if primary fails, governance chooses whatever seems fair"
```

after economic outcomes are known.

---

# 73. Fallback price-unit requirement

A fallback must produce exactly:

```text
settlementAsset / underlying
```

with the same normalized output convention.

A USD fallback does not become a stablecoin-denominated price without explicit conversion.

---

# 74. Oracle-source disagreement

If multiple sources are part of a deterministic aggregate rule, the config must define:

```text
aggregation method
deviation threshold
minimum number of valid sources
what happens if disagreement exceeds threshold
```

Do not let the finalizer choose the preferred source.

---

# 75. Derived-feed atomicity

For a derived price:

```text
underlying/USD
/
stablecoin/USD
```

the observations should represent compatible timestamps/windows.

Do not combine:

```text
fresh underlying price
with
very stale stablecoin price
```

if that violates the configured methodology.

---

# 76. Decimal safety

For every source:

```text
raw decimals
normalization scale
multiplication order
division order
rounding
```

must be explicit.

Use full-precision `mulDiv`-style arithmetic.

---

# 77. Oracle conversion rounding

Derived pair conversion should use one documented deterministic rounding rule.

The final normalized `S*` is then used symmetrically by:

```text
calls
puts
writers
holders
```

Do not round the underlying price differently for calls and puts.

---

# 78. Payoff rounding

After `S*` is fixed:

```text
economic payoff
```

must follow shared `PayoffMath`.

Then:

```text
external long payout -> round down
positive internal long credit -> round down
writer/net matured debit -> round up
```

as defined in `MATH.md`.

---

# 79. Rounding reserve

Conservative rounding may create non-negative dust:

```text
RoundingReserve(A) >= 0
```

This reserve is not user free collateral.

It must be separately accounted for if materialized.

---

# 80. Settlement fees

For the safest MVP:

```text
long contractual payout
```

MUST be fee-free in core V2 (`FEES.md` section 8, DD-057).

Oracle provider update fees may be paid separately by finalization caller.

A future protocol settlement fee must not silently reduce an already-promised long payout.

---

# 81. Reentrancy

`redeem()` and any function transferring settlement tokens must be protected against reentrancy.

Required ordering must ensure no state exists where:

```text
tokens paid
but long not burned
```

or:

```text
claim burned
then reentrant double-accounting recreates it
```

Use safe token-transfer patterns and appropriate guards.

---

# 82. Non-standard settlement tokens

Settlement assets MUST be limited to exact-accountable ERC-20s. The MVP rejects
the following outright (DD-040):

```text
fee-on-transfer
rebasing
callback-heavy
silent balance mutation
non-standard transfer semantics
```

Settlement correctness depends on token-unit conservation.

---

# 83. Token freeze/blacklist risk

A centralized stablecoin may:

```text
pause
freeze
blacklist
```

addresses.

This is an external asset risk.

If token transfer is blocked:

```text
Optara must not substitute another stablecoin
```

Existing claims remain denominated in the original settlement asset.

Operational response belongs to incident handling.

---

# 84. Stablecoin depeg versus transfer failure

Distinguish:

### Depeg

```text
USDT still transfers
but external USD value changes
```

Same-unit settlement remains possible.

### Token malfunction/freeze

```text
USDT cannot move correctly
```

Settlement transfer may become operationally blocked.

These are different incidents.

---

# 85. Kuru independence

Kuru is never queried for:

```text
settlement price
payoff
claim amount
writer liability
```

Kuru may provide option liquidity before expiry.

Settlement is independent.

---

# 86. Composability independence

Long tokens may be held in:

```text
wallets
Kuru
external vaults
other contracts
```

but redemption always requires actual long-token ownership/authorization and burn.

External accounting is not accepted as a synthetic Optara claim.

---

# 87. Smart-contract account support

Redemption and settlement workflows SHOULD not assume users are EOAs.

Where feasible support:

```text
smart wallets
multisigs
account-abstraction accounts
vault contracts
```

through standard ERC-20 approval/ownership semantics.

---

# 88. SDK settlement API

Recommended off-chain API surface:

```text
getRiskGroupState(groupId)

getOracleConfig(oracleConfigId)

canFinalize(groupId)

prepareFinalize(groupId)

previewSettlementPrice(groupId, oracleData)

getFinalizedPrice(groupId)

getSeriesPayoff(seriesId)

previewRedeem(seriesId, quantity)

previewSyncRiskGroup(account, groupId)

redeem(...)

syncRiskGroup(...)
```

All previews are advisory.

---

# 89. Finalization race behavior

If two callers attempt to finalize the same group:

```text
first valid transaction finalizes
second sees already-finalized state
```

The second cannot overwrite the result.

---

# 90. Oracle update front-running

If caller-submitted oracle update data is publicly visible, another actor may submit the same valid data first.

This should not change economics.

Permissionless finalization should be designed so that:

```text
who submits valid data
does not affect settlement price
```

---

# 91. MEV resistance principle

Settlement methodology must not allow a caller to choose among multiple economically different valid observations.

The more degrees of freedom the caller has, the greater the settlement-MEV surface.

Therefore:

```text
precommit price-selection semantics
minimize caller discretion
```

---

# 92. Timestamp source

Option expiry is based on:

```text
block.timestamp
```

or another explicitly specified chain time source.

Oracle observation timestamp comes from the oracle methodology.

The adapter must define their relationship.

Do not assume they are identical.

---

# 93. Chain reorganization/finality considerations

Monad execution finality assumptions used for settlement should be documented at deployment.

The oracle configuration's finalization delay should be compatible with:

```text
provider finality
chain finality
expected update propagation
```

Do not refinalize after ordinary chain finality simply because a later market price differs.

---

# 94. Emergency settlement pause

If the oracle adapter or SettlementEngine is suspected:

```text
new finalizations may be paused
```

Affected groups remain:

```text
EXPIRED_UNSETTLED
```

until trusted settlement resumes.

Do not settle with guessed prices merely to unblock users.

---

# 95. Already-finalized groups during pause

If a group was correctly finalized before an unrelated later oracle incident:

```text
its stored settlement price remains authoritative
```

No role can refinalize it. Canonical V2 has no refinalization or migration path; if
an exploit proves stored state invalid, the affected asset is contained under
`LIQUIDATION.md` sections 101–102.

---

# 96. Settlement solvency theorem

For each account/group:

```text
ActualLossAtS*
<=
ExactWorstCaseLoss
<=
GroupRequiredMargin
```

Across asset `A`:

```text
ActualNetLiability(a,A)
<=
RequiredMargin(a,A)
<=
CashBalance(a,A)
```

Therefore finalization should reveal a liability already bounded by pre-expiry margin.

Settlement does not create new economic risk; it resolves uncertainty.

---

# 97. Settlement invariant — one price

For every group:

```text
finalizedCount(groupId) <= 1
```

and if finalized:

```text
all series in group use same S*
```

---

# 98. Settlement invariant — immutable payoff

After finalization:

```text
payoff_i*
```

is a pure function of:

```text
S*
K_i
C_i
CS_i
Q_i
```

No market price or governance parameter may change it.

---

# 99. Settlement invariant — no double long consumption

One long unit may be consumed only once through:

```text
active close or unfinalized cancellation
locked-long internal settlement
external redemption
```

never more than one.

---

# 100. Settlement invariant — no double short debit

One matured short unit may be synchronized exactly once.

---

# 101. Settlement invariant — no cross-stablecoin payout

A series settled in `A` pays only `A`.

---

# 102. Settlement invariant — bounded payout

For every series:

```text
0 <= final payout
<= C * CS * Q
```

---

# 103. Settlement invariant — complete account group

If margin recognized multiple positions in group `g`, synchronization must include the complete canonical account/group position set.

No caller-supplied partial subset may determine the final account cash delta.

---

# 104. Settlement invariant — redemption works without writer interaction

A holder must not need:

```text
original writer signature
original buyer
Kuru
```

to redeem a finalized long.

---

# 105. Settlement invariant — writer cannot withdraw around matured debt

Before withdrawal:

```text
finalized-unsynced liabilities
```

must be reflected through synchronization/effective balance.

---

# 106. Settlement invariant — vault conservation

For each asset:

```text
physical token balance
```

must reconcile with internal claims/reserves under the accounting model.

---

# 107. Required unit tests — direct price

Test:

```text
raw oracle decimals -> WAD
exact denomination
positive values
boundary decimal values
overflow limits
```

---

# 108. Required unit tests — derived pair

Test:

```text
underlying/USD
stablecoin/USD
division
stablecoin depeg
rounding
zero denominator rejection
mismatched timestamp rejection
```

---

# 109. Required unit tests — finalization

Test:

```text
before expiry -> revert
too early for finality -> revert
invalid data -> revert
valid data -> finalize
second finalize -> revert/no-op
stored price immutable
```

---

# 110. Required unit tests — call settlement

For:

```text
K=10
C=5
```

test:

```text
S=0
S=10
S=12
S=15
S=1000
```

Expected:

```text
0
0
2
5
5
```

per underlying unit.

---

# 111. Required unit tests — put settlement

For:

```text
K=10
C=4
```

test:

```text
S=15
S=10
S=9
S=6
S=0
```

Expected:

```text
0
0
1
4
4
```

---

# 112. Required tests — locked hedge

Test:

```text
cash = 2
short = 5
locked long = 3
```

Expected atomic debit:

```text
2
```

No intermediate insolvency.

---

# 113. Required tests — asynchronous redemption

Test:

```text
group finalized
external holder redeems
writer not yet synced
writer cannot withdraw matured debt
writer sync later
global asset accounting remains conserved
```

---

# 114. Required fuzz tests

Fuzz:

```text
series terms
contract sizes
quantities
settlement prices
stablecoin decimals
portfolio composition
sync order
redemption order
```

Assert:

```text
payout bounded
single finalization
single redemption
single short debit
atomic hedge credit
per-asset conservation
no stale-balance withdrawal
```

---

# 115. Required invariant tests

At minimum:

```text
finalized price never changes

all series in group share price

current outstanding external claim
cannot exceed backed contractual claim

burned long cannot redeem

synced short cannot debit again

locked long consumed internally
cannot redeem externally

USDT claims never consume USDC accounting
```

---

# 116. Deployment checklist

Before launching an oracle config:

- [ ] provider deployed on intended Monad network;
- [ ] exact source/feed identifiers verified;
- [ ] exact pair denomination verified;
- [ ] direct/derived formula documented;
- [ ] source decimals verified;
- [ ] WAD normalization tested;
- [ ] observation rule fixed;
- [ ] finalization delay fixed;
- [ ] staleness semantics fixed;
- [ ] confidence threshold fixed if applicable;
- [ ] source-selection/fallback retrieval rule fixed;
- [ ] provider update fee behavior understood;
- [ ] chain/provider finality assumptions tested;
- [ ] failure behavior tested;
- [ ] no governance discretionary price path exists;
- [ ] SDK preview matches adapter result on reference vectors;
- [ ] SettlementEngine and RiskEngine share payoff semantics.

---

# 117. Canonical end-to-end flow

```text
ACTIVE RISK GROUP
        |
        | expiry reached
        v
EXPIRED_UNSETTLED
        |
        | caller supplies/prepares provider data
        v
ORACLE ADAPTER
        |
        | validate source
        | validate observation rule
        | normalize exact pair price
        v
SETTLEMENT ENGINE
        |
        | store one immutable S*
        v
FINALIZED RISK GROUP
        |
        +---------------------------+
        |                           |
        v                           v
LONG HOLDER                    WRITER ACCOUNT
        |                           |
        | redeem                    | syncRiskGroup
        v                           v
burn long                    short debit
pay pair stablecoin          locked-long credit
                              atomic net delta
        |                           |
        +-------------+-------------+
                      |
                      v
             PER-ASSET VAULT
              CONSERVATION
```

---

# 118. Final principle

> **Oracle finalization determines one immutable pair-denominated price; settlement then deterministically realizes claims that were already bounded and collateralized before expiry.**

The oracle chooses no economic terms.

The finalizer chooses no favorable outcome.

The SDK supplies no authority.

The contracts enforce the settlement.

---

## 119. Observation arithmetic and finalization admission

Compute observation bounds in checked signed wide arithmetic, e.g.
`int256(uint256(expiry)) + int256(offset)`. Require both results nonnegative and
representable as timestamps, start <= end, and earliest finalization >= observation
end. Never cast a negative offset to unsigned or rely on wraparound.

A config is not launch-ready merely because its fields are populated. Before any
issuance, it MUST name an implemented provider adapter, a unique observation
selection/proof rule, historical report availability/retention, timestamp skew,
normalization, report availability assumptions, fallback eligibility and priority,
and executable success/failure vectors. A report omitted by the caller is not
proof that the primary source failed. Fallback eligibility MUST be checked on-chain
under its precommitted phase/proof rule; callers cannot choose between valid prices.
A provider registry or adapter address for existing groups cannot be replaced by
Optara governance. Provider-owned upgrades remain an explicit external trust risk.

---

## 120. Exact claim accounting

All payoff sums in this document denote exact numerators from `MATH.md` section 24.
No leg is rounded to WAD or native units before group netting. The denominator is
`D_A = 10^(54-d)`. External redemption floors once; net account debits ceil once;
net positive account credits floor once. `MATH.md` section 118 defines exact
outstanding external claims, pending rounded account deltas, fractional shadow
rounding reserves, and unsolicited surplus. Those definitions govern the pooled
identity and replace any informal instruction to reduce an external claim reserve
by only the amount transferred.
