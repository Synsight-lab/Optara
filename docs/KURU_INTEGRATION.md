# Optara V2 — Kuru Integration Specification

**Document type:** Normative external-exchange integration specification  
**Protocol:** Optara  
**Integration:** Kuru on Monad  
**Target:** V2 solvency-first MVP  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; Kuru-facing assumptions verified against current public Kuru SDK/repositories on 2026-09-24

---

## 1. Purpose

This document defines how Optara V2 integrates with Kuru for secondary trading of Optara long option tokens.

The integration must preserve a strict architectural boundary:

```text
OPTARA
= option issuance
+ short obligations
+ pair-stablecoin margin
+ exact portfolio risk
+ locked hedges
+ expiry settlement

KURU
= secondary-market trading
+ order-book / market execution
+ Kuru-side trading balances
+ liquidity
+ price discovery
```

Kuru is intentionally **not** part of Optara's solvency proof.

Optara must remain settlement-correct when:

```text
Kuru has no liquidity
Kuru is unavailable
the option has never traded
the option market is temporarily inactive
a user chooses never to use Kuru
```

This document must be read with:

- `PROTOCOL_SPEC.md`
- `OPTION_SPEC.md`
- `MATH.md`
- `INVARIANTS.md`
- `MARGIN_AND_RISK.md`
- `LIQUIDATION.md`
- `STATE_MACHINE.md`
- `USER_FLOWS.md`

---

## 1.1 Optara integration-package architecture

The recommended V2 integration is an off-chain modular package rather than a Kuru dependency inside the clearing contracts:

```text
Application
   |
   +--> @optara/sdk  ----------------> Optara contracts
   |
   +--> @optara/kuru ----------------> Kuru SDK/contracts
             |
             +-----------------------> @optara/sdk
                                        when a workflow also needs an Optara call
```

Responsibilities:

```text
@optara/sdk
    canonical Optara reads/transaction construction

@optara/kuru
    Kuru market validation/discovery
    Kuru buy/sell operations
    Kuru inventory movement
    buy-to-close orchestration
    market-maker helpers

Optara contracts
    canonical collateral, shorts, hedge custody, margin, settlement
```

Neither package is financially authoritative. If `@optara/kuru` reports that a trade filled, Optara does not change state until the actual token/stablecoin movement and a valid Optara contract call occur.

A future on-chain router MAY provide atomic venue+Optara workflows, but that router is optional and must use ordinary Optara verification paths.

# 2. Verified Kuru assumptions

As of 2026-09-24, the public Kuru SDK/repositories support the following assumptions used by Optara:

1. Kuru standard markets can be created between ERC-20 base and quote assets.
2. A Kuru market has explicit base and quote token addresses.
3. Kuru exposes order-book trading.
4. Kuru market-making flows use a separate Kuru margin-account balance.
5. Market parameters include precision / minimum size / tick-size style configuration.
6. Kuru trading and custody are external to Optara accounting.

Relevant public references checked:

```text
Kuru-Labs/kuru-sdk
Kuru-Labs/kuru-sdk/examples/v2/createMarket.ts
Kuru-Labs/kuru-sdk-py
Kuru-Labs/kuru-sdk-py/docs/MARKET_MAKING.md
Kuru-Labs/Kuru-contracts-dex-public
```

This document intentionally does **not** hardcode:

```text
current Kuru fee rates
current router addresses
current margin-account addresses
current market deployment addresses
current frontend-listing policy
```

because these are deployment/exchange configuration details rather than immutable Optara protocol rules.

---

# 3. Canonical market shape

For each Optara series:

```text
Kuru base asset
=
Optara long option ERC-20

Kuru quote asset
=
that series' approved settlement stablecoin
```

Examples:

```text
oMON-USDT-10C-C5-EXP / USDT

oETH-USDC-4000C-C500-EXP / USDC

oBTC-USDe-100000P-C10000-EXP / USDe
```

Optara is not USDC-based.

The quote token used by the Kuru option market must correspond to the **series-specific settlement stablecoin**.

---

# 4. Why the long token is the base asset

The Optara long token is the instrument being bought and sold.

The settlement stablecoin is the unit in which users naturally quote its premium.

Therefore:

```text
base  = long option token
quote = series settlement stablecoin
```

If one long token trades at:

```text
0.70 USDT
```

then:

```text
price = 0.70 USDT per option token
```

This market price is a premium / secondary-market price.

It does not change:

```text
strike
cap
expiry
contract size
settlement asset
oracle rule
```

of the underlying Optara series.

