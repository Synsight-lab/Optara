# Optara V2 Protocol Specification

**Document type:** Normative protocol behavior specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.3.0-draft
**Date:** 2026-09-24  
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document defines the **normative state transitions and accounting behavior** of Optara V2.

It is intended to be precise enough that a Solidity engineer or coding agent can implement the protocol without inventing economic behavior that is not specified here.

This specification must be read together with:

- `README.md` — project overview;
- `PRD.md` — product requirements;
- `ARCHITECTURE.md` — component architecture;
- `OPTION_SPEC.md` — exact option-series semantics;
- `MATH.md` — authoritative protocol mathematics;
- `INVARIANTS.md` — system/economic invariants;
- `MARGIN_AND_RISK.md` — margin and risk policy;
- `LIQUIDATION.md` — core-V2 liquidation/emergency policy;
- `KURU_INTEGRATION.md` — external venue boundary;
- `STATE_MACHINE.md` and `USER_FLOWS.md` — lifecycle and interaction behavior.

If two documents appear to conflict, this protocol specification is authoritative for **runtime behavior and state transitions**, while `OPTION_SPEC.md` is authoritative for **option-series economics**.

---

## 2. Normative language

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative.

- **MUST / MUST NOT** — required for protocol correctness or safety.
- **SHOULD / SHOULD NOT** — strongly recommended; deviations require a documented design decision.
- **MAY** — optional behavior that does not change the core economic contract.

---

### 2.1 Client, SDK, and integration boundary

Optara may be accessed directly through contract ABIs or through modular off-chain packages:

```text
@optara/math
    deterministic reference math / previews

@optara/sdk
    typed reads, transaction builders, events, high-level Optara workflows

@optara/kuru
    Kuru-specific market/trading/inventory workflows
```

These packages are **non-authoritative**.

A contract MUST NOT accept an SDK-computed margin, health factor, settlement amount, external trade result, or collateral balance as proof that an operation is safe.

For every safety-critical transition:

```text
client preview
    -> optional/advisory

on-chain recomputation/validation
    -> mandatory/authoritative
```

The SDK MAY improve user experience and compose transactions, but canonical state lives in Optara contracts.

## 3. Core economic model

Optara V2 supports **European, capped, cash-settled call and put options**.

Every option market is defined around a pair:

```text
UNDERLYING / APPROVED_STABLECOIN
```

For each option series, the pair's approved stablecoin is simultaneously the:

```text
quote asset
+ strike denomination
+ payout-cap denomination
+ canonical premium quote asset
+ writer margin asset
+ cash-settlement asset
```

Examples:

```text
MON / USDT  -> USDT margin and settlement
ETH / USDC  -> USDC margin and settlement
BTC / USDe  -> USDe margin and settlement
```

Optara V2 is **not USDC-based** and MUST NOT assume all stablecoins are interchangeable.

A balance in one stablecoin MUST NOT secure a liability denominated in another stablecoin in core V2.

---

## 4. Non-negotiable protocol principles

The implementation MUST preserve all of the following:

1. **Bounded liability** — every option has an immutable maximum payout.
2. **Exact-loss coverage** — core V2 requires enough same-settlement-asset margin, after recognized locked hedges, to cover the portfolio's exact worst-case contractual expiry loss.
3. **Settlement-asset isolation** — one stablecoin cannot silently back another stablecoin's obligations.
4. **Immutable series economics** — strike, expiry, cap, option type, contract size, settlement asset, and oracle domain cannot change after series creation.
5. **No hedge double use** — a long option may reduce margin only while Optara controls that long and it cannot simultaneously be transferred, sold, redeemed, or counted again.
6. **No price-driven insolvency dependency** — core V2 MUST NOT depend on liquidators reacting before a price move exceeds account collateral.
7. **Kuru independence** — Optara settlement must remain correct even if Kuru is unavailable.
8. **Deterministic settlement** — one risk group receives one final settlement price according to a precommitted oracle rule.
9. **No socialized loss in core V2** — one user's option liability must not be intentionally pushed onto unrelated margin accounts.
10. **Risk-reducing actions remain possible** — subject to reentrancy and emergency constraints, users should be able to add collateral, lock valid hedges, close shorts, synchronize matured positions, and redeem valid settled claims.

---

## 5. Roles

### 5.1 Writer

A writer creates a short obligation by calling `write()` and receives newly minted long option tokens.

The writer MUST have sufficient margin after the new short is included in the account's portfolio.

### 5.2 Long holder

A long holder owns ERC-20 option tokens.

A long holder has no additional margin obligation merely because they own a long token. Their maximum acquisition loss is the consideration they paid outside Optara.

### 5.3 Hedged writer

A writer MAY deposit and lock compatible long option tokens into Optara. Those locked longs MAY reduce the writer's required margin when the RiskEngine proves that they reduce worst-case loss.

### 5.4 Trader / market maker

A trader MAY move long option tokens to Kuru or another compatible venue and trade them against the option series' settlement stablecoin.

Kuru balances are outside Optara's accounting domain.

### 5.5 Keeper

A keeper MAY call permissionless maintenance functions such as settlement finalization or bounded account synchronization where such functions are exposed.

A keeper MUST NOT be able to choose economic terms or an arbitrary settlement price.

### 5.6 Governance / protocol operator

Governance or authorized operators MAY manage approved underlyings, approved stablecoins, approved pair configurations, oracle configurations, operational limits, pause controls, and series-creation permissions.

They MUST NOT mutate the economic terms of an already-created series.

---

## 6. Core protocol entities

