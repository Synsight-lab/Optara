# Optara V2 — Fee Specification

**Document type:** Normative protocol fee and external-cost specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; exact production fee parameters are deployment configuration

---

## 1. Purpose

This document defines how fees interact with Optara V2.

It answers:

- which actions may charge Optara protocol fees;
- which actions must remain fee-free in core V2;
- how fees are denominated;
- how fees interact with margin and free collateral;
- how fees are accounted for in the vault;
- how Kuru fees differ from Optara fees;
- how oracle-provider fees are handled;
- how the SDK exposes fee previews without becoming authoritative;
- which fee models are forbidden because they would weaken settlement or solvency.

The core principle is:

> **Fees are separate from option liability, margin, and settlement claims.**

A fee must never be used to disguise undercollateralization.

This document must be read with:

- `PROTOCOL_SPEC.md`
- `MATH.md`
- `INVARIANTS.md`
- `MARGIN_AND_RISK.md`
- `ORACLE_AND_SETTLEMENT.md`
- `KURU_INTEGRATION.md`
- `SECURITY.md`
- `ACCESS_CONTROL.md`
- `ARCHITECTURE.md`

---

# 2. Canonical MVP fee policy

The safest core-V2 MVP is:

```text
Optara issuance fee      = 0
Optara close fee         = 0
Optara lock fee          = 0
Optara unlock fee        = 0
Optara deposit fee       = 0
Optara withdrawal fee    = 0
Optara settlement fee    = 0
Optara redemption fee    = 0
Optara synchronization fee = 0
```

Therefore, for the initial fee-free configuration:

```text
ProtocolOwnedBalance(asset) = 0
```

except for separately classified rounding reserve or accidentally received non-accounted tokens.

Kuru trading fees remain external.

Oracle provider update fees remain external/provider-specific.

The protocol MAY later enable the issuance-fee mechanism defined in this document without changing the option payoff model.

---

# 3. Why the MVP should begin fee-free

A fee-free launch reduces:

```text
accounting complexity
rounding complexity
vault reconciliation complexity
UX ambiguity
audit surface
economic edge cases
```

while the protocol is still proving:

```text
margin correctness
settlement correctness
Kuru integration
oracle finalization
portfolio netting
```

This is especially appropriate for the V2 solvency-first MVP.

---

# 4. Fee categories

Optara distinguishes four categories:

```text
A. OPTARA PROTOCOL FEES
B. KURU / EXTERNAL VENUE FEES
C. ORACLE PROVIDER FEES
D. NETWORK GAS
```

They must not be conflated.

---

# Part I — Optara protocol fees

## 5. Protocol-fee principle

Any Optara fee MUST:

```text
be explicit
be deterministic from on-chain configuration and transaction inputs
be denominated in a known asset
be separately accounted
not alter contractual option payoff
not reduce required margin
not become hidden collateral
not create cross-stablecoin accounting
```

---

## 6. Preferred future protocol fee: issuance fee

If Optara enables protocol monetization, the preferred core fee is:

```text
ISSUANCE FEE
```

charged when new long/short quantity is created.

This fee is preferred because:

```text
claim creation is an Optara-native action
fee can be computed before state change
fee does not depend on external market price
fee does not affect holder settlement
fee does not discourage short closing
fee does not require Kuru integration
```

---

## 7. Why not charge on premium

Premium is discovered externally.

Example:

```text
writer mints option
writer later sells on Kuru
```

Optara may never observe the final economic premium.

Therefore core V2 MUST NOT require:

```text
protocol fee = percentage of Kuru premium
```

for correctness.

Doing so would create:

```text
venue dependency
trade-price dependency
off-chain accounting dependency
easy fee evasion through transfers/other venues
```

---

## 8. Why not charge on final payout

The long holder's contractual payoff is:

```text
Payoff(S,Q)
```

A settlement/redemption fee deducted from that amount would make:

```text
actual holder payout
<
contractual payoff
```

unless the fee had been embedded into the immutable series contract from creation.

Core V2 intentionally does not do this.

Therefore:

```text
redemption fee = 0
settlement payout fee = 0
```

for the canonical V2 design.

---

## 9. Why not charge on short close