---

# 5. Optara long-token requirements for Kuru

Each Optara long token must be suitable for external ERC-20 trading.

Required properties:

```text
fungible
non-rebasing
no transfer tax
predictable decimals
standard transfer/transferFrom behavior
no balance mutation outside authorized mint/burn
immutable series association
```

Recommended:

```text
18 token decimals
```

unless the implementation formally chooses another convention.

The token must expose or be resolvable to:

```text
seriesId
underlying
settlement stablecoin
option type
strike
cap
contract size
expiry
oracleConfigId
```

Kuru does not need to understand those fields to trade the ERC-20, but frontends/indexers do.

---

# 6. Short positions are not traded on Kuru

Optara V2 tokenizes only the long claim.

The writer's short remains:

```text
shortQty[writer][seriesId]
```

inside the Optara ClearingHouse.

Therefore:

```text
selling an Optara long on Kuru
DOES NOT
transfer the writer's Optara short
```

Example:

```text
Alice writes 1 option.
Optara:
    Alice short = 1

Alice receives 1 long token.
Alice sells long to Bob on Kuru.

After trade:
    Alice Optara short = 1
    Bob owns long token = 1
```

The liability remains with Alice.

---

# 7. Accounting boundary

This boundary is mandatory.

```text
OPTARA CASH
!=
KURU TRADING CASH

OPTARA LOCKED LONG
!=
KURU LONG BALANCE

KURU TRADE
!=
OPTARA SHORT CLOSE
```

If a writer receives USDT on Kuru:

```text
Kuru USDT balance
```

is not Optara margin.

It becomes Optara margin only after the USDT is actually transferred into Optara and credited to:

```text
cashBalance[writer][USDT]
```

---

# 8. Kuru margin-account distinction

Kuru's market-making stack uses its own trading margin account.

That Kuru margin account exists for Kuru execution.

It must never be confused with:

```text
Optara Margin Account
```

which exists to secure option settlement obligations.

The two may contain the same ERC-20 token type but represent separate custody/accounting systems.

Example:

```text
Alice:
    100 USDT in Kuru
    5 USDT in Optara
```

Optara sees only:

```text
5 USDT
```

for margin purposes.

---

# 9. Kuru trading-flow variability

Optara must not assume every Kuru trade path uses exactly the same wallet/margin route.

Current Kuru SDKs expose different execution patterns, including Kuru-side margin-account flows for order-book market making.

The core Optara rule is therefore custody-based:

> Assets count for Optara only when Optara actually controls them under its own accounting rules.

This remains correct regardless of how Kuru evolves its own execution modes.

---

# 10. Market creation

A Kuru market for a series may be created after the option token contract exists. The application MAY use `@optara/kuru` as the typed wrapper around the relevant Kuru market-creation/discovery interfaces.

Conceptual inputs:

```text
baseAsset
    = optionToken(seriesId)

quoteAsset
    = settlementAsset(seriesId)

market precisions
tick size
minimum size
maximum size
Kuru fee parameters
Kuru AMM/backstop parameters if used
```

Exact Kuru deployment parameters are operational configuration.

They are not immutable Optara option terms.

---

# 11. Market identity registry

Optara MAY maintain a convenience registry:

```text
kuruMarket[seriesId] -> marketAddress
```

but this mapping must not become part of series economics.

Recommended rule:

```text
seriesId is canonical
Kuru market address is integration metadata
```

Why:

- a market may be replaced;
- multiple venues may trade the same token;
- a Kuru market may be unavailable;
- Optara settlement must not depend on a specific venue address.

---

# 12. Market registration permissions

For the MVP, registering a Kuru market in the official Optara frontend/registry SHOULD be controlled or verified to prevent malicious markets from masquerading as canonical markets.

Registration should verify:

```text
base == exact Optara optionToken
quote == exact series settlementAsset
market belongs to intended Kuru deployment/network
```

The underlying ERC-20 remains permissionlessly transferable even without official listing.

---

# 13. No unsecured minting for Kuru liquidity

Optara MUST NOT mint long option tokens merely to seed Kuru liquidity.

Every minted long must correspond to a matching Optara short obligation:

```text
Delta long supply
=
Delta short obligation
```

Therefore market makers obtain option inventory by:

```text
writing fully margined options
buying options from holders
receiving options from another valid holder
```

not by unsecured protocol inventory creation.

---

# 14. Liquidity provider / market maker inventory

A Kuru market maker may need:

```text
base inventory
= Optara long options

quote inventory
= series settlement stablecoin
```