### 6.1 Account

An Optara account contains, conceptually:

```text
cashBalance[settlementAsset]
shortQty[seriesId]
lockedLongQty[seriesId]
activeRiskGroups[]
activeSeries[]
```

An implementation MAY use subaccounts, account IDs, or owner-address accounts, but risk and ownership boundaries must be explicit.

### 6.2 Option series

A series defines one fungible long claim with immutable terms. See `OPTION_SPEC.md`.

### 6.3 Risk group

A core V2 risk group is:

```text
riskGroup = (
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

Only positions inside the same risk group may offset one another in the exact portfolio-loss calculation.

### 6.4 Settlement asset

The settlement asset is the **approved stablecoin quoted by the option pair**.

The protocol may support many settlement stablecoins at the same time, but their balances and liabilities are isolated.

### 6.5 Long option token

The long side is represented by an ERC-20 token specific to one series.

### 6.6 Short obligation

The short side is an internal ClearingHouse liability attached to the writer's account. It is not a freely transferable ERC-20 token in core V2.

---

## 7. Global protocol state

At minimum, the implementation must be able to determine:

```text
approvedSettlementAsset[asset]
approvedUnderlying[underlying]
approvedPair[underlying][settlementAsset]
series[seriesId]
riskGroupSettlement[groupId]
account cash balances by settlement asset
account short quantities by series
account locked-long quantities by series
option token supply by series
aggregate open short quantity by series
```

Any cached totals MUST be provably consistent with the underlying account and token state.

---

## 8. Series lifecycle

A series passes through the following economic states:

```text
ACTIVE
  |
  | block.timestamp >= expiry
  v
EXPIRED_UNSETTLED
  |
  | risk group's valid oracle settlement is finalized
  v
SETTLED
```

### ACTIVE

- new shorts may be written;
- longs may be transferred, traded, locked, unlocked, or used to close shorts;
- account margin rules apply.

### EXPIRED_UNSETTLED

- no new shorts may be written;
- no position may be treated as if it already has a final payout;
- transfer of long tokens MAY remain allowed;
- risk-increasing manipulation of the expired position MUST NOT be possible;
- the group stays in the required-margin sum at its full worst case;
- `cancelUnfinalizedShort`, safe `unlockLong` and free-cash withdrawal remain available (section 41);
- oracle finalization may occur according to the precommitted rule.

### SETTLED

- the settlement price is immutable;
- the option payoff is deterministic;
- long holders may redeem;
- accounts containing matured positions must settle those positions as complete risk groups.

---

## 9. Settlement-stablecoin isolation

Core V2 MUST use separate accounting domains per stablecoin.

For every account:

```text
cashBalance[USDT]
cashBalance[USDC]
cashBalance[USDe]
...
```

are independent claims.

The RiskEngine MUST calculate required margin per settlement asset:

```text
requiredMargin(account, asset)
```

and MUST enforce:

```text
cashBalance(account, asset) >= requiredMargin(account, asset)
```

after accounting for compatible locked long hedges in the loss function.

The following is forbidden in core V2:

```text
USDT surplus -> covers USDC shortfall
USDC surplus -> covers USDe shortfall
stablecoin A assumed equal to stablecoin B
```

Cross-stablecoin collateral is a future multi-collateral feature and requires explicit pricing, haircut, depeg, and liquidation rules.

---

## 10. Deposit flow

### Preconditions

`deposit(settlementAsset, amount)` MUST verify:

1. `amount > 0`;
2. `settlementAsset` is approved;
3. the asset satisfies supported ERC-20 behavior assumptions;
4. the received amount is exactly accountable;
5. the asset is not in `ASSET_WIND_DOWN`; while the asset is `ASSET_RESTRICTED`, only a cure deposit is accepted (below).

The MVP MUST reject fee-on-transfer, rebasing, callback-heavy, or otherwise non-standard settlement tokens (`DESIGN_DECISIONS.md` DD-040).

While an asset is restricted, an ordinary deposit would be exposed to a later
shortfall ratio (`LIQUIDATION.md` section 102). Therefore only a **cure deposit** is
accepted: into an account whose effective balance in that asset is below its
requirement, and at most up to that deficit. Anyone else who wants to restore
backing uses `recapitalize(asset, amount)`, which adds to `UnallocatedSurplus_A`
and credits no account.

### Effects

After a successful transfer:

```text
cashBalance[msg.sender][settlementAsset] += receivedAmount
```

Because only exact-transfer stablecoins are approved, `receivedAmount == amount`; the deposit reverts otherwise.

### Postcondition

The user's claim increases only in the same stablecoin that entered the MarginVault.

---

## 11. Writing / issuance flow

Conceptual function:

```text
write(seriesId, quantity, recipient)
```

### Preconditions

The function MUST verify:

1. the series exists;
2. the series is `ACTIVE`;
3. new risk is enabled for the pair, oracle config and settlement asset, and the asset is not restricted or in wind-down;
4. `quantity > 0` and respects quantity granularity;
5. `recipient != address(0)`;
6. writing the new short does not exceed account/series/risk-group position limits;
7. the new exposure does not exceed any aggregate exposure cap (section 42);
8. every finalized group affecting the asset is synchronized first (`MATH.md` section 93);
9. the post-write account remains sufficiently margined in the series' settlement stablecoin.

If the deployed core contains the optional issuance-fee mechanism, `write()` also
takes `maxFeeNative` and reverts if the computed fee exceeds it (`FEES.md` section 24).

### Simulation

Before committing state:

```text
simulatedShortQty[seriesId]
    = currentShortQty[seriesId] + quantity
