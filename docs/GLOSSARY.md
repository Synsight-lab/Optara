# Glossary

Plain-language definitions of every term in these docs. Code names are in `backticks`.

## Options basics

| Term | Meaning |
|---|---|
| **Option** | A contract that pays the holder money at expiry depending on the price of an asset. |
| **Call** | Pays `max(S − K, 0)` per unit of underlying at expiry. Profits when the price goes up. Uncapped. |
| **Put** | Pays `max(K − S, 0)` per unit of underlying at expiry. Profits when the price goes down. At most `K`. |
| **European** | Can only be settled at expiry, never earlier. |
| **Cash-settled** | Pays the payoff in a stablecoin. No one delivers the underlying asset. |
| **Underlying** | The asset whose price decides the payoff, e.g. ETH, BTC, MON. |
| **Strike (`K`)** | The price the payoff is measured against. |
| **Expiry** | The timestamp at which the option stops trading and its payoff is fixed. |
| **Contract size (`CS`)** | How many units of the underlying one whole option covers (e.g. 1 ETH or 0.1 ETH). |
| **Premium** | The price a buyer pays a seller for an option. Set by the market, never by Optara. |
| **Writer / seller** | The person who creates an option and owes its payoff. Holds a **short**. |
| **Buyer / holder** | The person who owns the option and receives its payoff. Holds a **long**. |
| **Uncapped** | No maximum payout. A call's payoff grows without limit as the price rises. |
| **Spread** | Short one option and long another of the same type, e.g. short 4,500 call + long 5,000 call. Its worst case is limited. |
| **Implied volatility (IV)** | The volatility number that, put into a pricing model, reproduces market option prices. Higher IV = more valuable options. |
| **Volatility surface** | IV for every combination of expiry and strike. |
| **Mark / mark value** | What Optara's pricing model says a position is worth right now. |

## Optara objects

| Term | Meaning |
|---|---|
| **Optara PM** | This protocol. PM = portfolio margin. |
| **Subaccount** | An Optara margin account, identified by `accountId`. Has an owner, optional operators, one settlement asset, a cash balance, and signed option balances. |
| **Settlement asset** | The stablecoin a series is quoted, margined and paid in (e.g. USDC). Each subaccount uses exactly one. |
| **Series** | One specific option: underlying, settlement asset, call/put, strike, contract size, expiry, oracle config. Identified by `seriesId`. |
| **Product** | A pair (underlying, settlement asset), e.g. ETH/USDC. One volatility surface per product. |
| **Settlement group (`groupId`)** | All series with the same underlying, settlement asset, expiry and settlement oracle config. They share one settlement price and settle together. |
| **Risk bucket** | All positions of one subaccount on one underlying. Margin is computed per bucket and summed. Liquidation works one bucket at a time. |
| **Signed balance** | A subaccount's quantity in a series: `+` = long, `−` = short. |
| **Wrapper (token)** | The ERC-20 token for a series' long claim (`ExternalOptionWrapper`). One per series. 18 decimals. |
| **Mint external long** | Open a short in your subaccount and receive the same quantity of wrapper tokens. The main way options are created. |
| **Wrap** | Turn an internal long into wrapper tokens. |
| **Unwrap** | Turn wrapper tokens into an internal long. |
| **Close short with wrapper** | Return wrapper tokens to cancel part of your short. |

## Margin and risk

| Term | Meaning |
|---|---|
| **Equity** | Cash plus the mark value of internal longs minus the mark value of internal shorts. What the account would be worth if closed at mark. |
| **Scenario** | A hypothetical market move: shift spot, shift IV, shift time. |
| **Scenario loss** | How much equity falls in a scenario. |
| **Initial margin (IM)** | Equity needed to open new risk or withdraw. Largest loss across the initial stress set, plus a buffer. |
| **Maintenance margin (MM)** | Equity needed to avoid liquidation. Largest loss across a milder stress set. Always ≤ IM. |
| **Healthy** | Equity ≥ IM. Everything allowed. |
| **Close-only** | MM ≤ equity < IM. Only actions that reduce risk are allowed. |
| **Liquidatable** | Equity < MM. Anyone may start a liquidation auction. |
| **Insolvent** | Equity < 0 even after liquidation. The shortfall becomes bad debt. |
| **Risk-increasing action** | Anything that can lower equity minus IM: minting, wrapping a long out, withdrawing, moving a long away. Needs fresh oracle data and a passing IM check. |
| **Risk-reducing action** | Depositing, unwrapping, closing a short. Always allowed, no oracle data needed. |
| **Product close-only** | A product whose oracle data is stale or untrustworthy. No new risk on it until fixed. |

