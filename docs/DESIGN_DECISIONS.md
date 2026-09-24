# Optara V2 — Design Decisions

**Document type:** Architecture Decision Record / canonical design-rationale specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Canonical design decisions for the current V2 architecture

---

## 1. Purpose

This document records the major design choices behind Optara V2.

Its purpose is to prevent future engineers, contributors, coding agents, auditors, and integrations from accidentally changing the protocol into a materially different financial system.

Each decision records:

```text
decision
status
reason
tradeoff
rejected alternative
future extension where applicable
```

This document is explanatory and architectural.

Where it conflicts with normative economic math or state behavior:

```text
MATH.md
INVARIANTS.md
PROTOCOL_SPEC.md
OPTION_SPEC.md
```

remain authoritative in their respective domains.

---

# 2. Design philosophy

Optara V2 prioritizes:

```text
1. contractual correctness
2. deterministic solvency
3. custody/accounting integrity
4. settlement correctness
5. bounded execution
6. composability
7. capital efficiency
8. gas optimization
9. convenience
```

Capital efficiency is pursued through:

```text
bounded liabilities
+
exact contractual portfolio offsets
```

not through intentionally leaving worst-case losses unfunded.

---

# DD-001 — European options only

**Status:** Accepted for core V2.

Optara options exercise only through expiry settlement.

No American-style early exercise exists.

### Rationale

European exercise simplifies:

```text
risk modeling
settlement
token fungibility
portfolio netting
state machine
oracle requirements
```

The protocol only needs one deterministic final settlement price.

### Rejected alternative

American options.

American exercise adds:

```text
early exercise timing
writer position mutation
exercise routing
path-dependent account state
more complex margin interactions
```

### Future

American options require a separate architecture.

---

# DD-002 — Cash settlement

**Status:** Accepted.

Long holders receive the series settlement stablecoin.

Optara does not physically deliver the underlying.

### Rationale

Cash settlement avoids:

```text
underlying custody
underlying delivery liquidity
covered-call inventory management
physical exercise logistics
```

### Consequence

A `MON/USDT` call writer backs a bounded USDT obligation with USDT rather than depositing MON.

---

# DD-003 — Capped calls and capped puts

**Status:** Accepted.

Payoffs:

```text
CALL:
min(max(S-K,0),C)

PUT:
min(max(K-S,0),C)
```

### Rationale

The cap makes every option liability finite.

This enables exact deterministic worst-case collateralization.

### Rejected alternative

Uncapped naked calls.

They have unbounded theoretical liability and would require a different margin/liquidation system.

---

# DD-004 — Put cap constrained by strike

**Status:** Accepted.

For puts:

```text
0 < C <= K
```

### Rationale

With:

```text
S >= 0
```

the natural maximum intrinsic put value is `K`.

The constraint keeps the series canonical and avoids economically redundant cap definitions.

---

# DD-005 — Pair-specific settlement stablecoin

**Status:** Accepted.

Every pair defines its own:

```text
UNDERLYING / SETTLEMENT_STABLECOIN
```

Examples:

```text
MON/USDT
ETH/USDC
BTC/USDe
```

The stablecoin is simultaneously:

```text
quote asset
strike unit
cap unit
canonical premium quote
margin asset
settlement asset
```

### Rationale

This keeps all financial quantities in one coherent unit.

### Rejected alternative

Universal USDC accounting.

Optara is explicitly not USDC-based.

---

# DD-006 — No cross-stablecoin margin

**Status:** Accepted.

```text
USDT surplus
cannot secure
USDC liability
```

### Rationale

Avoids:

```text
FX oracles
stablecoin haircuts
depeg correlations
cross-asset liquidation
conversion slippage
```

### Future

Cross-stablecoin collateral requires a separate multi-collateral risk system.

---

# DD-007 — Exact worst-case margin

**Status:** Accepted.

For one risk group:

```text
WorstCaseLoss
=
max_S
max(
    ShortLiability(S)
    -
    LockedLongCredit(S),
    0
)
```

### Rationale

Payoffs are bounded piecewise-linear functions.

The exact maximum is computable at finite critical points.

### Rejected alternatives

```text
FHS
SPAN
VaR
Expected Shortfall
Monte Carlo solvency
spot-only margin
```

These introduce approximation/statistical assumptions unnecessary for bounded core V2.

---

