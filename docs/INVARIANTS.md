# Optara V2 Invariants Specification

**Document type:** Normative safety, accounting, and mathematical invariants  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document defines the properties that **must always remain true** for Optara V2.

It is intended to be used by:

- smart-contract engineers;
- security reviewers and auditors;
- invariant/fuzz-test authors;
- formal-verification engineers;
- frontend/indexer engineers who need accounting guarantees;
- AI coding agents implementing or reviewing the protocol.

The invariants in this document cover:

- option-series validity;
- capped call and put payoff correctness;
- exact portfolio margin;
- settlement-stablecoin isolation;
- hedge custody and non-double-use;
- account solvency;
- issuance and supply conservation;
- vault accounting;
- oracle correctness;
- expiry and settlement;
- rounding and decimal conversion;
- Kuru accounting separation;
- lifecycle and access-control safety.

This document must be read together with:

- `MATH.md` — authoritative mathematical formulas;
- `OPTION_SPEC.md` — authoritative option-series semantics;
- `PROTOCOL_SPEC.md` — authoritative runtime state transitions;
- `ARCHITECTURE.md` — component boundaries;
- `PRD.md` — product requirements.

If documents conflict:

1. `MATH.md` is authoritative for numerical formulas and rounding;
2. `OPTION_SPEC.md` is authoritative for immutable series economics;
3. `PROTOCOL_SPEC.md` is authoritative for transition ordering;
4. this document is authoritative for properties that must hold before and after valid protocol operations.

---

## 2. Core design assumptions

Optara V2 supports **European, capped, cash-settled options**.

Every option pair is:

```text
UNDERLYING / APPROVED_STABLECOIN
```

The stablecoin on the right-hand side of the pair is the series':

```text
quote asset
strike denomination
payout-cap denomination
canonical premium quote asset
writer cash-margin asset
cash-settlement asset
```

Examples:

```text
MON / USDT  -> USDT margin and settlement
ETH / USDC  -> USDC margin and settlement
BTC / USDe  -> USDe margin and settlement
```

Optara is **not USDC-based**.

Core V2 does not assume:

```text
1 USDT = 1 USDC = 1 USDe
```

and does not use one stablecoin to secure another stablecoin's obligations.

---

## 3. Notation

For series `i`:

| Symbol | Meaning |
|---|---|
| `S` | settlement price in the series settlement stablecoin per underlying unit |
| `K_i` | strike per underlying unit |
| `C_i` | maximum payout cap per underlying unit |
| `CS_i` | underlying exposure per whole option token |
| `Q_i` | option-token quantity |
| `phi_i(S)` | capped payoff per underlying unit |
| `q^-_{a,i}` | short quantity of account `a` in series `i` |
| `q^+_{a,i}` | locked-long quantity of account `a` in series `i` |
| `W_{a,g}` | exact worst-case loss for account `a`, risk group `g` |
| `M_{a,g}` | required margin for account `a`, group `g` |
| `B_{a,A}` | raw cash balance of account `a` in settlement asset `A` |
| `RM_{a,A}` | required margin of account `a` in settlement asset `A` |
| `Delta_{a,g}` | signed matured cash delta owed to account `a` by finalized group `g` |
| `VB_A` | physical vault balance of settlement asset `A` |

Core normalized scale:

```text
WAD = 1e18
```

All economic values must be interpreted in the unit system defined in `MATH.md`.

---

# Part I — Series and pair invariants

## INV-SERIES-01 — Pair settlement asset is explicit

Every series must identify exactly one approved settlement stablecoin `A`.

```text
series.settlementAsset = A
```

That same asset must be used for:

```text
strike denomination
cap denomination
margin accounting
settlement accounting
canonical option-token quote market
```

No implementation path may silently replace `A` with a protocol-wide default stablecoin.

### Required tests

- create MON/USDT and confirm all accounting is USDT;
- create ETH/USDC and confirm all accounting is USDC;
- verify a USDT balance cannot satisfy ETH/USDC margin.

---

## INV-SERIES-02 — Series economic terms are immutable

Once created, these fields must never change:

```text
underlying
settlementAsset
optionType
strike
maxPayout
contractSize
expiry
oracleConfigId
```

Changing any one of these fields creates a different financial contract and therefore requires a new series.

---

## INV-SERIES-03 — Canonical series identity

One unique immutable economic tuple must map to one canonical series identity.

Conceptually:

```text
seriesId = H(
    protocolSeriesDomain,
    underlying,
    settlementAsset,
    optionType,
    strike,
    maxPayout,
    contractSize,
    expiry,
    oracleConfigId
)
```

Two economically identical tuples must not create two independently mutable definitions inside the same deployment domain.

---

## INV-SERIES-04 — Valid numerical domain

For every valid series:

```text
K > 0
C > 0
CS > 0
expiry > creationTime
S >= 0 at settlement
```

For puts:

```text
0 < C <= K
```

Negative settlement prices are unsupported in core V2.

---

## INV-SERIES-05 — Risk-group identity is exact

A core V2 risk group is defined by:

```text
g = (
    underlying,
    expiry,
    settlementAsset,
    oracleConfigId
)
```

Two positions may be portfolio-netted only if all four fields match.

Therefore the following are forbidden margin offsets:

```text
MON/USDT vs ETH/USDT
MON/USDT December vs MON/USDT January
MON/USDT vs MON/USDC
same pair/expiry with incompatible oracle domain
```

