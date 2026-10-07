# Venues and Kuru

Wrapper tokens are standard ERC-20s, so they can trade anywhere. Optara offers an **official router** with fee and
slippage protection, and treats every venue as optional. Kuru is the first venue.

**Rule:** venues trade external long claims; Optara clears the obligation.

## 1. Boundary rules (must always hold)

| Statement | Meaning |
|---|---|
| Kuru fill ≠ Optara close | Buying on Kuru doesn't reduce a short until the wrapper is burned in Optara |
| Kuru balance ≠ Optara margin | Stablecoin or wrappers inside Kuru never count as collateral or hedges |
| Kuru price ≠ oracle | Kuru prices are never used for margin, liquidation or settlement |
| Kuru venue fee ≠ Optara fee | Shown and limited separately |
| Kuru down ≠ Optara down | Minting, transfers, unwrap, close, liquidation, settlement and redemption all work without Kuru |

## 2. Modes

| Mode | Status at launch |
|---|---|
| Kuru through `KuruAdapter` | Enabled |
| Plain ERC-20 transfer / OTC | Always possible |
| `InhouseMatchingAdapter` | Future, disabled |
| `UniswapAdapter` | Future, disabled |

## 3. VenueRegistry

Stores the adapter per venue and the one official market per (venue, series):

```solidity
struct VenueMarket {
    bytes32 venueId;      // e.g. keccak256("KURU")
    address market;       // venue market address
    bytes32 seriesId;
    address base;         // = the series wrapper (checked)
    address quote;        // = the series settlement asset (checked)
    uint256 chainId;      // block.chainid at registration
    MarketStatus status;  // INACTIVE, ACTIVE, or EXPIRED once the series expires
    bytes   metadata;     // tick size, lot size, etc. (display only)
}
```

- `registerAdapter(venueId, adapter)` — governance (timelocked). `adapter.venueId()` must equal `venueId`
  (`InvalidAdapter(1)`); one adapter per venue (`InvalidAdapter(2)`). Registered **disabled**
  (`AdapterRegistered`, `AdapterEnabled(false)`).
- `setAdapterEnabled(venueId, enabled)` — enabling: governance; disabling: guardian, venue admin or governance,
  instantly (`AdapterEnabled`).
- `registerMarket(venueId, market, seriesId, metadata)` — role `VENUE_ADMIN`. Reads `(base, quote)` from the
  **adapter**, which reads the venue's own records (Kuru: its router's `verifiedMarket`), never the caller and never
  the market contract itself, so a contract that merely claims the right tokens fails. Requires `base == wrapper`
  (`InvalidMarket(1)`), `quote == settlementAsset` (`InvalidMarket(2)`), a new (venue, series) pair
  (`InvalidMarket(3)`) and an unexpired series (`InvalidMarket(4)`). Stores `chainId = block.chainid`. Event
  `MarketRegistered`.
- `setMarketStatus(venueId, seriesId, status)` — venue admin, ACTIVE or INACTIVE only (`InvalidMarket(5)`;
  `MarketStatusSet`). A market reads `EXPIRED` from the series' expiry onwards, whatever is stored, so the UI stops
  promoting trading and shows redemption instead.
- Views: `getMarket`, `tradableMarket(venueId, seriesId) → (adapter, market)` (reverts `AdapterDisabled` or
  `MarketNotVerified`), `adapterOf(venueId)`.

The registry affects nothing but the router: margin, liquidation and settlement never read it (INV-20, INV-52).

## 4. Adapter interface

Buys are **exact-in** (DD-33): the buyer names the most quote to spend and the fewest wrappers to accept. Kuru's
market orders are quote-in, so "buy exactly `qty`" isn't something the venue offers.

```solidity
interface IVenueAdapter {
    function venueId() external view returns (bytes32);
    function marketTokens(address market) external view returns (address base, address quote); // venue's records
    function quoteBuy(address market, uint256 premiumIn) external view returns (uint256 venueFee);
    function quoteSell(address market, uint256 proceeds) external view returns (uint256 venueFee);
    function buy(address market, uint256 premiumIn, uint256 maxVenueFee, address recipient, bytes calldata data)
        external returns (uint256 premiumSpent, uint256 venueFee);
    function sell(address market, uint256 qty, uint256 maxVenueFee, address recipient, bytes calldata data)
        external returns (uint256 qtySold, uint256 venueFee);
}
```

Adapters are called only by the router, which has already transferred the budget (or the wrappers) to them. They send
every output and every leftover to `recipient` (the router) and forward only what the current call produced:
tokens anyone else sends them stay put and can't block trading.

## 5. VenueRouter

```solidity
struct BuyOrder  { bytes32 venueId; bytes32 seriesId; uint256 premiumIn; uint256 minQty;
                   uint256 maxBuyerFeeNative; uint256 maxVenueFeeNative; address recipient; uint64 deadline; }
struct SellOrder { bytes32 venueId; bytes32 seriesId; uint256 qty; uint256 minProceeds;
                   uint256 maxVenueFeeNative; address recipient; uint64 deadline; }

function buyThroughVenue(BuyOrder calldata order, bytes calldata adapterData)
    external returns (uint256 qtyOut, uint256 premiumSpent, uint256 buyerFee, uint256 venueFee);
function sellThroughVenue(SellOrder calldata order, bytes calldata adapterData)
    external returns (uint256 qtySold, uint256 proceeds, uint256 venueFee);
```

Both: pause bit `ROUTER` (asset and product scope); `now ≤ deadline` (`DeadlineExpired`); `recipient ≠ 0`
(`InvalidRecipient`); amount > 0 (`ZeroAmount`); the market is registered, active and unexpired and its adapter
enabled (`MarketNotVerified`, `AdapterDisabled`).

