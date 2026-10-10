---
title-meta: "Optara Protocol Whitepaper"
author-meta: "Optara"
date-meta: "October 2026"
titlepage: false
geometry: margin=0.78in
fontsize: 10.5pt
colorlinks: true
linkcolor: "teal"
urlcolor: "blue"
header-includes:
  - \usepackage{graphicx}
---

\begin{center}
\vspace*{1.15in}
\includegraphics[width=2.45in]{/Users/mac/Documents/Lamsy/hackathon/Optara/brand/logo/optara-lockup-light-2000.png}

\vspace{0.85in}
{\Huge Optara Protocol Whitepaper}

\vspace{0.22in}
{\Large Portfolio-margined, cash-settled options for Monad}

\vspace{0.65in}
{\large October 2026}

\vfill
{\small Optara is a venue-agnostic options clearing protocol. Kuru is the first secondary-market venue.}
\end{center}

\newpage

\tableofcontents

\newpage

# Executive Summary

Optara is a decentralized options protocol designed for Monad. It lets users create, trade, margin, settle and redeem European options without requiring Optara itself to run a centralized matching engine.

In simple terms:

- A buyer pays a premium for the right to receive a cash payout if the market moves in their favor.
- A writer earns premium but must keep enough collateral in Optara to cover the risk.
- Optara checks the writer's margin using live prices and a volatility model.
- The long side of each option is represented by a normal ERC-20 token, so it can trade on Kuru or any other venue.
- At expiry, Optara settles everyone with one transparent price and one recovery ratio.

Optara's core design principle is:

```text
Optara clears and settles the risk.
Venues trade the long option tokens.
```

This means Kuru is important to the first version, but Optara is not dependent on Kuru for correctness. If Kuru is unavailable, users can still transfer option tokens, unwrap them into margin accounts, close shorts, settle expired options and redeem payouts.

The protocol is designed to support standard, uncapped European calls and puts. This is different from a fully collateralized capped option system. Uncapped calls can have very large payouts, so Optara uses portfolio margin, live spot oracles, signed implied-volatility surfaces, liquidation auctions, insurance and settlement windows.

Optara is not a promise that losses cannot happen. It is a system for making risk explicit, margined and orderly.

# Non-Technical Introduction

## What Is An Option?

An option is a financial contract whose payout depends on the future price of an asset.

A call option pays when the price goes up:

```text
call payout = max(settlement price - strike, 0)
```

A put option pays when the price goes down:

```text
put payout = max(strike - settlement price, 0)
```

The strike is the price level written into the contract. The expiry is the time when the option is settled. Optara options are European, which means they settle only at expiry. They are cash-settled, which means the payout is paid in a stablecoin such as USDC or USDT instead of delivering the underlying asset.

## Why Options Matter

Options allow people to express risk in a precise way.

- A trader can buy a call to get upside exposure while knowing the maximum loss upfront.
- A holder can buy a put to protect against downside.
- A market maker can write options and earn premium in exchange for taking risk.
- A sophisticated user can combine positions into spreads and hedges.

The challenge is that options need margin. If a writer sells an option, the protocol must make sure the writer can pay if the option finishes in the money. This is easy for capped options because the maximum payout is known. It is harder for standard uncapped calls because the price can theoretically rise far above the strike.

Optara solves this with portfolio margin.

## What Portfolio Margin Means

Portfolio margin looks at the whole account instead of one option at a time.

For example, suppose a user is short one ETH 4,500 call but long one ETH 5,000 call. The long 5,000 call reduces the risk of the short 4,500 call. A simple isolated-margin system may ignore that offset. A portfolio-margin system recognizes that the positions belong together and require less collateral than the short call alone.

Optara computes account health by asking:

```text
If the market moves sharply, how much could this account lose?
```

It tests multiple scenarios, including spot-price shocks, volatility shifts and time-to-expiry changes. The account must keep enough equity to pass those tests.

# The Problem

Onchain options face four hard problems.

First, fully collateralized systems are safe but capital-inefficient. If every option writer must post the full worst-case payout, many useful markets become too expensive to create.

Second, uncapped options are useful but risky. A naked call has no fixed maximum payout. The protocol must manage margin, liquidation and bad debt.

Third, order books are hard to build inside a derivatives protocol. Matching buyers and sellers, managing resting orders and building liquidity are specialized jobs. If the options protocol also runs the matching engine, the system becomes larger, more centralized and harder to audit.