# DD-008 — No normal price-driven liquidation

**Status:** Accepted.

Core V2 requires:

```text
CashBalance
>=
ExactWorstCaseLoss + nonnegative guards
```

before risk is created.

### Rationale

A price move cannot exceed the modeled contractual maximum liability.

### Rejected alternative

Perpetual-style:

```text
health factor
maintenance margin
liquidator race
```

### Future

Undercollateralized leverage is a different architecture requiring a separate specification.

---

# DD-009 — Capital efficiency through locked contractual hedges

**Status:** Accepted.

A compatible long may reduce margin only while Optara controls it.

### Rationale

The protocol can rely on the long claim at settlement only if it cannot disappear.

### Rejected alternative

Recognize wallet/Kuru/off-chain hedges.

External assets can be sold, transferred, or become unavailable.

---

# DD-010 — Risk groups are strict

**Status:** Accepted.

```text
riskGroup =
(
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

### Rationale

Only these positions share a deterministic common final settlement variable.

### Rejected offsets

No core offset across:

```text
different underlying
different expiry
different stablecoin
different oracle domain
```

---

# DD-011 — Different groups sharing one stablecoin add margin

**Status:** Accepted.

Example:

```text
MON/USDT group margin = 5
ETH/USDT group margin = 8

USDT required margin = 13
```

### Rationale

Payoffs do not net across groups, but one USDT cash balance can secure multiple independent USDT liabilities.

---

# DD-012 — Exact finite critical-point risk evaluation

**Status:** Accepted.

Critical prices:

```text
0
call: K, K+C
put:  K-C, K
```

### Rationale

Piecewise-linear portfolio liability reaches maxima at interval boundaries.

### Security consequence

No arbitrary scenario grid may replace the exact critical set.

---

# DD-013 — Bound account/group size

**Status:** Accepted.

Deployment must cap active positions/groups.

### Rationale

Exact risk evaluation and matured-group settlement must remain executable within gas limits.

### Rejected alternative

Unbounded account portfolios with on-chain full scans.

---

# DD-014 — ERC-20 tokenizes only the long side

**Status:** Accepted.

Long claim:

```text
ERC-20 transferable token
```

Short:

```text
internal ClearingHouse obligation
```

### Rationale

Long transfers do not move margin liability.

Short transfers would require atomic collateral and hedge migration.

---

# DD-015 — Short is non-transferable in core V2

**Status:** Accepted.

### Rationale

Prevents liability from moving to an undercollateralized recipient.

### Future

Transferable shorts require an atomic risk-transfer protocol.

---

# DD-016 — Standard fungible long per series

**Status:** Accepted.

One fungible token contract or equivalent fungible representation per series.

### Rationale

Supports:

```text
Kuru trading
wallet transfer
vault custody
market making
secondary ownership
```

---

# DD-017 — Same-series long required to close short

**Status:** Accepted.

A short close consumes:

```text
exact same seriesId
```

long quantity.

### Rationale

Avoids approximate economic equivalence becoming accounting equivalence.

---

# DD-018 — Long-token burn on claim consumption

**Status:** Accepted.

Long is burned/consumed when used for:

```text
active short close or expired-unfinalized cancellation
locked-long settlement credit
external redemption
```

### Rationale

Prevents double use.

---

# DD-019 — Kuru is secondary trading, not clearing

**Status:** Accepted.

```text
Kuru
=
liquidity + order book + price discovery