Buy:

1. `buyerFee(premiumIn) ≤ maxBuyerFeeNative` (`FeeTooHigh`): the bound is checked on the whole budget up front.
2. Pull exactly `premiumIn` from the buyer (`NonExactTransfer` for fee-on-transfer tokens) and hand it to the adapter.
3. The router **measures** the wrappers and the unspent quote that came back: `qtyOut ≥ minQty` (`SlippageExceeded`);
   the venue fee `≤ maxVenueFeeNative` (`FeeTooHigh`).
4. `buyerFee = ceil(premiumSpent × buyerTradeFeeBps / 10,000)` on what was **actually spent**; pull it and pass it to
   `FeeController.notifyBuyerFee` (split per FEES.md §3).
5. Wrappers to `recipient`; unspent premium back to the buyer, exactly.
6. The router and the adapter end with exactly the token balances they started the call with (`VenueBalanceLeft`,
   INV-50). Event `VenueTrade(venueId, seriesId, trader, recipient, isBuy, qty, premium, buyerFee, venueFee)`.

Sell: pull exactly `qty` wrappers, hand them to the adapter, measure proceeds and unsold wrappers;
`proceeds ≥ minProceeds` (`SlippageExceeded`), venue fee bound; proceeds to `recipient`, unsold wrappers back to the
seller; no Optara fee (the seller paid at mint); the same INV-50 check.

Helpers that act on a subaccount (buy-and-unwrap, buy-to-close, mint-and-sell) are composed by the frontend from
these calls and the clearing calls; the router doesn't hold operator rights over anyone's account.

## 6. KuruAdapter

Kuru is an on-chain central limit order book on Monad. `KuruAdapter` (not upgradeable; replaced by registering a new
one) uses Kuru's **non-margin market orders**, so nothing ever rests in Kuru's margin account.

Verified against Kuru's public source (`Kuru-Labs/Kuru-contracts-dex-public`: `Router.sol`, `OrderBook.sol`,
`MarginAccount.sol`) and against the live Monad mainnet contracts on a fork (`test/fork/KuruAdapter.fork.t.sol`,
VEN-008; mainnet Router `0xd651…95CC`, MarginAccount `0x2A68…90c5`):

| Topic | Kuru behavior | Adapter |
|---|---|---|
| Market verification | `Router.verifiedMarket(market)` returns the 11-field `MarketParams`; zero for markets Kuru didn't deploy | `marketTokens` and every trade read it |
| Buy | `placeAndExecuteMarketBuy(uint96 quoteSize, uint256 minOut, false, false)`: `quoteSize` is in **price-precision** units; Kuru pulls `quoteSize × 10^quoteDecimals / pricePrecision` and sends the base and any unfilled quote straight back | Budget converted (rounded down); `minOut = 0` (the router enforces `minQty` by balance) |
| Sell | `placeAndExecuteMarketSell(uint96 size, uint256 minOut, false, false)`: `size` in **size-precision** units (`size × 10^baseDecimals / sizePrecision` pulled) | Quantity converted (rounded down); remainder returned unsold |
| Fees | Taker fee taken **in base** on buys, **in quote** on sells | Reported in quote: `spent × bps` (buy), `net × bps / (10,000 − bps)` (sell), each ≤ the user's bound |
| Partial fills | Unfilled quote is refunded, but Kuru computes it in price-precision units rounded down: it keeps up to **one price unit** (e.g. 1e-4 USDC at precision 1e4) | The router refunds exactly what came back; the buyer fee is charged on the actual spend |
| Docs vs. chain | Kuru's docs list `minOut` as `uint96`; the source and the live selector use `uint256` | `IKuru.sol` follows the chain |
| Market creation | `Router.deployProxy` is **owner-gated** (`Unauthorized()` for anyone else) | Optara only *registers* markets Kuru has created; each series' market needs Kuru to deploy it |

Canonical Kuru market for every series: **base = wrapper, quote = series settlement asset.** Examples:
`oETH-USDC-4500C-261225 / USDC`, `oMON-USDT-4C-261225 / USDT`.

Resting orders aren't placed by the adapter. Writers who want to post asks use Kuru directly with their wrappers.
Kuru's testnet "Spot V2" deployment has a different interface (`swap`, `batch`, account-core balances) and needs its
own adapter; only the mainnet interface above is verified.

## 7. Flows

| Flow | Steps |
|---|---|
| **Writer sells on Kuru** | deposit → `mintExternalLong` (pays seller fee) → `sellThroughVenue` or place asks on Kuru directly → proceeds arrive outside Optara → optionally deposit to improve margin |
| **Buyer buys on Kuru** | `buyThroughVenue` with a premium budget and `minQty` (pays buyer fee + Kuru fee) → wrappers in wallet → hold, transfer, unwrap, or redeem after settlement |
| **Writer buys to close** | buy wrappers (router or Kuru) → `closeShortWithWrapper` → margin released |
| **Hedge** | buy wrappers of another strike → `unwrapLong` into the subaccount → margin falls |
| **Expiry** | wrappers left on Kuru must be withdrawn by the holder and redeemed in Optara after the ratio is fixed |

## 8. Future in-house matching

An `InhouseMatchingAdapter` can be added later through the same router and registry:

- signed maker/taker orders with nonces and cancellation;
- premium transfer and wrapper delivery through the router;
- the same buyer/seller fees and risk checks.

Because contracts are upgradeable, a later version may also match **internal balances** directly (premium lands
inside the account as margin immediately). That needs a spec revision: an internal transfer primitive with batched
risk checks. Adding either must not change settlement or replace Kuru.