```

The RiskEngine MUST evaluate the affected risk group using the simulated position.

### Effects

If sufficiently margined:

```text
shortQty[writer][seriesId] += quantity
aggregateOpenShortQty[seriesId] += quantity
increase series/group/pair/oracle/asset exposure counters by C*CS*quantity
mint optionToken(seriesId) quantity to recipient
```

### SDK preview rule

An SDK MAY provide:

```text
previewWrite(account, seriesId, quantity)
```

but `write()` MUST calculate/verify the canonical post-write margin from current on-chain state during execution. No preview result is accepted as a trusted input.

### Important premium rule

`write()` MUST NOT assume a premium amount.

Optara creates the secured option claim; the premium is discovered externally when the long token is sold or otherwise exchanged.

If the writer sells the long token on Kuru, the proceeds are **not Optara margin** until the relevant stablecoin is actually transferred back into Optara and credited to the writer's Optara account.

---

## 12. Long-token transfer and external trading

Long option tokens are standard transferable claims unless locked inside Optara.

A holder MAY:

- hold the token in a wallet;
- transfer it;
- deposit it into Kuru's own trading/margin system;
- sell it on a Kuru `OPTION_TOKEN / SETTLEMENT_STABLECOIN` market;
- transfer it to another compatible DeFi protocol;
- return it to Optara to close a matching short;
- lock it inside Optara as a recognized hedge;
- redeem it after settlement.

Optara MUST NOT treat external custody as a recognized hedge.

---

## 13. Kuru accounting boundary

Kuru is an external trading venue.

The canonical Kuru market for a series is:

```text
Base  = Optara long option ERC-20
Quote = series settlement stablecoin
```

Kuru's current SDK exposes standard markets between ERC-20 base and quote assets and uses a separate Kuru margin account for trading balances. Optara therefore MUST treat Kuru balances as external until assets actually move back into Optara.

Consequences:

```text
Kuru USDT balance != Optara USDT margin balance
Kuru option balance != Optara locked hedge
Kuru trade execution != Optara position close
```

A short closes only when Optara itself receives and consumes the matching long token.

The recommended MVP integration layer is the off-chain `@optara/kuru` package. It MAY simplify market discovery, trades, inventory movement, and buy-to-close workflows, but it MUST preserve this accounting boundary. A future on-chain adapter/router MAY be added for atomic workflows, but core protocol correctness MUST NOT depend on it.

---

## 14. Locking a long as a hedge

Conceptual function:

```text
lockLong(seriesId, quantity)
```

### Preconditions

1. the caller owns or has approved the required long tokens;
2. `quantity > 0`;
3. the series is `ACTIVE` (a lock after expiry cannot add hedge recognition);
4. the resulting account/group position count and numerator bounds (`MATH.md` section 24) are respected;
5. the token is transferred into Optara custody in this call; only the transferred amount is credited, never a pre-existing custody surplus.

A locked long in a group where the account has no short is allowed; it is still
indexed, counts toward position limits, and is credited at settlement.

### Effects

```text
OptionToken transferred to ClearingHouse/escrow
lockedLongQty[account][seriesId] += quantity
```

### Margin recognition

The RiskEngine MAY count the locked long's payoff only inside a compatible risk group.

A long from a different:

- underlying;
- expiry;
- settlement stablecoin; or
- oracle/settlement domain

MUST NOT reduce the group's required margin in core V2.

---

## 15. Unlocking a long hedge

Conceptual function:

```text
unlockLong(seriesId, quantity, recipient)
```

Before release, Optara MUST simulate the account as if the requested locked quantity no longer exists.

Unlock succeeds only if:

```text
postUnlockCashBalance(asset)
    >= postUnlockRequiredMargin(asset)
```

for the affected settlement asset.

If the group is finalized, it MUST be settled before any hedge release. Expired-unfinalized unlock uses the full post-removal worst-case check in section 41.

A settled locked long MUST NOT be both credited during account settlement and later unlocked for external redemption.

---

## 16. Closing a short before expiry

A writer closes a short by returning an equal quantity of the **same series' long token** to Optara.

Conceptual function:

```text
closeShort(seriesId, quantity, source)   // source = EXTERNAL | LOCKED
```

### Preconditions

```text
series ACTIVE
0 < quantity <= shortQty[account][seriesId]
```

and the caller explicitly selects where the matching long comes from:

- `EXTERNAL` — the caller transfers `quantity` identical long tokens into Optara in this call;
- `LOCKED` — `quantity <= lockedLongQty[account][seriesId]`; the caller's own locked hedge in the identical series is consumed.

A locked hedge is never consumed implicitly; only an explicit `LOCKED` source may use it.
A `LOCKED` close removes one short unit and one identical long unit together, so the
account's net liability is unchanged at every price and the close cannot fail a margin check.

### Effects

```text
burn quantity long tokens (from the caller transfer or from Optara custody)
shortQty[account][seriesId] -= quantity
aggregateOpenShortQty[seriesId] -= quantity
if source == LOCKED: lockedLongQty[account][seriesId] -= quantity
decrement gross exposure counters (section 42)
```

After the close, the RiskEngine recalculates the affected group and any excess margin becomes withdrawable.

A long token from a different series MUST NOT close the short, even if its payoff looks economically similar.

---

## 17. Exact portfolio-margin model

Core V2 uses deterministic worst-case payoff analysis, not FHS, SPAN, or a statistical volatility model.

For one series with settlement price `S`:

```text
CALL payoff per underlying unit
= min(max(S - K, 0), C)

