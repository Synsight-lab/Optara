# Optara PM — Build Plan

The specification is [`docs/`](docs/README.md). This plan orders the work. Every step cites the docs it implements
and ends only when its tests pass ([TESTING.md](docs/TESTING.md) §0: unit, fuzz, invariant, E2E for every contract).
V2's plan is in git history.

## 0. Repository layout

```text
contract/     Foundry project (all on-chain code, tests, deploy scripts)
reference/    Independent Python reference model + spec checks (exists)
deployments/  Per-network manifests and exported ABIs (step 14)
indexer/      Envio HyperIndex + health worker (step 15)
keepers/      Settlement keeper, liquidation bot, spot updater (step 15)
publisher/    Surface publisher service (step 15)
frontend/     Web app (step 16)
```

## 1. Build decisions

| Decision | Choice | Why |
|---|---|---|
| Compiler | Solidity 0.8.28, `evm_version = cancun`, optimizer 200 runs | Same toolchain as V2 (proven on Monad) |
| Code size | `code_size_limit = 131072` | Monad allows 128 KB runtime code |
| Math | Solady `FixedPointMathLib` (`lnWad`, `expWad`, `sqrt`, `fullMulDiv`) | MATH.md §6 requires audited primitives |
| Pricer | `OptionPricer` as an **internal** library (inlined) | No linked-library deployment step; cheaper calls; Monad's size limit leaves room |
| Proxies | OpenZeppelin v5 `TransparentUpgradeableProxy`, deployed by `UpgradeAdmin`, which owns every `ProxyAdmin` | Upgrade logic stays out of implementations, so a bad implementation can't brick upgrades |
| Governance | `ProtocolControl` (roles, pauses, manual close-only) read by every module; governance = timelock with the default admin role | One place for every safety switch (DD-20) |
| Storage | ERC-7201 namespaced storage in every upgradeable module | ACCESS_CONTROL protected storage; layout-safe upgrades |
| Dependencies | forge-std v1.9.7, OpenZeppelin v5.7.0 (+ upgradeable v5.7.0), Solady v0.1.26, as git submodules | Pinned tags |

## 2. Steps

Each step: code → unit tests → fuzz tests → differential tests against `reference/` where math is involved →
invariant handlers and E2E flows extended as modules land.

