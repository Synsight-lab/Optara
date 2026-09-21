# Premium Guard and Kuru

Premium is what a buyer pays a seller for an option token before expiry. In V1 it is set only by voluntary trades, mainly on Kuru. It never affects collateral, settlement, payouts or residuals.

```text
premium is an input to a Kuru trade, never to the vault
```

## Two Layers of Buyer Protection

Be exact about what protects a buyer. V1 has **no protocol-owned trade router**, so nothing forces a buyer's trade through Optara code.

**Layer 1: hard, enforced by Kuru on the order itself.**

- A Kuru limit buy cannot fill above its limit price.
- A Kuru order with a minimum output cannot deliver less than that.

The official frontend must set both on every buy, computed from the buyer's **all-in** cost (premium plus Kuru fee), not the gross premium.

**Layer 2: advisory, enforced by the official frontend using `PremiumExecutionGuard`.**

The guard checks whether a proposed trade is inside sensible bounds. It cannot bind a user who trades directly against Kuru, and user-facing copy must never say otherwise.

> Optara guarantees collateral and settlement. Kuru enforces the order's price and minimum output. Optara does not guarantee that a user gets a good premium.

If a protocol-owned router is added later, it must call the guard and revert on any failed check, which turns Layer 2 into an on-chain guarantee for that router's users.

## `PremiumExecutionGuard`

A read-only contract. It holds no funds, executes no trades and needs no approvals. Every function is `view`.

### Purpose

- Confirm the series is official and not expired.
- Confirm the Kuru market is the registered one.
- Price the option against Chainlink-based bounds.
- Compare fee-inclusive **totals** against those bounds and against the buyer's own limit.

### Constructor and parameters

```solidity
constructor(address factory_)
```

Guard parameters, all changeable by `ADMIN` only (the guard asks `factory.hasRole`):

```solidity
uint16 public sellerDiscountToleranceBps;   // how far below intrinsic value a sell may be, <= 10_000
uint32 public maxReferenceAge;              // seconds; max age of the Chainlink reference price
uint16 public maxVenueFeeBps;               // max Kuru taker or maker fee the guard will accept, <= 10_000
```

These are advisory settings, not series economics, so they may change.

### Types

```solidity
enum Reason {
    OK,
    NOT_OFFICIAL_SERIES,
    EXPIRED,
    WRONG_MARKET,
    DEADLINE_PASSED,
    VENUE_FEE_TOO_HIGH,
    ORACLE_UNAVAILABLE,
    EMPTY_RANGE,
    ABOVE_BUYER_LIMIT,
    ABOVE_HARD_MAX,
    BELOW_ACCEPTABLE_MIN,
    ZERO_AMOUNT
}

struct BuyCheck {
    bytes32 seriesId;
    address market;                // the Kuru market the trade will use
    uint256 optionAmount;          // option raw units
    uint256 grossPremium;          // quote raw units, TOTAL for optionAmount, from the Kuru quote
    uint16  takerFeeBps;           // Kuru taker fee, read by the frontend from the market
    uint256 buyerMaxTotalPremium;  // quote raw units, all-in cap the buyer chose
    uint256 deadline;              // unix seconds
}

struct SellCheck {
    bytes32 seriesId;
    address market;
    uint256 optionAmount;
    uint256 grossPremium;          // TOTAL for optionAmount
    uint16  makerFeeBps;           // Kuru maker-side value
    bool    makerFeeIsRebate;
    uint256 deadline;
}

struct CheckResult {
    bool valid;
    Reason reason;
    uint256 acceptableMinPremium;  // TOTAL, quote raw units
    uint256 hardMaxPremium;        // TOTAL, quote raw units
    uint256 allInCost;             // buy only
    uint256 netProceeds;           // sell only
    uint256 referencePrice;        // PRICE_SCALE
}
```

Every premium figure is a **total** for `optionAmount` in quote raw units. Per-option figures may be shown to users for display but are never compared against a bound. Comparing a per-option number against a total bound is wrong by a factor of the option amount and fails open, because a per-option cost sits below a total bound for any size above one whole option.

### Functions

```solidity
function checkBuy(BuyCheck calldata c)  external view returns (CheckResult memory);
function checkSell(SellCheck calldata c) external view returns (CheckResult memory);

function setSellerDiscountToleranceBps(uint16 v) external;   // ADMIN
function setMaxReferenceAge(uint32 v) external;              // ADMIN
function setMaxVenueFeeBps(uint16 v) external;               // ADMIN
```