Fourth, expiry settlement can become unfair if the protocol lets the first users redeem before all debts are known. Early redeemers could drain the pool before later redeemers arrive.

Optara's design addresses these directly:

- Portfolio margin improves capital efficiency.
- Liquidation and insurance manage writer default risk.
- ERC-20 option wrappers let external venues handle trading.
- A settlement window prevents first-come-first-served redemptions.

# Protocol Thesis

Optara separates three jobs that are often mixed together.

| Job | Handled By | Why |
|---|---|---|
| Risk creation and margin | Optara | The protocol must know who owes what. |
| Trading and price discovery | Kuru first, other venues later | Markets need liquidity and order-book UX. |
| Final settlement | Optara | Payoffs must be deterministic and fair. |

The result is a venue-agnostic options clearing layer.

```text
Writer deposits collateral into Optara
Writer mints option tokens
Writer sells tokens on Kuru or elsewhere
Buyer holds, trades, unwraps or redeems tokens
Optara margins the short and settles the option at expiry
```

This architecture allows Optara to gain distribution through Kuru without making Kuru a settlement dependency.

# Why Monad

Optara is built for Monad because options require frequent, low-latency, stateful actions: updating oracles, checking margin, creating series, buying through venues, settling accounts and liquidating risky positions.

Monad is an Ethereum-compatible Layer 1. Its developer documentation describes high throughput, fast blocks, fast finality, parallel execution, asynchronous execution, MonadDb and Ethereum RPC compatibility. The public Monad developer documentation describes Monad as EVM-compatible and designed for roughly 10,000 transactions per second, 300 ms block frequency and 600 ms finality. See Monad's developer documentation at <https://monad.docsbot.app/introduction/monad-for-developers> and the Monad developer GitHub profile at <https://github.com/monad-developers>.

For Optara, the important properties are:

- EVM compatibility: Solidity contracts, Foundry tooling, viem, wagmi and common Ethereum wallet flows can be reused.
- Low-latency execution: order-book trading, oracle updates and liquidation interactions benefit from fast confirmation.
- High throughput: many small option trades, order-book interactions and keeper operations are more realistic when blockspace is abundant.
- Monad-native ecosystem: Kuru is built for Monad, so Optara can integrate with a venue designed around the same execution environment.

Optara does not require Monad to make bad risk safe. It uses margin and settlement rules for that. Monad matters because it makes the intended user experience more practical: fast trading, frequent oracle refreshes and more responsive liquidation.

# Why Kuru

Kuru is the first trading venue for Optara because it is a Monad-native, fully onchain central limit order book. Kuru's public contract repository describes it as a fully onchain CLOB with backstop liquidity features. It combines an order book with AMM-style backstop liquidity and maintains price-time priority in its order book. Source: <https://github.com/Kuru-Labs/Kuru-contracts-dex-public>.

This matters for options because option tokens are not ordinary spot assets. They often need:

- visible bids and asks;
- maker quotes around fair value;
- limit orders;
- partial fills;
- price discovery across strikes and expiries;
- market-maker workflows.

Kuru's public SDK documentation also describes the core market-making flow: orders interact with an order book contract, balances are held in Kuru's margin account, and order lifecycle can be tracked through onchain events such as order creation, trades and cancellations. Source: <https://github.com/Kuru-Labs/kuru-sdk-py/blob/main/docs/MARKET_MAKING.md>.

Optara uses Kuru for trading, not for solvency.

Kuru prices do not set Optara margin. Kuru balances do not count as Optara collateral. A Kuru fill does not close an Optara short until the option token is burned or unwrapped in Optara. This boundary is intentional.

## Why Not Only Use Uniswap?

Uniswap-style AMMs can work for some ERC-20 assets, but options have changing fair value, expiry, strikes and asymmetric risk. Passive LPs must supply both option tokens and settlement assets, which means someone must first mint or acquire the option tokens. Without active market making, an AMM pool can become stale or thin.

Kuru's order-book model is a better first fit because market makers can quote option tokens directly, update prices as spot and volatility move, and manage orders by strike and expiry.

Uniswap or other AMMs can still be added later as optional venues. They should not be the core solvency layer.

# System Overview

Optara has these main parts:

| Component | Plain-Language Role |
|---|---|
| SubAccounts | User margin accounts holding cash and signed option balances. |
| OptionSeriesRegistry | Stores the immutable terms of each option series. |
| ExternalOptionWrapper | ERC-20 token representing a long option claim. |
| OptionClearing | Entry point for deposits, withdrawals, minting, wrapping, unwrapping and closing shorts. |
| PortfolioRiskManager | Computes account equity, initial margin and maintenance margin. |
| LiveSpotOracle | Provides current prices for margin and liquidation. |
| VolSurfaceOracle | Provides signed implied-volatility surfaces for option pricing. |
| SettlementOracle | Provides the final expiry price. |
| SettlementWindow | Finalizes expired groups, settles accounts and opens redemption. |
| LiquidationModule | Moves risky positions to liquidators through auctions. |
| FeeController | Charges and splits protocol fees. |
| InsuranceFund | Covers bad debt before holders take a haircut. |
| VenueRegistry | Records official venues and markets. |
| VenueRouter | Lets users trade through registered venues with fee and slippage protection. |
| KuruAdapter | Connects the router to Kuru market orders. |
| ProtocolControl | Roles, pausing and close-only controls. |
| UpgradeAdmin | Timelocked upgrades and implementation allowlists. |

The protocol boundary is simple:

```text
Inside Optara: margin, cash, internal longs, shorts, settlement and liquidation.
Outside Optara: wallet tokens, Kuru balances, OTC transfers and external venue orders.
```

Only assets inside Optara count toward margin.

# Option Lifecycle

## 1. Product Approval

Governance approves a product such as MON/USDC or ETH/USDC. A product defines the underlying asset, settlement asset, strike bounds, contract-size bounds, expiry bounds and risk configuration.

## 2. Series Creation

A trusted series creator creates a specific option series:

```text
underlying: MON
settlement asset: USDC
type: call
strike: 0.0245 USDC
contract size: 1 MON
expiry: timestamp
settlement rule: official expiry oracle
```

Series terms are write-once. They cannot be changed after creation.

## 3. Writer Deposits Collateral

The writer creates a subaccount and deposits the settlement stablecoin. Each subaccount uses one settlement asset.

## 4. Writer Mints External Longs

The writer calls `mintExternalLong`.

This does two things at once:

```text
writer's Optara account receives an internal short balance
writer's wallet receives ERC-20 long option tokens
```

The writer pays the seller fee at mint time. The protocol checks that the account stays healthy after the new short and after the fee.

## 5. Writer Sells The Tokens

The writer can sell the option tokens:

- through the Optara router into Kuru market orders;
- directly on Kuru by placing limit orders;
- OTC by transferring tokens;
- later through another approved venue.

The premium is not automatically collateral unless it is deposited back into Optara.

## 6. Buyer Holds Or Uses The Token

The buyer can hold the wrapper token, trade it, unwrap it into an Optara margin account, use it to close a short, or redeem it after settlement.

## 7. Expiry And Settlement

At expiry, the group is finalized with the settlement oracle price. Keepers settle all accounts in the group. Insurance covers any shortfall. A single recovery ratio is fixed. Only then can wrapper holders redeem.

# Position Model

Optara uses signed internal balances:

```text
+1 option = internal long
-1 option = internal short
```

Wrapper tokens are external long claims. They are ERC-20s and can move anywhere. But while a long is outside Optara, it does not reduce margin.

This rule avoids hidden risk:

```text
Wallet tokens do not count as margin.
Kuru balances do not count as margin.
Only internal Optara positions and cash count.
```

If a writer buys back option tokens and wants to close a short, the writer must burn those wrapper tokens through `closeShortWithWrapper`.

# Margin System

Optara measures an account with three values:

| Term | Meaning |
|---|---|
| Equity | Cash plus marked internal longs minus marked internal shorts. |
| Initial margin | Equity required to open new risk or withdraw. |
| Maintenance margin | Equity required to avoid liquidation. |

An account can be:

| State | Condition | Meaning |
|---|---|---|
| Healthy | equity >= initial margin | The account can open risk and withdraw. |
| Close-only | maintenance margin <= equity < initial margin | The account can reduce risk but not open more. |
| Liquidatable | equity < maintenance margin | Anyone can start liquidation. |
| Insolvent | equity < 0 after available remedies | Shortfall may hit insurance and recovery ratio. |

