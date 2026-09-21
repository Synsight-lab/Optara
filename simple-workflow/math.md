# Math

Every formula that decides who gets what. The vault must reproduce the vectors at the end of this file exactly.

## Units

Two kinds of number exist and must never be mixed:

```text
raw units    integer token amounts exactly as the ERC-20 stores them
human value  what a person says out loud ("5.25 USDC")
```

Symbols:

```text
U   underlying asset
Q   quote asset
K   strike: human price of 1 whole U in whole Q, times PRICE_SCALE
S   settlement price, same unit as K
R   reference price, same unit as K
C   contract size: raw units of U in ONE WHOLE option token
a   an option amount in raw option-token units
```

Worked reading of `K`: if one whole MON is 10.00 whole USDC, then `K = 10e18`, no matter how many decimals MON or USDC have.

## Scales

```text
PRICE_SCALE  = 1e18
BPS_SCALE    = 10_000
OPTION_SCALE = 10 ** optionDecimals
UQ_SCALE     = PRICE_SCALE * 10**underlyingDecimals / 10**quoteDecimals
```

Both asset decimals and `optionDecimals` are at most 18, so `UQ_SCALE` is an exact integer of at least 1. All three scales are computed once in the vault constructor and stored as `immutable`.

**What the V1 factory fixes.** Users cannot choose the contract size or the option decimals. The factory always sets `optionDecimals = 18` and `C = 10 ** underlyingDecimals`, so one option is exactly one whole underlying token. The formulas here are general and the math library must handle any `C`, but vault and factory tests use the fixed values. Vector 6 covers them for a low-decimal underlying.

## Converting Underlying to Quote

There is exactly one correct form:

```text
quoteRaw(underlyingRaw, price) = underlyingRaw * price / UQ_SCALE
```

Every place that needs "what is this much underlying worth in quote" uses this expression, with an explicit rounding direction chosen by the caller. There is never a second expression.

Sanity check, MON (18 dp) against USDC (6 dp) at 5.25:

```text
UQ_SCALE = 1e18 * 1e18 / 1e6 = 1e30
quoteRaw(1e18, 5.25e18) = 1e18 * 5.25e18 / 1e30 = 5.25e6   (5.25 USDC)
```

Sanity check with the decimals reversed, U at 6 dp and Q at 18 dp:

```text
UQ_SCALE = 1e18 * 1e6 / 1e18 = 1e6
quoteRaw(1e6, 5.25e18) = 1e6 * 5.25e18 / 1e6 = 5.25e18   (5.25 whole quote)
```

## Collateral

```text
CALL:  collateralPerOption = C                                // raw U per whole option
PUT:   collateralPerOption = ceilDiv(C * K, UQ_SCALE)         // raw Q per whole option

requiredCollateral(a) = ceilDiv(a * collateralPerOption, OPTION_SCALE)
```

`collateralPerOption` is the maximum liability of one whole option. Both roundings are **up**, so the vault never accepts an amount whose maximum liability exceeds the collateral received. It is computed once and never recomputed.

Use `Math.mulDiv` for every multiply-then-divide so nothing overflows in the middle.

## Settlement Rates

Settlement computes two rates once and stores them forever. Both are in collateral raw units per one whole option.

### Call (paid in U)

```text
if S <= K:  buyerPayoutRate = 0
else:       buyerPayoutRate = floor(C * (S - K) / S)

writerResidualRate = collateralPerOption - buyerPayoutRate
```

`UQ_SCALE` does not appear because the quote units cancel when the in-the-money quote value is converted back to underlying by dividing by `S`.

### Put (paid in Q)

```text
if S >= K:  buyerPayoutRate = 0
else:       buyerPayoutRate = floor(C * (K - S) / UQ_SCALE)

writerResidualRate = collateralPerOption - buyerPayoutRate
```

### Why the rates are always safe

```text
CALL: (S - K) / S < 1 for all S > K > 0, so buyerPayoutRate < C = collateralPerOption
PUT:  C*(K - S) < C*K, so buyerPayoutRate < ceilDiv(C*K, UQ_SCALE) = collateralPerOption
```

So `writerResidualRate >= 0`, and by construction:

```text
buyerPayoutRate + writerResidualRate == collateralPerOption
```

