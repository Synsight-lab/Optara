# Liquidation

Uncapped options need liquidation: when a writer's margin runs low, their risk must move to someone who can carry it.
Liquidation in Optara PM is **permissionless**, needs **no matching engine** and **no Kuru liquidity**, and always
**improves** the liquidated account's health.

Formulas: [MATH.md](MATH.md) §12. Parameters: [PARAMETERS.md](PARAMETERS.md) §5.

## 1. When can an account be liquidated?

Only when its equity is below maintenance margin (`equity < MM`), measured with fresh spot data and a surface that
is fresh or within `maxSurfaceStale` (with stale penalties).

Healthy and close-only accounts can never be liquidated.

## 2. Auction lifecycle

Liquidation happens per **risk bucket** (one subaccount × one underlying) through a Dutch auction:

```text
startAuction(accountId, underlying, oracleUpdate)
    requires equity < MM
    records startTime; bonus starts at startBonusBps

liquidateSlice(...)   // any number of times while the auction is active
    bonus grows linearly to maxBonusBps over auctionDuration

auction ends when:
    equity ≥ IM × (1 + targetHealthBufferBps)     -> healthy with a buffer (anyone may call endAuction)
    or the bucket has no positions left
```

After `auctionDuration` the bonus stays at `maxBonusBps` and **whole-bucket mode** turns on: slices up to 100% are
allowed.

If the account recovers on its own (deposit, closing), anyone can call `endAuction` once it's above the target.

## 3. Portfolio-slice liquidation (main path)

```solidity
function liquidateSlice(
    uint256 accountId,          // account being liquidated
    address underlying,         // bucket
    uint256 liquidatorAccountId,// must be owned/operated by msg.sender, same settlement asset
    uint16  sliceBps,           // minSliceBps..maxSliceBps (..10_000 in whole-bucket mode)
    uint256 minCashToLiquidator,  // protects the liquidator
    uint256 maxCashFromLiquidator,// protects the liquidator
    OracleUpdate calldata update
) external;
```

What happens:

1. Apply oracle updates; require the auction is active and the account is still below the target.
2. Compute `sliceMark`, `sliceMM`, `discount` and `penalty` ([MATH.md](MATH.md) §12).
3. Move `sliceBps` of **every unexpired position** in the bucket (shorts and internal longs) from the account to the
   liquidator account. Each leg's moved quantity is rounded **down** to a multiple of `minPositionQty`. Expired legs
   stay and settle normally. `sliceMM` is the account's actual MM drop, so rounding can't overstate it. If the
   liquidator already holds the opposite position in a series, the moved position nets against it (INV-24).
4. Move cash:
   - net-liability slice: the account pays the liquidator `−sliceMark + discount`;
   - net-asset slice: the liquidator pays the account `max(0, sliceMark − discount)`.
5. The account pays `penalty` to the insurance fund. If cash runs out, the liquidator's payment comes first and the
   penalty is reduced.
6. Require: the liquidator account is healthy (equity ≥ IM) and the liquidated account's `equity − MM` strictly
   increased after rounding. In theory it rises by at least `sliceMM × (1 − bonus − penalty)` ([MATH.md](MATH.md)
   §12). Only dust-sized slices, whose gain rounding can erase, revert here.

The liquidator takes over **real risk with its own capital**. It never receives the slice's margin requirement from
the failing account. That's what makes every slice improve the account.

Open-interest caps are not checked on transfers: moving a short doesn't change the total short.

## 4. Wrapper-burn liquidation (alternative path)

```solidity
function liquidateWithWrapper(
    uint256 accountId, bytes32 seriesId, uint256 qty,
    uint256 liquidatorAccountId, uint256 minCashToLiquidator, OracleUpdate calldata update
) external;
```

1. The liquidator burns `qty` wrappers of a series the account is **short**.
2. The account's short shrinks by `qty`, and MM falls by `ΔMM > 0`.
3. The account pays the liquidator the burned liability's mark value plus `ΔMM × bonus`, and pays `ΔMM × penalty` to
   insurance.

This works when wrappers can be bought (e.g. on Kuru), but it's never the only path, because wrapper liquidity may be
thin.

## 5. When the account can't pay (bad debt during liquidation)

If a net-liability slice costs more than the account's cash:

1. The account pays all its remaining cash to the liquidator.
2. `InsuranceFund` tops up the liquidator, up to `maxInsurancePerLiquidation` and the fund's balance.
3. Anything still unpaid is **not** paid. The liquidator saw the offered amount through `minCashToLiquidator` and
   chose to accept. The Dutch bonus keeps rising until someone accepts.
4. Emit `BadDebtCovered(accountId, insuranceAmount)`.

If nobody takes the remaining positions, they stay with the account until expiry. Settlement then collects what it
can, insurance covers the rest, and only beyond that does the recovery ratio fall below 1 ([SETTLEMENT.md](SETTLEMENT.md)).

## 6. Timing around expiry

| Period | Liquidation |
|---|---|
| Before expiry | Normal auctions on all legs |
| Expired, not finalized | Auctions may continue on unexpired legs of the bucket. Expired legs are not transferred. |
| Finalized | No auctions on finalized legs; they settle into fixed debts or claims |

## 7. Guarantees

| Guarantee | How |
|---|---|
| Healthy accounts can't be liquidated | `startAuction` requires `equity < MM`; slices require below-target health |
| Every slice improves health | Mark-value cash transfer; `maxBonusBps + penaltyBps < 10_000` ([MATH.md](MATH.md) §12) |
| No over-liquidation | Slice bounds, plus the auction ends at IM + buffer |
| No Kuru dependency | Slice transfers move internal positions directly |
| Liquidators can't be griefed by price moves | `minCashToLiquidator` / `maxCashFromLiquidator` |
| The account isn't drained | The liquidator funds its own margin |

## 8. Events

```solidity
event AuctionStarted(uint256 indexed accountId, address indexed underlying, uint256 equity, uint256 mm, uint64 startTime);
event SliceLiquidated(uint256 indexed accountId, address indexed underlying, uint256 indexed liquidatorAccountId,
    uint16 sliceBps, int256 sliceMark, uint256 sliceMM, uint256 discount, uint256 penalty, int256 cashToLiquidator);
event WrapperLiquidated(uint256 indexed accountId, bytes32 indexed seriesId, uint256 qty, uint256 liquidatorAccountId,
    uint256 cashToLiquidator, uint256 penalty);
event BadDebtCovered(uint256 indexed accountId, address indexed asset, uint256 insuranceAmount, uint256 unpaid);
event AuctionEnded(uint256 indexed accountId, address indexed underlying, uint8 reason); // 0 healthy, 1 empty
```

## 9. Liquidator playbook (for bot builders)

1. Watch `AccountHealth` from the indexer, or compute it from on-chain views.
2. When `equity < MM`: fetch fresh spot and surface data, then `startAuction`.
3. Estimate the payoff of a slice at the current bonus (`previewSlice` view). Take it when profitable after hedging
   costs.
4. Keep a funded subaccount in the same settlement asset. The slice must fit within your IM.
5. Hedge or close the taken positions afterwards: unwrap longs from Kuru to offset, or buy wrappers and close.
