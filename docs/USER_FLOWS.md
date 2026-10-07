# User Flows

Step-by-step journeys. Each lists the calls, what changes, and what can go wrong. Function details:
[PROTOCOL_SPEC.md](PROTOCOL_SPEC.md).

**Example market:** ETH/USDC, spot 4,000. Series `C4500` = 4,500 call, 30 days, CS = 1. Mark ≈ 106.77 USDC.

## Writer flows

### F1. Open an account and deposit
1. `createSubAccount(USDC)` → `accountId`.
2. Approve USDC to `OptionClearing`, then `depositCollateral(accountId, 4,000e6)`.
3. Result: cash 4,000 USDC. No positions; health is "no risk".

Can fail: asset not approved; fee-on-transfer token (`NonExactTransfer`).

### F2. Mint wrappers and sell them on Kuru
1. Frontend fetches a fresh `OracleUpdate` (spot + surface + leaves) and calls `previewMint(accountId, C4500, 1e18)`.
   It shows: seller fee 3.20 USDC, IM after ≈ 3,418, equity after ≈ 3,890, OK.
2. `mintExternalLong(accountId, C4500, 1e18, writerWallet, maxSellerFee = 3.5e6, update)`.
3. Result: balance −1, cash −3.20, 1 wrapper in the wallet. The account stays healthy.
4. `sellThroughVenue({KURU, C4500, qty: 1e18, minProceeds, maxVenueFee, writerWallet, deadline}, data)`, or post asks on
   Kuru directly.
5. The premium (e.g. 104 USDC net of Kuru fees) lands in the **wallet**, not in Optara.

Can fail: stale data (`StaleSpot`/`StaleSurface`); not enough margin (`NotHealthy`); fee above max; product
close-only; OI cap; insurance below minimum.

### F3. Put the premium to work (optional)
1. `depositCollateral(accountId, 104e6)`.
2. Equity rises by 104; free margin rises by the same amount.

The UI must say: "Premium on Kuru is external. Deposit it into Optara to improve your margin."

### F4. Hedge with a spread
1. Buy 1 × `C5000` wrapper (router or Kuru).
2. `unwrapLong(accountId, C5000, 1e18)`. No oracle data needed.
3. Margin drops from ≈ 3,418 IM to ≈ 438 IM. The spread's worst case is bounded at 500.

### F5. Buy back and close
1. Buy 1 × `C4500` wrapper.
2. `closeShortWithWrapper(accountId, C4500, 1e18)`.
3. Balance 0; margin released; the account leaves the group.

### F6. Withdraw
1. Fetch an `OracleUpdate`; show `maxWithdrawable(accountId)`.
2. `withdrawCollateral(accountId, amount, wallet, update)`.

Can fail: `NotHealthy` (the amount exceeds free margin); stale data while positions are open.

### F7. Sell an internal long
1. `wrapLong(accountId, C5000, 1e18, wallet, update)`. Needs the account to stay healthy without the hedge.
2. Sell the wrapper on Kuru.

### F8. Margin trouble
| Situation | UI shows | User can |
|---|---|---|
| Close-only (MM ≤ equity < IM) | Amber: "New risk blocked" | Deposit, close shorts, unwrap hedges |
| Liquidatable (equity < MM) | Red: "Liquidation possible" + distance to MM | Same as above, fast; once healthy again any active auction can be ended |

## Buyer flows

### F9. Buy on Kuru through the official router
1. The frontend estimates the fill from Kuru's book and shows the premium, Optara's buyer fee (3%) and Kuru's fee
   (`quoteBuy`) **separately**.
2. Approve USDC to `VenueRouter`; `buyThroughVenue({KURU, C4500, premiumIn: 110e6, minQty: 0.99e18, maxBuyerFee,
   maxVenueFee, wallet, deadline}, data)`. Buys are exact-in: the buyer names the budget and the fewest wrappers to
   accept (DD-33).
3. Wrappers in the wallet; unspent USDC refunded exactly; the buyer fee is charged on what was spent.

Disclosures before buying: payoff at expiry, recovery-ratio risk, oracle-liveness risk, upgradeable contracts.

### F10. Hold to expiry and redeem
1. After expiry, wait for: finalize → all accounts settled → recovery ratio set. The UI shows each step.
2. `redeemWrapper(C4500, 1e18, wallet)` → receives `max(S* − 4,500, 0) × ratio`.

If the wrapper sits on Kuru: withdraw it to the wallet first.

### F11. Unwrap to use as margin (traders)
`unwrapLong` into one's own subaccount (same settlement asset). It can now offset shorts.

## Liquidator flow

### F12. Take a slice
1. Watch for `equity < MM` (indexer or views).
2. `startAuction(accountId, ETH, update)`.
3. Poll `previewSlice(accountId, ETH, 2500)` as the bonus rises.
4. `liquidateSlice(accountId, ETH, myAccountId, 2500, minCash, maxCash, update)`.
5. The liquidator now holds 25% of the bucket's positions and the cash from [MATH.md](MATH.md) §12.1. It hedges or
   closes them later.

Alternative: buy wrappers and call `liquidateWithWrapper`.

## Keeper and settlement flows

### F13. Expiry to payout
| Step | Call | Who |
|---|---|---|
| 1 | Wait for `expiry + minFinalizationDelay` | — |
| 2 | `finalizeGroup(groupId, roundProof)` | Any keeper (reward) |
| 3 | `settleAccountGroup(account, groupId)` for every participant (or batch) | Keepers (escalating reward) |
| 4 | `computeRecoveryRatio(groupId)` when participants == 0 | Anyone |
| 5 | `redeemWrapper(...)` / `claimSettlement(...)` | Holders / creditors |

### F14. Shortfall
Same as F13. At step 4 the insurance fund covers what it can. If a gap remains, the ratio is < 1 and every claimant
receives the same percentage. The UI shows the ratio and the insurance contribution.

### F15. Oracle stalled
If no valid round exists by `expiry + maxFinalizationDelay`, the group shows `ORACLE_STALLED`. Writers can still
cancel shorts with wrappers; nothing is redeemed; a late valid round can still finalize.

### F16. Surface goes stale
| Age of surface | What users see |
|---|---|
| > `surfaceStaleAfter` | "Volatility data delayed. New positions paused." |
| > `maxSurfaceStale` | Product close-only |

Closes, unwraps and deposits keep working throughout.

## Other flows

### F17. No Kuru (OTC)
mint → transfer the wrapper directly to a buyer → expiry → settle → redeem. Works identically.

### F18. Listing a series (ops)
`createSeries(params)` by `SERIES_CREATOR` → wrapper deployed → `registerMarket` for the Kuru market
(VENUE_ADMIN) → publishers add the expiry as a tenor.

### F19. Publishing a surface (publisher)
Calibrate → off-chain no-arbitrage checks → build the grid and Merkle root → collect quorum signatures → serve
via API. Any user or keeper submits it on-chain in an `OracleUpdate`.