The risk manager prices every option using a Black-76 style model. It then runs stress scenarios. Each scenario shifts market variables such as spot, implied volatility and time. The worst equity drop becomes the margin requirement.

This is the source of Optara's capital efficiency. Writers do not post full worst-case collateral for every position. Instead, they post enough collateral for defined stress scenarios, with liquidation and insurance as backstops.

# Oracles

Optara uses three separate oracle roles.

| Oracle | Used For | Not Used For |
|---|---|---|
| LiveSpotOracle | Margin, liquidation, moneyness and fee marks. | Expiry settlement. |
| VolSurfaceOracle | Option pricing for margin and liquidation. | Final payoff. |
| SettlementOracle | Final price at expiry. | Live margin. |

These are deliberately separate.

Kuru prices are never used as oracle inputs. This prevents circular margin, where the venue being margined would also define the margin requirement.

## Live Spot

The v1 design uses Pyth-style pull feeds for live spot. A caller includes signed price updates in the transaction. The oracle checks freshness, confidence bands and explicit pair configuration.

## Volatility Surface

Optara needs implied volatility to price options for margin. Monad currently has spot oracle infrastructure, but there is no obvious public, ready-made implied-volatility surface feed for every Optara product. Therefore Optara uses a signed volatility-surface oracle.

A surface report includes product identity, sequence number, validity window, tenors, at-the-money total variance, IV bounds, confidence and a Merkle root of grid values. Approved publishers sign the report using EIP-712. The contract checks quorum, freshness, sequence, IV movement limits and calendar sanity.

For ETH and BTC, publisher inputs can include specialist volatility data and liquid centralized option markets. For MON, volatility is synthetic at launch: realized volatility, proxy assets and publisher judgment. The UI must disclose this.

## Settlement Price

The settlement oracle fixes one price at expiry using a deterministic round-in-force rule. A caller cannot choose the favorable price after the fact. If no valid price arrives, the group enters an oracle-stalled state rather than inventing a price.

# Trading And Venues

Optara's long option tokens are normal ERC-20 tokens. That makes the protocol composable.

The official route is:

```text
buyer -> VenueRouter -> KuruAdapter -> Kuru market -> option tokens
```

The router gives users:

- deadline protection;
- slippage protection;
- maximum Optara buyer fee;
- maximum venue fee;
- exact refund of unspent premium where possible.

But direct trading is still possible:

```text
user wallet -> Kuru MarginAccount -> Kuru limit bid or ask
```

In that direct Kuru path, Optara contracts are not called during order placement. Optara comes in before and after the order:

- before: Optara creates the option token and writer supply;
- after: the user withdraws filled tokens from Kuru and uses Optara to unwrap, close or redeem.

Direct Kuru limit orders currently bypass Optara's buyer fee. This is a deliberate composability tradeoff. Charging every direct trade would require a less standard token, a custodial adapter, or a protocol-wide payout fee.

# Fees

Optara has protocol fees and venue fees.

| Fee | Paid By | When | Recipient |
|---|---|---|---|
| Seller fee | Writer | When minting external long tokens | Split across insurance, treasury and keeper reserve. |
| Buyer fee | Buyer | When buying through the official VenueRouter | Split across insurance, treasury and keeper reserve. |
| Liquidation penalty | Liquidated account | During liquidation | Insurance fund. |
| Venue fee | Trader | On Kuru or another venue | The venue. |
| Oracle update fee | Caller | When submitting provider data | Oracle provider. |

The default fee split in the specification is:

```text
60% insurance fund
30% treasury
10% keeper reserve
```

Fees are charged with user-set maximums so users are not surprised if parameters or market conditions change between quote and transaction.

# Insurance Fund

The insurance fund exists because portfolio margin is not full collateralization. Extreme price moves can create bad debt.

Losses are absorbed in this order:

```text
1. the short account's collateral
2. liquidation
3. insurance fund
4. pro-rata recovery ratio for long holders
```

The insurance fund is funded by:

- a launch seed deposit from governance, grants or treasury;
- a share of seller fees;
- a share of buyer fees;
- liquidation penalties;
- swept settlement dust.

New risk in a settlement asset is blocked unless insurance and keeper reserves meet their configured minimums.

# Liquidation

Liquidation protects the protocol when an account falls below maintenance margin.

