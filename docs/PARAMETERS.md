# Parameters

Every configurable number, its default, its unit and who may change it. Defaults are starting points to be
confirmed by risk review and gas benchmarks before launch.

**Change rules:**

- Changes that **reduce** risk (lower caps, higher floors, larger shocks) may be applied by the risk admin
  immediately.
- Changes that **increase** risk go through the governance timelock.
- No change applies retroactively to series terms, finalized results or recovery ratios.

## 1. Accounts and positions

| Name | Default | Unit | Changed by |
|---|---|---|---|
| `maxSeriesPerAccount` | 16 (hard cap 64) | count | Governance (timelock) |
| `maxBucketsPerAccount` | 4 (hard cap 16; ≤ `maxSeriesPerAccount`) | count | Governance |
| `minPositionQty` | 0.01 option (`1e16`) | quantity | Governance; every non-zero balance must be a multiple of it, at least 1× (limits dust-account griefing). It can only change to an exact divisor of its current value, so existing balances stay valid |
| `maxRiskCheckGas` | 8,000,000 (target) | gas | Benchmark target, not on-chain |

## 2. Risk parameter set (one per `riskParameterSetId`)

| Name | Default | Unit |
|---|---|---|
| `imBufferBps` | 500 | bps of the current mark of all short positions (added to IM) |
| `minIv` (ETH, BTC) | 0.10 (10%) | WAD |
| `minIv` (MON) | 0.60 (60%) | WAD |
| `maxIv` | 5.00 (500%) | WAD |
| `nearExpiryFloorSeconds` | 3,600 | seconds |
| `maxOpenInterestPerSeries` | set per series class; hard cap 1e24 (1,000,000 options) | quantity (1e18) |
| `maxShortUnderlyingPerProduct` | set per product | underlying units (WAD) |
| `initialStressSet` | §3 | scenarios |
| `maintenanceStressSet` | §3 | scenarios |

Constraints enforced on-chain: `maxScenarioCount = 24`; `minIv < maxIv`; MM set no harsher than IM set (checked
off-chain in review); `imBufferBps ≤ 5000`.

## 3. Default stress sets

**Initial stress set (24 scenarios):**

| # | Spot shocks (bps) | Vol shock (bps) | Time |
|---|---|---|---|
| 1–8 | −5000, −3000, −1500, 0, +1500, +3000, +5000, +10000 | −3000 | now |
| 9–16 | same 8 spot shocks | +7500 | now |
| 17–24 | same 8 spot shocks | 0 | near-expiry floor |

**Maintenance stress set (12 scenarios):**

| # | Spot shocks (bps) | Vol shock (bps) | Time |
|---|---|---|---|
| 1–6 | −3000, −1500, 0, +1500, +3000, +5000 | −3000 | now |
| 7–12 | same 6 spot shocks | +3000 | now |

These match the design plan's shock ranges (spot −50% to +100%, vol −30% to +75%, now and near-expiry). Horizon
calibration (`timeMode = 2`) is an open decision ([DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) OD-1).

## 4. Oracles

| Name | Default | Unit | Notes |
|---|---|---|---|
| `maxSpotAge` | 60 | seconds | Per product, in `LiveSpotOracle` source (≤ 1 day) |
| `maxConfidenceBps` | 100 (1%) | bps of the price, per Pyth leg | Per product, in `LiveSpotOracle` source (1–10,000) |
| `surfaceStaleAfter` | 300 | seconds | After this, risk-increasing actions stop. This and the rows below (to `maxReportLifetime`) are per product in `VolSurfaceOracle.SurfaceConfig` |
| `staleIvPenaltyBpsPerHour` | 1,000 | bps of IV per hour | Direction-aware |
| `maxLongTimeValueStale` | 1,800 | seconds | Longs valued at intrinsic after this |
| `maxSurfaceStale` | 21,600 (6 h) | seconds | Product close-only after this |
| `maxIvMoveBps` | 2,000 | bps (relative ATM change per update) | Waived in emergency mode |
| `maxConfidenceBps` | 1,000 | bps | Above → product close-only |
| `minPublisherQuorum` | 2 (of ≥ 3 publishers) | count | Timelocked |
| `maxReportLifetime` (ETH, BTC) | 900 | seconds | `expiresAt − validAfter` limit |
| `maxReportLifetime` (MON) | 300 | seconds | |
| `maxTenors` / `maxMoneynessNodes` per check | 4 / 4 | count | Per series |
| `minFinalizationDelay` | 300 | seconds | Per settlement oracle config |
| `maxFinalizationDelay` | 604,800 (7 days) | seconds | `ORACLE_STALLED` after this |