Closing a short reduces risk.

A close fee can discourage:

```text
risk reduction
position cleanup
margin release
```

and complicate buy-to-close workflows.

Therefore core V2 SHOULD keep:

```text
closeShort fee = 0
```

---

## 10. Why not charge hedge lock/unlock fee

Locking a compatible hedge can reduce protocol risk.

Unlock already requires a complete post-state safety check.

Charging these state transitions is unnecessary for core economics.

Canonical:

```text
lockLong fee   = 0
unlockLong fee = 0
```

---

## 11. Why not charge deposit fee

Deposit increases same-asset collateral.

A deposit fee reduces the amount credited and can confuse solvency calculations.

Canonical:

```text
deposit fee = 0
```

The user receives cash credit for the exact supported settlement-token amount actually received.

---

## 12. Why not charge ordinary withdrawal fee

Withdrawal already cannot exceed free collateral.

A protocol withdrawal fee creates extra:

```text
rounding
accounting
UI
```

complexity with little core benefit.

Canonical:

```text
withdrawal fee = 0
```

Network gas remains external.

---

# Part II — Future issuance-fee mechanism

## 13. Fee basis

If enabled, issuance fee SHOULD be based on the **new gross maximum contractual payout created**, not:

```text
current spot
current intrinsic value
Kuru premium
portfolio margin after hedges
```

For newly written series quantity `Q`:

```text
GrossMaxPayout
=
C * CS * Q
```

where:

```text
C  = cap per underlying unit
CS = contract size
Q  = newly created option quantity
```

---

## 14. Why gross max payout is the preferred fee base

It is:

```text
deterministic
bounded
known at write time
independent of market price
independent of Kuru
independent of volatility model
harder to game through portfolio hedging
proportional to claim size created
```

If the fee were based on net portfolio margin, a writer could potentially alter fee level through temporary hedge structure even though the same new claim supply is created.

---

## 15. Issuance fee formula

Let:

```text
F_bps
=
configured issuance fee in basis points
```

with:

```text
0 <= F_bps <= MAX_ISSUANCE_FEE_BPS
```

Then in normalized precision:

```text
GrossMaxPayoutWad
=
C * CS * Q
```

with the WAD scaling defined in `MATH.md`.

Fee:

```text
IssuanceFeeWad
=
ceil(
    GrossMaxPayoutWad
    * F_bps
    / 10_000
)
```

Then convert to the series settlement stablecoin native units conservatively upward:

```text
IssuanceFeeNative
=
toNativeUp(IssuanceFeeWad)
```

---

## 16. Fee denomination

The issuance fee MUST be denominated in:

```text
series.settlementAsset
```

Examples:

```text
MON/USDT option -> fee in USDT
ETH/USDC option -> fee in USDC
BTC/USDe option -> fee in USDe
```

No global USDC fee asset exists.

---

## 17. No cross-stablecoin fee payment

A `MON/USDT` write cannot satisfy its fee using:

```text
USDC
USDe
another stablecoin
```

unless a future external router swaps it first and the exact USDT is received.

---

## 18. Fee and margin are separate

The fee is not part of:

```text
WorstCaseLoss
RequiredMargin
SafetyBuffer
RoundingGuard
```

and it MUST NOT reduce any of them.

Correct:

```text
RequiredMarginPostWrite = 5 USDT
IssuanceFee             = 0.05 USDT

writer needs enough cash for:
post-fee cash >= 5 USDT
```

Incorrect:

```text
RequiredMargin = 5 - 0.05
```

---

## 19. Post-fee safety equation

If the fee is paid from the writer's Optara cash balance:

```text
CashBefore
=
writer cash before write
```

Then require:

```text
CashAfterFee
=
CashBefore - IssuanceFee
```

and:

```text
CashAfterFee
>=
RequiredMarginPostWrite
```

Therefore the effective required available amount is:

```text
RequiredMarginPostWrite
+
IssuanceFee
```

subject to existing free cash.

---

## 20. Fee cannot consume encumbered collateral

A write MUST NOT succeed if:

```text
CashBefore >= RequiredMarginPostWrite
```

but:

```text
CashBefore - IssuanceFee
<
RequiredMarginPostWrite
```

