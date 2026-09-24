# Optara V2 Option Specification

**Document type:** Normative option-product and series specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; not production-audited

---

## 1. Purpose

This document defines exactly what an Optara V2 option is.

It specifies:

- the pair and settlement model;
- immutable series parameters;
- capped call and put payoff functions;
- contract size and quantity semantics;
- tokenization rules;
- price and decimal conventions;
- series identity;
- lifecycle behavior;
- margin-compatibility rules;
- redemption semantics;
- edge cases and test vectors.

`PROTOCOL_SPEC.md` defines how accounts and contracts act on these option series.

---

## 2. Product definition

An Optara V2 option is a:

> **European-style, capped, cash-settled option whose strike, payout cap, premium market quote, writer margin, and final settlement are denominated in the approved stablecoin of its underlying/stablecoin pair.**

Every series is either:

```text
CALL
or
PUT
```

Every series has a finite maximum payout.

No core V2 series has unlimited contractual liability.

---

## 3. Pair model

Every series belongs to one approved pair:

```text
UNDERLYING / SETTLEMENT_STABLECOIN
```

Examples:

```text
MON / USDT
ETH / USDC
BTC / USDe
```

The right-hand asset MUST be an approved stablecoin for core V2.

For a `MON/USDT` series:

```text
strike               -> denominated in USDT per MON
max payout            -> denominated in USDT per MON
canonical premium     -> quoted in USDT
writer cash margin    -> USDT
final cash settlement -> USDT
```

For an `ETH/USDC` series, each of those values is instead denominated in USDC.

Optara MUST NOT hardcode USDC as the universal quote or settlement asset.

---

## 4. Stablecoin denomination semantics

The settlement asset is a token denomination, not an abstract U.S.-dollar promise by Optara.

If a series settles in USDT, the protocol promises the contractual number of **USDT token units**.

If USDT trades away from one U.S. dollar, Optara does not silently convert the obligation into USDC or another stablecoin.

Therefore:

```text
MON/USDT strike and settlement must use MON priced in USDT units
ETH/USDC strike and settlement must use ETH priced in USDC units
```

An oracle may derive the pair price from multiple feeds, but the final normalized price MUST be expressed in the exact settlement stablecoin unit.

---

## 5. Immutable series definition

Conceptually:

```solidity
struct Series {
    address underlying;          // approved underlying identifier
    address settlementAsset;     // approved pair stablecoin
    OptionType optionType;       // CALL or PUT
    uint256 strikeWad;           // settlement asset per underlying, 1e18 normalized
    uint256 maxPayoutWad;        // max settlement payout per underlying, 1e18 normalized
    uint256 contractSizeWad;     // underlying units per 1 whole option token, 1e18 normalized
    uint64 expiry;               // unix timestamp
    bytes32 oracleConfigId;      // immutable pair settlement configuration
    address optionToken;         // ERC-20 long token
}
```

The exact Solidity storage layout MAY differ, but the economic meaning MUST not.

---

## 6. Immutable fields

After series creation, the following MUST NOT change:

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

The long-token contract address is also fixed once bound to the series.

Changing any of these would create a different financial contract and therefore requires a new series.

---

## 7. Normalized unit system

Optara SHOULD use a protocol-wide internal fixed-point scale:

```text
WAD = 1e18
```

Recommended meanings:

```text
strikeWad
= settlement-stablecoin units per 1 underlying unit, normalized to 1e18

maxPayoutWad
= maximum settlement-stablecoin payout per 1 underlying unit, normalized to 1e18

contractSizeWad
= underlying units represented by 1 whole option token, normalized to 1e18

quantityWad
= option-token quantity, where 1 whole option token = 1e18 units
```

The ERC-20 settlement asset may have 6, 8, 18, or another approved decimal count. Conversion to native token units occurs only at defined accounting/transfer boundaries.

---

## 8. Contract size

`contractSizeWad` specifies how much underlying exposure one whole option token represents.

Examples:

```text
contractSizeWad = 1e18
-> 1 option token represents 1 MON of exposure

contractSizeWad = 0.1e18
-> 1 option token represents 0.1 ETH of exposure
```

Contract size is immutable per series.

Two otherwise identical options with different contract sizes are different series.

For MVP simplicity, deployments MAY standardize contract size per underlying, but the protocol math must not silently assume it is always exactly one.

---

## 9. Quantity

Long option tokens SHOULD use 18 decimals.

Therefore:

```text
1e18 option-token units = 1 whole option token
```

Writers MAY write fractional option quantities if the deployment's quantity granularity permits it.

The SeriesFactory or ClearingHouse MUST enforce a minimum quantity increment to avoid pathological dust and gas behavior.

---

## 10. Call payoff

For settlement price `S`, strike `K`, and cap `C`, all expressed as settlement-stablecoin units per one underlying unit:

```text
intrinsicCall(S) = max(S - K, 0)

cappedCallPerUnderlying(S)
    = min(intrinsicCall(S), C)
```

For contract size `CS` and option quantity `Q`:

```text
CallPayoff(S, Q)
    = cappedCallPerUnderlying(S) * CS * Q
```

with fixed-point scaling applied between multiplications.

### Call regions

```text
S <= K
    payoff = 0

K < S < K + C
    payoff rises one-for-one with S

S >= K + C
    payoff = C per underlying unit
```

Thus the buyer's upside from the option claim is capped at the series maximum payout.

---

## 11. Put payoff

For settlement price `S`, strike `K`, and cap `C`:

```text
intrinsicPut(S) = max(K - S, 0)

cappedPutPerUnderlying(S)
    = min(intrinsicPut(S), C)
```

For contract size `CS` and quantity `Q`:

```text
PutPayoff(S, Q)
    = cappedPutPerUnderlying(S) * CS * Q
```

### Put regions

When `C <= K`:

```text
S >= K
    payoff = 0

K - C < S < K
    payoff rises as S falls

0 <= S <= K - C
    payoff = C per underlying unit
```

---

## 12. Put-cap canonicalization

The underlying settlement price cannot be negative.

An ordinary cash-settled put with strike `K` already has a natural maximum intrinsic value of `K` when `S = 0`.

Therefore core V2 SHOULD enforce:

```text
0 < maxPayout <= strike
```

for puts.

A put cap greater than its strike is economically redundant and SHOULD be rejected to preserve canonical series identity and simpler risk math.

---

## 13. Maximum contractual payout

For any series and any non-negative settlement price:

```text
0 <= payoffPerUnderlying <= maxPayout
```

For one whole option token:

```text
maxPayoffPerOption
    = maxPayout * contractSize
```

For quantity `Q`:

```text
maxTotalPayoff
    = maxPayout * contractSize * Q
```

This bound is the foundation of Optara's solvency-first margin model.

---

## 14. Economic interpretation of the cap

A capped call is economically equivalent, before considering market microstructure and tokenization, to a defined-risk call spread with width equal to the payout cap:

```text
long call at K
short call at K + C
```

A capped put is similarly equivalent to a put spread:

```text
long put at K
short put at K - C
```

Optara implements the capped payoff directly as a single option series rather than requiring the buyer to hold two separate leg tokens.

This makes the writer's maximum liability explicit at creation.

---

## 15. Premium

The premium is **not an immutable field of the option series**.

The series defines the payoff contract; the market determines what that contract is worth.

Therefore:

```text
series terms -> fixed
premium       -> market-discovered
```

On Kuru, the canonical market SHOULD be:

```text
OPTION_TOKEN / SETTLEMENT_STABLECOIN
```

so the premium is naturally quoted in the same stablecoin used for strike, margin, and settlement.

A trade at a different price does not change the option's contractual payoff.

---

## 16. Buyer and writer PnL

Ignoring protocol/exchange fees:

```text
buyerPnL = settlementPayoff - premiumPaid

writerPnL = premiumReceived - settlementPayoff
```