**`writerResidualRate` must be computed by subtraction.** Deriving it from its own formula and rounding it separately breaks this identity and over-allocates collateral in a way ordinary tests do not catch.

## Claims

Both claim types are linear in the stored rate and round **down**:

```text
grossBuyerPayout(a)    = floor(a * buyerPayoutRate    / OPTION_SCALE)
grossWriterResidual(a) = floor(a * writerResidualRate / OPTION_SCALE)
```

Fees are taken out of these gross amounts (see `contracts.md`). The amount removed from `collateralLocked` is always the **gross** amount.

## Solvency Proof

### One position

```text
grossBuyerPayout(a) + grossWriterResidual(a)
    = floor(a*rb/OS) + floor(a*rw/OS)
   <= a*(rb + rw)/OS
    = a*collateralPerOption/OS
   <= ceilDiv(a*collateralPerOption, OS)
    = requiredCollateral(a)
```

Two floors on the claim side, one ceiling on the collateral side. Every rounding step favors the vault.

### Many writers and holders

Writers mint `a_1..a_n`. Holders redeem `b_1..b_m` with `sum(b) <= sum(a)`. Writers claim `w_1..w_p` with `sum(w) = sum(a)`.

```text
collateral collected:  sum ceilDiv(a_i*cpo, OS)  >=  ceilDiv(sum(a_i)*cpo, OS)
claims:                sum floor(b_j*rb/OS) <= sum(a)*rb/OS
                       sum floor(w_k*rw/OS) <= sum(a)*rw/OS
total claims          <= sum(a)*(rb + rw)/OS = sum(a)*cpo/OS  <=  collateral collected
```

Splitting mints or claims into many transactions only adds dust. It can never create a deficit. This is why the fuzz tests fragment mints and claims.

## Rounding Table

Every direction is fixed. Changing one means redoing the proof.

```text
collateralPerOption (PUT)   ceil
requiredCollateral          ceil
buyerPayoutRate             floor
writerResidualRate          exact subtraction
grossBuyerPayout            floor
grossWriterResidual         floor
mintFee                     ceil    (added on top; cannot affect solvency)
exerciseFee                 floor   (carved from a gross amount already computed)
```

## Dust

Dust is whatever collateral is left after every claim. It is never negative and stays in the vault for ever. There is no sweep function. It is at most about one unit of the collateral asset per claim.

## Minimum Size

`minOptionAmount` applies **only to mint**:

```text
mint:     a >= minOptionAmount and requiredCollateral(a) > 0
redeem:   a > 0
claim:    a > 0
```

A holder can end up with less than the minimum through a partial fill or a plain transfer. If redeem rejected them, their funds would be stuck for ever.

## Worked Test Vectors

Exact integers. They are normative. Write them as unit tests before the vault exists.

### Vector 1: Call, 18 dp underlying, 6 dp quote, exact division

```text
CALL. U dp = 18, Q dp = 6, optionDecimals = 18
OPTION_SCALE = 1e18   UQ_SCALE = 1e30
C = 1e18   K = 10e18   S = 12.5e18

collateralPerOption = 1e18
mint a = 5e18            requiredCollateral = ceilDiv(5e18*1e18, 1e18) = 5e18

buyerPayoutRate    = floor(1e18 * 2.5e18 / 12.5e18) = 2e17
writerResidualRate = 1e18 - 2e17 = 8e17

holder redeems 5e18:  gross = floor(5e18*2e17/1e18) = 1e18
writer claims  5e18:  gross = floor(5e18*8e17/1e18) = 4e18
total out = 5e18 = collateral, dust = 0
```

### Vector 2: Put, 8 dp underlying, 6 dp quote

```text
PUT. U dp = 8, Q dp = 6, optionDecimals = 18
OPTION_SCALE = 1e18   UQ_SCALE = 1e20
C = 1e6   K = 60000e18   S = 55000e18

collateralPerOption = ceilDiv(1e6 * 60000e18, 1e20) = 6e8
mint a = 3e18            requiredCollateral = ceilDiv(3e18*6e8, 1e18) = 1.8e9

buyerPayoutRate    = floor(1e6 * 5000e18 / 1e20) = 5e7
writerResidualRate = 6e8 - 5e7 = 5.5e8

holder redeems 3e18:  gross = floor(3e18*5e7/1e18)   = 1.5e8
writer claims  3e18:  gross = floor(3e18*5.5e8/1e18) = 1.65e9
total out = 1.8e9 = collateral, dust = 0
```