Fees can only come from cash that remains free after the new risk is funded.

---

## 21. Existing cash example

Alice has:

```text
CashBefore = 6 USDT
```

New write:

```text
RequiredMarginPostWrite = 5 USDT
IssuanceFee = 0.10 USDT
```

After fee:

```text
CashAfterFee = 5.90
```

Check:

```text
5.90 >= 5
```

Write may succeed.

Free collateral after write:

```text
0.90 USDT
```

---

## 22. Insufficient fee example

Alice has:

```text
CashBefore = 5 USDT
RequiredMarginPostWrite = 5 USDT
IssuanceFee = 0.10 USDT
```

If the fee is deducted:

```text
CashAfterFee = 4.90
```

Then:

```text
4.90 < 5
```

Write MUST revert unless Alice supplies additional USDT.

---

## 23. Fee ordering

Safe conceptual order:

```text
1. simulate post-write short portfolio
2. calculate RequiredMarginPostWrite
3. calculate current issuance fee
4. calculate CashAfterFee
5. require CashAfterFee >= RequiredMarginPostWrite
6. debit fee from user cash
7. credit protocol-owned fee accounting
8. record short
9. mint long
```

Implementation may reorder internal effects for atomicity/reentrancy safety, but the final committed state must satisfy this logic.

---

## 24. Fee slippage protection

Because fee configuration may change between SDK preview and transaction inclusion, `write()` SHOULD support a user-protection parameter such as:

```text
maxFeeNative
```

Then require:

```text
computedFee <= maxFeeNative
```

If governance increases the fee above the user's accepted amount before execution:

```text
transaction reverts
```

---

## 25. SDK fee preview

`@optara/sdk` MAY expose:

```text
previewWriteFee(seriesId, quantity)

previewWrite(...)
```

returning:

```text
settlementAsset
grossMaxPayout
issuanceFee
postWriteMargin
additionalCashNeeded
```

All values are advisory until execution.

---

## 26. `@optara/math` fee helpers

If the fee mechanism is enabled, `@optara/math` MAY expose:

```text
grossMaxPayout(...)
issuanceFee(...)
```

for reference/testing.

The contract recomputes the authoritative fee.

---

# Part III — Protocol fee accounting

## 27. Separate protocol-owned balance

If protocol fees are enabled, maintain fee ownership separately from user cash.

Conceptually:

```text
protocolOwnedBalance[settlementAsset]
```

This is not:

```text
user cash
required margin
rounding reserve
outstanding long claim
```

---

## 28. Fee transfer inside the vault

If fee is debited from internal user cash:

```text
userCash -= fee
protocolOwnedBalance += fee
```

The physical vault balance does not change at fee assessment time.

Ownership classification changes.

---