---

# Part II — Option payoff invariants

## INV-PAYOFF-01 — Capped call formula

For a call:

```text
phi_call(S) = min(max(S - K, 0), C)
```

Total payoff:

```text
Payoff_call(S,Q)
    = phi_call(S) * CS * Q
```

subject to fixed-point normalization.

Piecewise:

```text
S <= K       -> 0
K < S < K+C  -> S-K
S >= K+C     -> C
```

---

## INV-PAYOFF-02 — Capped put formula

For a put:

```text
phi_put(S) = min(max(K - S, 0), C)
```

Total payoff:

```text
Payoff_put(S,Q)
    = phi_put(S) * CS * Q
```

For `C <= K`:

```text
0 <= S <= K-C  -> C
K-C < S < K     -> K-S
S >= K           -> 0
```

---

## INV-PAYOFF-03 — Payout bound

For every valid series, quantity, and non-negative settlement price:

```text
0 <= phi_i(S) <= C_i
```

and:

```text
0 <= Payoff_i(S,Q)
   <= C_i * CS_i * Q
```

Therefore:

```text
MaxContractualLiability_i(Q)
    = C_i * CS_i * Q
```

No underlying price movement may produce a payout above this bound.

---

## INV-PAYOFF-04 — Call monotonicity and saturation

For a call:

```text
S1 <= S2
=> phi_call(S1) <= phi_call(S2)
```

and:

```text
S >= K + C
=> phi_call(S) = C
```

Once capped, further upside cannot increase protocol liability.

---

## INV-PAYOFF-05 — Put monotonicity and saturation

For a put:

```text
S1 <= S2
=> phi_put(S1) >= phi_put(S2)
```

and:

```text
0 <= S <= K - C
=> phi_put(S) = C
```

Further downside below the cap boundary cannot increase protocol liability.

---

## INV-PAYOFF-06 — Boundary exactness

Call:

```text
phi_call(K)     = 0
phi_call(K + C) = C
```

Put:

```text
phi_put(K)     = 0
phi_put(K - C) = C
```

These boundaries must remain exact under the chosen fixed-point representation.

---

## INV-PAYOFF-07 — Spread-equivalence identity

For testing, the capped call must satisfy:

```text
min(max(S-K,0),C)
=
max(S-K,0) - max(S-(K+C),0)
```

For puts where `C <= K`:

```text
min(max(K-S,0),C)
=
max(K-S,0) - max((K-C)-S,0)
```

The protocol need not implement two legs, but the direct capped payoff must equal these identities.

---

## INV-PAYOFF-08 — Quantity and contract-size linearity

Before integer rounding boundaries:

```text
Payoff(S,Q) = phi(S) * CS * Q
```

Therefore payoff is linear in both `CS` and `Q`.

For positive scalar `x`:

```text
Payoff(S, xQ) = x * Payoff(S,Q)
```

subject only to explicitly defined native-token rounding.

---

# Part III — Premium invariants

## INV-PREMIUM-01 — Premium does not change contractual payoff

The market premium is not part of the immutable payoff function.

```text
Payoff(S,Q)
```

must be independent of:

```text
premiumPaid
premiumReceived
Kuru execution price
secondary-market price
```

---

## INV-PREMIUM-02 — External premium is not Optara collateral

A premium received on Kuru or another external venue contributes **zero** to Optara margin until the exact settlement stablecoin physically enters Optara and is credited to the margin account.

```text
externalPremiumReceivable
!=
OptaraCashBalance
```

The correct collateral equation is:

```text
AdditionalDepositNeeded
    = max(RequiredMargin - ExistingOptaraCashBalance, 0)
```

not:

```text
RequiredMargin - expectedPremium
```

---

# Part IV — Portfolio-risk invariants

## INV-RISK-01 — Short liability function

For account `a`, group `g`:

```text
ShortLiability_{a,g}(S)
    = Σ_i [phi_i(S) * CS_i * q^-_{a,i}]
```

where the sum includes only short series in the same risk group.

---

## INV-RISK-02 — Locked-long credit function

For account `a`, group `g`:

```text
LockedLongCredit_{a,g}(S)
    = Σ_j [phi_j(S) * CS_j * q^+_{a,j}]
```

Only compatible long tokens controlled by Optara may appear in this sum.

---

## INV-RISK-03 — Net liability and loss

Signed net liability:

```text
NetLiability_{a,g}(S)
    = ShortLiability_{a,g}(S)
      - LockedLongCredit_{a,g}(S)
```

Margin-relevant loss:

```text
Loss_{a,g}(S)
    = max(NetLiability_{a,g}(S), 0)
```

Negative net liability is a potential credit at settlement; it does not create negative required margin.

---

## INV-RISK-04 — Exact worst-case loss

For every account and active risk group:

```text
W_{a,g}
    = max_{S >= 0} Loss_{a,g}(S)
```

This is the core margin quantity.

Core V2 must not substitute:

```text
expected loss
VaR
historical simulation
FHS
SPAN approximation
spot-only loss
```

for `W_{a,g}`.

---

## INV-RISK-05 — Exact finite critical-point set

For each call:

```text
K
K + C
```

For each put:

```text
K - C
K
```

The candidate set is:

```text
Critical(g)
    = {0}
      union {K_i, K_i+C_i for calls}
      union {K_j-C_j, K_j for puts}
```