PUT payoff per underlying unit
= min(max(K - S, 0), C)
```

where:

```text
K = strike
C = max payout cap
```

For one risk group:

```text
shortLiability(S)
    = sum(short position payouts at S)

lockedLongCredit(S)
    = sum(locked compatible long payouts at S)

netLoss(S)
    = max(shortLiability(S) - lockedLongCredit(S), 0)

worstCaseLoss
    = max over all S >= 0 of netLoss(S)
```

Because every payoff is bounded and piecewise linear, the exact maximum can be found by evaluating the finite set of payoff breakpoints.

### Required margin

For one risk group:

```text
groupRequiredMargin
    = ceilToSettlementUnits(worstCaseLoss)
      + explicitSafetyBuffer
```

For one settlement stablecoin:

```text
requiredMargin(account, asset)
    = sum(groupRequiredMargin for all active or expired-unfinalized groups using asset)
```

Core V2 recognizes no cross-group offsets.

### Current spot price

The current spot price MUST NOT be required to prove solvency in the fully worst-case-collateralized core mode.

Current price may be used by frontends, analytics, or market makers, but a sudden price jump cannot make the contractual maximum loss exceed the amount modeled by the RiskEngine.

---

## 18. Critical-point evaluation

For each call series:

```text
K
K + C
```

are payoff breakpoints.

For each put series:

```text
max(K - C, 0)
K
```

are payoff breakpoints.

The group evaluator MUST include:

```text
S = 0
all relevant call and put breakpoints
an upper terminal point at or above every call cap boundary
```

Beyond the largest call cap boundary, all capped-call payouts are flat and put payouts are zero, so the portfolio loss is also flat with respect to further price increases.

The implementation MAY remove duplicate points and use optimized data structures, but MUST return the same worst-case result as direct evaluation.

---

## 19. Withdrawal flow

Conceptual function:

```text
withdraw(settlementAsset, amount, recipient)
```

A withdrawal is collateral-decreasing and therefore safety-critical.

### Preconditions

1. `amount > 0`;
2. `amount <= cashBalance[account][settlementAsset]` after required finalized-group synchronization;
3. every finalized risk group affecting that asset is synchronized completely, while expired-unfinalized groups retain their full worst-case reservation;
4. the simulated post-withdraw account satisfies margin requirements;
5. the vault has sufficient actual balance of the exact settlement asset.

### Required synchronization

A caller MUST NOT be able to omit a finalized short or hedge that would change withdrawable equity.

The implementation MUST therefore use a **complete bounded account position index** or another mechanism that proves all relevant finalized positions were processed.

An unverified caller-supplied partial series list is insufficient for a withdrawal safety check.

### Postcondition

```text
cashBalance -= amount
transfer exact settlementAsset to recipient
```

No asset conversion occurs inside the withdrawal flow.

An SDK MAY expose `maxWithdrawable()` or `previewWithdraw()`, but the contract MUST synchronize every finalized group affecting the asset and recompute the canonical post-withdraw margin during execution.

---

## 20. Why core V2 does not use price-driven liquidation

Core V2 requires:

```text
same-asset collateral + recognized locked hedge protection
>= exact worst-case contractual portfolio loss
```

Therefore, once an account is valid, a change in the underlying price cannot make its contractual expiry loss exceed the modeled worst-case loss.

Accordingly:

- core V2 MUST NOT rely on a liquidator racing a price move;
- core V2 does not need mark-to-market maintenance margin for solvency;
- core V2 does not need an insurance fund to cover ordinary option gap risk;
- a future leveraged mode where `posted margin < exact worst-case loss` requires a separate liquidation and bad-debt specification.

Canonical V2 exposes no administrative liquidation or position close-out. Incidents are handled only by containment (`LIQUIDATION.md` section 101) and, if backing was lost, verified-shortfall resolution (`LIQUIDATION.md` section 102).

---

## 21. Oracle and risk-group finalization

Settlement MUST be bound to the **exact pair denomination**.

For `MON/USDT`, the final price must represent MON in USDT units.

Optara MUST NOT silently treat a generic MON/USD feed as MON/USDT by assuming `1 USDT = 1 USD`.

A derived path MAY be approved, for example:

```text
MON/USDT = (MON/USD) / (USDT/USD)
```

provided the oracle configuration commits to:

- all required feeds;
- decimal normalization;
- staleness thresholds;
- finality rule;
- fallback behavior;
- price-selection timestamp/window.

### Group-level settlement price

Because all series in a risk group share:

```text
underlying
expiry
settlementAsset
oracleConfigId
```

they MUST use the same finalized settlement price.

Conceptually:

```text
finalizeRiskGroup(groupId)
```

records one immutable `settlementPrice` for that group.

A series payoff is then derived deterministically from its own strike/cap and the group's final price.

---

## 22. Matured risk-group settlement

This is a critical rule.

If an account's margin was reduced because multiple positions inside a risk group offset one another, those positions MUST be settled **atomically as a complete matured risk group**.

The protocol MUST NOT debit a matured short first and only later credit the locked long that was used to justify lower margin.

Example:

```text
cash margin = 2 USDT
short liability at expiry = 5 USDT
locked-long credit at expiry = 3 USDT
net liability = 2 USDT
```

A per-series debit of 5 USDT would falsely make the account appear insolvent even though the portfolio was correctly margined.

### Required algorithm

Conceptual function:

```text
syncRiskGroup(account, groupId)
```

MUST:

1. require that `groupId` is finalized;
2. enumerate every active short and locked long belonging to that account and group;
3. compute all matured short debits;
4. compute all matured locked-long credits;
5. compute the net cash delta in the group's settlement stablecoin;
6. apply the cash delta atomically;
7. burn/consume all matured locked-long tokens credited in this synchronization;
8. clear the corresponding matured short and locked-long position quantities;
9. update group/account indexes;
10. emit sufficient events for independent reconstruction.

The account's cash after settlement must be non-negative in core V2. A negative result indicates an invariant failure. The operation MUST revert without moving assets; it does not persist a pause. The separate containment transaction in `LIQUIDATION.md` section 101 records and enforces the incident restriction.

---

## 23. Long redemption

A settled long token is a deterministic claim in the series' settlement stablecoin.

Conceptual function:

```text
redeem(seriesId, quantity, recipient)
```

### Preconditions

1. the risk group is finalized;
2. `quantity > 0`;
3. caller owns or has authorized the specified tokens;
4. tokens are not locked as a margin hedge in another account;
5. the settlement asset is not `ASSET_RESTRICTED` and settlement execution is not paused.

### Effects

```text
payout = floor(longPayoff(seriesId, quantity))
burn quantity long tokens
transfer payout settlementAsset to recipient
```

In `ASSET_WIND_DOWN`, the transfer is `floor(rho_A * payout)` (`LIQUIDATION.md` section 102).

A `redeemToMargin()` variant MAY burn the long and credit the payout into the holder's Optara cash balance instead of transferring tokens externally.

### No double redemption

Burning is mandatory. A redeemed quantity MUST never remain available as a claim.

---

## 24. Settlement liquidity and pooled custody

The MarginVault may pool the same approved stablecoin across accounts, but accounting ownership remains segregated by account.

Long claims may be paid before every writer has explicitly synchronized because the writers' collateral is already physically present in the vault and writers with matured debt cannot withdraw around that debt.

The protocol MUST preserve the accounting identity that matured writer obligations remain encumbered until synchronized, even if an external long holder has already redeemed.

A writer withdrawal MUST therefore synchronize all finalized risk groups relevant to the requested settlement asset before determining free collateral.

---

## 25. Premium semantics

The premium is the market price paid to acquire a long token. It is **not part of the contractual payoff formula**.

Optara core does not set the premium.

Canonical secondary markets SHOULD quote premium in the same stablecoin as the series settlement asset:

```text
OPTION / SETTLEMENT_STABLECOIN
```

If a writer receives premium on Kuru:

```text
Kuru premium proceeds
    -> remain Kuru balance
    -> writer withdraws/transfers stablecoin
    -> writer deposits into Optara
    -> only then does it become Optara margin