## 29. Global vault identity with fees

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
```

This identity must hold independently per settlement asset.

---

## 30. Fee withdrawal by protocol treasury

If fees are enabled, protocol-owned fees may be transferred out only up to:

```text
ProtocolOwnedBalance(A)
```

A fee collection action must:

```text
decrease ProtocolOwnedBalance(A)
decrease physical VaultBalance(A)
by the same native amount
```

It must not touch user claims.

---

## 31. Safest MVP behavior

Because canonical MVP fees are zero:

```text
ProtocolOwnedBalance(A) = 0
```

and no treasury fee-withdrawal path is required for the initial deployment.

If issuance fees are activated, access-control and deployment configuration must explicitly enable the fee-collection path.

---

# Part IV — Fee parameter governance

## 32. Prospective fee changes only

Governance MAY change the issuance fee for future writes.

It MUST NOT:

```text
retroactively charge existing longs
retroactively debit existing shorts
reduce finalized payouts
```

---

## 33. Fee is not a series economic term

The issuance fee does not alter:

```text
strike
cap
contract size
expiry
settlement asset
oracleConfigId
payoff
```

Therefore it does not need to be part of `seriesId`.

---

## 34. User transaction protection

Because current fee may be changed prospectively:

```text
maxFeeNative
```

or an equivalent bounded user parameter SHOULD protect writes from unexpected fee changes.

---

## 35. Maximum governance fee bound

If fees are enabled, the contracts SHOULD enforce:

```text
MAX_ISSUANCE_FEE_BPS
```

as an immutable or high-security bounded parameter.

Governance should not have unlimited ability to set:

```text
10,000 bps
```

unless that behavior is explicitly desired and audited.

The exact maximum is a deployment decision.

---

# Part V — Kuru fees

## 36. Kuru fees are external

When users trade option tokens on Kuru:

```text
Kuru trading fee
```

belongs to Kuru's market/trading system.

It is not an Optara protocol fee.

---

## 37. Kuru fee does not alter option payoff

If Bob buys an option and pays:

```text
premium + Kuru fee
```

Optara still settles:

```text
Payoff(S,Q)
```

The trading fee affects Bob's economic PnL, not the contract payout.

---

## 38. Kuru fee does not alter writer margin

Writer margin remains:

```text
exact worst-case contractual portfolio loss
```

not:

```text
worst-case loss - Kuru fees
```

or:

```text
worst-case loss + Kuru fees
```

---

## 39. Kuru buy-to-close fee

A writer buying a long on Kuru may pay trading fees.

Those fees are external costs.

Optara closes based on:

```text
same-series long token received and burned
```

not what the writer paid.

---

# Part VI — Oracle provider fees

## 40. Oracle update fee

Some oracle systems require the finalization caller to pay a provider update fee.

This is:

```text
oracle-provider fee
```

not an Optara option fee.

---

## 41. Provider fee is not deducted from long payout

Forbidden:

```text
LongPayout
=
ContractualPayoff
-
OracleUpdateFee
```

unless such a deduction had been explicitly defined as part of immutable option economics, which core V2 does not do.

---

## 42. Finalization caller pays provider fee

Preferred:

```text
caller supplies provider-required native/token fee
```

to the oracle/provider path.

The fee is separate from:

```text
writer collateral
long claims
protocol-owned fee balances
```

---

## 43. Keeper reimbursement

Canonical MVP:

```text
no protocol-funded keeper reimbursement
```

If future keeper reimbursement is added, it needs explicit accounting and must not be silently deducted from long-holder settlement.

---

# Part VII — Network gas

## 44. Gas is external

Users pay network gas for:

```text
deposit
write
lock
unlock
close
withdraw
finalize
sync
redeem
Kuru interaction
```

Gas is not recorded as an Optara protocol fee.

---

# Part VIII — Fee behavior by action

## 45. Fee matrix

| Action | Core V2 Optara fee | External fee may exist? |
|---|---:|---:|
| Deposit | 0 | Network gas |
| Withdraw | 0 | Network gas |
| Write | 0 in MVP; optional future issuance fee | Network gas |
| Transfer long | 0 | Network gas |
| Lock long | 0 | Network gas |
| Unlock long | 0 | Network gas |
| Close short | 0 | Kuru trade fee if long bought there + gas |
| Kuru buy/sell | Not an Optara fee | Kuru fee + gas |
| Finalize risk group | 0 | Oracle-provider fee + gas |
| Sync risk group | 0 | Network gas |
| Redeem | 0 | Network gas |

---

# Part IX — Fee invariants

## 46. FEE-INV-01 — Payoff independence

```text
Payoff(series,S,Q)
```

does not depend on current Optara fee settings.

---

## 47. FEE-INV-02 — Margin independence

Fee configuration does not reduce:

```text
WorstCaseLoss
RequiredMargin
```

---

## 48. FEE-INV-03 — Fee cannot create undercollateralization

If a fee is debited during write:

```text
CashAfterFee
>=
RequiredMarginPostWrite
```

must hold.

---

## 49. FEE-INV-04 — Exact settlement asset

An Optara issuance fee is denominated in:

```text
series.settlementAsset
```

---

## 50. FEE-INV-05 — No fee from locked hedge

Long-option hedges are not sold/burned merely to pay protocol fees.

---

## 51. FEE-INV-06 — No hidden redemption fee

External long redemption receives the contractual payout subject only to required conservative integer rounding.

---

## 52. FEE-INV-07 — Kuru fee isolation

Kuru trading fees do not enter Optara collateral or settlement accounting.

---

## 53. FEE-INV-08 — Oracle fee isolation

Oracle-provider update fees do not reduce user claims.

---

## 54. FEE-INV-09 — Protocol-owned fees segregated

If enabled:

```text
ProtocolOwnedBalance(A)
```

must not be counted as any user's cash.

---

## 55. FEE-INV-10 — Fee withdrawal cannot touch user claims

Any protocol fee withdrawal satisfies:

```text
amount <= ProtocolOwnedBalance(asset)
```

before transfer.

---

# Part X — Forbidden fee designs

## 56. Do not charge fee by reducing cap after issuance

Forbidden:

```text
C_new = C_old - protocol fee
```

after series creation.

---

## 57. Do not take fees from required margin

Forbidden:

```text
CashBalance = RequiredMargin
protocol withdraws fee
CashBalance < RequiredMargin
```

---

## 58. Do not charge percentage of hypothetical Kuru premium

Optara cannot reliably know all external sale prices.

---

## 59. Do not require Kuru trade for fee collection

Users may:

```text
hold
transfer OTC
trade elsewhere
```

The core protocol must still function.

---

## 60. Do not charge liquidation fee in core V2

There is no ordinary market-price liquidation in core V2.

Therefore:

```text
liquidation penalty
liquidator bonus
```

are not part of this fee model.

---

## 61. Do not charge cross-stablecoin fee

Do not debit:

```text
USDC
```

for a USDT-series fee merely because their USD values are close.

---

# Part XI — Testing

## 62. Fee-free MVP tests

Assert every core action produces:

```text
protocol fee delta = 0
```

when fee configuration is zero.

---

## 63. Future issuance-fee tests

If enabled, test:

```text
fee = 0 bps
small fee
maximum configured fee
fractional quantities
different stablecoin decimals
very small gross max payout
rounding-up behavior
```

---

## 64. Margin interaction tests

Test:

```text
cash exactly equals required margin
+ non-zero fee
-> write reverts
```

and:

```text
cash equals required margin + fee
-> write succeeds
```

subject to rounding.

---

## 65. Protocol-owned accounting tests

After fee:

```text
userCash decreases
protocolOwnedBalance increases
physical vault unchanged
```

After fee collection:

```text
protocolOwnedBalance decreases
physical vault decreases equally
```

---

## 66. Fuzz fee splitting

Compare:

```text
one write Q
vs
multiple writes summing to Q
```

Document any rounding difference.

Conservative rounding must not cause protocol deficit.

If anti-fragmentation equality is required, derive fee at sufficient precision before native conversion.

---

# 67. Deployment checklist

For fee-free MVP:

- [ ] all Optara protocol fee settings are zero;
- [ ] no redemption deduction exists;
- [ ] no settlement deduction exists;
- [ ] no close fee exists;
- [ ] Kuru fee displayed as external;
- [ ] oracle-provider update fee displayed as external;
- [ ] `ProtocolOwnedBalance` is zero/unused;
- [ ] docs/frontend do not imply premium is an Optara fee.

If future issuance fee is enabled:

- [ ] fee base is gross new max payout;
- [ ] fee charged in exact settlement asset;
- [ ] post-fee margin safety checked;
- [ ] max-fee user protection implemented;
- [ ] protocol-owned balance isolated;
- [ ] fee-withdrawal authorization reviewed;
- [ ] maximum fee bound configured;
- [ ] differential fee math tests passing.

---

# 68. Canonical fee flow

Future optional issuance-fee mode:

```text
WRITER CASH
    |
    | preview write
    v
POST-WRITE REQUIRED MARGIN
    +
ISSUANCE FEE
    |
    v
CHECK:
CashAfterFee >= RequiredMargin
    |
    +------ insufficient ------> revert
    |
    v
debit user fee
credit protocol-owned balance
record short
mint long
```

For the canonical MVP:

```text
IssuanceFee = 0
```

so only the exact margin requirement is economically relevant.

---

# 69. Final principle

> **Fees must monetize protocol use without changing the financial promise of the option or weakening the collateral that backs it.**

For core V2, the cleanest launch configuration is fee-free.

If protocol revenue is enabled later, an explicit same-settlement-asset issuance fee is the preferred native mechanism.
