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

Stores verified markets:

```solidity
struct VenueMarket {
    bytes32 venueId;      // e.g. keccak("KURU")
    address market;       // venue market address
    bytes32 seriesId;
    address base;         // MUST equal the series wrapper
    address quote;        // MUST equal the series settlement asset
    uint256 chainId;
    uint8   status;       // 0 inactive, 1 active, 2 expired
    bytes   metadata;     // tick size, lot size, etc.
}
```

- `registerMarket` (role `VENUE_ADMIN`) checks `base == wrapper(seriesId)`, `quote == settlementAsset(seriesId)`
  and `chainId == block.chainid`. It reads the market's tokens from the venue contract through the adapter; it
  never trusts the caller.
- Wrong markets can't be registered. The frontend shows only registered, active markets as official.
- When a series expires, its market status becomes `expired`, so the UI stops promoting trading and shows
  redemption instead.

## 4. Adapter interface

```solidity
interface IVenueAdapter {
    function venueId() external view returns (bytes32);
    function marketTokens(address market) external view returns (address base, address quote);
    function quoteBuy(address market, uint256 qty) external view returns (uint256 premium, uint256 venueFee);
    function quoteSell(address market, uint256 qty) external view returns (uint256 proceeds, uint256 venueFee);
    function buy(address market, uint256 qty, uint256 maxPremium, uint256 maxVenueFee, address recipient, bytes calldata data)
        external returns (uint256 premiumPaid, uint256 venueFeePaid);
    function sell(address market, uint256 qty, uint256 minProceeds, uint256 maxVenueFee, address recipient, bytes calldata data)
        external returns (uint256 proceeds, uint256 venueFeePaid);
}
```

Adapters hold tokens only during a call and must end each call with zero balance. Any leftovers are returned to the
user.

## 5. VenueRouter

```solidity
function buyThroughVenue(bytes32 adapterId, bytes32 seriesId, uint256 qty, uint256 maxPremium,
    uint256 maxBuyerFeeNative, uint256 maxVenueFeeNative, address recipient, uint64 deadline, bytes calldata adapterData)
    external returns (uint256 premiumPaid, uint256 buyerFee, uint256 venueFee);

function sellThroughVenue(bytes32 adapterId, bytes32 seriesId, uint256 qty, uint256 minProceeds,
    uint256 maxVenueFeeNative, address recipient, uint64 deadline, bytes calldata adapterData)
    external returns (uint256 proceeds, uint256 venueFee);
```

Buy:

1. `now ≤ deadline`; series active; the market is registered and active for `(adapterId, seriesId)`.
2. Pull `maxPremium + maxBuyerFeeNative + maxVenueFeeNative` of the settlement asset from `msg.sender`.
3. `adapter.buy(...)` → wrappers to the router.
4. `buyerFee` from the actual premium ([FEES.md](FEES.md) §4); require `≤ maxBuyerFeeNative`.
5. Collect the fee; send the wrappers to `recipient`; refund the rest.

Sell: pull wrappers, `adapter.sell(...)`, require `proceeds ≥ minProceeds`, send proceeds to `recipient`. No Optara
fee.

Optional helpers (composed calls, never solvency assumptions):

- **Mint and sell:** `mintExternalLong` → `sellThroughVenue` → optionally `depositCollateral` with the proceeds.
- **Buy and unwrap:** `buyThroughVenue` (recipient = router) → `unwrapLong` into the buyer's subaccount.
- **Buy to close:** `buyThroughVenue` → `closeShortWithWrapper`.

The helpers that act on a subaccount require the caller to be its owner or operator.

## 6. KuruAdapter

Kuru is an on-chain central limit order book on Monad. Trading balances live in Kuru's own margin account.

| Task | How |
|---|---|
| Market verification | Read base and quote from the Kuru market contract; must match wrapper and settlement asset |
| Buy | Deposit the quote into Kuru for the trade, place an immediate-or-cancel buy for `qty` with a price limit derived from `maxPremium`, withdraw the filled wrappers, return unused quote |
| Sell | Deposit the wrappers, place an immediate-or-cancel sell with a limit derived from `minProceeds`, withdraw the proceeds |
| Fee preview | Read Kuru's taker fee and expose it in `quoteBuy`/`quoteSell` |
| Resting orders | Not done by the adapter. Writers who want to post asks use Kuru directly with their wrappers |

Exact Kuru contract addresses, function names and margin-account flow must be verified against the deployed Kuru
contracts and SDK at implementation time. Don't hardcode them in this spec. The adapter is replaceable, so a Kuru
change only needs a new adapter.

Canonical Kuru market for every series: **base = wrapper, quote = series settlement asset.** Examples:
`oETH-USDC-4500C-261225 / USDC`, `oMON-USDT-4C-261225 / USDT`.

## 7. Flows

| Flow | Steps |
|---|---|
| **Writer sells on Kuru** | deposit → `mintExternalLong` (pays seller fee) → `sellThroughVenue` or place asks on Kuru directly → proceeds arrive outside Optara → optionally deposit to improve margin |
| **Buyer buys on Kuru** | `buyThroughVenue` (pays buyer fee + Kuru fee) → wrappers in wallet → hold, transfer, unwrap, or redeem after settlement |
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