## Oracles

| Term | Meaning |
|---|---|
| **Live spot oracle** | Current price of the underlying, used for margin and liquidation only (`LiveSpotOracle`). |
| **Volatility-surface oracle** | Signed IV surface reports, used for pricing (`VolSurfaceOracle`). |
| **Surface report** | One signed snapshot of a product's IV surface: header + Merkle root of grid points. |
| **Surface publisher** | An approved off-chain service that computes and signs surface reports. |
| **Quorum** | The minimum number of distinct publisher signatures required on a report. |
| **Total variance (`w`)** | `IV² × time to expiry (in years)`. The surface stores this instead of IV. |
| **Log-moneyness (`k`)** | `ln(K / F)`: how far a strike is from the forward price. |
| **Settlement oracle** | The oracle that fixes the single price at expiry (`SettlementOracle`). Separate from the live spot oracle. |
| **Round-in-force** | The settlement rule: the Chainlink round that was current at the observation time. |
| **Stale** | Data older than its allowed age. Stale data blocks new risk. |
| **ORACLE_STALLED** | A group whose settlement price did not arrive by its deadline. Nothing is redeemed until a valid price arrives. |

## Liquidation, settlement, insurance

| Term | Meaning |
|---|---|
| **Dutch auction** | An auction whose reward to the liquidator starts at 0 and rises over time until someone accepts. |
| **Slice** | A fraction (`sliceBps`) of every position in a risk bucket, moved to a liquidator. |
| **Discount / bonus** | The liquidator's reward, as a fraction of the slice's maintenance margin. |
| **Liquidation penalty** | A fee the liquidated account pays to the insurance fund. |
| **Bad debt** | A loss no account's collateral can cover. |
| **Insurance fund** | Protocol-owned stablecoin that covers bad debt before anyone's payout is reduced. |
| **Settlement window** | The period after finalization during which keepers settle every account in a group. |
| **Recovery ratio** | The fraction of their payoff that long holders receive. 100% unless bad debt exceeds the insurance fund. The same for everyone in a group. |
| **Redemption** | Burning wrapper tokens for their payoff after the recovery ratio is fixed. |
| **Keeper** | Anyone running a bot that calls permissionless maintenance functions (settle, finalize, liquidate) for a small reward. |

## Fees and venues

| Term | Meaning |
|---|---|
| **Seller (open) fee** | Optara fee charged when minting wrappers, as a percentage of the minted options' mark value. |
| **Buyer (acquisition) fee** | Optara fee charged when buying through Optara's official router, as a percentage of the premium. |
| **Venue fee** | A fee charged by the trading venue (e.g. Kuru). Not an Optara fee. |
| **Venue** | A place where wrapper tokens trade: Kuru, a future in-house matcher, Uniswap, or a plain transfer. |
| **VenueRouter** | Optara's official contract for buying and selling through venues with fee and slippage limits. |
| **Adapter** | A venue-specific contract the router calls (e.g. `KuruAdapter`). |

## Units

| Term | Meaning |
|---|---|
| **WAD** | Fixed-point with 18 decimals: `1e18` = 1.0. Used for prices, strikes, IV, contract size, quantities. |
| **Native units** | A token's own integer units, e.g. USDC has 6 decimals, so 1 USDC = 1,000,000. Cash balances use native units. |
| **bps** | Basis points. 10,000 bps = 100%. |