Premium affects economic profit and loss, but it does not change the protocol's payoff formula.

If premium proceeds remain on Kuru, they are not Optara collateral.

---

## 17. Series identity

Every unique set of immutable economic terms MUST map to a unique series identity within a deployment.

Recommended conceptual derivation:

```text
seriesId = keccak256(
    protocolSeriesDomain,
    underlying,
    settlementAsset,
    optionType,
    strikeWad,
    maxPayoutWad,
    contractSizeWad,
    expiry,
    oracleConfigId
)
```

`protocolSeriesDomain` SHOULD prevent accidental collision with unrelated protocol versions or factories.

The `optionToken` address MUST NOT be an input if it is deterministically deployed from `seriesId`, avoiding circular identity.

Duplicate series creation MUST return/reuse the canonical existing series or revert.

---

## 18. Series creation validation

A new series MUST satisfy all of the following:

### Asset checks

```text
underlying is approved
settlementAsset is approved
UNDERLYING/settlementAsset pair is approved
underlying != settlementAsset
```

### Type check

```text
optionType is exactly CALL or PUT
```

### Strike check

```text
strikeWad > 0
```

Core V2 does not support zero-strike options.

### Cap check

```text
maxPayoutWad > 0
```

For puts:

```text
maxPayoutWad <= strikeWad
```

### Contract-size check

```text
contractSizeWad > 0
```

and it must lie within deployment-configured bounds.

### Expiry check

The expiry must:

- be in the future;
- satisfy minimum time-to-expiry;
- satisfy maximum time-to-expiry;
- conform to any standardized expiry schedule if the deployment uses one.

### Oracle check

`oracleConfigId` MUST be approved for the exact:

```text
underlying
settlementAsset
expiry/finality rule
```

### Duplicate check

The economic series identity MUST be unique.

---

## 19. OptionToken semantics

Each series is represented by one fungible ERC-20 long token.

Required behavior:

- ERC-20 compatible;
- 18 decimals recommended;
- mint restricted to the Optara clearing/issuance path;
- burn restricted to valid close or settlement paths, with holder approval where required;
- exposes or can resolve its `seriesId`;
- transferable while not in Optara hedge custody;
- no rebasing;
- no transfer tax;
- no balance-changing hooks that alter claim quantity without Optara authorization.

The token represents only the **long claim**.

It does not itself represent the writer's short liability.

---

## 20. Token metadata

Token metadata SHOULD be deterministic and human-readable.

Example conceptual naming:

```text
Name:
Optara MON/USDT 10C Cap5 2026-12-25

Symbol:
oMON-USDT-10C-C5-261225
```

Metadata is display information only.

Integrations MUST identify the economic contract from `seriesId` and immutable on-chain series fields, not from the symbol string.

---

## 21. Series lifecycle and token transferability

### Before expiry

Long tokens may be transferred, traded, locked, or consumed to close shorts.

### After expiry but before oracle finalization

Long tokens MAY remain transferable.

Their payout is not yet final.

No holder may redeem until settlement is finalized.

### After settlement

Long tokens MAY remain transferable as deterministic stablecoin claims until redeemed.

On redemption, the redeemed quantity is burned.

---

## 22. Short-side representation

Core V2 does not tokenize short positions as freely transferable liabilities.

The short is stored in the writer's Optara margin account:

```text
shortQty[account][seriesId]
```

Rationale:

- margin is account-specific;
- locked hedges are account-specific;
- transferring a short without transferring sufficient collateral could break solvency;
- a short transfer would require an atomic recipient risk check and collateral migration.

A future version may define transferable short positions, but core V2 does not.

---

## 23. Closing relation

One unit of a long token can close exactly one unit of short quantity in the **same series**.

```text
same seriesId
same quantity
```

No approximate economic substitution is allowed.

For example, a `MON/USDT 10C Cap5` long cannot directly close a `MON/USDT 10C Cap4` short.

---

## 24. Hedge compatibility

A long option may reduce margin for a short portfolio only if both belong to the same risk group:

```text
same underlying
same expiry
same settlement stablecoin
same oracle/settlement domain
```

Strike, cap, option type, and contract size MAY differ; the exact RiskEngine payoff calculation determines whether and how much the long reduces worst-case loss.

Examples that may be netted mathematically:

```text
short MON/USDT 10 call + long MON/USDT 12 call
same expiry and oracle domain
```

or:

```text
short MON/USDT put + long MON/USDT call
same expiry and oracle domain
```

if the long actually reduces the exact worst-case portfolio loss.

The protocol MUST not assume a hedge based on labels; it must evaluate the payoff functions.

---

## 25. Incompatible positions

Core V2 MUST NOT use the following as margin offsets:

```text
MON/USDT position vs ETH/USDT position
MON/USDT December expiry vs MON/USDT January expiry
MON/USDT position vs MON/USDC position
same pair/expiry but incompatible oracle domain
wallet-held long not locked in Optara
Kuru-held long not locked in Optara
```

These positions may all exist in the same user's broader portfolio, but they are not netted by the core margin engine.

---

## 26. Settlement price

The settlement price `S` MUST be expressed as:

```text
settlement-stablecoin units per 1 underlying unit
```

Examples:

```text
MON/USDT -> USDT per MON
ETH/USDC -> USDC per ETH
```

The settlement engine MUST normalize the oracle output into the same fixed-point unit used by `strikeWad` and `maxPayoutWad` before computing payoff.

---

## 27. Oracle pair correctness

A settlement oracle configuration MUST correspond to the exact pair denomination.

Acceptable patterns include:

### Direct feed

```text
MON/USDT
```

### Approved derived feed

```text
MON/USDT = (MON/USD) / (USDT/USD)
```

The protocol MUST NOT use:

```text
MON/USD as MON/USDT
```

merely because USDT is expected to be near one U.S. dollar.

The same rule applies to every approved stablecoin.

---

## 28. Settlement calculation

Recommended normalized process:

```text
1. obtain final settlementPriceWad
2. compute payoffPerUnderlyingWad
3. multiply by contractSizeWad
4. multiply by option quantityWad
5. convert WAD settlement value to native settlement-token units
6. round long payout down at the final transfer/credit boundary
```

RiskEngine required margin MUST use equivalent economics with conservative upward rounding where necessary.

The RiskEngine and SettlementEngine MUST share the same payoff math library.

---

## 29. Call test vectors

Assume:

```text
Pair          = MON/USDT
Strike        = 10 USDT
Max payout    = 5 USDT
Contract size = 1 MON
Quantity      = 1 option
```

Expected payoff:

| Settlement MON/USDT | Call payoff |
|---:|---:|
| 0 | 0 USDT |
| 8 | 0 USDT |
| 10 | 0 USDT |
| 11 | 1 USDT |
| 12.5 | 2.5 USDT |
| 15 | 5 USDT |
| 20 | 5 USDT |
| 1000 | 5 USDT |

The payoff MUST never exceed 5 USDT for this one-option position.

---

## 30. Put test vectors

Assume:

```text
Pair          = MON/USDT
Strike        = 10 USDT
Max payout    = 4 USDT
Contract size = 1 MON
Quantity      = 1 option
```

Expected payoff:

| Settlement MON/USDT | Put payoff |
|---:|---:|
| 15 | 0 USDT |
| 10 | 0 USDT |
| 9 | 1 USDT |
| 7 | 3 USDT |
| 6 | 4 USDT |
| 3 | 4 USDT |
| 0 | 4 USDT |

The payoff MUST never exceed 4 USDT.

---

## 31. Contract-size test vector

Assume:

```text
Pair          = ETH/USDC
Strike        = 4,000 USDC
Max payout    = 500 USDC per ETH
Contract size = 0.1 ETH per option
Quantity      = 3 options
Settlement    = 4,800 USDC/ETH
```

Per-ETH call intrinsic:

```text
4,800 - 4,000 = 800 USDC
```