If quoting both sides, the market maker may need both assets within the Kuru trading system according to Kuru's execution model.

Those Kuru balances do not reduce an Optara writer's margin.

---

# 15. Writer issuance-to-market flow

Canonical flow:

```text
Writer deposits settlement stablecoin into Optara
                |
                v
Writer calls write(seriesId, Q, recipient)
                |
                v
Optara verifies post-write exact margin
                |
                v
Optara records short Q
Optara mints long Q
                |
                v
Writer transfers/deposits long into Kuru flow
                |
                v
Writer lists/sells OPTION / SETTLEMENT_STABLECOIN
                |
                v
Buyer receives long economic ownership
Writer receives Kuru-side quote proceeds
```

Optara does not need to know the trade price.

---

# 16. Direct recipient issuance

`write()` may mint the long to a recipient different from the writer:

```text
write(seriesId, quantity, recipient)
```

This can support:

```text
OTC workflows
routers
market-making adapters
atomic sale flows
```

but the short still belongs to the writer's Optara account.

If premium payment is external, Optara does not count it as margin.

---

# 17. Buyer flow

A buyer acquires the long token on Kuru.

The buyer receives:

```text
transferable long claim
```

and does not inherit:

```text
writer collateral obligation
writer short position
writer margin account
```

The buyer may:

```text
hold
resell
transfer
withdraw from Kuru custody
lock it in their own Optara account as a hedge
use it to close their own matching short
redeem after settlement
```

subject to custody requirements.

---

# 18. Secondary trading

Long ownership may change repeatedly:

```text
Alice -> Bob -> Dave -> Erin
```

The right to settlement follows the surviving long token.

Optara does not track historical buyers for payout rights.

At redemption:

```text
current token holder / authorized owner
```

controls the claim.

---

# 19. Kuru-held token at expiry

If the long token is held inside a Kuru margin/custody system rather than directly by the user's wallet, Optara must not pretend that the user directly possesses the ERC-20.

To redeem directly from Optara, the token must either:

```text
1. be withdrawn/transferred from Kuru to an address that can call/approve Optara redemption

or

2. be moved by a future explicitly integrated adapter that obtains valid custody/authorization
```

No synthetic Kuru balance may be redeemed from Optara without the actual ERC-20 claim being burned.

---

# 20. Writer buyback close

A writer may close before expiry:

```text
1. buy the exact same series long on Kuru
2. obtain custody of that token
3. transfer/approve it to Optara
4. call closeShort(seriesId, quantity)
5. Optara burns the long
6. Optara reduces same-series short quantity
7. RiskEngine recalculates margin
8. released margin becomes free collateral
```

The Kuru purchase by itself does not close the short.

---

# 21. Same-series requirement

A long closes only:

```text
same seriesId
same quantity
```

Example:

```text
MON/USDT K=10 Cap=5
```

cannot be closed by:

```text
MON/USDT K=10 Cap=4
```

or:

```text
MON/USDT K=12 Cap=5
```

even if economically similar.

---

# 22. Locking a Kuru-acquired long as hedge

Flow:

```text
buy long on Kuru
        |
        v
withdraw/obtain ERC-20 custody
        |
        v
lockLong(seriesId, quantity)
        |
        v
Optara custody receives token
        |
        v
RiskEngine may recognize payoff
```

While locked, it cannot simultaneously remain tradeable on Kuru.

---

# 23. Unlock-to-Kuru flow

If a user wants to sell a locked hedge:

```text
request unlock
        |
        v
Optara simulates portfolio without hedge
        |
   +----+----+
   |         |
 safe      unsafe
   |         |
   v         v
release    revert
   |
   v
user may transfer/deposit it to Kuru
```

The token must never leave Optara before post-unlock margin safety is proven.

---

# 24. Premium semantics

Kuru discovers the premium.

If:

```text
OPTION token price = 0.70 USDT
```

then the trade consideration is:

```text
0.70 USDT per option token
```

This affects trader PnL.

It does not change the Optara payoff function.

---

# 25. Premium and writer margin

Suppose:

```text
RequiredMargin = 5 USDT
Writer Optara cash = 5 USDT
```

Writer sells the option for:

```text
0.50 USDT on Kuru
```

Immediately after the Kuru trade:

```text
Optara cash = 5 USDT
RequiredMargin = 5 USDT
```

If writer later deposits the premium:

```text
Optara cash = 5.50 USDT
RequiredMargin = 5 USDT
FreeCollateral = 0.50 USDT
```

The premium increases cash.