Optara's main liquidation path is a Dutch auction over a slice of the risky portfolio. A liquidator takes a fraction of the positions and must have its own healthy account after receiving them. The liquidated account pays or receives the mark value of the slice adjusted by the auction discount.

The important rule is:

```text
The liquidator funds the risk it takes.
The failing account does not pay the liquidator's margin requirement.
```

This makes liquidation improve account health instead of draining already-low collateral.

There is also a wrapper-burn path. If a liquidator holds option tokens matching a short, the liquidator can burn them to reduce the risky account's short. This path is useful when wrappers are liquid, but it is not required. Portfolio-slice liquidation can work even if Kuru liquidity is thin.

# Settlement

Settlement is designed to avoid first-come-first-served payout races.

The lifecycle is:

```text
ACTIVE -> EXPIRED -> FINALIZED -> ALL_SETTLED -> REDEEMABLE
```

At finalization, the settlement price is fixed. Redemption is still closed.

Then keepers settle every account in the group. Each account's longs and shorts are netted across all series in that group. Accounts that owe money pay what they can. Accounts owed money receive claims.

After all participants are settled, the protocol computes one recovery ratio:

```text
recovery ratio = min(1, available pool / total claims)
```

If everyone is solvent and insurance is not needed, the ratio is 100%. If bad debt exceeds insurance, every long holder in the group receives the same percentage of their payout. Redemption order does not matter.

# User Journeys

## Buyer Journey

1. Choose a market, direction, strike and expiry.
2. Review the premium, fair-value comparison, max loss and breakeven.
3. Buy through the Optara router on Kuru, or place a direct Kuru bid.
4. Hold the wrapper token.
5. Before expiry, sell it, transfer it, unwrap it into an account, or use it to close a short.
6. After expiry and settlement, redeem for cash payout.

The buyer's maximum loss on the option purchase is the premium paid. The buyer still faces recovery-ratio risk if writers default beyond insurance.

## Writer Journey

1. Create or choose a subaccount.
2. Deposit settlement stablecoin.
3. Choose a series to write.
4. Preview margin, liquidation risk, seller fee and write room.
5. Mint external long tokens.
6. Sell tokens on Kuru or hold them for later.
7. Monitor health.
8. Deposit more collateral, buy back tokens and close, or allow the position to settle.

The writer earns premium only after the option tokens are actually sold. Minting alone creates the short and the tokens; it does not magically create buyer premium.

## Market Maker Journey

1. Maintain funded Optara subaccounts for margin.
2. Mint option tokens or buy tokens externally.
3. Quote bid and ask markets on Kuru.
4. Use Optara fair value and Greeks-like exposure analytics to manage inventory.
5. Withdraw filled tokens from Kuru when needed.
6. Unwrap tokens into Optara to hedge shorts or close positions.

## Keeper Journey

Keepers call permissionless maintenance functions:

- refresh oracle data;
- finalize expired groups;
- settle participant accounts;
- compute recovery ratios;
- monitor auctions and liquidations.

Keeper rewards come from the keeper reserve. If the reserve is empty, the functions are still permissionless, but rewards may be zero.

## Liquidator Journey

1. Watch accounts below maintenance margin.
2. Start auctions.
3. Estimate the profitability of taking a slice.
4. Take risk into a funded liquidator account.
5. Hedge, close or carry the received positions.

Liquidators are not trusted actors. They are economically incentivized participants.

# Governance And Upgradeability

Optara's core modules are upgradeable through timelocked governance. This is necessary because the protocol has complex risk models, oracle integrations and venue integrations. However, upgradeability is limited by protected storage rules.

The following must never be rewritten:

- series terms;
- wrapper token address;
- finalized settlement price;
- recovery ratio;
- redeemed amounts and credited claims.

Roles include:

| Role | Purpose |
|---|---|
| Governance | Upgrades, parameters, product approvals, fees and treasury actions through timelock. |
| Guardian | Pause, close-only, emergency mode and adapter disabling. |
| Risk admin | Make parameters more conservative quickly. |
| Series creator | Create series inside approved bounds. |
| Oracle admin | Configure oracle sources. |
| Venue admin | Register verified venue markets. |
| Account owner | Manage their own account. |
| Operator | Act for an account if approved by its owner. |

Users must understand that upgradeability creates governance trust. Timelocks and public monitoring reduce this risk, but they do not remove it.

# Security Model

Optara's main security goals are:

1. Risk cannot be opened on stale or forged data.
2. Venues cannot alter Optara accounting.
3. Settlement cannot be drained by early redeemers.
4. Liquidation must improve account health.
5. Core computations must be bounded in gas.
6. Protected data cannot be rewritten by upgrades.

Important mitigations include:

- EIP-712 signed surface reports with quorum.
- Spot oracle freshness and confidence checks.
- Direction-aware stale volatility handling.
- Product close-only mode when data is weak or stale.
- One recovery ratio per settlement group.
- Insurance seed gating before new risk opens.
- Non-reentrant state-changing functions.
- Exact token transfer accounting for settlement assets.
- Event-based indexer reconciliation.
- Upgrade timelocks and code-hash allowlists.

Optara should be audited before mainnet production use. The highest-risk areas are the option-pricing library, volatility-surface oracle, margin engine, liquidation accounting, settlement accounting and venue adapters.

# Key Risks

## Writer Risk

Writers can be liquidated. A writer who sells options and withdraws or fails to maintain margin can lose collateral.

## Buyer Recovery Risk

Buyers can receive less than the full payoff if bad debt exceeds the insurance fund.

## Oracle Risk

Spot, volatility and settlement data are critical. If they fail, new risk can stop, liquidations may be delayed, or settlement may stall.

## Governance Risk

Contracts are upgradeable. Users rely on timelocks, multisigs and monitoring.

## Venue Liquidity Risk

Kuru may have thin order books for some strikes or expiries. Users may be unable to exit at a fair price before expiry.

## Synthetic MON Volatility Risk

MON may not have a mature listed options market. MON volatility surfaces are therefore more judgment-driven at launch and should use conservative floors, shorter report lifetimes and lower open-interest caps.

## Stablecoin Risk

Settlement assets such as USDC or USDT can face depeg, freeze or issuer risk. Each subaccount is tied to one settlement asset.

# Glossary

| Term | Meaning |
|---|---|
| Call | Option that pays when price is above strike. |
| Put | Option that pays when price is below strike. |
| Strike | Price level used to calculate payoff. |
| Expiry | Time when the option payoff is fixed. |
| Premium | Price paid for the option. |
| Writer | User who creates the option and owes the payoff. |
| Buyer | User who owns the long option claim. |
| Wrapper | ERC-20 token representing a long option claim. |
| Subaccount | Optara margin account. |
| Equity | Cash plus marked positions. |
| Initial margin | Required equity to open risk or withdraw. |
| Maintenance margin | Required equity to avoid liquidation. |
| Recovery ratio | Percentage of payoff paid after settlement if bad debt exists. |
| Keeper | Bot or user who calls maintenance functions. |
| Surface publisher | Service that signs implied-volatility reports. |
| Venue | Place where wrapper tokens trade, such as Kuru. |

# References

Protocol documentation in this repository:

- `docs/README.md`
- `docs/PRD.md`
- `docs/ARCHITECTURE.md`
- `docs/PROTOCOL_SPEC.md`
- `docs/MARGIN_AND_RISK.md`
- `docs/ORACLES.md`
- `docs/SETTLEMENT.md`
- `docs/LIQUIDATION.md`
- `docs/FEES.md`
- `docs/VENUES_AND_KURU.md`
- `docs/ACCESS_CONTROL.md`
- `docs/SECURITY.md`
- `docs/INDEXER_AND_KEEPERS.md`

External sources:

- Monad developer documentation: <https://monad.docsbot.app/introduction/monad-for-developers>
- Monad "Why Monad" documentation: <https://monad.docsbot.app/introduction/why-monad>
- Monad Developers GitHub profile and network summary: <https://github.com/monad-developers>
- Kuru public contracts: <https://github.com/Kuru-Labs/Kuru-contracts-dex-public>
- Kuru SDK: <https://github.com/Kuru-Labs/kuru-sdk>
- Kuru market-making SDK documentation: <https://github.com/Kuru-Labs/kuru-sdk-py/blob/main/docs/MARKET_MAKING.md>

# Disclaimer

This whitepaper is an architectural and product description. It is not legal, tax, accounting, investment or financial advice. It does not guarantee protocol safety, market liquidity, oracle availability, stablecoin solvency, regulatory compliance or future returns. Users should understand the risks of options, leverage, smart contracts, governance, oracles and decentralized venues before interacting with the protocol.