Both checks return a result instead of reverting, so a frontend can show the reason. A future router must revert on `valid == false`.

### Common checks (both functions)

In this order; the first failure sets `reason` and returns `valid = false`:

1. `factory.vaultOf(seriesId)` is nonzero, else `NOT_OFFICIAL_SERIES`.
2. `block.timestamp < expiry`, else `EXPIRED`.
3. `market != address(0)` and `market == factory.kuruMarketOf(seriesId)`, else `WRONG_MARKET`.
4. `block.timestamp <= deadline`, else `DEADLINE_PASSED`.
5. The venue fee bps is at most `maxVenueFeeBps`, else `VENUE_FEE_TOO_HIGH`.
6. `ChainlinkAnchor.tryLatestPrice(feed, feedDecimals, maxReferenceAge)` is ok, else `ORACLE_UNAVAILABLE`.
7. Compute `acceptableMinPremium` and `hardMaxPremium` (below). If `acceptableMinPremium > hardMaxPremium`, the range is empty: `EMPTY_RANGE`.

### Bounds

Let `R` be the reference price, `K` the strike, `C` the contract size, `a` the option amount. All results are totals in quote raw units.

```text
E_up(a)   = mulDivUp  (a, C, optionScale)
E_down(a) = mulDivDown(a, C, optionScale)

callIntrinsic = mulDivUp(E_up(a),   max(R - K, 0), uqScale)
putIntrinsic  = mulDivUp(E_up(a),   max(K - R, 0), uqScale)

callHardMaxGross = mulDivDown(E_down(a), R, uqScale)
putHardMaxGross  = mulDivDown(E_down(a), K, uqScale)

hardMaxPremium       = mulDivDown(hardMaxGross, BPS_SCALE - exerciseFeeBps, BPS_SCALE)
acceptableMinPremium = mulDivUp(intrinsic, BPS_SCALE - sellerDiscountToleranceBps, BPS_SCALE)
```

Rounding rules, which must not be changed: **every step rounds in the direction that rejects more.** Minimums round up and maximums round down. Do not share one rounded `E(a)` between the two bounds, because they need it rounded in opposite directions. Use `Math.mulDiv` with an explicit rounding mode at every step.

`hardMaxPremium` is net of `exerciseFeeBps` because a holder receives the gross payout minus that fee. The seller floor is not adjusted, because the writer never pays that fee.

**What these bounds are and are not.** They are conservative rails around today's reference price. They are not option pricing and not proofs. In particular, a call's payout in quote terms is unbounded if the underlying rallies, so a premium above `hardMaxPremium` for a call is "economically suspicious for a simple routed buy", not "impossible to profit". Never describe them as guarantees.

**Empty range.** If the seller floor is above the buyer ceiling (possible on deep in-the-money options when `sellerDiscountToleranceBps < exerciseFeeBps`), no price is acceptable. The result is `EMPTY_RANGE` and the frontend must fall back to a manual limit order with a warning. Never resolve it by preferring one bound. Launch with `sellerDiscountToleranceBps >= MAX_EXERCISE_FEE_BPS` (100) to keep this rare.

### `checkBuy` extra steps

```text
takerFee    = ceilDiv(grossPremium * takerFeeBps, BPS_SCALE)          // rounds UP
allInCost   = grossPremium + takerFee

if allInCost > buyerMaxTotalPremium: ABOVE_BUYER_LIMIT
if allInCost > hardMaxPremium:       ABOVE_HARD_MAX
```

### `checkSell` extra steps

```text
if makerFeeIsRebate:  netProceeds = grossPremium + floor(grossPremium * makerFeeBps / BPS_SCALE)   // rebate rounds DOWN
else:                 netProceeds = grossPremium - ceilDiv (grossPremium * makerFeeBps, BPS_SCALE) // fee rounds UP

if netProceeds < acceptableMinPremium: BELOW_ACCEPTABLE_MIN
```

Both branches round toward a lower `netProceeds`, so the seller check can only become stricter. Until the maker-side value is verified on the deployed market (see below), the frontend must pass `makerFeeIsRebate = false`.

## What the Guard Does Not Do

- No depth, spread, price-impact or quote-age checks. Those need Kuru order-book reads and live in the frontend.
- No trade execution, no approvals, no funds.
- No settlement input. Nothing here affects the vault.

## Frontend Responsibilities