Optara
=
issuance + margin + clearing + settlement
```

### Rationale

Optara remains solvent if Kuru fails or becomes illiquid.

---

# DD-020 — Kuru market uses option/stablecoin pair

**Status:** Accepted.

```text
Base  = Optara long token
Quote = series settlement stablecoin
```

### Rationale

Premium naturally uses the same quote asset as the option pair.

---

# DD-021 — Kuru balances never count as Optara margin

**Status:** Accepted.

### Rationale

Kuru is a separate custody/accounting domain.

Actual stablecoin must return to Optara before it becomes margin.

---

# DD-022 — Kuru trade never automatically closes short

**Status:** Accepted.

Writer must:

```text
buy exact long
obtain custody
call closeShort
burn long
```

### Rationale

External trade state is not canonical Optara accounting.

---

# DD-023 — Kuru integration lives primarily in `@optara/kuru`

**Status:** Accepted.

### Rationale

Venue-specific logic should not pollute core contracts.

`@optara/kuru` handles:

```text
market discovery
trading workflows
inventory movement
buy-to-close composition
```

### Future

An optional audited on-chain router may support atomic workflows but cannot become a solvency dependency.

---

# DD-024 — SDK-based modular architecture

**Status:** Accepted.

Packages:

```text
@optara/math
@optara/sdk
@optara/kuru
```

### Rationale

Separates:

```text
protocol truth
reference math
developer UX
venue integration
```

---

# DD-025 — SDK is non-authoritative

**Status:** Accepted.

SDK may:

```text
preview
build transactions
decode events
compose workflows
```

Contracts recompute all safety-critical values.

### Security consequence

A compromised SDK should not be able to create an undercollateralized protocol state.

---

# DD-026 — `@optara/math` is an independent reference model

**Status:** Accepted.

### Rationale

Used for:

```text
frontends
previews
simulation
differential testing
```

### Important

It must not become an oracle/proof accepted by Solidity.

---

# DD-027 — Keep core contracts financially authoritative

**Status:** Accepted.

Authoritative contracts include:

```text
ClearingHouse
MarginVault
RiskEngine
SettlementEngine
SeriesFactory
OptionToken
OracleAdapter
```

### Rationale

Financial security cannot depend on off-chain package availability.

---

# DD-028 — Provider-agnostic oracle abstraction

**Status:** Accepted.

Series bind:

```text
oracleConfigId
```

not hardcoded application-level provider logic.

### Rationale

Allows approved provider/configuration diversity while preserving immutable settlement semantics.

---

# DD-029 — Exact pair-denominated settlement oracle

**Status:** Accepted.

For `MON/USDT`:

```text
S = USDT per MON
```

not generic MON/USD.

### Rationale

Stablecoin may depeg.

### Derived path

Allowed if precommitted, e.g.:

```text
MON/USDT
=
MON/USD / USDT/USD
```

---

# DD-030 — One final settlement price per risk group

**Status:** Accepted.

### Rationale

All series in a netted risk group must resolve against the same underlying final price.

---

# DD-031 — Permissionless deterministic finalization preferred

**Status:** Accepted where oracle integration permits.

### Rationale

A finalizer should merely advance deterministic state.

No privileged keeper should choose price.

---

# DD-032 — Precommitted oracle fallback

**Status:** Accepted.

Fallback logic is fixed before series creation.

### Rejected alternative

Governance deciding a “fair price” after expiry.

---

# DD-033 — Atomic matured risk-group settlement

**Status:** Accepted.

For account/group:

```text
Delta
=
LockedLongCredit*
-
ShortDebit*
```

applied atomically.

### Rationale

Pre-expiry margin may rely on offsetting legs.

Settling legs independently can create false insolvency.

---

# DD-034 — Lazy per-account synchronization

**Status:** Accepted.

No protocol-wide writer loop at finalization.

### Rationale

Global writer iteration is unbounded.

### Flow

```text
finalize group once
then
sync accounts individually / bounded batches
```

---

# DD-035 — External long can redeem before writer sync

**Status:** Accepted.

### Rationale

Writer collateral is already physically in the vault and matured debt remains economically encumbered.

### Requirement

Vault/accounting identities and withdrawal synchronization must preserve backing.

---

# DD-036 — Withdrawals synchronize matured debt first

**Status:** Accepted.

### Rationale

Raw cash may be stale after finalization.

No user may withdraw around deterministic matured liability.

---

# DD-037 — Per-asset pooled vault accounting

**Status:** Accepted.

For asset `A`:

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

### Rationale

Supports asynchronous redemption and writer synchronization while preserving conservation.

---

# DD-038 — Conservative rounding

**Status:** Accepted.

```text
required margin             -> UP
writer debit                -> UP
external payout             -> DOWN
positive locked-long credit -> DOWN
withdrawable collateral     -> DOWN
```

### Rationale

Rounding must not create insolvency.

---

# DD-039 — Native token units for cash ledger

**Status:** Accepted.

### Rationale

Ensures exact ERC-20 reconciliation.

Economic math may use WAD, but actual stablecoin accounting remains native units.

---

# DD-040 — Fee-on-transfer/rebasing settlement tokens rejected

**Status:** Accepted for MVP.

### Rationale

Core accounting expects predictable token-unit conservation.

---

# DD-041 — Stablecoin depeg does not trigger cross-asset rescue

**Status:** Accepted.

If USDT backs USDT claims:

```text
external USD value change
```

does not itself create a USDT-unit deficit.

### Consequence

Existing USDT claims remain USDT claims.

---

# DD-042 — No socialized loss in ordinary core V2

**Status:** Accepted.

One healthy user's collateral is not used to repair another account's deficit.

### Rationale

A core-V2 deficit indicates invariant/implementation failure, not expected market behavior.

### Incident exception

If backing is verifiably lost, the asset is restricted and then resolved with one
uniform recovery ratio (`LIQUIDATION.md` section 102, `MATH.md` section 119).
This is chosen over indefinite freezing (claims never resolve) and over
first-come-first-served redemption (early redeemers take everything).

---

# DD-043 — No ordinary insurance-fund dependency

**Status:** Accepted.

### Rationale

Exact worst-case margin should fund normal contractual losses.

An insurance fund would be incident/backstop infrastructure, not ordinary solvency.

---

# DD-044 — No ordinary liquidator role

**Status:** Accepted.

### Rationale

Core V2 does not rely on price-triggered liquidation.

Keepers may perform deterministic maintenance, not economic liquidation.

---

# DD-045 — Risk-reducing actions preserved during pause where safe

**Status:** Accepted.

Examples:

```text
deposit
lock hedge
close short
trusted sync
trusted redemption
```

### Rationale

Emergency controls should contain risk, not trap users unnecessarily.

---

# DD-046 — Narrow access control

**Status:** Accepted.

No implicit:

```text
SDK_ROLE
KURU_ROLE
FRONTEND_ROLE
LIQUIDATOR_ROLE
```

### Rationale

Off-chain layers operate through user signatures or permissionless functions.

---

# DD-047 — Governance controls future risk, not past economics

**Status:** Accepted.

Governance may change:

```text
future pair approvals
future oracle configs
future limits
future fee settings
```

but cannot rewrite existing series or finalized prices.

---

# DD-048 — Pauser can stop, not steal

**Status:** Accepted.

Emergency pauser authority is narrow.

No collateral seizure, arbitrary mint, or settlement-price selection.

---

# DD-049 — Permissionless `syncRiskGroup` preferred

**Status:** Accepted if function is deterministic.

### Rationale

Anyone should be able to advance deterministic state without receiving account funds or choosing economics.

---

# DD-050 — Composable longs, isolated shorts

**Status:** Accepted.

This is the main composability philosophy.

```text
asset that is safe to move
-> long

