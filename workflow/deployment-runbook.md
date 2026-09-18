# Deployment Runbook

## Purpose

This file defines how to deploy V1 safely to Monad testnet and mainnet.

## Pre-Deployment Requirements

Before deployment:

- Founder decisions resolved or explicitly deferred.
- Contracts implemented from [implementation-spec.md](./implementation-spec.md).
- Tests from [testing-and-invariants.md](./testing-and-invariants.md) pass.
- External audit complete.
- Launch assets selected and allowlisted.
- Chainlink feed addresses confirmed.
- Pyth feed IDs confirmed.
- Optional DEX TWAP source confirmed.
- Kuru Router address confirmed.
- Kuru market parameter recommendations confirmed.
- Emergency multisig created and tested.
- Timelock/governance process documented.

## Deployment Order

1. Deploy `ProtocolConfig`.
2. Deploy oracle adapters:
   - `ChainlinkOracleAdapter`
   - `PythOracleAdapter`
   - optional `DexTwapOracleAdapter`
3. Deploy `OracleRouter`.
4. Deploy `SeriesRegistry`.
5. Deploy `KuruMarketAdapter`.
6. Deploy `PremiumExecutionGuard`.
7. Deploy `OptionSeriesFactory`.
8. Grant roles, including `FEE_ADMIN_ROLE`.
9. Configure allowlisted assets.
10. Configure approved oracle configs.
11. Configure default fee rates and the fee recipient, within the hard caps.
12. Configure Kuru Router/market defaults and maximum linkable venue fees.
13. Transfer admin roles to multisig/timelock.
14. Renounce deployer-only admin roles where appropriate.

Fee rates must be configured **before** the first `createSeries` call, because each series snapshots them at creation and can never be changed afterward. A series created against the wrong defaults must be abandoned and recreated.

## Testnet Procedure

For each launch pair:

1. Create test series.
2. Mint call and put options.
3. Link or deploy Kuru markets.
4. Place test sell orders.
5. Run premium range checks.
6. Execute buyer route with max premium.
7. Advance time or deploy short-expiry test series.
8. Settle with Chainlink/Pyth quorum.
9. Redeem buyer payout and confirm the exercise fee matches the expected value.
10. Claim writer residual.
11. Verify accounting invariants, including `vaultBalance >= collateralLocked + accruedFees`.
12. Sweep fees and confirm collateral is untouched.
13. Confirm the observed Kuru taker-fee convention against FD-17 and record the result.
14. Test oracle failure behavior.
15. Test Kuru unavailable behavior.

## Mainnet Procedure

1. Freeze commit hash.
2. Publish audit report and deployment config.
3. Deploy contracts.
4. Verify contracts on explorer.
5. Set allowlists.
6. Create first limited-size series.
7. Link Kuru market.
8. Run small mint.
9. Run small Kuru trade.
10. Wait for expiry.
11. Settle.
12. Redeem.
13. Claim writer residual.
14. Only then increase launch limits.

## Rollout Limits

Recommended staged rollout:

```text
Stage 0: internal testnet only
Stage 1: public testnet
Stage 2: mainnet guarded beta with low caps
Stage 3: higher caps after successful expiries
Stage 4: broader asset support after audit follow-up
```

V1 should include per-series or per-asset caps if feasible.

## Required Deployment Artifacts

Store in repository:

```text
deployments/monad-testnet.json
deployments/monad-mainnet.json
deployments/oracle-feeds.md
deployments/kuru-markets.md
deployments/roles.md
deployments/verification.md
```

## Post-Deployment Monitoring

Monitor:

- Oracle freshness.
- Chainlink/Pyth deviation.
- Per-series `vaultBalance` against `collateralLocked + accruedFees`.
- Fee accrual and sweep events.
- Kuru market depth.
- Kuru spread and any change to a linked market's fee parameters.
- Premium route rejections.
- Series collateralization.
- Redemption failures.
- Reentrancy or failed transfer anomalies.
- Admin role changes.
- Pause events.

## Emergency Actions

If issue found before expiry:

1. Pause minting.
2. Pause premium routing.
3. Leave transfers alone unless necessary.
4. Investigate.

If issue found during settlement:

1. Pause settlement only if oracle or settlement code is unsafe.
2. Do not use Kuru fallback.
3. Publish status.

If issue found during redemption:

1. Pause redemption only if redemption path is exploitable.
2. Snapshot state.
3. Prepare remediation plan.

## Needs Founder Decision

- Mainnet launch date.
- Initial asset pairs.
- Series caps.
- Admin multisig signers.
- Timelock duration.
- Bug bounty provider and size.
- Whether launch is guarded beta or open.