Then:

```text
W_{a,g}
    = max_{S in Critical(g)} Loss_{a,g}(S)
```

provided all group positions are included.

The RiskEngine must not use an arbitrary sampled grid that can miss the true maximum.

---

## INV-RISK-06 — Risk engine must never understate exact loss

Let:

```text
W_exact
```

be the real-number mathematical worst-case loss and:

```text
W_impl
```

be the native-token requirement produced by Solidity after precision handling.

The implementation must satisfy:

```text
W_impl >= ceilToNative(W_exact)
```

or an equivalent stronger conservative bound.

Numerical truncation must never reduce required margin below exact contractual worst-case loss.

---

## INV-RISK-07 — Adding a short cannot reduce required risk

With all other positions unchanged, adding non-negative short quantity cannot decrease pointwise liability.

Therefore:

```text
W_afterWrite >= W_beforeWrite
```

and, for a monotone buffer policy:

```text
M_afterWrite >= M_beforeWrite
```

A successful `write()` must never make the account appear safer merely because of a risk-engine bug.

---

## INV-RISK-08 — Closing a short cannot increase exact risk

For a valid same-series close:

```text
W_afterClose <= W_beforeClose
```

and required margin must not increase except for an explicitly documented unrelated state change in the same transaction.

---

## INV-RISK-09 — Locking an additional long cannot increase exact risk

For a compatible long hedge:

```text
W_afterLock <= W_beforeLock
```

If it does not reduce the worst-case loss:

```text
W_afterLock = W_beforeLock
```

No heuristic hedge credit is permitted.

---

## INV-RISK-10 — Unlocking/removing a long cannot reduce exact risk

For a locked compatible long removed from the group:

```text
W_afterUnlock >= W_beforeUnlock
```

The protocol must simulate this state before releasing the token.

---

# Part V — Margin and solvency invariants

## INV-MARGIN-01 — Group required margin

For group `g`:

```text
M_{a,g}
    = W_{a,g}
      + SafetyBuffer_g
      + RoundingGuard_g
```

where:

```text
SafetyBuffer_g >= 0
RoundingGuard_g >= 0
```

A safety buffer may be zero in the solvency-first MVP if arithmetic underestimation is otherwise impossible.

---

## INV-MARGIN-02 — Required margin by settlement asset

Let `G_a(A)` be account `a`'s active risk groups settled in stablecoin `A`.

```text
RM_{a,A}
    = Σ_{g in G_a(A)} M_{a,g}
```

Risk groups do not offset one another in core V2.

Cash in the same settlement stablecoin may secure the summed requirement.

---

## INV-MARGIN-03 — Post-action account safety

After every operation that can increase risk or reduce collateral:

```text
B_{a,A} >= RM_{a,A}
```

must hold for every affected settlement asset `A`.

This applies to at least:

```text
write
withdraw
unlockLong
risk-increasing migration/adapter operation
```

If the inequality would fail, the transaction must revert.

---

## INV-MARGIN-04 — Settlement-stablecoin isolation

For any two assets `A != B`:

```text
surplus(a,A)
```

must not satisfy:

```text
deficit(a,B)
```

Core V2 contains no ordinary margin formula using:

```text
FX(A/B)
haircut(A)
USD-equivalent(A)
```

to cross-collateralize stablecoins.

---

## INV-MARGIN-05 — Free collateral

After all matured groups relevant to asset `A` are synchronized:

```text
FreeCollateral_{a,A}
    = B_{a,A} - RM_{a,A}
```

For a valid account:

```text
FreeCollateral_{a,A} >= 0
```

Maximum ordinary withdrawal is:

```text
MaxWithdrawable_{a,A}
    = FreeCollateral_{a,A}
```

subject to native-unit granularity and emergency restrictions.

---

## INV-MARGIN-06 — Withdrawal bound

For requested withdrawal `X`:

```text
0 <= X <= FreeCollateral_{a,A}
```

must hold after required matured-group synchronization.

Equivalently:

```text
B'_{a,A} = B_{a,A} - X
B'_{a,A} >= RM_{a,A}
```

A withdrawal must never be checked against stale raw cash while finalized unsynchronized debt exists.

---

## INV-MARGIN-07 — Core V2 price-gap solvency theorem

For each active risk group `g` and any valid final settlement price `S_g`:

```text
Loss_{a,g}(S_g) <= W_{a,g} <= M_{a,g}
```

For all groups settled in stablecoin `A`:

```text
Σ_g Loss_{a,g}(S_g)
    <= Σ_g W_{a,g}
    <= Σ_g M_{a,g}
    = RM_{a,A}
    <= B_{a,A}
```

Therefore, for a valid core-V2 account:

```text
actual contractual net liability in A
<= account cash balance in A
```

for **any combination of underlying settlement prices** across the account's independently margined groups.

This is the mathematical reason core V2 does not require a liquidator to race a market price move to preserve ordinary option solvency.

---

## INV-MARGIN-08 — No hidden undercollateralized mode

Core V2 must never silently permit:

```text
B_{a,A} < RM_{a,A}
```

by changing one margin factor or accepting a lower maintenance threshold.

Any future mode where:

```text
posted margin < exact worst-case loss
```

is a different risk system and requires explicit liquidation, gap-risk, insurance, and bad-debt specifications.

---

# Part VI — Hedge custody invariants

## INV-HEDGE-01 — Only Optara-controlled longs receive margin credit