liability requiring solvency control
-> short stays internal
```

---

# DD-051 — External vault shares are not Optara hedges

**Status:** Accepted.

### Rationale

Only actual canonical long tokens under Optara custody can be guaranteed available for settlement.

---

# DD-052 — External lending risk remains external

**Status:** Accepted.

Third-party lending protocols may value Optara longs.

Their:

```text
LTV
liquidation
bad debt
```

do not change Optara accounting.

---

# DD-053 — Cross-chain canonical option bridging deferred

**Status:** Deferred.

### Rationale

Bridging introduces:

```text
double redemption
bridge compromise
canonical ownership ambiguity
settlement timing
```

Requires separate design.

---

# DD-054 — Core V2 starts fee-free

**Status:** Accepted for MVP.

```text
Optara protocol fees = 0
```

### Rationale

Reduce audit/accounting complexity while core mechanics mature.

External:

```text
Kuru fees
oracle-provider fees
network gas
```

still exist.

---

# DD-055 — Preferred future fee is issuance fee

**Status:** Accepted as future-compatible mechanism.

If enabled:

```text
fee base
=
new gross max contractual payout
```

and fee is paid in:

```text
series settlement stablecoin
```

### Rationale

Deterministic and venue-independent.

### Rejected alternatives

```text
premium percentage
redemption fee
settlement payout haircut
close fee
```

---

# DD-056 — Fees cannot consume required margin

**Status:** Accepted.

If fee enabled:

```text
CashAfterFee
>=
RequiredMarginPostWrite
```

### Rationale

Protocol revenue cannot weaken solvency.

---

# DD-057 — No settlement/redemption fee in core V2

**Status:** Accepted.

### Rationale

Long holder receives contractual payoff subject only to conservative integer rounding.

---

# DD-058 — Frontend/indexer are non-authoritative

**Status:** Accepted.

### Rationale

They may be stale or compromised.

Contracts remain the final authority.

---

# DD-059 — Canonical metadata from on-chain series, not token symbol

**Status:** Accepted.

### Rationale

Symbols are human-readable and collision-prone.

Integrations must use canonical series fields/addresses.

---

# DD-060 — Current spot is not required for active margin

**Status:** Accepted.

### Rationale

Exact worst-case bounded payout already covers all valid expiry prices.

Current spot remains useful for:

```text
UI
analytics
market making
premium pricing
```

not solvency proof.

---

# DD-061 — Premium is market-discovered and separate from margin

**Status:** Accepted.

### Rationale

Optara does not need to price options itself.

Premium received externally becomes margin only after the exact settlement stablecoin actually enters Optara.

---

# DD-062 — Optara does not provide primary pricing model

**Status:** Accepted.

No canonical:

```text
Black-Scholes
vol surface
IV model
```

is required to issue/settle.

### Rationale

Market price discovery belongs to external trading/market makers.

---

# DD-063 — No hidden undercollateralized mode

**Status:** Accepted.

A single config value must not silently transform:

```text
fully worst-case collateralized
```

into:

```text
leveraged undercollateralized
```

### Future

Leverage requires separate:

```text
maintenance margin
liquidation
insurance
bad-debt
mark-price
```

specification.

---

# DD-064 — Exact risk math beats heuristic gas optimization

**Status:** Accepted.

An optimized algorithm may replace direct O(n²) evaluation only if it returns mathematically identical results.

---

# DD-065 — One economic implementation, multiple reference surfaces

**Status:** Accepted.

Canonical:

```text
MATH.md
    |
    +--> Solidity PayoffMath/RiskEngine
    |
    +--> @optara/math