It does not reduce contractual required margin.

---

# 26. Option price versus option payoff

Kuru market price:

```text
market valuation before expiry
```

Optara payoff:

```text
immutable contract function of final settlement price
```

They are different concepts.

Kuru price may reflect:

```text
spot
time to expiry
volatility expectations
liquidity
supply/demand
interest rates
market-maker inventory
```

Optara core does not need to model those variables to settle the option.

---

# 27. No Kuru price inside RiskEngine

Core RiskEngine MUST NOT use:

```text
Kuru last trade
Kuru midpoint
Kuru bid
Kuru ask
Kuru AMM price
```

to determine exact worst-case margin.

Margin comes from contractual payoffs.

This keeps option solvency independent from market liquidity.

---

# 28. No Kuru price as settlement oracle

Kuru's option-token price is not the underlying settlement price.

Even a MON option market quoted in USDT trades the **option**, not MON itself.

Therefore:

```text
OPTION/USDT price
```

MUST NOT be passed into the option payoff as:

```text
S_MON_USDT
```

The settlement oracle must provide the underlying's price in the exact stablecoin denomination.

---

# 29. Spot hedging through Kuru

A trader MAY separately use Kuru spot markets to hedge economic exposure.

Example:

```text
short MON call
+
buy MON spot
```

may reduce the trader's personal delta risk.

Core Optara V2 does not recognize that external spot position for margin.

Why:

```text
external custody
price-path dependence
possible sale before expiry
different settlement mechanics
```

A future multi-collateral/covered-call mode may explicitly support on-protocol underlying collateral.

---

# 30. Trading after expiry

At:

```text
block.timestamp >= expiry
```

Optara series state becomes:

```text
EXPIRED_UNSETTLED
```

No new Optara shorts may be written.

The ERC-20 may remain technically transferable unless the token contract deliberately restricts it.

Integration/frontends SHOULD clearly mark the market:

```text
EXPIRED — AWAITING SETTLEMENT
```

and SHOULD avoid presenting it as an ordinary active option market.

The core protocol must not depend on Kuru being able to pause the market.

---

# 31. Trading after finalization

After final settlement:

```text
option token
=
deterministic claim on settlement stablecoin
```

until redeemed.

Technically the token may remain transferable.

Operationally, the official frontend SHOULD prioritize:

```text
redeem
```

rather than continued speculative trading.

A Kuru market may be delisted/hidden operationally, but Optara redemption cannot depend on delisting.

---

# 32. Redemption flow

For holder with actual ERC-20 custody:

```text
redeem(seriesId, Q)
        |
        v
Optara computes fixed settled payout
        |
        v
burn Q long tokens
        |
        v
transfer exact series settlement stablecoin
```

Kuru is not in this path.

---

# 33. Market delisting policy

Recommended official integration lifecycle:

```text
ACTIVE SERIES
-> listed/tradable

EXPIRED_UNSETTLED
-> mark expired
-> discourage/disable official order entry where operationally possible

SETTLED
-> mark redeemable
-> delist/hide from active options view

FULLY REDEEMED / CLOSED
-> archive
```

This is frontend/integration policy.

It is not an Optara consensus invariant.

---

# 34. Kuru outage behavior

If Kuru becomes unavailable:

```text
Optara write may still function
Optara margin checks still function
Optara hedge custody still functions
Optara expiry still functions
Optara settlement still functions
Optara redemption still functions
```

Users may lose:

```text
easy secondary liquidity
easy writer buyback
easy price discovery
```

but not the contractual option claim.

---

# 35. Liquidity failure behavior

If the Kuru market has no bids/asks:

```text
no protocol insolvency occurs merely from illiquidity
```

Writer cannot rely on being able to close cheaply.

Buyer cannot rely on being able to exit before expiry.

This is market-liquidity risk, not core clearing risk.

---

# 36. Slippage

Kuru execution price may differ materially from expected premium.

Optara MUST NOT guarantee:

```text
minimum secondary-market value
exit price
writer close cost
```

Slippage is external trading risk.

---

# 37. Market precision

When creating a Kuru market, integration code must correctly configure:

```text
price precision
size precision
tick size
minimum order size
maximum order size
token decimals
```

These parameters must be compatible with:

```text
option token decimals
settlement stablecoin decimals
expected premium range
```

Incorrect precision can make the market unusable even though the Optara option itself remains valid.

---

# 38. Minimum size and dust

If Optara supports fractional option quantities smaller than Kuru's configured market minimum:

```text
some valid Optara positions may be too small to trade on Kuru
```

This is acceptable.

Optara protocol validity must not depend on Kuru's minimum order size.

The frontend should warn users.

---

# 39. Maximum price expectations

Market setup should choose Kuru price precision/range compatible with realistic option premium values.

However:

```text
Kuru market max/precision
```

must never constrain:

```text
Optara contractual payout
```

If Kuru configuration is poor, the remedy is market reconfiguration/new market, not changing the option series.

---

# 40. Fees

Kuru trading fees are external trading costs.

Optara core should not hardcode them into:

```text
payoff
required margin
settlement amount
series identity
```

If Optara later charges its own issuance or settlement fee, those fees require the separate `FEES.md` specification.

---

# 41. `@optara/kuru` package and optional future router

The primary MVP integration module SHOULD be the off-chain `@optara/kuru` package.

Possible responsibilities:

```text
validate canonical market base/quote
query order book / venue state
buy option
sell option
move option/stablecoin inventory
buy same-series long for close
coordinate follow-up @optara/sdk closeShort()
market-maker utilities
```

This package cannot make a Kuru fill equivalent to an Optara state transition.

A future **on-chain** Kuru router/adapter MAY simplify atomic workflows where Kuru's contracts permit them, for example:

```text
buy exact long
-> receive ERC-20
-> closeShort()
```

or:

```text
receive buyer premium
-> deposit exact stablecoin
-> perform canonical write
-> deliver long
```

Any such router remains optional and is not trusted by the core solvency model.

---

# 42. Integration-module security boundary

`@optara/kuru` and any future on-chain Kuru router MUST NOT:

```text
invent Optara collateral
credit unreceived premium
mark an external long as locked without custody
mark a short closed before long-token burn
alter option terms
alter oracle settlement
bypass ClearingHouse risk checks
```

Core accounting must verify final asset movement itself.

---

# 43. Buy-to-close orchestration

`@optara/kuru` MAY orchestrate a multi-transaction buy-to-close flow. A future on-chain router MAY attempt an atomic form:

```text
buy exact long on Kuru
-> receive long
-> call Optara closeShort
```

in one atomic transaction where Kuru interfaces permit.

Safety conditions:

```text
exact series token received
minimum output enforced
short quantity exists
burn completes
post-state accounting reconciles
unused assets returned
```

If the Kuru leg fails, the entire atomic close SHOULD revert where technically feasible.

---

# 44. Premium-to-margin orchestration

An SDK flow MAY guide a user through premium receipt and deposit. A future on-chain primary-sale router MAY atomically:

```text
collect buyer settlement stablecoin
-> credit writer Optara cash
-> run post-write margin check
-> write option
-> transfer long to buyer
```

Safe ordering matters.

The protocol must not mint an unsecured long based on premium expected later.

---

# 45. No adapter-required settlement

Even if adapters exist:

```text
direct Optara redemption
direct Optara settlement
direct Optara close with supplied long
```

must remain possible without Kuru.

---

# 46. Market maker flow

A market maker may:

```text
1. acquire/mint option inventory through valid Optara positions
2. acquire series settlement stablecoin
3. move relevant inventory into Kuru trading domain
4. post bids and asks
5. manage fills
6. withdraw assets as needed
```

If the market maker is also an Optara writer:

```text
its Kuru inventory
does not reduce
its Optara required margin
```

unless long tokens are removed from Kuru and locked in Optara.

---

# 47. Maker inventory and short liability

Example:

```text
MM writes 100 option tokens.
MM Optara short = 100.

MM deposits 50 option tokens into Kuru.
MM keeps 50 in wallet.
```

Optara still sees:

```text
short = 100
```

The location of long supply does not reduce writer obligation.

---

# 48. Buyer settlement ownership

Suppose long tokens circulate through Kuru.

At finalization:

```text
writer identity is irrelevant to buyer redemption
original buyer identity is irrelevant
trade history is irrelevant
```

The redeeming long-token quantity defines the claim.

---

# 49. Indexer requirements

The official Optara integration/indexer SHOULD expose:

```text
seriesId
optionToken
settlementAsset
expiry
series state
Kuru market address(es)
Kuru market active/inactive status
redemption status
```

It must distinguish:

```text
on-chain Optara truth
```

from:

```text
off-chain/indexed Kuru metadata
```

---

# 50. Frontend requirements

The frontend should clearly display:

```text
Pair
Option type
Strike
Cap
Expiry
Contract size
Settlement stablecoin
Current Kuru premium / order book
Max payout
Series state
```