Capped per-ETH payout:

```text
min(800, 500) = 500 USDC
```

Per option:

```text
500 * 0.1 = 50 USDC
```

For three options:

```text
50 * 3 = 150 USDC
```

Expected settlement payout = **150 USDC**.

---

## 32. Fractional-quantity test vector

Assume the same `ETH/USDC` series above and a holder owns:

```text
0.25 option token
```

If the full-option payout is 50 USDC, the economic payout before native-token rounding is:

```text
50 * 0.25 = 12.5 USDC
```

The final token transfer is converted to USDC's native decimals and rounded according to the protocol's long-payout rule.

---

## 33. Boundary behavior

The following must be exact:

### Call at strike

```text
S = K -> payout = 0
```

### Call at cap boundary

```text
S = K + C -> payout = C per underlying
```

### Put at strike

```text
S = K -> payout = 0
```

### Put at cap boundary

```text
S = K - C -> payout = C per underlying
```

### Underlying at zero

```text
S = 0 is valid
```

Negative settlement prices are unsupported in core V2.

---

## 34. Very large prices

Call settlement math MUST remain safe for very large non-negative oracle prices.

Because the call payout is capped:

```text
S >> K + C
```

still produces exactly the capped payout.

The implementation SHOULD compute comparisons and bounded differences in a way that avoids unnecessary overflow-prone intermediate values.

---

## 35. Stablecoin decimals

Different pairs may use stablecoins with different decimals.

For example:

```text
USDC -> commonly 6 decimals
USDT -> deployment-specific token decimals
USDe -> deployment-specific token decimals
```

The protocol MUST read or configure supported-token decimals explicitly and MUST NOT assume every stablecoin uses 6 or 18 decimals.

Internal economic math SHOULD remain normalized to WAD; token-decimal conversion happens at deposits, withdrawals, and settlement transfers/credits.

---

## 36. Rounding semantics

To preserve solvency:

### Long settlement

```text
round DOWN to native settlement-token units
```

A long must never receive more than the contractual capped amount because of rounding.

### Margin requirement

```text
round UP to native settlement-token units
```

A writer must never be allowed to post less than the mathematically required loss coverage because of rounding.

### Writer matured debit

When a normalized amount must be converted into native token units, debit SHOULD round UP unless the accounting implementation proves a symmetric exact alternative.

Any resulting dust MUST be tracked explicitly.

---

## 37. Long-token supply semantics

During the active pre-expiry phase, writing and closing preserve:

```text
new write:
    long supply +Q
    aggregate active short +Q

pre-expiry close:
    long supply -Q
    aggregate active short -Q
```

After settlement, long redemption and writer synchronization may occur at different times.

Therefore post-expiry correctness MUST be checked with cumulative settlement accounting rather than assuming `currentLongSupply == currentUnsyncedShortQty` at every instant.

No implementation should use that pre-expiry equality as a post-settlement invariant.

---

## 38. Locked-long settlement semantics

A locked long used for margin remains an actual long claim.

When its risk group settles and the account is synchronized:

1. its deterministic payout is computed;
2. the long quantity is consumed/burned;
3. the account receives the corresponding internal settlement-stablecoin credit;
4. the same token can no longer be unlocked or externally redeemed.

Locked-long credits and matured short debits in the same risk group MUST be applied atomically.

---

## 39. Kuru market convention

The recommended Kuru market for an Optara option series is:

```text
Base  = OptionToken(seriesId)
Quote = settlementAsset(seriesId)
```

Examples:

```text
oMON-USDT-10C-C5 / USDT
oETH-USDC-4000C-C500 / USDC
```

Kuru's current SDK supports standard markets using ERC-20 base and quote token addresses, which is compatible with this representation.

Kuru's own trading balances and margin system are external to Optara.

---

## 40. Canonical option examples

### Example A — capped call

