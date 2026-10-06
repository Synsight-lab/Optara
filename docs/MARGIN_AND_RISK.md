# Margin and Risk Policy

How `PortfolioRiskManager` decides what an account may do. Formulas are in [MATH.md](MATH.md) §5–§9; numbers are
in [PARAMETERS.md](PARAMETERS.md).

## 1. What counts toward margin

| Counts | Does not count |
|---|---|
| Cash in the subaccount (its one settlement asset) | Stablecoin in the user's wallet |
| Internal longs (unwrapped) | Wrapper tokens in a wallet, on Kuru, or anywhere outside Optara |
| Internal shorts (as liabilities) | Premium sitting on Kuru or in a wallet |
| Finalized-but-unsettled positions at their fixed payoff | Other subaccounts of the same owner |
| | Spot or perp positions (not supported in v1) |
| | Other stablecoins |

A long reduces margin only while it is **inside** the subaccount. Wrapping it out removes that credit.

## 2. Risk buckets

Margin is computed per **risk bucket** = one subaccount × one underlying, and the buckets are added up.

- Positions on the **same underlying** offset each other across strikes, types and expiries, because they are
  stressed with the same spot shock.
- Positions on **different underlyings** never offset. An ETH loss is not reduced by a BTC gain.
- All buckets share the subaccount's one cash balance.

A subaccount may hold at most `maxBucketsPerAccount` underlyings and `maxSeriesPerAccount` series.

## 3. Initial and maintenance margin

| | Initial margin (IM) | Maintenance margin (MM) |
|---|---|---|
| Stress set | `initialStressSet` ∪ `maintenanceStressSet` (larger shocks, near-expiry scenarios) | `maintenanceStressSet` (milder) |
| Buffer | `+ imBufferBps` × current mark of all shorts | none |
| Needed for | Opening risk, wrapping out, withdrawing | Avoiding liquidation |

Each scenario shifts spot, IV and time. Margin = the largest equity drop across the set ([MATH.md](MATH.md) §9). Using the union of both sets for IM
guarantees `MM ≤ IM`; basing the buffer on short mark guarantees that risk-reducing actions never lower health.

## 4. Account health and allowed actions

| State | Condition | Allowed |
|---|---|---|
| **Healthy** | equity ≥ IM | Everything |
| **Close-only** | MM ≤ equity < IM | Risk-reducing actions only |
| **Liquidatable** | equity < MM | Risk-reducing actions; anyone may liquidate |
| **Insolvent** | equity < 0, nothing left to liquidate | Waits for settlement; shortfall → insurance → recovery ratio |

### Risk-increasing actions (need fresh oracle data and equity ≥ IM afterwards)

- `mintExternalLong`
- `wrapLong`
- `withdrawCollateral`
- `closeShortWithInternalLong` (checked on the **source** account, which loses a long)
- Receiving a slice as liquidator (checked on the liquidator account)

### Risk-reducing actions (no oracle data, no margin check)

- `depositCollateral`
- `unwrapLong`
- `closeShortWithWrapper`
- Paying off settlement debts

These can never lower health ([MATH.md](MATH.md) §9.1), so they always stay open. A guardian pause can still stop
them in an emergency.

## 5. Oracle freshness rules

| Data | Fresh if | Needed for |
|---|---|---|
| Spot | age ≤ `maxSpotAge` | Every risk-increasing action, liquidation |
| Surface | `validAfter ≤ now ≤ expiresAt` and age ≤ `surfaceStaleAfter` | Every risk-increasing action |
| Surface (for liquidation only) | age ≤ `maxSurfaceStale` | Liquidation may use a stale surface with direction-aware penalties ([MATH.md](MATH.md) §5.1) |

When data is not fresh:

- **Blocked:** risk-increasing actions on that product.
- **Still open:** deposits, unwraps, closes.
- **Liquidation:** allowed with a fresh report in the same transaction, or with stale penalties up to
  `maxSurfaceStale`.
- **Beyond `maxSurfaceStale`:** the product enters close-only automatically until a fresh surface is accepted.

## 6. Product close-only

A **product** (underlying × settlement asset) becomes close-only when any of these holds:

- the surface is older than `maxSurfaceStale`;
- the latest surface has `confidenceBps > maxConfidenceBps`;
- the guardian sets it close-only (incident, publisher outage, emergency upgrade);
- the insurance fund or keeper reserve for the settlement asset is below its minimum.

In close-only, no account may open new risk on that product. Existing positions can still be reduced, liquidated and
settled.

## 7. Open-interest limits

Per-account counts limit gas. These caps limit **economic** exposure:

| Cap | Measured as | Checked on |
|---|---|---|
| `maxOpenInterestPerSeries` | total internal short quantity of the series | mint, liquidation transfers |
| `maxShortUnderlyingPerProduct` | Σ \|short qty\| × CS across all series of the product | mint |

Lowering a cap never forces anyone to close. It only blocks new risk.

## 8. Expired, finalized and settled positions

| Stage | How positions are valued |
|---|---|
| Before expiry | Black-76 with live spot and surface IV; full scenarios |
| Expired, not finalized | Intrinsic at live spot (`T = 0`); spot shocks only |
| Finalized, not settled | Exact payoff at `S*`; no scenarios (no uncertainty left) |
| Settled | Gone from the account; cash adjusted |

After expiry no new risk can be opened on that series. Closes with wrappers stay open until finalization.

## 9. Synthetic MON volatility

There is no liquid MON options market to derive a surface from, so MON IV is synthetic: realized volatility, proxy
assets and publisher judgment. Policy for MON products:

- higher `minIv` floor;
- shorter report `expiresAt`;
- lower open-interest caps;
- larger IM buffer if needed;
- close-only as soon as publisher liveness degrades;
- the UI must say "MON volatility is synthetic".

## 10. Capital efficiency note

Margin size is driven by the stress sets. The default IM set includes a `+100%` spot shock and a near-expiry
scenario, which is conservative: a naked 30-day call needs about 33× its premium ([MATH.md](MATH.md) §10).
Scenario `timeMode = 2` (shift by a horizon) allows liquidation-horizon calibration later without code changes. See
[DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) OD-1.

## 11. Gas

A margin check prices every leg in every scenario: up to `maxSeriesPerAccount × maxScenarioCount` Black-76 calls.
The risk check at maximum positions must fit `maxRiskCheckGas` (benchmark before launch). If it doesn't, reduce
`maxSeriesPerAccount` or the scenario count, or use the signed price-table fallback ([ORACLES.md](ORACLES.md) §3.9).