### Vector 3: Call, non-terminating division, dust appears

```text
CALL. C = 1e18, OPTION_SCALE = 1e18, K = 3e18, S = 7e18

buyerPayoutRate    = floor(1e18 * 4e18 / 7e18) = 571428571428571428
writerResidualRate = 1e18 - 571428571428571428 = 428571428571428572

collateral for a = 1e18 is 1e18
holder redeems (1e18 - 1): floor((1e18-1) * 571428571428571428 / 1e18) = 571428571428571427
writer claims  1e18:       floor(1e18 * 428571428571428572 / 1e18)     = 428571428571428572
total out = 999999999999999999, dust left in vault = 1 wei
```

### Vector 4: Out of the money, both types

```text
CALL with S <= K:  buyerPayoutRate = 0, writerResidualRate = collateralPerOption
PUT  with S >= K:  buyerPayoutRate = 0, writerResidualRate = collateralPerOption

redeem() of any amount burns the tokens, pays 0, charges no fee, and skips the
transfer entirely (some tokens revert on zero transfers).
```

### Vector 5: Fees

```text
Continue Vector 1 with mintFeeBps = 10 and exerciseFeeBps = 25.

mintFee      = ceilDiv(5e18 * 10, 10000) = 5e15
writer pays  5e18 + 5e15 = 5.005e18
collateralLocked += 5e18        accruedFees += 5e15

grossPayout  = 1e18
exerciseFee  = floor(1e18 * 25 / 10000) = 2.5e15
netPayout    = 1e18 - 2.5e15 = 9.975e17
collateralLocked -= 1e18        accruedFees += 2.5e15
```

The outflow from `collateralLocked` is the gross amount either way. The fee only changes where it goes.

### Vector 6: Put with the factory-fixed contract size (one whole underlying)

```text
PUT. U dp = 8, Q dp = 6, optionDecimals = 18
OPTION_SCALE = 1e18   UQ_SCALE = 1e20
C = 10**8 = 1e8 (one whole BTC per option)   K = 60000e18   S = 55000e18

collateralPerOption = ceilDiv(1e8 * 60000e18, 1e20) = 6e10          (60,000 USDC)
mint a = 3e18            requiredCollateral = ceilDiv(3e18*6e10, 1e18) = 1.8e11   (180,000 USDC)

buyerPayoutRate    = floor(1e8 * 5000e18 / 1e20) = 5e9              (5,000 USDC per option)
writerResidualRate = 6e10 - 5e9 = 5.5e10                            (55,000 USDC)

holder redeems 3e18:  gross = floor(3e18*5e9/1e18)    = 1.5e10
writer claims  3e18:  gross = floor(3e18*5.5e10/1e18) = 1.65e11
total out = 1.8e11 = collateral, dust = 0
```

## Invariants

1. **Full collateral before mint.** `collateralLocked >= requiredCollateral(totalShortAmount)` after every mint. It holds with slack because a sum of ceilings is at least the ceiling of the sum.
2. **Supply matches shorts.** Before settlement, `totalSupply == totalShortAmount`.
3. **Settlement is final.** The price and both rates are written once.
4. **Kuru and premium cannot affect payout.** No trading price or premium is an input to collateral, settlement or claims.
5. **Claims never exceed collateral.** Per the proof above. With fees, `balanceOf(vault) >= collateralLocked + accruedFees` at all times.
6. **No double redemption.** Tokens are burned before the payout is sent.
7. **No early exercise.** `settle`, `redeem` and `claimWriterResidual` revert before expiry (before settlement for the last two).
8. **Conservative rounding** as in the table.
9. **Canonical identity.** A token is official only if `factory.isOptionToken(token)` is true.

## Edge Cases

- `S == K`: both types pay 0 and the writer gets the full collateral back.
- Very large `S` (call): payout approaches `C` but never reaches it.
- Very small `S` (put): payout approaches `collateralPerOption` but never exceeds it. In quote terms the limit is `E(a) * K / UQ_SCALE`, which is `requiredCollateral(a)` up to rounding, where `E(a) = a * C / OPTION_SCALE`.
- `S == 0` is rejected by the oracle library and never reaches this math.
