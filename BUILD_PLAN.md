# Optara V2 — Build Plan (contracts, indexer, frontend)

Scope: everything in `docs/` except the SDK packages (`@optara/math`, `@optara/sdk`,
`@optara/kuru`, `@optara/shared`), which live in a separate repo and plug in later.
The docs remain the source of truth; every step below cites the section it implements.

## 0. Repository layout

```text
contract/       Foundry project (merged core, factory, token, oracle, config)
indexer/        Node/TypeScript event indexer + read API (SQLite)
frontend/       Vite + React + wagmi/viem web app (thin client layer in src/lib/optara)
test-vectors/   Independent exact-rational Python reference + generated JSON vectors
deployments/    Exported ABIs + per-network deployment manifests (consumed by SDK repo)
docs/           Specifications (unchanged except the repo-layout note, step 9)
```

## 1. Architecture decisions (confirmed with the user)

| Decision | Choice | Doc basis |
|---|---|---|
| Contract layout | **Merged core**: one `OptaraCore` holds accounts, custody, settlement, containment. Risk/payoff math are internal libraries. Separate: `OptaraConfig` (roles, approvals, pauses, limits), `SeriesFactory`, `OptionToken` clones, `OracleRegistry`, `ChainlinkSettlementAdapter`, `SettlementEngine`-equivalent logic lives in the core. | ARCHITECTURE §5 "exact Solidity types may differ"; ACCESS_CONTROL §17 "choose the simplest auditable design" |
| Oracle rule | Chainlink round-in-force at observation end, proven by immediate successor or latest round; direct and derived (U/USD ÷ S/USD) sources; precommitted primary→secondary selection with on-chain proof that the primary observation is invalid | ORACLE §§6–25, 71–77, 119; OPTION_SPEC §27 |
| Fees | No fee code (fee-free MVP, `write(seriesId, quantity, recipient)`) | FEES §§2, 24 |
| Upgradeability | None. Immutable core, one-time sealed wiring | ACCESS_CONTROL §§40–45 |
| Target chain | Monad (128 KB code size limit) | Monad docs |

## 2. Contracts (phase order follows ARCHITECTURE §26 / PROTOCOL_SPEC §39)

1. **Libraries**: `PayoffMath` (capped payoff, exact numerator, bounded products),
   `RiskMath` (critical points, worst-case numerator, settlement numerators),
   `FixedPointMath` (ceilDiv/floorDiv, D_A, rho scaling). MATH §§6–11, 22–26, 47, 50–54.
2. **OptaraConfig**: roles (GOVERNANCE, CONFIG, SERIES_CREATOR, ORACLE_CONFIG, PAUSER,
   UNPAUSER), asset/underlying/pair approval + status, series bounds, quantity increment,
   position limits (hard caps), buffer defaults, exposure limits (raise = governance,
   lower = pauser), scoped pause bits (global / asset / oracle config). ACCESS_CONTROL,
   PROTOCOL_SPEC §§29, 31, 37, 42, STATE_MACHINE §§3, 9–17.
3. **OracleRegistry + ChainlinkSettlementAdapter**: immutable configs, signed offset
   validation, `verifySettlementPrice(configId, expiry, data) payable`, statuses
   APPROVED/SUSPENDED/RETIRED. ORACLE §§6–25, 32–36, 71–77, 119; ARCHITECTURE §13.
4. **OptionToken (ERC-20, 18 dec, clone) + SeriesFactory**: validation, deterministic
   `seriesId`/`groupId` with `protocolSeriesDomain` (chainId + core + version),
   deterministic metadata. OPTION_SPEC §§5–20, 41; PROTOCOL_SPEC §43.
5. **OptaraCore**: deposit (+cure), recapitalize, withdraw, write, closeShort
   (EXTERNAL/LOCKED), cancelUnfinalizedShort, lockLong, unlockLong, syncRiskGroup,
   syncAccount, finalizeRiskGroup, redeem, checkAndRestrict, restrictAsset,
   clearAssetRestriction, propose/execute/cancel shortfall resolution, exposure
   counters with O(1) group release, bounded account indexes, views (requiredMargin,
   effectiveCash, freeCollateral, deficit, previews, lifecycle). PROTOCOL_SPEC §§10–24,
   41–43; MATH §§24–37, 46–58, 93–97, 118–119; LIQUIDATION §§101–102.
6. **Deployment scripts + manifest/ABI export** with explicit JSON config, chainId check,
   no silent defaults, role verification, deployer-role revocation. DEPLOYMENT.

## 3. Tests (TESTING.md, TEST_CASES.md)

- Unit tests named by catalog ID (`test_PAY_001_...`) for every contract area.
- Fuzz tests: payoff properties, risk monotonicity, rounding, split redemption.
- Differential tests: Solidity vs independent Python `Fraction` reference, via FFI fuzz
  and static JSON vectors (the same vectors the SDK repo will use).
- Stateful invariant suite with handlers and ghost/shadow accounting (INV-001..020,
  supply identities, pooled vault identity, exposure-counter identity).
- Hostile-token and reentrancy suites; DOS/gas at maximum limits; deploy tests
  DEPLOY-TEST-001..015.
- `contract/test/TRACEABILITY.md`: every TEST_CASES ID mapped to a test or marked
  N/A with justification (SDK/Kuru-package IDs move to the SDK repo; UPG-* N/A for the
  immutable core; FEE-004..010 N/A with no fee code; ORN-010 N/A for Chainlink).
- Coverage report (`forge coverage`), target 100% of core production code.

## 4. Indexer (`indexer/`)

Finality-depth log polling (viem), idempotent event store + derived tables in SQLite,
reorg rollback, on-chain reconciliation, monitoring alerts (cash < required, ORACLE_STALLED,
exposure near caps, restrictions), HTTP read API. Tests: reducers (unit) and an anvil
end-to-end run. SECURITY §§78–79, LIQUIDATION §91, DEPLOYMENT §68.

## 5. Frontend (`frontend/`)

Vite + React + wagmi/viem. Thin client layer in `src/lib/optara` with the function names
planned for `@optara/sdk`, so the SDK swaps in later by changing imports. All margin and
payoff numbers come from on-chain views (no local authoritative math). Screens: markets,
series detail (terms, max payout, state, write/lock/close/cancel/redeem), portfolio
(per-asset cash, required, free, groups, sync, deposit/withdraw), settlement (finalize
with Chainlink round proof), disclosures (settlement-liveness before acquisition,
ORACLE_STALLED state). Kuru trading stays in `@optara/kuru` (SDK repo); the frontend shows
verified market metadata only. KURU_INTEGRATION §§50–54; SECURITY §§74–77.

## 6. Local end-to-end

Anvil deployment with mock stablecoins (6 and 18 decimals) and mock Chainlink feeds,
seeded series, scripted lifecycle, indexer and frontend pointed at it.

## 7. Values not invented

Production oracle feeds, token addresses, limits, exposure caps, timelock delay and
signers stay as required fields in `contract/deploy/production.json` (deployment fails
if missing). Local/test values are labeled as such. PRD §20; DEPLOYMENT §84.

## 8. Docs touch-up (only where the build makes them inaccurate)

ARCHITECTURE §25 / README §14 / DEPLOYMENT §48: SDK packages live in a separate repo and
consume `deployments/` + `test-vectors/`.