## 5. Liquidation

| Name | Default | Unit |
|---|---|---|
| `startBonusBps` | 0 | bps of slice MM |
| `maxBonusBps` | 1,000 | bps |
| `auctionDuration` | 1,800 | seconds |
| `bonusSlopeBpsPerSecond` | `(maxBonusBps − startBonusBps) / auctionDuration` | derived |
| `minSliceBps` | 500 | bps |
| `maxSliceBps` | 2,500 | bps |
| `targetHealthBufferBps` | 500 | bps above IM where the auction ends |
| `liquidationPenaltyBps` | 200 | bps of slice MM, to insurance |
| `maxInsurancePerLiquidation` | per asset | native units |

Constraints (`setLiquidationParams`, `InvalidLiquidationParams`): `startBonusBps ≤ maxBonusBps`,
`maxBonusBps + liquidationPenaltyBps < 10_000`, `0 < auctionDuration ≤ 7 days`,
`0 < minSliceBps ≤ maxSliceBps ≤ 10_000`, `targetHealthBufferBps ≤ 10_000`. `initialize` sets the defaults above;
`maxInsurancePerLiquidation` starts at 0 (no top-ups) until governance sets it per asset.

## 6. Fees

| Name | Default | Hard cap | Unit |
|---|---|---|---|
| `sellerOpenFeeBps` | 300 | 1,000 | bps of minted mark value |
| `minSellerFeeNative[asset]` | 0.10 USDC equivalent | — | native; `setMinSellerFee` |
| `buyerTradeFeeBps` | 300 | 1,000 | bps of executed premium |
| `insuranceShareBps` | 6,000 | — | bps of each fee |
| `treasuryShareBps` | 3,000 | — | bps |
| `keeperShareBps` | 1,000 | — | bps |

Shares must sum to 10,000. Hard caps are constants in `FeeController` (`MAX_FEE_BPS`); changing them needs an
upgrade. `initialize` sets the rates and split above; per-asset values (`minSellerFeeNative`, §7 minimums and
rewards) start at 0 and are set by the deployment script when the asset is approved.

## 7. Insurance and keepers

| Name | Default | Unit |
|---|---|---|
| `minimumInsuranceSeed[asset]` | set at launch (suggest ≥ 5% of the asset's OI caps at max shock) | native |
| `minimumKeeperReserve[asset]` | set at launch | native |
| `settleRewardNative` | 0.50 USDC equivalent | native per account settled |
| `REWARD_ESCALATION_BPS_PER_HOUR` | 2,500 (+25% of base per full hour since finalization) | constant; upgrade to change |
| `MAX_REWARD_MULTIPLE_BPS` | 40,000 (4× base) | constant; upgrade to change |
| `finalizeRewardNative` | 2 USDC equivalent | native |

## 8. Governance

| Name | Default |
|---|---|
| `upgradeTimelock` (`UpgradeAdmin.upgradeDelay`, immutable) | 7 days; allowed 2–365 days |
| `emergencyUpgradeTimelock` (`UpgradeAdmin.emergencyDelay`, immutable) | 24 hours (multisig threshold ≥ 4/7); allowed 1 hour – 365 days |
| `parameterTimelock` (risk-increasing changes) | 48 hours |
| `publisherSetTimelock` | 48 hours |

## 9. Series bounds (per product)

| Name | Example (ETH/USDC) |
|---|---|
| `minStrike` / `maxStrike` | 100 / 1,000,000 USDC |
| `minContractSize` / `maxContractSize` | 0.001 / 100 ETH |
| `minTimeToExpiry` / `maxTimeToExpiry` | 1 hour / 400 days (hard cap 730 days) |
| `maxSettlementPriceWad` | 1e30 (USD 10¹² per ETH; hard cap 1e36; `maxContractSize × maxSettlementPrice ≤ 1e50`) |
| Display symbols | "ETH", "USDC" (1–16 bytes) |
| Series per settlement group | ≤ 256 (constant) |