For a long quantity to appear in:

```text
q^+_{a,i}
```

Optara must control the corresponding option-token units.

Wallet-held, Kuru-held, or externally escrowed longs must contribute zero margin credit.

---

## INV-HEDGE-02 — Escrow quantity conservation

For each series `i`, after every completed transaction:

```text
OptionTokenBalanceOf(OptaraHedgeCustody, i)
    = Σ_accounts lockedLongQty[account][i]
```

unless the architecture explicitly uses multiple authorized custody contracts, in which case the left side is the sum across those contracts.

No synthetic locked-long accounting entry may exist without real token custody.

---

## INV-HEDGE-03 — No hedge double use

One option-token unit may perform at most one economic role at a time.

A unit counted as a locked hedge must not simultaneously be:

```text
transferred
sold on Kuru
used to close a short
redeemed externally
counted as a hedge for another account
```

---

## INV-HEDGE-04 — Unlock is check-before-release

For requested unlock `ΔQ`, the risk engine must evaluate:

```text
q^+' = q^+ - ΔQ
```

before token release.

The token may be released only if:

```text
B_{a,A} >= RM'_{a,A}
```

The protocol must never release first and validate later.

---

## INV-HEDGE-05 — Settled locked long is consumed exactly once

When a matured locked long is credited during `syncRiskGroup`:

```text
lockedLongQty -> 0 or reduced by synchronized quantity
option-token quantity -> burned/consumed
```

That same quantity must never remain externally redeemable.

---

# Part VII — Issuance and quantity-conservation invariants

## INV-SUPPLY-01 — Write creates equal long and short quantity

For every successful write of quantity `Q`:

```text
ΔLongSupply_i = +Q
ΔAggregateShortCreated_i = +Q
```

Cumulatively:

```text
CumulativeLongMinted_i
    = CumulativeShortCreated_i
```

---

## INV-SUPPLY-02 — Pre-expiry close consumes equal long and short quantity

For every valid pre-expiry close `Q`:

```text
ΔLongSupply_i = -Q
ΔOpenShortQty_i = -Q
```

The long must be the exact same `seriesId`.

Economically similar but different series cannot close each other.

---

## INV-SUPPLY-03 — Active pre-expiry equality

Before settlement redemption/expiry synchronization creates asynchronous state:

```text
CurrentLongSupply_i
    = AggregateOpenShortQty_i
```

Locked longs remain in long supply because locking changes custody, not claim quantity.

---

## INV-SUPPLY-04 — Post-settlement cumulative long identity

For series `i`, define:

```text
M_i = cumulative quantity minted by writes
C_i = cumulative quantity burned in pre-expiry closes
R_i = cumulative quantity burned by external redemption
H_i = cumulative locked-long quantity consumed during account settlement
L_i = current outstanding long supply
```

Then:

```text
M_i = C_i + R_i + H_i + L_i
```

This must hold at all times.

---

## INV-SUPPLY-05 — Post-settlement cumulative short identity

Define:

```text
S_i = cumulative short quantity synchronized/cleared after expiry
O_i = current unsynchronized/open short quantity
```

Then:

```text
M_i = C_i + S_i + O_i
```

At full completion:

```text
L_i = 0
O_i = 0
M_i - C_i = R_i + H_i = S_i
```

---

## INV-SUPPLY-06 — No post-expiry misuse of pre-expiry equality

After long redemption and writer synchronization begin at different times, the protocol and tests must **not** assume:

```text
CurrentLongSupply_i == CurrentUnsyncedShortQty_i
```

The correct post-expiry invariants are the cumulative identities above.

---

# Part VIII — Oracle invariants

## INV-ORACLE-01 — Settlement price unit matches the pair

For every group:

```text
S_g
```

must mean:

```text
settlement-stablecoin units per 1 underlying unit
```

Examples:

```text
MON/USDT -> USDT per MON
ETH/USDC -> USDC per ETH
```

`S`, `K`, and `C` must share the same denomination.

---

## INV-ORACLE-02 — No implicit stablecoin peg assumption

For MON/USDT, the protocol must not substitute a MON/USD feed and assume:

```text
USDT/USD = 1
```

If a derived route is used:

```text
MON/USDT = (MON/USD) / (USDT/USD)
```

and the route must be explicitly committed by `oracleConfigId`.

---

## INV-ORACLE-03 — Derived pair formula

For normalized feeds:

```text
S_underlying/stablecoin
    = P_underlying/USD / P_stablecoin/USD
```

When both inputs are WAD-scaled:

```text
S_wad
    = roundConfigured(
        P_underlying_usd_wad * WAD
        / P_stablecoin_usd_wad
      )
```

with:

```text
P_stablecoin_usd_wad > 0
```

All feed IDs, staleness limits, decimal normalization, and rounding rules must be precommitted.

---

## INV-ORACLE-04 — One finalized price per risk group

A risk group may have at most one final settlement price:

```text
S_g^*
```

After finalization:

```text
S_g^*(t) = constant
```

All series in the group must use the same `S_g^*`.

---

## INV-ORACLE-05 — Invalid oracle data cannot finalize settlement

Settlement finalization must fail if the precommitted oracle rules report invalid, stale, non-final, zero-denominator, or otherwise unacceptable data.

Governance must not replace a failed price with an arbitrary outcome-dependent value.

---

# Part IX — Lifecycle invariants

