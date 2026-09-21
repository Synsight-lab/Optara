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

## Fees

- [ ] Mint fee charged on top of collateral, never deducted from it.
- [ ] Exercise fee carved from gross payout with collateral outflow unchanged.
- [ ] `accruedFees` segregated from `collateralLocked` in storage and in every code path.
- [ ] Fee rates snapshotted per series at creation and immutable thereafter.
- [ ] Hard fee caps enforced as compile-time constants.
- [ ] `sweepFees` restricted to `FEE_ADMIN_ROLE` and cannot reach collateral.
- [ ] Zero-fee equivalence fuzz test passing.
- [ ] Fee line items shown separately in all user-facing flows.
- [ ] Kuru taker fees, maker-side adjustments, and AMM spread included in every premium quote and bound.
- [ ] Kuru taker-fee convention, maker fee or rebate convention, and AMM-spread behavior verified against deployed contracts, FD-17.
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
- [ ] Oracle config approval keyed on `(underlying, quote, configHash)`, verified by cross-pair rejection test.
- [ ] `createSeries` gated by `SERIES_CREATOR_ROLE`, FD-22.
- [ ] Open-interest caps set per launch series, FD-09.
- [ ] No transfer pause exists; option tokens are freely transferable.
- [ ] Kuru never used for settlement.
- [ ] Chainlink/Pyth deviation checks implemented.
- [ ] Reference-price stale checks implemented.
- [ ] Settlement anchoring implemented: Chainlink round in force at expiry with `maxChainlinkAgeAtExpiry`, Pyth first update with `maxPythSettlementLag`.
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
- [ ] At least one settlement source required on every approved config.
- [ ] No DEX TWAP adapter deployed or referenced.
- [ ] Deviation bounds within floor and ceiling on every approved config.
- [ ] Settlement price anchored to expiry, never a live read.
- [ ] Chainlink anchor proof verified against the immediate successor round, so exactly one round qualifies and no other round can be substituted.
- [ ] `maxChainlinkAgeAtExpiry` configured per feed heartbeat plus buffer, FD-21.
- [ ] `maxPythSettlementLag` configured per feed, FD-21.
- [ ] `maxPythConfidenceBps` configured per Pyth feed, FD-02, and the confidence check implemented.
- [ ] Pyth update data archived around every expiry for Pyth-required series.
- [ ] Composed settlement feeds are rejected in V1; every approved feed is direct for its pair.
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