```

The protocol MUST NOT grant margin credit for an external receivable or unwithdrawn exchange balance.

---

## 26. Fees

Fee percentages are not defined by this specification.

Any fee implementation MUST obey these constraints:

1. fees MUST be explicit and separately accounted;
2. a fee MUST NOT change an already-created series' contractual payoff formula;
3. Kuru trading fees are external to Optara;
4. fees MUST NOT be counted as writer margin before they are actually in the relevant Optara account;
5. settlement fees, if ever introduced, MUST NOT reduce a long holder below the payoff promised by the series unless the fee was explicitly part of the immutable series contract at creation.

For the safest MVP, settlement payout semantics SHOULD remain fee-free and exact.

---

## 27. Rounding rules

Solvency depends on consistent rounding.

The implementation MUST use shared math code for risk and settlement.

Required direction (`MATH.md` section 53), each applied once to an exact numerator:

```text
long-holder payout / credit -> round DOWN
required margin             -> round UP
writer net matured debit    -> round UP
```

This ensures rounding cannot create a deficit.

Any resulting base-unit dust MUST be tracked and MUST NOT be withdrawable as user collateral while claims remain outstanding.

`OPTION_SPEC.md` defines the normalized units used by the payoff functions.

---

## 28. Active-position bounds

The protocol MUST avoid unbounded loops over protocol-wide users or positions.

Core V2 MUST enforce bounded per-account state, such as:

```text
MAX_ACTIVE_SERIES_PER_ACCOUNT
MAX_ACTIVE_GROUPS_PER_ACCOUNT
MAX_SERIES_PER_RISK_GROUP_PER_ACCOUNT
```

Exact numeric limits are deployment parameters and must be fixed before launch.

The chosen limits MUST be high enough for practical strategies but low enough that:

- margin evaluation cannot exceed block gas limits;
- complete matured-group synchronization is always executable;
- withdrawal checks can prove completeness.

---

## 29. Pause behavior

Emergency controls SHOULD distinguish risk-increasing actions from risk-reducing and settlement actions.

Recommended behavior during a risk pause:

| Action | Expected behavior |
|---|---|
| Deposit settlement stablecoin | Allowed |
| Lock compatible long hedge | Allowed |
| Close active short (`EXTERNAL` or `LOCKED` source) | Allowed |
| Cancel expired-unfinalized short | Allowed |
| Write new short | Blocked |
| Unlock hedge | Blocked if it increases risk |
| Withdraw collateral | Blocked or allowed only under full safety checks, depending on incident class |
| Finalize valid oracle settlement | Allowed unless oracle itself is the incident |
| Sync finalized risk group | Allowed |
| Redeem settled long | Allowed whenever settlement data is trusted |

A confirmed asset-wide solvency restriction (`LIQUIDATION.md` section 101) is stricter than a risk pause: it also blocks withdrawals, redemptions, hedge unlocks and every other outflow of that asset until it is cleared or resolved under `LIQUIDATION.md` section 102.

Governance MUST NOT use pause powers to rewrite strike, cap, expiry, settlement stablecoin, or finalized settlement price.

---

## 30. Oracle failure handling

An expired group MUST remain `EXPIRED_UNSETTLED` if the precommitted oracle rule cannot produce a valid price.

The protocol MUST NOT invent a settlement price merely to unblock users.

Each oracle configuration MUST predefine:

- primary source;
- approved fallback source or path, with on-chain eligibility rules;
- staleness limits relative to the observation;
- observation window;
- finality delay;
- a finite `maxFinalizationDelay` escalation deadline (`ORACLE_STALLED`);
- behavior when no valid source exists (section 41).

Manual governance price selection after observing market outcomes is forbidden. Recovery while a group is unfinalized follows section 41.

---

## 31. Access-control rules

Core V2 SHOULD separate at least these permissions (canonical names from `ACCESS_CONTROL.md`):

```text
GOVERNANCE_ROLE       approves assets/pairs, clears restrictions, timelocked policy
CONFIG_ROLE           prospective low/medium-risk settings after governance approval
SERIES_CREATOR_ROLE   creates factory-validated series
ORACLE_CONFIG_ROLE    registers/suspends oracle configs for future series
PAUSER_ROLE           pauses risk paths and restricts an asset (guardian)
```

No core `UPGRADER_ROLE` exists in canonical V2.

Rules:

- users do not need permission to deposit, write an existing series, trade long tokens, close, lock, unlock when safe, sync, or redeem;
- series creation SHOULD be permissioned for the MVP;
- adding a new stablecoin or pair requires explicit approval;
- changing oracle configuration for an existing series is forbidden;
- changing immutable series economics is forbidden;
- admin rescue functions MUST NOT sweep accounted user collateral.

---

## 32. Reentrancy and token-transfer ordering

External token calls are hostile boundaries.

The implementation MUST:

- use reentrancy protection on state-changing entry points with external transfers;
- follow checks-effects-interactions or an equivalent safe pattern;
- use safe ERC-20 transfer wrappers;
- never trust ERC-20 return values blindly;
- avoid calling arbitrary external contracts during RiskEngine math;
- keep oracle reads/finalization separate from user-controlled callbacks;
- reject or explicitly adapt tokens with hooks or unusual transfer semantics.

---

## 33. Required events

At minimum, emit enough information to reconstruct protocol state:

```text
SeriesCreated
CollateralDeposited
CollateralWithdrawn
OptionWritten
ShortClosed
LongLocked
LongUnlocked
ShortCancelledUnfinalized
RiskGroupFinalized
RiskGroupSynced
LongRedeemed
AssetApproved / AssetDisabled
PairApproved / PairDisabled
OracleConfigApproved / OracleConfigDisabled
PauseStateChanged
AssetRestricted / AssetRestrictionCleared
Recapitalized
ShortfallResolved
ExposureLimitChanged
```

Events SHOULD include `account`, `seriesId` or `groupId`, `settlementAsset`, quantity, and cash delta where relevant.

---

## 34. Core invariants

### P-1. Payout is bounded

```text
0 <= payoff(series, S, Q)
   <= maxPayout(series) * contractSize * Q