```

Differential testing checks agreement.

On-chain contracts remain authoritative.

---

# DD-066 — Optional `redeemToMargin`

**Status:** Optional / not required for MVP.

A settled long could:

```text
burn
-> credit same settlement stablecoin to Optara cash
```

### Benefit

Reduces external token transfer and lets users reuse settlement proceeds.

### Constraint

Must use same payout semantics and cannot cross stablecoins.

---

# DD-067 — Immutable versioned financial core

**Status:** Accepted for canonical core V2.

Existing obligations pin the complete financial implementation and internal authority
paths under `ACCESS_CONTROL.md` sections 40–45. New implementations take new risk
through new versioned deployments; no forced migration or arbitrary emergency upgrade
is permitted. This preserves settlement semantics but means critical defects may
require scoped containment and separately designed recovery. Timelock notice is
not a guaranteed user exit. Upgradeable variants require a separate trust specification.

---

# DD-068 — Series creation permission model remains deployment decision

**Status:** Deferred.

Possible:

```text
governance/creator curated
permissionless within approved bounds
```

Regardless of creator:

```text
factory validation is mandatory
```

---

# DD-069 — Exact production oracle provider/config remains deployment decision

**Status:** Deferred.

The architecture is provider-agnostic.

Provider choice must satisfy `ORACLE_AND_SETTLEMENT.md`.

---

# DD-070 — Safety buffer may be zero if rounding is proven conservative

**Status:** Accepted.

Core economic solvency derives from exact worst-case loss.

Buffer is optional operational conservatism.

It does not replace numerical correctness.

---

# DD-071 — Kuru market parameters are integration metadata

**Status:** Accepted.

Examples:

```text
tick size
minimum order
Kuru fee
market address
```

are not part of Optara series identity.

### Rationale

A series remains valid if its Kuru market is replaced or absent.

---

# DD-072 — Kuru option price never drives margin or settlement

**Status:** Accepted.

### Rationale

Kuru price is the market value of the option claim, not underlying settlement price or contractual maximum liability.

---

# DD-073 — Protocol must function without SDK

**Status:** Accepted.

Users/integrations may call contracts directly.

### Rationale

SDK is convenience infrastructure, not availability-critical consensus infrastructure.

---

# DD-074 — Protocol must function without official frontend

**Status:** Accepted.

### Rationale

Long-lived financial claims must remain callable directly or through alternative interfaces.

---

# DD-075 — Protocol must function without Kuru

**Status:** Accepted.

### Rationale

Kuru improves liquidity, not settlement correctness.

---

# DD-076 — Series economic terms are immutable

**Status:** Accepted and non-negotiable.

No ordinary privileged function may change existing:

```text
underlying
option type
strike
cap
contract size
expiry
settlement asset
oracle domain
```

---

# DD-077 — Finalized settlement is immutable

**Status:** Accepted and non-negotiable.

Once valid `S*` is finalized:

```text
no refinalization
```

through ordinary governance/admin action.

---

# DD-078 — No caller-supplied incomplete risk set

**Status:** Accepted.

Safety-critical operations must use complete canonical bounded position indexes.

### Rationale

A caller could omit unfavorable positions.

---

# DD-079 — Settlement account-group sync is idempotent

**Status:** Accepted.

Economic cash delta applies once.

Repeated call:

```text
reverts
or
no-ops
```

without second debit/credit.

---

# DD-080 — External holder redemption is permissionless to owner/authorized caller

**Status:** Accepted.

Holder does not require:

```text
writer signature
original buyer
Kuru
keeper approval
```

after settlement.

---

# DD-080A — Exact payoff numerators, one rounding point

**Status:** Accepted (v0.3).

Payoffs are kept as exact integers `phi * CS * Q` and rounded once per group total
or per redemption (`MATH.md` section 24). Per-leg rounding could let a settlement
debit at an interior price exceed the posted margin by one native unit.

---

# DD-080B — Oracle stall: reserve and allow matched exits, never invent a price

**Status:** Accepted (v0.3).

Unfinalized groups stay reserved; `ORACLE_STALLED` is a flag, not a price.
Cancellation with an identical long, safe unlock and free-cash withdrawal remain
available (`PROTOCOL_SPEC.md` section 41). Permanent failure of every source can
leave unmatched claims unresolved; this is disclosed rather than hidden behind an
arbitrary fallback price.

---

# DD-080C — Asset-wide containment, uniform shortfall resolution

**Status:** Accepted (v0.3).

A confirmed deficit restricts every outflow of that asset. If backing was lost, one
timelocked recovery ratio applies to every claimant (`LIQUIDATION.md` sections 101–102).
Rejected: writer-only freeze (pooled redemptions drain first) and indefinite freeze.

---

# DD-080D — Aggregate exposure caps released at finalization

**Status:** Accepted (v0.3).

Gross exposure caps bound total issuance across accounts. A group's exposure leaves
pair/oracle/asset scopes when the group finalizes, so abandoned zero-payoff tokens
cannot permanently consume capacity (`PROTOCOL_SPEC.md` section 42).

---

# DD-080E — Explicit LOCKED-source close

**Status:** Accepted (v0.3).

A writer may close (or cancel while unfinalized) using its own locked hedge of the
identical series, but only by naming the `LOCKED` source. Removing identical short
and long legs together is risk-neutral, so this cannot fail a margin check, while an
unlock-then-close sequence could. A hedge is never consumed implicitly.

---

# Part I — Decisions explicitly rejected for core V2

## 81. Rejected: uncapped calls

Reason:

```text
unbounded liability
```

---

## 82. Rejected: universal USDC collateral

Reason:

```text
conflicts with pair-specific market design
```

---

## 83. Rejected: FHS/SPAN as core solvency model

Reason:

```text
unnecessary approximation for bounded deterministic payoff
```

---

## 84. Rejected: cross-expiry netting

Reason:

```text
price can move between expiries
```

---

## 85. Rejected: cross-underlying statistical netting

Reason:

```text
correlation is not deterministic contractual protection
```

---

## 86. Rejected: wallet-held long hedge credit

Reason:

```text
user can transfer it away
```

---

## 87. Rejected: Kuru-held collateral credit

Reason:

```text
external custody/accounting
```

---

## 88. Rejected: transferable short token in core V2

Reason:

```text
liability transfer without guaranteed collateral transfer
```

---

## 89. Rejected: normal liquidation dependency

Reason:

```text
exact worst-case loss is already funded
```

---

## 90. Rejected: payout haircut as normal bad-debt mechanism

Reason:

```text
breaks immutable claim promise
```

---

## 91. Rejected: governance-selected post-expiry price

Reason:

```text
discretion / conflict / manipulation
```

---

## 92. Rejected: SDK-authoritative margin

Reason:

```text
off-chain compromise could create insolvency
```

---

## 93. Rejected: Kuru price as settlement oracle

Reason:

```text
OPTION/STABLECOIN price
!=
UNDERLYING/STABLECOIN price
```

---

## 94. Rejected: premium-dependent required margin

Reason:

```text
premium is external market consideration
not contractual liability bound
```

---

## 95. Rejected: redemption fee in core V2

Reason:

```text
would alter promised long-holder payout
```

---

# Part II — Deferred future architecture

## 96. Leveraged/undercollateralized writer mode

Requires separate design.

---

## 97. Cross-stablecoin collateral

Requires:

```text
FX
haircuts
depeg policy
liquidation
```

---

## 98. Volatile collateral

Requires:

```text
collateral oracle
haircut
liquidation
gap-risk handling
```

---

## 99. Cross-expiry portfolio margin

Requires path/time risk model.

---

## 100. Transferable shorts

Requires atomic liability/collateral migration.

---

## 101. American exercise

Requires new state and margin mechanics.

---

## 102. Official cross-chain option representation

Requires bridge/canonical-claim specification.

---

## 103. Lending against long tokens inside Optara

External protocols may already do so, but native Optara lending is separate.

---

## 104. Advanced primary-sale auction/pricing

Not required for core issuance.

Kuru/market makers handle price discovery.

---

# Part III — Canonical system architecture resulting from these decisions

## 105. On-chain layer

```text
SeriesFactory
OptionTokenFactory
OptionToken
ClearingHouse
MarginVault
RiskEngine
SettlementEngine
OracleAdapter
AccessController
PayoffMath
RiskMath
```

Financial source of truth.

---

## 106. Off-chain packages

```text
@optara/math
    reference math

