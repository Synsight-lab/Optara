# Production Checklist

## Purpose

This checklist must be complete before mainnet launch.

## Product

- [ ] V1 scope frozen.
- [ ] No margin or leverage in V1.
- [ ] No early exercise in V1.
- [ ] No pre-expiry close flow in V1.
- [ ] User-facing risk copy approved.
- [ ] Fake-series warnings implemented.
- [ ] Kuru liquidity risk disclosed.
- [ ] Premium range warnings implemented.

## Contracts

- [ ] `SeriesRegistry` implemented.
- [ ] `OptionSeriesFactory` implemented.
- [ ] `OptionSeriesVault` implemented.
- [ ] `OracleRouter` implemented.
- [ ] `ChainlinkOracleAdapter` implemented.
- [ ] `PythOracleAdapter` implemented.
- [ ] `PremiumExecutionGuard` implemented as validation-only, per the resolved V1 scope.
- [ ] No protocol-owned trade router deployed, per the resolved V1 scope.
- [ ] `KuruMarketAdapter` implemented.
- [ ] `ProtocolConfig` implemented, including fee defaults and fee recipient.
- [ ] Optional DEX TWAP adapter decision made.

## Fees

- [ ] Mint fee charged on top of collateral, never deducted from it.
- [ ] Exercise fee carved from gross payout with collateral outflow unchanged.
- [ ] `accruedFees` segregated from `collateralLocked` in storage and in every code path.
- [ ] Fee rates snapshotted per series at creation and immutable thereafter.
- [ ] Hard fee caps enforced as compile-time constants.
- [ ] `sweepFees` restricted to `FEE_ADMIN_ROLE` and cannot reach collateral.
- [ ] `sweepDust` gated on full wind-down.
- [ ] Zero-fee equivalence fuzz test passing.
- [ ] Fee line items shown separately in all user-facing flows.
- [ ] Kuru maker and taker fees included in every premium quote and bound.
- [ ] Kuru taker-fee convention verified against deployed contracts, FD-17.
- [ ] Maximum linkable venue fee configured and enforced.

## Security

- [ ] All live series parameters immutable.
- [ ] Settlement result write-once.
- [ ] Reentrancy guards in place.
- [ ] SafeERC20 used.
- [ ] Fee-on-transfer tokens rejected.
- [ ] Rebasing tokens rejected.
- [ ] Collateral rounded up.
- [ ] Payout rounded down.
- [ ] `writerResidualRate` computed by subtraction, never independently rounded.
- [ ] Worked test vectors from the math spec asserted exactly.
- [ ] Minimum sizes enforced at mint only, never on redeem or residual claim.
- [ ] Transfer pause verified not to block mint or burn.
- [ ] Kuru never used for settlement.
- [ ] Chainlink/Pyth deviation checks implemented.
- [ ] Oracle stale checks implemented.
- [ ] Premium route fail-closed behavior implemented.
- [ ] Emergency pause scoped.

## Tests

- [ ] Unit tests passing.
- [ ] Fuzz tests passing.
- [ ] Invariant tests passing.
- [ ] Oracle failure tests passing.
- [ ] Kuru manipulation tests passing.
- [ ] Premium manipulation tests passing.
- [ ] Reentrancy tests passing.
- [ ] Decimal mismatch tests passing.
- [ ] Rounding edge tests passing.
- [ ] Coverage reviewed.

## Audit

- [ ] Internal review complete.
- [ ] Slither run complete.
- [ ] External audit complete.
- [ ] Audit fixes implemented.
- [ ] Fix review complete.
- [ ] Known issues documented.
- [ ] Bug bounty ready.

## Oracle

- [ ] Chainlink feeds confirmed.
- [ ] Pyth feed IDs confirmed.
- [ ] Feed decimals confirmed.
- [ ] Stale thresholds configured.
- [ ] Deviation threshold configured.
- [ ] Single-oracle policy decided.
- [ ] DEX TWAP policy decided.
- [ ] Settlement price anchored to expiry, never a live read.
- [ ] Anchor proof verified against the preceding observation so a later round cannot be substituted.
- [ ] `maxSettlementLag` configured per feed heartbeat, FD-21.
- [ ] Staleness thresholds confirmed to apply to reference reads only.
- [ ] Prolonged-outage recovery path decided, FD-20, or permanent-lock risk explicitly accepted and disclosed.
- [ ] Oracle outage procedure documented.

## Kuru

- [ ] Kuru Router address confirmed.
- [ ] Kuru market deployment tested.
- [ ] Market precision parameters tested.
- [ ] Min size tested.
- [ ] Kuru market linking tested.
- [ ] Kuru downtime behavior tested.
- [ ] Kuru manipulation does not affect settlement.

## Operations

- [ ] Deployment scripts ready.
- [ ] Mainnet config reviewed by two people.
- [ ] Multisig configured.
- [ ] Timelock configured if used.
- [ ] Role transfer complete.
- [ ] Deployer permissions removed or minimized.
- [ ] Monitoring dashboards live.
- [ ] Alerting live.
- [ ] Incident runbook published.

## Founder Decisions

- [ ] All items in [founder-decisions.md](./founder-decisions.md) resolved or explicitly deferred.

