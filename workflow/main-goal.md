# Main Goal

## Purpose

Build a secure V1 options protocol on Monad that issues fully collateralized European call and put options as ERC-20 tokens, then lets those option tokens trade on Kuru as secondary-market assets.

The protocol must make one security promise above all others:

```text
Trading activity can change who owns an option token,
but it must never change how much collateral the option vault owes.
```

Kuru is used for price discovery and exchange. The protocol's own contracts are responsible for series creation, collateral custody, settlement, payout calculation, and redemption.

Premiums are market-discovered. A writer may choose the price at which they are willing to sell, and a buyer may choose the maximum premium they are willing to pay, but writer-specified asks should only be eligible for official routed execution when they fall inside a defensible market-acceptable range. Executed premium comes from voluntary trades, normally through Kuru limit-order matching.

## V1 Scope

V1 supports:

- European call options.
- European put options.
- One ERC-20 option token per immutable option series.
- Fully collateralized minting.
- Oracle-based settlement, priced at expiry and callable at any time after it.
- Secondary trading through Kuru Router and Kuru OrderBook markets.
- Canonical series discovery through a factory and registry.
- Protocol fees at mint and exercise, structurally isolated from collateral.
- No leverage, no margin, no undercollateralized writing, and no early exercise.

V1 intentionally excludes:

- American-style exercise.
- Borrowing, margin, leverage, rehypothecation, or partial collateral.
- Protocol settlement based on Kuru market prices.
- Dynamic series parameter changes after deployment.
- Exotic options, spreads, covered-call automation, vault strategies, or portfolio margin.
- Any mechanism where a malicious buyer or seller can cause the vault to release more collateral than the option payoff permits.

## Product Thesis

Options become easier to use on Monad if each series is represented by a standard ERC-20 token. ERC-20 option tokens can be transferred, integrated into wallets, and listed on Kuru without Kuru needing native knowledge of options.

The tradeoff is that the protocol must be extremely strict about what the ERC-20 token represents. A token balance is only a claim on a specific immutable series, with a specific underlying asset, quote asset, strike, expiry, option type, oracle, collateral model, and settlement formula.

## Success Criteria

The project is successful when:

- A writer can deposit the correct collateral and mint option tokens.
- A buyer can acquire option tokens directly or through Kuru.
- A buyer can protect themselves with an explicit maximum premium, slippage limit, and deadline for any one-click or routed purchase flow.
- A writer can specify an ask premium, but official helpers and frontends can reject or clearly flag asks that are outside reasonable economic and market-liquidity bounds.
- A buyer can redeem option tokens after settlement for the correct payout.
- A writer can withdraw only the residual collateral that remains after buyer claims.
- The protocol stays solvent even if Kuru is manipulated, thinly traded, paused, upgraded, unavailable, or filled with wash trades.
- Manipulated premium prices cannot change settlement, collateral release, or protocol accounting.
- Users and integrators can distinguish canonical option series from fake tokens.
- Series parameters cannot be changed after creation.
- Protocol fees are collected without ever reducing the collateral backing outstanding claims.
- Fee rates are fixed for a series' life, so a position's economics cannot change after entry.
- Users see protocol fees and Kuru venue fees as separate, explicit line items.
- Every critical accounting operation is covered by explicit invariants and tests.

## Security Philosophy

The protocol assumes markets are adversarial. Buyers, sellers, liquidity providers, keepers, and external venues may behave strategically or maliciously.

The protocol must therefore protect itself with structural guarantees:

- Require collateral before minting.
- Calculate maximum liability before accepting a position.
- Burn or mark claims before transferring payout.
- Use conservative rounding.
- Reject stale reference prices and invalid, unanchored, or too-late settlement prices.
- Isolate Kuru from collateral and settlement logic.
- Never treat writer-selected asks or isolated Kuru premium prices as protocol-recognized fair value.
- Validate premium execution against hard economic bounds, market-health checks, and buyer-side limits.
- Treat ERC-20 token integrations as untrusted external calls.
- Use canonical factory and registry checks for all official series.

## Document Map

- [PRD.md](./PRD.md) defines product requirements and V1 acceptance criteria.
- [architectural.md](./architectural.md) describes the contract architecture and trust boundaries.
- [design-decisions.md](./design-decisions.md) records the major design decisions and rejected alternatives.
- [math-of-core-invariants.md](./math-of-core-invariants.md) defines the collateral, payoff, rounding, and accounting invariants.
- [user-flow.md](./user-flow.md) describes the expected writer, buyer, keeper, and integrator flows.
- [implementation-spec.md](./implementation-spec.md) defines the production build specification.
- [contract-interfaces.md](./contract-interfaces.md) defines Solidity-facing interfaces and required errors.
- [storage-layout.md](./storage-layout.md) defines required storage and accounting relationships.
- [state-machine.md](./state-machine.md) defines legal state transitions.
- [oracle-spec.md](./oracle-spec.md) defines the Chainlink/Pyth oracle model and expiry anchoring.
- [premium-pricing-spec.md](./premium-pricing-spec.md) defines premium range and execution safety.
- [fee-spec.md](./fee-spec.md) defines Optara protocol fees and Kuru venue fee accounting.
- [kuru-integration-spec.md](./kuru-integration-spec.md) defines Kuru integration boundaries.
- [security-threat-model.md](./security-threat-model.md) defines threats and mitigations.
- [testing-and-invariants.md](./testing-and-invariants.md) defines required tests and invariant targets.
- [deployment-runbook.md](./deployment-runbook.md) defines deployment and rollout steps.
- [production-checklist.md](./production-checklist.md) defines the launch readiness checklist.
- [founder-decisions.md](./founder-decisions.md) lists decisions that require founder approval.