@optara/sdk
    Optara developer/client workflows

@optara/kuru
    venue-specific integration
```

Non-authoritative.

---

## 107. Applications

```text
web frontend
indexer
bots
market makers
external integrations
```

Replaceable.

---

# 108. Canonical architecture diagram

```text
                        USERS / APPS
                             |
              +--------------+--------------+
              |                             |
              v                             v
        @optara/sdk                   @optara/kuru
              |                             |
              +----------+                  v
              |          |                Kuru
              v          v
       @optara/math   OPTARA CONTRACTS
                         |
          +--------------+---------------+
          |              |               |
          v              v               v
     Risk/Margin      Custody        Settlement
```

The authoritative path always terminates in Optara contracts.

---

# 109. Canonical financial architecture

```text
PAIR-SPECIFIC STABLECOIN
          |
          v
EXACT WORST-CASE PORTFOLIO MARGIN
          |
          v
WRITE SHORT + MINT LONG
          |
          +--------------------+
          |                    |
          v                    v
     KURU / DEFI          OPTARA HEDGE LOCK
     composability         margin offset
          |
          v
        EXPIRY
          |
          v
ONE GROUP SETTLEMENT PRICE
          |
          +--------------------+
          |                    |
          v                    v
LONG REDEMPTION        WRITER GROUP SYNC
          |                    |
          +---------+----------+
                    |
                    v
            PER-ASSET VAULT
             CONSERVATION