```text
Underlying       = MON
Settlement pair  = MON/USDT
Type             = CALL
Strike           = 10 USDT
Max payout       = 5 USDT per MON
Contract size    = 1 MON
Expiry           = 2026-12-25 16:00 UTC
Oracle domain    = approved MON/USDT settlement config
```

Economic meaning:

> At expiry, each whole option token pays the holder the increase of MON above 10 USDT, capped at 5 USDT, for 1 MON of exposure.

### Example B — capped put

```text
Underlying       = MON
Settlement pair  = MON/USDT
Type             = PUT
Strike           = 10 USDT
Max payout       = 4 USDT per MON
Contract size    = 1 MON
Expiry           = 2026-12-25 16:00 UTC
Oracle domain    = approved MON/USDT settlement config
```

Economic meaning:

> At expiry, each whole option token pays the holder the decline of MON below 10 USDT, capped at 4 USDT, for 1 MON of exposure.

---

## 41. Invalid series examples

The following MUST be rejected in core V2:

```text
MON / unapproved-token
CALL with maxPayout = 0
PUT with strike = 10 and maxPayout = 12
option with expiry already passed
option with zero contract size
option using an unapproved oracle path
MON/USDT series whose oracle returns MON/USD with no approved USDT conversion
series that duplicates an existing canonical series
```

---

## 42. Series-level invariants

### O-1. Pair consistency

```text
series settlement asset == approved stablecoin of the configured pair
```

### O-2. Payout denomination

Strike, cap, oracle settlement price, margin liability, and redemption all refer to the same settlement-stablecoin unit system.

### O-3. Bounded payoff

```text
0 <= payout <= maxPayout * contractSize * quantity
```

### O-4. Immutable terms

Series economics cannot mutate after creation.

### O-5. Long-token identity

One long token contract corresponds to one canonical series.

### O-6. Same-series close

Only the identical series' long token may directly cancel that series' short quantity.

### O-7. No hidden premium term

Premium does not modify payoff.

### O-8. Single final settlement domain

Every series in a compatible risk group resolves from the same final pair-denominated settlement price.

### O-9. No stablecoin equivalence assumption

The protocol does not assume USDT, USDC, USDe, or another approved stablecoin are economically interchangeable.

### O-10. Burn on claim consumption

Any long quantity used for close, internal settled hedge credit, or external redemption is consumed exactly once.

---

## 43. Implementation checklist

An engineer implementing series support MUST be able to answer yes to all of the following:

- Is the underlying/stablecoin pair explicitly approved?
- Is the settlement stablecoin stored per series?
- Are strike and max payout denominated in that stablecoin?
- Is the oracle output normalized into the exact same denomination?
- Is the payout capped in all code paths?
- Is contract size applied exactly once?
- Is option quantity applied exactly once?
- Are token-decimal conversions explicit?
- Are long payouts rounded down?
- Is required margin rounded up?
- Is the series ID deterministic and collision-resistant?
- Are immutable terms actually immutable?
- Can duplicate economic series be prevented?
- Can the long token be traded as an ERC-20?
- Can a locked long be prevented from external use?
- Can only the identical long series close the short?
- Is a redeemed/consumed long burned exactly once?
- Does Kuru integration use the series settlement stablecoin as quote?
- Does any code accidentally assume `settlementAsset == USDC`? It must not.

---

## 44. Summary

The canonical Optara V2 option is:

```text
European
+ capped
+ cash-settled
+ ERC-20 long claim
+ internal short liability
+ pair-specific approved stablecoin denomination
+ exact same-stablecoin margin backing
+ deterministic oracle settlement
```

The most important product rule is:

> **The option pair chooses the stablecoin. That same approved stablecoin defines the strike unit, cap unit, canonical premium quote, writer margin asset, and final settlement asset for the series.**

---

## 45. External implementation reference

The Kuru market convention described here is based on the official Kuru SDK repository as inspected on 2026-09-24:

- https://github.com/Kuru-Labs/kuru-sdk

Before deployment, integration tests must confirm the exact Kuru market contracts, router addresses, token-deposit behavior, and SDK version used by Optara.