```

subject to fixed-point normalization.

### P-2. Post-action margin safety

After every risk-increasing or collateral-decreasing action:

```text
cashBalance(account, asset)
    >= requiredMargin(account, asset)
```

for each affected settlement asset.

### P-3. No cross-stablecoin substitution

```text
surplus(assetA) cannot satisfy deficit(assetB)
```

in core V2.

### P-4. Locked hedge custody

Every quantity counted as a hedge is controlled by Optara.

### P-5. No hedge double use

One long token unit can produce at most one of:

- external transfer/trade;
- short close;
- margin hedge credit;
- settlement redemption/credit.

It cannot perform two of them simultaneously.

### P-6. Pre-finalization issuance conservation

Until a group is finalized, every burn path (active close, unfinalized cancellation)
reduces long supply and open short quantity equally, so:

```text
current long supply
    == aggregate open short quantity
```

After finalization, redemption and writer sync happen at different times; the
cumulative identities in `MATH.md` section 58 apply instead.

### P-7. Single group settlement price

A risk group has at most one finalized settlement price.

### P-8. Atomic matured-group settlement

A margin-netted matured risk group is settled as one account-level unit.

### P-9. No double redemption

Redeemed long quantity is burned.

### P-10. Kuru independence

Kuru downtime or Kuru margin balances cannot invalidate Optara's settlement accounting.

### P-11. Off-chain non-authority

`@optara/math`, `@optara/sdk`, `@optara/kuru`, frontends, indexers, and bots are convenience/reference layers. None may create collateral, close a short, recognize a hedge, authorize a withdrawal, or finalize settlement except through a valid canonical on-chain transition.

### P-12. Immutable option economics

No privileged role can mutate an existing series' strike, cap, expiry, type, contract size, settlement asset, or oracle domain.

### P-13. Same-asset withdrawal

A withdrawal transfers only the stablecoin whose account balance is reduced.

### P-14. Exact settlement debit bound

For every account group and every valid settlement price, the integer net debit
(`MATH.md` section 54) is at most the group's pre-funded native margin.

### P-15. Aggregate exposure bound

No write can push any series, pair, oracle-config or settlement-asset exposure
counter above its configured limit (section 42).

---

## 35. Unsupported behavior in core V2

The following are intentionally out of scope unless separately specified:

- American-style early exercise;
- uncapped naked calls;
- undercollateralized naked option selling;
- price-driven maintenance-margin liquidation;
- FHS or SPAN margin;
- cross-expiry offsets;
- cross-underlying offsets;
- cross-stablecoin margin substitution;
- volatile-token collateral such as MON backing a stablecoin liability;
- physical delivery of the underlying;
- freely transferable short-liability tokens;
- governance-selected settlement prices after observing outcomes;
- automatic use of Kuru balances as Optara collateral.
- trusting SDK/frontend/indexer-computed health or margin as authoritative protocol state.

---

## 36. Minimum implementation acceptance tests

An implementation is not conformant unless tests demonstrate at least:

1. `MON/USDT` and `ETH/USDC` accounts are accounted independently.
2. USDT cannot satisfy a USDC margin deficit.
3. Writing a series mints matching long quantity and records matching short quantity.
4. A write that exceeds exact margin reverts.
5. A capped call never pays above its cap, even at extremely large settlement prices.
6. A capped put never pays above its cap and never requires a negative underlying price.
7. A compatible locked long reduces margin exactly where the payoff math proves it does.
8. An incompatible long does not reduce margin.
9. A locked hedge cannot be transferred or redeemed externally.
10. Unlocking a hedge reverts if the remaining account would be under-margined.
11. Closing a short consumes the identical series' long token, from an external transfer or an explicitly selected own locked hedge.
12. A Kuru balance is not visible as Optara margin.
13. A finalized hedged risk group settles atomically without a temporary false insolvency.
14. A user cannot withdraw around unsynchronized finalized debt.
15. Long redemption burns the token and cannot be repeated.
16. RiskEngine and SettlementEngine use identical exact-numerator payoff semantics.
17. `@optara/math` matches canonical Solidity payoff/risk results across the supported differential-test domain.
18. SDK previews cannot bypass stale-state or post-state on-chain checks.
19. `@optara/kuru` workflows only affect Optara after actual assets reach an Optara entry point.
20. Different stablecoin decimals do not break payout or margin accounting.
21. Settlement uses the exact configured pair denomination and does not assume stablecoin parity with USD.
22. Oracle finalization cannot occur twice.
23. A sudden underlying-price jump does not create a liability larger than the pre-funded worst-case amount.
24. At interior settlement prices, the integer net debit never exceeds the posted margin.
25. Account splitting cannot exceed an aggregate exposure cap; finalization releases group exposure from wider scopes.
26. Expired-unfinalized cancellation and safe unlock work while the oracle is stalled.
27. A confirmed asset restriction blocks all outflows of that asset; shortfall resolution pays every claimant the same ratio.

---

## 37. Deployment parameters that remain configurable

The following values are deployment/configuration parameters rather than undefined economic behavior:

- approved underlying list;
- approved stablecoin list;
- approved underlying/stablecoin pairs;
- oracle configurations;
- minimum time-to-expiry for new series;
- maximum time-to-expiry;
- minimum/maximum strikes and caps;
- quantity granularity;
- maximum active positions/groups per account;
- aggregate exposure caps per series, pair, oracle config and settlement asset;
- `maxFinalizationDelay` and fallback eligibility per oracle config;
- safety-buffer defaults for new groups (zero in the MVP);
- protocol fee parameters;
- pause-role addresses;
- series-creator addresses;
- immutable versioned-core bindings and initialization sealing.

An implementation agent MUST NOT invent these values silently. They belong in deployment configuration and governance documentation.

---

## 38. Canonical end-to-end flow

```text
1. Governance approves UNDERLYING / STABLECOIN pair and oracle domain.