It must not label the settlement stablecoin generically as "USDC".

---

# 51. Writer UX

Before `write()`:

```text
show exact additional Optara collateral required
```

After mint:

```text
show that long token is separate from short liability
```

Before Kuru sale:

```text
explain proceeds remain outside Optara margin
unless explicitly deposited back
```

---

# 52. Buyer UX

Before trade, show:

```text
premium
max gross payout
expiry
cap
settlement stablecoin
```

Buyer should understand:

```text
payout above cap does not grow further
```

---

# 53. Close UX

A writer buying back should see:

```text
Kuru acquisition
!=
Optara close
```

until:

```text
closeShort()
```

successfully burns the token.

---

# 54. Expiry UX

At expiry:

```text
ACTIVE
->
EXPIRED_UNSETTLED
```

Display:

```text
awaiting final oracle price
```

After finalization:

```text
SETTLED
```

display:

```text
payoff per token
redeem action
```

---

# 55. Security invariants

## KI-INV-01

```text
Kuru balance is never Optara collateral
```

## KI-INV-02

```text
Kuru-held long is never Optara locked hedge
```

## KI-INV-03

```text
Kuru trade never directly reduces Optara shortQty
```

## KI-INV-04

```text
closeShort requires actual same-series long-token consumption
```

## KI-INV-05

```text
Kuru market price never changes option payoff terms
```

## KI-INV-06

```text
Kuru availability is not required for expiry settlement
```

## KI-INV-07

```text
Kuru OPTION price is not the underlying settlement oracle
```

## KI-INV-08

```text
base token of canonical Kuru market
=
exact series optionToken
```

## KI-INV-09

```text
quote token of canonical Kuru market
=
exact series settlementAsset
```

## KI-INV-10

```text
no unsecured option supply may be created to seed Kuru liquidity
```

## KI-INV-11

```text
@optara/kuru result
!=
Optara accounting state
```

Only canonical Optara contract state transitions may credit collateral, recognize hedges, close shorts, or settle claims.

---

# 56. Required integration tests

Test at least:

```text
create/identify OPTION/STABLECOIN market

writer write -> move long -> sell on Kuru

buyer acquire -> withdraw -> transfer

writer buyback -> withdraw/receive -> closeShort

long bought on Kuru -> lock as Optara hedge

locked hedge cannot be simultaneously placed on Kuru

Kuru proceeds do not change Optara cash until deposit

wrong quote stablecoin market is rejected by official registry

wrong option-token base market is rejected

Kuru outage does not block Optara settlement

option held in Kuru custody cannot be synthetically redeemed from Optara

same-series token closes short

different-series token fails to close

expiry changes integration status

settled long can redeem without Kuru
```

---

# 57. Main implementation rule

The integration should be built so that removing Kuru entirely from the system leaves this core path valid:

```text
deposit margin
-> write
-> hold/transfer long
-> finalize expiry
-> settle writer
-> redeem long
```

Kuru improves:

```text
liquidity
price discovery
early exit
writer buyback
market making
```

It does not supply the correctness of the option contract.

---

# 58. Canonical integration diagram

```text
                       OPTARA
        +----------------------------------+
        | Series + Clearing + Risk + Vault |
        +----------------+-----------------+
                         |
                         | write()
                         v
                +----------------+
                | ERC-20 LONG    |
                | OPTION TOKEN   |
                +--------+-------+
                         |
                         | transfer/deposit
                         v
        +----------------------------------+
        |               KURU               |
        |                                  |
        | Base  = OPTION TOKEN             |
        | Quote = SERIES STABLECOIN        |
        |                                  |
        | Order book / liquidity / trades  |
        +----------+--------------+--------+
                   |              |
           option token       stablecoin
                   |              |
                   v              v
                Buyers          Sellers
                   |
                   | withdraw/transfer
                   v
        +------------------------------+
        | Wallet / Optara recognized   |
        | custody path                 |
        +---------------+--------------+
                        |
             +----------+----------+
             |                     |
             v                     v
        redeem()              lockLong() /
                              closeShort()
```

---

# 58A. Modular integration rule

If Kuru changes its client API, order types, market-discovery method, or margin-account workflow, the preferred change surface is:

```text
@optara/kuru
```

not:

```text
RiskEngine
ClearingHouse
MarginVault
SettlementEngine
```

This is the main modularity benefit of the SDK architecture.

# 59. Final integration principle

> **Kuru trades the Optara long claim; Optara clears the obligation.**

The two systems must remain composable but accounting-independent.