The frontend and backend do everything the guard cannot. These are the rules for the official UI.

### Identity

- Show a token as official only if `factory.isOptionToken(token)` is true. Names, symbols and Kuru listings prove nothing.
- Show a Kuru market as official only if it equals `factory.kuruMarketOf(seriesId)`.
- Because anyone can create a series, list only series with open interest or a Kuru market, and mark any series with `mintPaused == true` as frozen and stop offering it for minting.

### Buy flow

1. Verify the series and market as above.
2. Walk the Kuru order book for the requested size. If depth is less than the size, refuse the simple route. Never extrapolate from the last level.
3. Refuse the simple route if spread, price impact or quote age exceed configured limits. Fall back to a manual limit order with warnings.
4. Read the market's taker fee and compute `allInCost`. Call `guard.checkBuy`. Refuse the simple route on any failure.
5. Let the buyer choose a **maximum total cost**, a **minimum option amount out** and a **deadline**.
6. Build the Kuru order so that Kuru itself enforces the limit: derive the limit price and minimum output from the buyer's all-in cap, so that `price * size + fee` cannot exceed it.
7. Submit. If the deadline has passed, do not submit.

### Sell flow (posting an ask)

1. Read the maker-side fee value and call `guard.checkSell`.
2. Warn or block below `acceptableMinPremium`, depending on product choice (decision D8).

### Fee display

Always show these as separate lines, never one blended number:

- Writer: required collateral, mint fee, total to pay.
- Buyer: gross premium, Kuru taker fee, all-in cost, and the exercise fee rate that applies if the option finishes in the money.
- Seller: gross premium, Kuru maker fee or rebate, net proceeds.
- Holder: gross payout, exercise fee, net payout.

### Required warnings

- Kuru liquidity is not guaranteed and a position may not be sellable before expiry.
- The Kuru market price is not the settlement price. Settlement uses Chainlink at expiry.
- The guard's range is advice, not a guarantee, and does not protect trades made directly on Kuru.
- The deadline is enforced by the frontend, and a resting Kuru limit order may stay open until cancelled.
- Tokens inside a Kuru order or margin account are not paid out automatically. Withdraw them to the wallet before or after expiry, then redeem.

### Automatic payout

After settlement a keeper calls `vault.payout(accounts)`, so wallet holders and writers are paid without sending a transaction. Nothing needs to be enabled. Tell users that smart-contract wallets and contracts are not paid automatically and must call `redeem` or `claimWriterResidual` themselves, and that anyone can always do so.

## Kuru Notes

The contracts never call Kuru, so none of this affects safety. It affects the frontend and the UI copy.

### Creating a market

Anyone can create the market through the Kuru Router's `deployProxy`, with the option token as the base asset and the quote asset as the quote, market type `NO_NATIVE` for two ERC-20s. Kuru market parameters (`sizePrecision`, `pricePrecision`, `tickSize`, `minSize`, `maxSize`, `takerFeeBps`, `makerFeeBps`, `kuruAmmSpread`) are chosen by whoever deploys the market. Calibrate them per pair so normal orders never round to zero size and ticks are usable for option-sized premiums. Then `ADMIN` calls `factory.setKuruMarket(seriesId, market)` after confirming the market's base and quote assets.

Kuru addresses listed in Kuru's public docs (re-verify before use):

```text
Monad mainnet   Router (market factory)  0xd651346d7c789536ebf06dc72aE3C8502cd695CC
Monad testnet   Router                   0x7EFbE105Ca7415dE98F96622173458ac1c054630
```

### Fee facts that are not yet verified

Kuru's public docs do not state how the taker fee or maker-side value is applied. Until measured on the deployed market, the frontend must assume the worst case:

- Treat the taker fee as **added to the quote spent** (buyer pays more), and always enforce a minimum output too, which also covers the case where the fee is instead taken from the base received.
- Treat the maker-side value as a **fee**, not a rebate.
- Add the market's AMM spread as extra cost whenever a fill can reach AMM liquidity.

Verify by testing on a Monad testnet market before the frontend goes live: post an ask, take it with a market buy, and record the taker's quote spent and base received and the maker's proceeds, then repeat with a fill that reaches AMM liquidity. Keep the results in the launch notes and replace the assumptions with the measured behavior. This is a frontend launch item, not a contract blocker.

Kuru does not enforce a deadline on swaps, and nothing shows that resting limit orders expire. Treat the deadline as a frontend rule.