## INV-LIFE-01 — State progression is monotonic

A series/risk group progresses only forward:

```text
ACTIVE
  -> EXPIRED_UNSETTLED
  -> SETTLED
```

It must never transition backward.

---

## INV-LIFE-02 — No writing after expiry

If:

```text
block.timestamp >= expiry
```

then new short issuance for that series must be impossible.

---

## INV-LIFE-03 — No redemption before valid finalization

A long option may be transferred after expiry if allowed, but cannot be redeemed until its risk group has a valid immutable finalized settlement price.

---

## INV-LIFE-04 — Settled payoff is immutable

Once group price `S_g^*` is finalized and series payoff is derived:

```text
phi_i^* = phi_i(S_g^*)
```

that payoff must never change.

---

# Part X — Matured-account settlement invariants

## INV-SETTLE-01 — Atomic risk-group settlement

For account `a`, finalized group `g`:

```text
Short^*_{a,g}
    = Σ_i Payoff_i(S_g^*, q^-_{a,i})
```

```text
LockedLong^*_{a,g}
    = Σ_j Payoff_j(S_g^*, q^+_{a,j})
```

Define:

```text
Delta_{a,g}
    = LockedLong^*_{a,g} - Short^*_{a,g}
```

The cash effect must be applied atomically:

```text
B'_{a,A} = B_{a,A} + Delta_{a,g}
```

subject to native-unit rounding rules.

The protocol must not debit short legs first and credit margin-recognized longs later.

---

## INV-SETTLE-02 — Finalized group cannot make a previously valid core account negative

Ignoring unexpected token/oracle failure and applying the specified conservative rounding guard, a correctly margined core-V2 account must satisfy:

```text
B'_{a,A} >= 0
```

after atomic settlement of finalized groups.

A negative result indicates an invariant violation or unsupported external-asset behavior and must enter emergency handling rather than silently socializing loss.

---

## INV-SETTLE-03 — Effective balance includes unsynchronized matured deltas

For asset `A`:

```text
EffectiveBalance_{a,A}
    = RawCashBalance_{a,A}
      + Σ finalized-unsynced groups g in A Delta_{a,g}
```

Any operation that depends on available cash must use an equivalent economically synchronized state.

A withdrawal may not rely on raw cash alone.

---

## INV-SETTLE-04 — Synchronization preserves economic balance

Immediately before and after a correct `syncRiskGroup`:

```text
EffectiveBalance_before
    = RawCashBalance_after
```

subject only to the protocol's deterministic rounding rule.

Synchronization changes representation from pending economic effect to realized ledger state; it must not create a second economic gain or loss.

---

## INV-SETTLE-05 — Settlement-value conservation before rounding

For each finalized series `i`, after excluding quantity closed pre-expiry:

```text
TotalShortLiability_i
    = TotalLongClaim_i
```

Across group `g`:

```text
Σ_accounts ShortLiability_{a,g}
    = Σ_accounts LockedLongCredit_{a,g}
      + ExternalLongClaims_g
```

Therefore:

```text
Σ_accounts (
    ShortLiability_{a,g}
    - LockedLongCredit_{a,g}
)
= ExternalLongClaims_g
```

before native-token rounding.

---

## INV-SETTLE-06 — Conservative settlement-value conservation after rounding

After applying required rounding:

```text
AggregateWriterDebits
    >= AggregateInternalLockedLongCredits
       + AggregateExternalLongPayouts
```

The non-negative difference may only be attributable to:

```text
RoundingReserve
+ explicitly configured protocol fees
```

It must not become an uncovered claim.

---

# Part XI — Redemption invariants

## INV-REDEEM-01 — Redemption uses finalized series payoff

For settled series `i`, redeem quantity `Q`:

```text
RedeemEconomicValue
    = phi_i^* * CS_i * Q
```

External transfer:

```text
RedeemNative
    = toNativeDown(RedeemEconomicValue)
```

---

## INV-REDEEM-02 — Redemption burns the claim

For each successful redemption:

```text
ΔLongSupply_i = -Q
```

A redeemed quantity must never remain available for another redemption.

---

## INV-REDEEM-03 — Same quantity cannot be both locked-credit and external redemption

For any option-token unit:

```text
consumedAsLockedLongCredit
+
consumedAsExternalRedemption
<= 1 economic use
```

No quantity may be credited internally and later paid externally.

---

## INV-REDEEM-04 — Holder identity does not change payout

For the same series and quantity, any valid holder receives the same contractual payout.

Settlement must not depend on:

```text
original buyer
purchase price
Kuru trade history
writer identity
wallet holding period
```

---

# Part XII — Rounding and decimal invariants

## INV-ROUND-01 — WAD/native conversion bounds

For normalized economic value `xWad` and settlement token decimals `d`:

```text
toNativeDown(xWad,d)
    <= exactNativeValue
    <= toNativeUp(xWad,d)
```

and, where conversion is non-exact:

```text
toNativeUp - toNativeDown <= 1 native base unit
```

---

## INV-ROUND-02 — Mandatory rounding directions

To protect solvency:

```text
external long payout          -> DOWN
positive internal long credit -> DOWN
required margin               -> UP
writer/net matured debit      -> UP
```

No opposite rounding direction may be introduced in a way that creates an uncovered obligation.

---

## INV-ROUND-03 — Risk rounding must be conservative