2. Authorized creator registers a capped European option series.

3. Writer deposits the pair's settlement stablecoin into Optara.

4. Writer calls write().

5. RiskEngine evaluates exact worst-case loss of the affected risk group.

6. If safe, Optara records the short and mints long ERC-20 tokens.

7. Writer may sell those long tokens on Kuru against the same settlement stablecoin.

8. Kuru proceeds remain external until withdrawn and deposited back into Optara.

9. Writer may acquire compatible longs and lock them inside Optara to reduce exact margin.

10. Writer may close a short by returning and burning the identical long series before expiry.

11. At expiry, the risk group's configured oracle rule produces one final pair-denominated settlement price.

12. Long holders may redeem deterministic capped cash payouts in the series settlement stablecoin.

13. Each writer account settles every matured position in that risk group atomically, including locked-long credits and short debits.

14. Remaining same-stablecoin collateral becomes withdrawable after all affected margin checks pass.
```

---

## 39. Engineering priority order

Recommended order:

```text
1. Solidity payoff/fixed-point math
2. series + long token
3. pair-stablecoin custody + ClearingHouse
4. canonical RiskEngine
5. write/close/lock/unlock/withdraw safety
6. oracle + settlement + redemption
7. invariants/fuzzing of financial core
8. @optara/math independent reference model
9. Solidity <-> @optara/math differential tests
10. @optara/shared ABI/types/deployments
11. @optara/sdk clients/previews/transaction builders
12. @optara/kuru integration workflows
13. applications/indexer
14. end-to-end/adversarial tests + audit
```

The off-chain packages are intentionally implemented after the core financial behavior is executable and testable.

---

## 40. External implementation reference

The Kuru integration assumptions in this specification are based on the official Kuru SDK repositories as inspected on 2026-09-24:

- https://github.com/Kuru-Labs/kuru-sdk
- https://github.com/Kuru-Labs/kuru-sdk-py

These references support the assumptions that Kuru standard markets are configured with ERC-20 base/quote token addresses and that Kuru trading balances live in Kuru's own margin-account domain. Optara must continue to verify these assumptions against the deployed Kuru contracts and SDK version used at integration time.

Venue-specific interaction code SHOULD be isolated in `@optara/kuru` so Kuru SDK/API changes do not require changes to core Optara risk or settlement contracts.

---

## 41. Expired-unfinalized positions and oracle recovery

Expiry does not release margin. Until finalization, every expired-unfinalized group
remains in the account's bounded risk index and required-margin sum at its exact
worst-case requirement. All finalized groups affecting an asset MUST be synchronized
before cash-spending actions. An unfinalized group is reserved, not synchronized.

While a group is expired but unfinalized, `cancelUnfinalizedShort(seriesId, quantity, source)`
MUST permit account-authorized cancellation with the same explicit `source` rule as
`closeShort` (section 16): `EXTERNAL` identical long tokens transferred in by the caller,
or `LOCKED` from the caller's own locked hedge in the identical series. It atomically
burns the long, reduces the same short, updates supply and gross exposure counters,
and validates the complete post-state. It accepts no price, pays no settlement amount,
and cannot spend another user's long; a locked hedge is consumed only when `LOCKED`
is named explicitly. A finalized group must use normal settlement; racing cancellation
and finalization is resolved by transaction ordering.

`unlockLong` MUST permit release of an expired-unfinalized hedge only after the complete
post-removal margin check. It MUST NOT release a finalized hedge outside atomic
settlement. Withdrawals of independently proven free collateral remain possible
with unfinalized groups reserved. These recovery actions remain subject to scoped
custody/risk pauses and are not early exercise.

Each immutable oracle config MUST define a finite `maxFinalizationDelay`. At its
expiry-relative deadline an unfinalized group is flagged `ORACLE_STALLED` for
monitoring and user disclosure; this is a recovery flag, not a settlement price or
a debt write-off. Deterministic late finalization remains allowed if the exact
precommitted historical observation/fallback can still be authenticated. Validation
uses observation-time staleness, not current-time freshness.

If all approved sources permanently fail, unmatched claims remain unresolved and
backed; there is no universal guaranteed settlement deadline. The protocol MUST
NOT invent a price, return encumbered writer funds, or promise automatic migration.
The SDK/frontend MUST disclose this residual liveness risk before acquisition and
show cancellation/free-collateral recovery paths. The finite delay is an escalation
deadline, not a promise of final payout. Production activation requires tested
historical retrieval and precommitted fallback rules.

---

## 42. Aggregate issuance exposure limits

Gas limits per account are not protocol exposure limits. Before activation configure
finite nonzero maximum gross outstanding claim exposure for each series, pair,
oracle config and settlement asset. Track exact maximum-payoff numerators:

```text
ExposureN(scope) = sum(C_i * CS_i * outstandingLongQuantity_i in scope)
limit test: ExposureN(scope) <= configuredLimitN(scope)
```

Scopes contain one settlement asset; no cross-stablecoin or USD conversion exists.
Counters use the same checked product scale as `MATH.md` section 24 and are bounded
by `int256.max`. A write simulates the increase in EVERY affected scope and reverts
if any limit is exceeded, irrespective of account, recipient, locked hedges, or
net margin. Updates are constant in protocol user count. Long transfers/locks do
not change exposure.

Exposure is also tracked per risk group (`ExposureN(group)`), and the pair,
oracle-config and settlement-asset counters are sums of the per-group counters of
**unreleased** groups:

```text
before finalization:
    every burn (active close, unfinalized cancellation) decrements
    series, group, pair, oracle-config and asset counters by C*CS*Q

