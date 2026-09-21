# Monad/Kuru Options Protocol Spec Pack

## Start Here

Read in this order:

1. [main-goal.md](./main-goal.md)
2. [PRD.md](./PRD.md)
3. [architectural.md](./architectural.md)
4. [design-decisions.md](./design-decisions.md)
5. [math-of-core-invariants.md](./math-of-core-invariants.md)
6. [implementation-spec.md](./implementation-spec.md)
7. [contract-interfaces.md](./contract-interfaces.md)
8. [storage-layout.md](./storage-layout.md)
9. [state-machine.md](./state-machine.md)
10. [oracle-spec.md](./oracle-spec.md)
11. [premium-pricing-spec.md](./premium-pricing-spec.md)
12. [fee-spec.md](./fee-spec.md)
13. [kuru-integration-spec.md](./kuru-integration-spec.md)
14. [security-threat-model.md](./security-threat-model.md)
15. [testing-and-invariants.md](./testing-and-invariants.md)
16. [deployment-runbook.md](./deployment-runbook.md)
17. [production-checklist.md](./production-checklist.md)
18. [founder-decisions.md](./founder-decisions.md)
19. [user-flow.md](./user-flow.md)

## Non-Negotiable V1 Rules

- Fully collateralized European options only.
- Calls collateralized by underlying.
- Puts collateralized by quote.
- No leverage, margin, borrowing, liquidation, or early exercise.
- One immutable ERC-20 option token per series.
- Kuru is secondary trading only.
- Kuru is never settlement.
- Settlement uses Chainlink primary and Pyth corroborator. There is no third oracle source.
- The settlement price is the first oracle observation at or after expiry, proven onchain, never a live read.
- Oracle config approval is keyed on the asset pair, never on the config alone.
- Series creation is gated by `SERIES_CREATOR_ROLE` in V1, not permissionless.
- Premium execution uses Kuru depth only for route safety.
- Writer asks must pass acceptable premium range checks for official routed execution.
- Buyer routes must enforce max premium, min output, and deadline, all on fee-inclusive cost.
- Series parameters, fee rates, and settlement results are immutable per series.
- Protocol fees never reduce collateral backing outstanding claims.
- Kuru venue fees are accounted for in every quote and never captured by Optara.
- No protocol-owned trade router in V1.

## Agent Instructions

An AI agent building this system must:

- Implement exactly the interfaces and state transitions unless the spec is updated first.
- Stop and ask the founder before resolving any item in [founder-decisions.md](./founder-decisions.md).
- Treat every `Needs Founder Decision` item as a blocker for production launch.
- Treat a `Needs Founder Decision` item in another spec as a pointer to
  [founder-decisions.md](./founder-decisions.md). If it introduces a decision not
  listed there, raise it rather than choosing a value.
- Keep settlement independent from Kuru.
- Implement the worked test vectors in [math-of-core-invariants.md](./math-of-core-invariants.md)
  as the first tests, before the vault, and treat them as normative.
- Never let a fee path touch collateral backing outstanding claims.
- Write tests before considering the implementation production-ready.
- Run the launch checklist before deployment.
