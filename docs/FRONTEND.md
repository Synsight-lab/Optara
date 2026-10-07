# Frontend

How to build the web app for Optara PM. The contracts are the source of truth: the app reads every margin,
price and payout from contract views and never computes an authoritative number itself.

## 1. Stack and structure

- React + TypeScript + viem/wagmi + TanStack Query (the same stack as V2's frontend).
- `src/lib/optara/`: a thin client with names matching the future SDK: reads (`getSeries`, `getHealth`,
  `previewMint`…), transaction builders (`buildMint`…), oracle helpers (`fetchOracleUpdate`), formatting.
- Deployment addresses and ABIs come from `deployments/<network>.json`.

## 2. Pages

| Route | Page | Main content |
|---|---|---|
| `/` | Markets | Series grouped by product and expiry: type, strike, mark, IV, OI, Kuru bid/ask, status |
| `/series/:id` | Series | Terms, payoff chart, IV and mark, wrapper address, Kuru market, actions (§4), settlement status |
| `/portfolio` | Portfolio | Subaccounts, health bar, equity, IM, MM, positions, wallet wrappers, Kuru balances (marked external), required actions |
| `/trade/:id` | Trade | Router buy/sell with fee breakdown and limits |
| `/liquidations` | Liquidations | Accounts below MM, active auctions, current bonus, slice preview |
| `/settlement` | Settlement | Expired groups: finalize, participants left, settle buttons, ratio, redeem/claim |
| `/system` | System status | Oracle freshness per product, close-only flags, insurance balances, pending upgrades |

## 3. Data sources

| Data | Source |
|---|---|
| Series, terms, wrapper | `OptionSeriesRegistry.getSeries`; the indexer for lists |
| Health, equity, IM, MM | `PortfolioRiskManager.healthOf` (check the `fresh` flag) |
| Previews | `previewMint`, `previewWithdraw`, `previewSlice`, `previewSettle`, `previewRedeem`, fee previews |
| Mark and IV | `priceOf`, `ivOf` |
| Oracle freshness | `LiveSpotOracle` / `VolSurfaceOracle` views |
| Kuru quotes | `KuruAdapter.quoteBuy/quoteSell` and the Kuru API (display only) |
| History, lists | Indexer API ([INDEXER_AND_KEEPERS.md](INDEXER_AND_KEEPERS.md)) |

## 4. Actions on the Series page

| Action | Shown when | Before sending | Approval needed |
|---|---|---|---|
| Mint & sell | Active, product enabled, healthy | `fetchOracleUpdate` → `previewMint` (fee, IM after) | none |
| Unwrap | Active, user holds wrappers | none | none (burns from caller) |
| Close short | Short, before finalization | none | none |
| Wrap | Internal long, active | `previewWrap` | none |
| Buy (router) | Active, verified market | `quoteBuy` + `previewBuyerFee` | settlement asset → `VenueRouter` |
| Sell (router) | Holds wrappers, verified market | `quoteSell` | wrapper → `VenueRouter` |
| Redeem | Group REDEEMABLE | `previewRedeem` | none |

Before any risk-increasing transaction the app must:

1. Fetch a fresh `OracleUpdate`: a Pyth price update, the latest signed surface report, and proofs for the leaves
   the account needs (publisher API).
2. Re-run the preview with that data.
3. Send the transaction with the update attached and `value` = the provider fee.

## 5. Health display

```text
Equity  ████████████████░░░░  3,890 USDC
IM      ──────────────┤        3,418      Healthy
MM      ───────┤               1,447
```

| State | Color | Message |
|---|---|---|
| Healthy | Green | "You can open new positions." |
| Close-only | Amber | "New risk blocked. Deposit or reduce positions." |
| Liquidatable | Red | "Your positions can be liquidated now." |
| Data stale | Grey overlay | "Prices delayed. Shown values may be outdated." |

Also show a **liquidation spot price** estimate (the spot at which equity = MM), computed by calling views at
shocked spots. Label it an estimate.

## 6. Required disclosures (show and require acknowledgement once)

1. **Uncapped risk (writers):** "Calls you write have no maximum loss. If your margin runs low you will be
   liquidated at a discount."
2. **Recovery ratio (buyers):** "If losses exceed the insurance fund, all holders of this expiry receive the same
   reduced percentage of their payoff."
3. **Premium location:** "Premium received on Kuru stays in your wallet. Deposit it to improve your Optara margin."
4. **Kuru vs Optara:** "Kuru balances do not count as Optara collateral."
5. **Upgradeability:** "Optara contracts are upgradeable after a 7-day timelock."
6. **Oracle dependency:** "New positions need fresh price and volatility data. If data stops, only closing is
   possible."
7. **MON:** "MON volatility is synthetic. No liquid MON options market exists yet."
8. **Settlement timing:** "Payouts open only after every account in this expiry is settled."

## 7. Fee display

Always three separate lines: **Optara fee**, **Kuru fee**, **Premium**. Each limit the user signs
(`maxSellerFee`, `maxBuyerFee`, `maxVenueFee`, the premium budget and `minQty`) is shown with a default slippage of 1% and is editable.

## 8. Settlement page

For each expired group: state (`EXPIRED`, `ORACLE_STALLED`, `FINALIZED`, `REDEEMABLE`), settlement price,
participants left, keeper reward, "Settle next 20" (batch) button, ratio, insurance contribution, and the user's
redeemable amount.

## 9. Errors → messages

| Error | Message |
|---|---|
| `NotHealthy` | "Not enough margin for this. Deposit more or reduce size." |
| `StaleSpot` / `StaleSurface` | "Price data is out of date. Refresh and try again." |
| `ProductCloseOnly` | "This market is closing-only right now." |
| `InsuranceBelowMinimum` | "New positions are paused for this asset." |
| `FeeTooHigh` | "The fee changed. Review and retry." |
| `SlippageExceeded` / `DeadlineExpired` | "Price moved. Review and retry." |
| `OpenInterestCap` | "This market is at its open-interest limit." |
| `PositionLimit` | "Too many positions in this account. Close some or use another subaccount." |
| `PositionBelowMinimum` | "Positions must be at least 0.01 options." |
| `NotLiquidatable` | "This account is no longer liquidatable." |
| `SettlementIncomplete` | "Settlement is still running. Payouts open soon." |
| `RatioNotSet` | "Payouts aren't open yet." |
| `ActionPaused` | "This action is temporarily paused." |

## 10. Units and formatting

- Strikes, prices, IV: WAD → display with 2–4 decimals; IV as a percentage.
- Quantities: 18 decimals; minimum step `minPositionQty`.
- Cash: native decimals of the settlement asset.
- Never parse a wrapper's symbol for economics. Use `getSeries`.

## 11. Frontend tests

- Units: formatting, parsing, health classification, fee breakdown.
- Components: each action button's enable/disable logic for every state in [STATE_MACHINE.md](STATE_MACHINE.md).
- Integration (local chain): F1–F13 from [USER_FLOWS.md](USER_FLOWS.md), with a mock publisher and a mock Kuru.
- Disclosure gating: the buy and mint flows can't proceed until acknowledged.