at finalizeRiskGroup(g), in O(1):
    pair/oracle/asset counters -= ExposureN(g)
    mark g released

after finalization:
    burns (redemption, internal hedge consumption) decrement only the
    series and group counters
```

Rationale: once a group is finalized its claims are fixed amounts already backed
by writer cash, so they no longer represent open, unknown risk. Releasing at
finalization prevents abandoned zero-payoff tokens (which holders rarely bother to
burn) from permanently consuming pair- and asset-level issuance capacity. Short sync
alone does not change any counter. Expired-unfinalized and `ORACLE_STALLED` groups
keep consuming capacity until finalized, because their outcome is still unknown.

Governance may timelock prospective limit increases; the guardian may lower limits
to stop issuance. A limit below existing exposure blocks increases, never forces
burns, changes payoffs, or blocks reductions/settlement. Cross-account issuance MUST
not bypass these aggregate counters. Lower per-account count limits are gas controls
and MUST NOT be advertised as an economic loss ceiling.

---

## 43. Conservation, arithmetic bounds, and version identity

The cumulative close quantity `C_i` in supply identities includes BOTH active closes
and expired-unfinalized cancellations. Each burns and reduces identical series
quantity. Every unit of exposure is released exactly once: by a pre-finalization
burn, or by the group release at finalization (section 42). Finalization and
short-only synchronization do not themselves burn external longs.

Factory validation MUST reject call `strikeWad + maxPayoutWad` overflow and invalid
signed observation timestamp arithmetic. Position validation MUST enforce exact
numerator product and complete account/group sum bounds for both shorts and hedges.
`protocolSeriesDomain` MUST include chain ID and the immutable core/factory version
identity. A risk group and its tokens cannot silently migrate to a new core.
A replacement registry can advertise new deployments but cannot redirect existing
series accounting or settlement authority.