The fixed-point RiskEngine must never return less than the exact real-number contractual worst-case loss after native conversion.

If intermediate truncation can understate loss, the implementation must add a provable `RoundingGuard`.

---

## INV-ROUND-04 — Matured group nets before native conversion

For a finalized account group:

```text
DeltaWad = LockedLongWad - ShortWad
```

Then:

```text
DeltaWad > 0 -> credit = toNativeDown(DeltaWad)
DeltaWad < 0 -> debit  = toNativeUp(-DeltaWad)
```

The implementation should not convert each leg independently before netting if that changes the specified economic result.

---

## INV-ROUND-05 — Rounding reserve is non-negative protocol dust

For settlement asset `A`:

```text
RoundingReserve_A >= 0
```

Rounding dust is not user free collateral and must not be assigned to an arbitrary account while outstanding claims remain.

---

# Part XIII — Vault and asset-conservation invariants

## INV-VAULT-01 — Physical custody is per settlement asset

For each approved stablecoin `A`:

```text
VB_A = actual ERC20 balance held by authorized Optara settlement custody
```

No balance of another stablecoin is included in `VB_A`.

---

## INV-VAULT-02 — Deposits credit only actual received asset

A deposit of asset `A` may increase:

```text
B_{a,A}
```

only after Optara has actually received the supported token amount.

For the MVP, fee-on-transfer/rebasing settlement tokens should be rejected so:

```text
ledgerCredit = actualReceived = requestedTransfer
```

for approved assets.

---

## INV-VAULT-03 — Withdrawals debit before/with exact transfer

A successful withdrawal of asset `A`, amount `X`, must satisfy:

```text
ΔB_{a,A} = -X
ΔVB_A    = -X
```

subject to safe ERC-20 transfer semantics.

A transfer must not occur without the corresponding ledger debit and safety check.

---

## INV-VAULT-04 — Global pooled-custody identity

For settlement asset `A`, define:

```text
EffectiveCashClaims_A
    = Σ_accounts EffectiveBalance_{a,A}
```

and:

```text
OutstandingExternalSettledClaims_A
```

as settled stablecoin value still owed to externally redeemable long tokens.

Then, ignoring separately owned protocol fees:

```text
VB_A
    = EffectiveCashClaims_A
      + OutstandingExternalSettledClaims_A
      + RoundingReserve_A
      + ProtocolOwnedVaultBalance_A
```

For the fee-free MVP:

```text
ProtocolOwnedVaultBalance_A = 0
```

This identity is primarily for invariant/fuzz testing and off-chain accounting; production contracts need not globally iterate all users.

---

## INV-VAULT-05 — External redemption preserves pooled identity

If an external settled claim of `R` native units is redeemed:

```text
VB_A' = VB_A - R
```

and:

```text
OutstandingExternalSettledClaims_A'
    = OutstandingExternalSettledClaims_A - R
```

The pooled identity must remain unchanged.

---

## INV-VAULT-06 — No cross-stablecoin reserve substitution

For `A != B`:

```text
VB_A
```

must not be counted toward claims denominated in `B`.

Core V2 has no ordinary settlement formula using the market value of another stablecoin as reserve coverage.

---

# Part XIV — Kuru/composability invariants

## INV-KURU-01 — Kuru and Optara accounting domains are separate

At all times:

```text
KuruBalance(user,A)
!=
OptaraCashBalance(user,A)
```

unless an explicit asset transfer has completed and Optara has credited it.

Likewise:

```text
KuruOptionBalance
!=
OptaraLockedLongQty
```

---

## INV-KURU-02 — Trading a long does not transfer the writer's short

If an option token moves:

```text
Bob -> Dave
```

on Kuru or another venue:

```text
shortQty[writer][seriesId]
```

must remain unchanged.

The long claim is transferable; the short liability remains with the margined writer account.

---

## INV-KURU-03 — Kuru trade execution does not close an Optara short

A writer's short quantity decreases only when Optara itself receives/controls and consumes the exact same-series long token through a valid close path.

A Kuru purchase alone is insufficient.

---

## INV-KURU-04 — Optara solvency is independent of Kuru availability

If Kuru is:

```text
illiquid
paused
unavailable
not listing a series
```

Optara must still be able to:

```text
finalize valid settlement
synchronize writers
redeem valid longs
preserve margin accounting
```

Kuru is a trading dependency, not a settlement-solvency dependency.

---

# Part XV — Access-control and admin invariants

## INV-ADMIN-01 — Admin cannot rewrite existing option economics

No privileged role may change an existing series':

```text
strike
cap
expiry
option type
contract size
settlement stablecoin
underlying
oracle settlement domain
```

---

## INV-ADMIN-02 — Admin cannot rewrite finalized settlement

Once:

```text
S_g^*
```

is finalized, governance, pauser, keeper, or upgrade operator must not replace it through an ordinary privileged function.

---

## INV-ADMIN-03 — Rescue functions cannot sweep accounted user collateral

Any emergency token rescue mechanism must exclude amounts required for:

```text
EffectiveCashClaims
OutstandingExternalSettledClaims
RoundingReserve
other explicitly accounted obligations
```

for that exact settlement asset.

---

## INV-ADMIN-04 — Pause cannot create economic asymmetry

A pause mode must not selectively allow actions that increase protocol liability while blocking the corresponding risk-reducing or settlement actions without an incident-specific safety reason.