| # | Step | Implements | Done when |
|---|---|---|---|
| 1 | **Scaffold**: Foundry project, dependencies, config, CI | ARCHITECTURE §10, TESTING §8 | `forge build` and an empty test run pass |
| 2 | **Math**: `FixedPoint` (unit conversions, rounding), `OptionPricer` (normal CDF, Black-76, intrinsic, surface interpolation, stale IV) | MATH §1–§7 | PRC-001..007, VOL-010/011 math parts; differential vectors from `reference/pm_model.py` |
| 3 | **Shared base**: types, errors, events, roles, pause bits, ERC-7201 base, `UpgradeAdmin` (timelock + allowlist) | PROTOCOL_SPEC §11–§14, ACCESS_CONTROL | UPG-001/002, ACL-*, PAU-* |
| 4 | **Series**: `OptionSeriesRegistry`, `ExternalOptionFactory`, `ExternalOptionWrapper` | OPTION_SPEC, PROTOCOL_SPEC §2 | SER-* |
| 5 | **Ledger**: `SubAccounts` (owners, operators, cash, signed balances, totals, participants, position indexes) | PROTOCOL_SPEC §1, OPTION_SPEC §8 | ACC-*, INV-1/2/6/27 unit + fuzz |
| 6 | **Oracles**: `LiveSpotOracle` (+ Pyth source), `VolSurfaceOracle` (EIP-712 quorum, Merkle leaves), `SettlementOracle` (round-in-force, ported from `d89d3a1`) | ORACLES | SPT-*, VOL-*, STL-001..004 |
| 7 | **Risk**: `PortfolioRiskManager` (equity, buckets, scenarios, IM/MM, stale rules, health, previews) | MATH §8–§9, MARGIN_AND_RISK | MRG-*, differential IM/MM vs reference |
| 8 | **Fees & insurance**: `FeeController`, `InsuranceFund` | FEES, MATH §11 | FEE-* |
| 9 | **Clearing**: `OptionClearing` (deposit, withdraw, mint, wrap, unwrap, closes, `updateOracles`, custody, `pay*`) | PROTOCOL_SPEC §3–§4 | CLR-*, PRV-* |
| 10 | **Liquidation**: `LiquidationModule` | LIQUIDATION, MATH §12 | LIQ-* |
| 11 | **Settlement**: `SettlementWindow` | SETTLEMENT, MATH §13 | STL-* |
| 12 | **Venues**: `VenueRegistry`, `VenueRouter`, `KuruAdapter` (+ mock venue, fork test) | VENUES_AND_KURU | VEN-* |
| 13 | **System tests**: full invariant suite, E2E F1–F19, gas at max positions, upgrade/storage tests, Slither (added to CI here) | TESTING §0, §5–§7 | All INV/LIV, E2E-*, GAS-*, `check_traceability.py` |
| 14 | **Deployment**: scripts, manifests, ABI export, launch checklist | DEPLOYMENT | Local + testnet deploys verified |
| 15 | **Off-chain**: indexer (Envio + health worker), keepers, spot updater, surface publisher | INDEXER_AND_KEEPERS | KPR-*, PUB-*, IDX-* |
| 16 | **Frontend** | FRONTEND, USER_FLOWS | FE-* |

## 3. Rules while building

- The docs win. If code needs something the docs don't say, fix the docs in the same step and record it in
  [DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md).
- No contract is merged without its unit and fuzz tests ([TESTING.md](docs/TESTING.md) §0.2).
- Margin may never come out below the reference beyond rounding (TESTING §3).
- Values that must come from launch decisions (feeds, addresses, caps, signers) are required deploy inputs, never
  silent defaults.

## 4. Progress