```

---

# 110. Decision-change process

A future proposal that changes any accepted decision should explicitly answer:

```text
Which invariant changes?

Which document becomes outdated?

Does the change alter option-holder rights?

Does it introduce new oracle assumptions?

Does it introduce liquidation/gap risk?

Does it introduce external custody assumptions?

Does it affect stablecoin isolation?

Does it require new access control?

Does it change SDK trust?

Does it change Kuru dependence?

What new tests are required?
```

A change should not be implemented merely because it appears more capital-efficient or convenient.

---

# 111. Non-negotiable decisions

The following define the current core-V2 security model and should not change without treating the result as a new protocol version:

```text
capped payouts
pair-specific settlement stablecoin
exact worst-case margin
no cross-stablecoin margin
locked-long custody for hedge credit
same risk-group deterministic netting
no normal liquidation dependency
long-token burn on claim consumption
single immutable group settlement price
atomic matured-group settlement
Kuru non-authority
SDK non-authority
```

---

# 112. Final principle

Optara V2 intentionally keeps the trusted financial core narrow.

It makes:

```text
the long claim
composable

the short liability
controlled

the payoff
bounded

the margin
exact

the settlement
deterministic

the SDK
modular but non-authoritative

the exchange
useful but non-essential
```

That combination is the core design decision behind the protocol.