Recommended generally allowed operations during a normal risk pause:

```text
deposit collateral
lock valid hedge
close short
finalize trusted settlement
sync matured group
redeem settled long
```

---

# Part XVI — Bounded-execution invariants

## INV-GAS-01 — No protocol-wide settlement loop

No ordinary state transition may require iteration over:

```text
all protocol writers
all long holders
all accounts
```

Series finalization must remain bounded regardless of user count.

---

## INV-GAS-02 — Per-account risk evaluation is bounded

The deployment must enforce limits such that complete evaluation of one account/risk group is always executable.

At minimum, define bounded values for:

```text
MAX_ACTIVE_SERIES_PER_ACCOUNT
MAX_ACTIVE_GROUPS_PER_ACCOUNT
MAX_SERIES_PER_GROUP_PER_ACCOUNT
```

---

## INV-GAS-03 — Complete-group settlement remains executable

Because matured risk groups must settle atomically per account, the maximum allowed positions in one risk group must be chosen so `syncRiskGroup(account, groupId)` cannot exceed practical gas limits.

A configuration that allows creation of an account state that can no longer be synchronized is invalid.

---

# Part XVII — Security-transition invariants

## INV-STATE-01 — Checks before risk-increasing effects

For operations such as `write`, the protocol must validate the simulated post-operation account before leaving the account in the new risky state.

The final committed state must satisfy all margin invariants.

---

## INV-STATE-02 — Checks before collateral release

For `withdraw` and `unlockLong`, solvency must be proven **before** assets leave Optara control.

---

## INV-STATE-03 — External calls cannot observe/use an unsafe intermediate state

Token transfers, callbacks, and other external calls must not permit reentrancy into a transient state where:

```text
short liability exists without required margin
locked hedge credit exists after hedge release
redeemed claim remains unburned
withdrawn collateral remains credited
```

---

## INV-STATE-04 — No zero-cost claim creation

There must be no state transition that increases long-token supply without an equal recorded short obligation and successful margin check.

---

# Part XVIII — Formal core-solvency derivation

## 1. Single group

By definition:

```text
W_{a,g}
    = max_{S>=0} Loss_{a,g}(S)
```

Therefore for any actual settlement price `S_g^*`:

```text
Loss_{a,g}(S_g^*) <= W_{a,g}
```

Required group margin is:

```text
M_{a,g}
    = W_{a,g} + nonNegativeBuffers
```

so:

```text
Loss_{a,g}(S_g^*) <= M_{a,g}
```

---

## 2. Multiple groups in one settlement stablecoin

For all groups using asset `A`:

```text
ActualLoss_A
    = Σ_g Loss_{a,g}(S_g^*)
```

and:

```text
ActualLoss_A
    <= Σ_g W_{a,g}
    <= Σ_g M_{a,g}
    = RM_{a,A}
```

Since account safety requires:

```text
B_{a,A} >= RM_{a,A}
```

then:

```text
B_{a,A} >= ActualLoss_A
```

for any valid combination of group settlement prices.

---

## 3. Why this is stronger than liquidation-based solvency

The inequality above does not depend on:

```text
current spot price
liquidator reaction time
market liquidity
oracle update frequency before expiry
volatility forecasts
```

It depends only on:

```text
correct bounded option terms
exact risk-group membership
correct locked-long custody
exact worst-case payoff math
same-asset collateral remaining in Optara
correct settlement oracle at expiry
```

This is the central solvency property of core Optara V2.

---

# Part XIX — Required invariant/fuzz test suite

The implementation should encode the invariants above as executable Foundry invariants and property tests.

## A. Payoff properties

For random valid `S, K, C, CS, Q`:

```text
0 <= payoff <= C*CS*Q
```

Test:

- call monotonicity;
- put monotonicity;
- exact strike boundaries;
- exact cap boundaries;
- extreme prices;
- `S = 0`;
- fractional contract sizes;
- fractional quantities;
- spread-equivalence identities.

---

## B. Risk-engine properties

For random bounded portfolios:

```text
RiskEngineWorstCase
>=
Loss(S)
```

for every sampled `S`.

Additionally compare the on-chain algorithm to an independent high-precision reference evaluator over the complete critical-point set.

Test:

```text
write -> W does not decrease
close short -> W does not increase
lock long -> W does not increase
unlock long -> W does not decrease
```

---

## C. Stablecoin isolation properties

Fuzz deposits and positions across USDT/USDC/USDe-style mock assets.

Verify:

```text
balance[A] changes only from flows involving A
margin[A] is not satisfied by balance[B]
vault[A] is not spent for B claims
```

for `A != B`.

---

## D. Hedge custody properties

Verify:

```text
sum lockedLongQty == Optara escrow token balance
```

per series after every completed operation.

Attempt to:

- transfer locked long;
- redeem locked long;
- use it to close while still counted as hedge;
- count one token in two accounts.

All invalid paths must fail.

---

## E. Supply conservation properties

Before expiry:

```text
longSupply == aggregateOpenShortQty
```

After expiry, test the cumulative identities:

```text
M = C + R + H + L
M = C + S + O
```

under arbitrary interleavings of:

```text
external redemption
writer synchronization
locked-long settlement
```

---

## F. Withdrawal properties

After arbitrary valid writes, closes, hedge locks, hedge unlocks, and settlements:

```text
withdraw <= freeCollateral
```

must succeed subject to balances, while:

```text
withdraw > freeCollateral
```

must revert.

Include finalized-but-unsynchronized groups to prove stale raw cash cannot be withdrawn.

---

## G. Settlement properties

For every finalized risk group:

- one immutable price;
- same price used for all group series;
- atomic short/locked-long netting;
- no negative account cash for a correctly margined core portfolio;
- locked longs consumed once;
- external longs redeemed once;
- writer debit conservatively covers payouts after rounding.

---

## H. Vault properties

Track a shadow accounting model for each settlement asset and prove:

```text
VB_A
=
EffectiveCashClaims_A
+ OutstandingExternalSettledClaims_A
+ RoundingReserve_A
+ ProtocolOwnedVaultBalance_A
```

for every supported asset independently.

---

## I. Oracle properties

Test:

- direct pair normalization;
- derived pair conversion;
- stablecoin depeg values not equal to 1;
- decimal combinations;
- zero denominator rejection;
- stale data rejection;
- finalization only once;
- same finalized price for every series in a group.

---

## J. Reentrancy/state-ordering properties

Using hostile mock ERC-20s/adapters where applicable, verify no callback can observe or exploit a state where:

```text
withdrawn funds are still credited
burned claims remain redeemable
unlocked hedges remain margin-counted
new shorts exist without margin
```

Unsupported callback-heavy or fee-on-transfer stablecoins should be rejected for the MVP.

---

# Part XX — Minimum invariant checklist before deployment

A deployment is not ready if any of these cannot be proven or tested:

```text
[ ] Every payout is capped.
[ ] Call/put boundary math is exact.
[ ] Required margin >= exact worst-case group loss.
[ ] Every post-risk action preserves cash >= required margin.
[ ] No stablecoin cross-collateralization exists in core V2.
[ ] Every margin-recognized long is physically locked by Optara.
[ ] No long token can be double-used.
[ ] Write quantity equals newly created short quantity.
[ ] Pre-expiry close burns matching long and short quantity.
[ ] Post-expiry cumulative quantity identities reconcile.
[ ] One immutable settlement price exists per risk group.
[ ] Derived oracle pricing respects the actual settlement stablecoin.
[ ] Matured risk groups settle atomically per account.
[ ] Withdrawals account for all finalized unsynchronized liabilities.
[ ] External redemption burns the claim.
[ ] Locked-long settlement consumes the locked claim.
[ ] Writer debits never underfund holder payouts because of rounding.
[ ] Vault accounting reconciles independently per stablecoin.
[ ] Kuru balances never count as Optara margin until transferred in.
[ ] Kuru outage cannot prevent Optara settlement.
[ ] No admin can rewrite live series economics or finalized settlement.
[ ] No protocol-wide settlement loop exists.
[ ] Every allowed account state remains synchronizable within gas bounds.
```

---

# Part XXI — Canonical invariant summary

The most important Optara V2 invariants can be reduced to the following equations.

### 1. Bounded option payout

```text
0 <= Payoff_i(S,Q)
   <= C_i * CS_i * Q
```

### 2. Exact group loss

```text
W_{a,g}
=
max_{S>=0}
max(
    ShortLiability_{a,g}(S)
    - LockedLongCredit_{a,g}(S),
    0
)
```

### 3. Required margin

```text
RM_{a,A}
=
Σ_{g settled in A}
(
    W_{a,g}
    + SafetyBuffer_g
    + RoundingGuard_g
)
```

### 4. Account safety

```text
B_{a,A} >= RM_{a,A}
```

for every affected settlement stablecoin.

### 5. No cross-stablecoin substitution

```text
A != B
=>
balance[A] cannot secure liability[B]
```

### 6. Hedge custody

```text
lockedLongQty
<= actual Optara-controlled long-token quantity
```

with equality to assigned escrow balances after completed transitions.

### 7. Atomic matured settlement

```text
Delta_{a,g}
=
LockedLong^*_{a,g}
-
Short^*_{a,g}
```

applied as one group operation.

### 8. Write conservation

```text
CumulativeLongMinted_i
=
CumulativeShortCreated_i
```

### 9. Post-expiry long conservation

```text
M_i = C_i + R_i + H_i + L_i
```

### 10. Post-expiry short conservation

```text
M_i = C_i + S_i + O_i
```

### 11. Settlement-value conservation

Before rounding:

```text
Σ ShortLiability
=
Σ LockedLongCredit
+
ExternalLongClaims
```

After conservative rounding:

```text
WriterDebits
>=
InternalLongCredits
+
ExternalLongPayouts
```

### 12. Per-asset pooled-vault accounting

```text
VB_A
=
EffectiveCashClaims_A
+
OutstandingExternalSettledClaims_A
+
RoundingReserve_A
+
ProtocolOwnedVaultBalance_A
```

### 13. Core solvency theorem

For any final prices:

```text
ActualLoss_A
<=
RM_{a,A}
<=
B_{a,A}
```

for every valid account and settlement stablecoin `A`.

---

## 22. Engineering rule

If an optimization, integration, or convenience feature makes any invariant in this document difficult to preserve, the feature must be changed or removed.

For core Optara V2, the priority order is:

```text
1. exact contractual correctness
2. per-stablecoin solvency
3. no double-counting of collateral or hedges
4. deterministic settlement
5. accounting conservation
6. composability
7. gas efficiency
8. convenience
```

The first five properties are not negotiable.