| Step | Status | Notes |
|---|---|---|
| 1 | **Done** | `contract/` Foundry project, pinned submodules, profiles (default / ci / nightly / fork), CI (contracts, coverage gate, reference checks) |
| 2 | **Done** | `FixedPoint`, `OptionPricer`. 59 tests: unit, fuzz (10k in CI), differential vs reference (vectors + 2k FFI runs), gas. 100% line/branch coverage. Mutation check: 3/3 injected bugs caught. Gas: Black-76 5.3k, CDF 1.3k, surface IV 3.5k. Spec changes: NR `erfcc` CDF (DD-19), per-second stale penalty (C-12) |
| 3 | **Done** | `ProtocolControl` (roles, scoped pause bits, manual close-only), `UpgradeAdmin` (Transparent proxies, allowlist, 7-day / 24-hour paths, anyone executes), `OptaraModule` base (ERC-7201, transient reentrancy guard), shared `Errors.sol` (mirrored in PROTOCOL_SPEC §13 and enforced by the checker). Tests: unit, fuzz, invariant (with ghost model), storage-layout script. 100% coverage. Mutation check: 4/4 caught. Found and fixed: unbounded delay could wrap the uint64 eta. Spec changes: DD-20, DD-21 |
| 4 | **Done** | `OptionSeriesRegistry` (settlement assets, products with bounds and overflow hard caps, write-once terms, ≤ 256 series per group), `ExternalOptionFactory` (deterministic clones), `ExternalOptionWrapper` (ERC-20 + permit; fixed minter and three burners), `SeriesNaming`. Tests: unit, fuzz (incl. independent calendar check), invariant (write-once terms, group membership, supply conservation). 100% coverage. Mutation check: 5/5 caught. Spec changes: DD-22 (dependencies fixed at initialize via predicted addresses), DD-23 (overflow caps, settlement price clamp), C-13 (LiquidationModule burns; tenor coverage checked at mint) |
| 5 | **Done** | `SubAccounts`: accounts, operators, cash, signed balances; one write path `applyDelta` keeping totals (INV-2), minimum and multiple (INV-6), asset match (INV-5), bounded series/bucket indexes (INV-43) and the participant counter (INV-27); ledger events rebuild every balance; series data cached. Tests: unit, fuzz, invariant with ghost model, gas. 100% coverage. Mutation check: 6/6 caught. Gas: change 7.5k, close 15k, open 212k (cached) / 359k (first in series). Spec: DD-24 |
| 6 | **Done** | `LiveSpotOracle` (Pyth direct/derived, INV-18, exact fee + refund), `SettlementOracle` (V2 round-in-force rule with immutable hashed configs, fallback only after proven failure), `VolSurfaceOracle` (EIP-712 quorum with independent signer, ORACLES §3.4 checks, Merkle leaves, status, emergency/low-confidence flags). Tests: unit, fuzz (exactly-one-provable-round, every-field-signed, leaf exactness, IV-move boundary), invariants, differential EIP-712 against `cast` (alloy). 100% coverage. Mutation check: 12/12 caught. Spec: DD-25, DD-26, C-14 (settlement clamp per group from contract sizes), C-15 |
| 7 | **Done** | `PortfolioRiskManager` (equity, per-product buckets, IM over IM ∪ MM sets + short-mark buffer, MM, stale-direction IVs, expired/finalized legs, STRICT / LIQUIDATION / VIEW modes, close-only causes, OI caps, previews, risk-set admin). Supporting changes: ledger caches full series data + `positionsOf` + product short notional; surface `impliedVols`; `isRiskSetForProduct`. Tests: worked examples to the cent, differential vs reference (1e-9 of notional), pinned decisive portfolios, property fuzz (INV-13/14/41), invariants, GAS-001 = 4.76M. 100% coverage. Mutation check: 10/10 caught (after adding pinned portfolios; harness now rejects non-compiling mutants). Spec: DD-27, DD-28 |
| 8 | **Done** | `FeeController` (seller/buyer fee previews rounding up, exact split with treasury remainder, push-then-notify custody, treasury withdrawals, keeper reserve + escalating rewards capped at 4× and at the reserve, per-asset minimums with raise-instant/lower-governance, `reservesHealthy` wired into the risk manager) and `InsuranceFund` (exact deposits, permissioned notify with balance check, cover ≤ balance paid only to Clearing). Tests: FEE-001/003/004/006–013 unit, fuzz (INV-9 split, rounding, INV-37 rewards), invariant (recorded = held, INV-9, INV-10/37). 100% coverage. Mutation check: 27/28 caught; 1 equivalent (`>` vs `>=` at zero elapsed time). Spec: §8 rewritten, FEES §9, DD-29 |
| 9 | **Done** | `OptionClearing` (deposit with exact-transfer check, withdraw with STRICT health, `mintExternalLong` in the FEES §2 order with reserve gate, OI caps on the post-mint ledger and fee before health, wrap/unwrap, both closes incl. after expiry until finalization, `updateOracles`, `payInsurance`/`payOut` custody hooks, `previewMint`) and `OracleUpdates` (shared with liquidation: `spotProductIds`, stale reports skipped, exact provider fee + refund: DD-30). Tests: CLR-001..024, FEE-002, PRV-001 (incl. USER_FLOWS F2 numbers), fuzz (INV-1/2/7/9/13, PRV-001/002), invariant (custody = Σ cash, INV-1/2/27/9, INV-11/13 handler checks, progress check), GAS-003 mint to 16 legs with a full update = 5.80M. 100% coverage. Mutation check: 33/33 caught (after 3 added tests). Spec: §3–§4 rewritten, ORACLES §4, DD-30 |
| 10 | Next | |
