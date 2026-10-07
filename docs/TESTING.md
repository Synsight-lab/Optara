# Testing Strategy

How to prove Optara PM works. The concrete list of required tests is in [TEST_CASES.md](TEST_CASES.md).

## 0. Mandatory rules (MUST)

### 0.1 Four test types are required for the system

| Type | What it proves | Where | Tool |
|---|---|---|---|
| **Unit** | Each function does exactly what [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) says: success path, every revert, every event, access control | `test/unit/<Contract>.t.sol` | Foundry |
| **Fuzz** | Properties hold for random inputs (amounts, prices, IVs, times, quantities), not just hand-picked ones | `test/fuzz/<Contract>.fuzz.t.sol` | Foundry fuzzing (≥ 10,000 runs in CI) |
| **Invariant** | Every property in [INVARIANTS.md](INVARIANTS.md) holds after any random sequence of actions by many actors | `test/invariant/` (handlers + `Invariants.t.sol`) | Foundry invariant tests (§5) |
| **E2E** | Full user journeys across all contracts work together: deposit → mint → trade → liquidate → expiry → settle → redeem | `test/e2e/` | Foundry on a local chain with all contracts deployed by the real deploy script |

None of the four replaces another. A change is not done until all four pass.

### 0.2 Every contract has its own tests

**Every contract, library and adapter that is created MUST have its own test file before it is merged.** For each
contract:

1. **Unit:** every external and public function has a success test, a test for each error it can raise, an event
   assertion, and an access-control test (wrong caller reverts).
2. **Fuzz:** every function that takes an amount, price, quantity, time or bps value has a fuzz test of its
   properties (bounds, monotonicity, rounding direction, no overflow).
3. **Invariant:** every function that changes state is called by an invariant handler (§5), so INVARIANTS.md is
   checked across it.
4. **E2E:** the contract takes part in at least one E2E flow.

Required coverage per contract (the TEST_CASES areas are the minimum, not the limit):

| Contract | Unit | Fuzz | Invariant handler | E2E | TEST_CASES areas |
|---|---|---|---|---|---|
| `SubAccounts` | ✓ | ✓ | ✓ | ✓ | ACC, CLR |
| `OptionSeriesRegistry` | ✓ | ✓ | ✓ | ✓ | SER |
| `ExternalOptionFactory` | ✓ | — | ✓ | ✓ | SER |
| `ExternalOptionWrapper` | ✓ | ✓ | ✓ | ✓ | CLR, STL, ACL |
| `OptionClearing` | ✓ | ✓ | ✓ | ✓ | CLR, PRV |
| `PortfolioRiskManager` | ✓ | ✓ | ✓ | ✓ | MRG, PRV |
| `OptionPricer` (library) | ✓ | ✓ | — (pure) | ✓ | PRC, VOL |
| `LiveSpotOracle` | ✓ | ✓ | ✓ | ✓ | SPT |
| `VolSurfaceOracle` | ✓ | ✓ | ✓ | ✓ | VOL |
| `SettlementOracle` | ✓ | ✓ | ✓ | ✓ | STL |
| `SettlementWindow` | ✓ | ✓ | ✓ | ✓ | STL |
| `LiquidationModule` | ✓ | ✓ | ✓ | ✓ | LIQ |
| `FeeController` | ✓ | ✓ | ✓ | ✓ | FEE |
| `InsuranceFund` | ✓ | ✓ | ✓ | ✓ | FEE, LIQ, STL |
| `VenueRegistry` | ✓ | — | ✓ | ✓ | VEN |
| `VenueRouter` | ✓ | ✓ | ✓ | ✓ | VEN, FEE |
| `KuruAdapter` | ✓ | ✓ | ✓ (mock venue) | ✓ (+ fork) | VEN |
| `ProtocolControl` | ✓ | ✓ | ✓ | ✓ | ACL, PAU |
| `UpgradeAdmin` | ✓ | ✓ | ✓ | ✓ | UPG, ACL |

"—" means the type does not apply (no numeric input, or a pure library). It never means "skip because it's hard".

### 0.3 Adding a new contract

A new contract (including a new venue adapter or a new module) is mergeable only when:

1. It has a row in the table above and in [ARCHITECTURE.md](ARCHITECTURE.md).
2. Its unit and fuzz test files exist and pass.
3. Its state-changing functions are added to the invariant handlers.
4. It is used in at least one E2E flow.
5. Its functions, errors and events are in [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) and mapped in
   [TEST_CASES.md](TEST_CASES.md), and `python3 reference/check_traceability.py` passes. The checker fails if an
   ARCHITECTURE.md module has no row in this table.
6. Coverage meets §7.

A pull request that adds or changes contract code without its tests MUST NOT be merged.

## 1. Principles

1. **An independent reference model checks every formula.** It is written in Python with arbitrary precision and
   never generated from the Solidity code.
2. **Every invariant has a stateful fuzz test** that runs random sequences of all actions.
3. **Every function has success, revert and event tests.**
4. **Margin, liquidation and settlement are tested with numbers worked out by hand** (the examples in
   [MATH.md](MATH.md)).
5. **Gas is measured at the configured maximums,** not on toy portfolios.

## 2. Test layers

| Layer | Tool | Scope |
|---|---|---|
| Math unit | Foundry + reference vectors | `OptionPricer` (ln, exp, sqrt, CDF, Black-76), interpolation, rounding helpers |
| Contract unit | Foundry | Each function in [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md): checks, effects, events, errors |
| Property fuzz | Foundry fuzzing | Pricing bounds, health monotonicity, liquidation improvement, settlement identities |
| Stateful invariants | Foundry invariant tests (handlers) | All of [INVARIANTS.md](INVARIANTS.md) |
| Differential | Foundry FFI or JSON vectors vs Python reference | Prices, IV, equity, IM, MM, slices, settlement, ratios |
| Integration | Foundry, local chain | End-to-end flows F1–F19 with mock oracles, publishers and a mock venue |
| Fork | Foundry fork of Monad mainnet (`FOUNDRY_PROFILE=fork`, `FORK_RPC_URL`) | Real Kuru router, order books and margin account (VEN-008); runs nightly and on demand in CI, never blocking pushes |
| Upgrade | OpenZeppelin upgrades plugin + custom tests | Storage layout, protected storage, timelock |
| Gas | `forge snapshot` + dedicated benchmarks | Risk check at max positions, liquidation, settlement batch |
| Static analysis | Slither | Zero unresolved findings |
| Services | Vitest/pytest | Publisher pipeline, keeper loops, indexer reorg handling |
| Frontend | Vitest + Testing Library + local chain | See [FRONTEND.md](FRONTEND.md) §11 |

## 3. Reference model (`reference/`)

**Implemented now** (standard library only, so no installs):

| Script | What it does |
|---|---|
| `reference/pm_model.py` | Independent model of [MATH.md](MATH.md): Black-76, CDF approximation, surface interpolation, margin (IM ∪ MM, short-mark buffer, stale rules), fees, liquidation cash flows, exact-integer settlement |
| `reference/verify_math.py` | 24 checks: pricing properties, CDF error bound, interpolation, every worked example, the margin theorems (risk-reducing monotonicity, MM ≤ IM, homogeneity, bucket separation, stale direction), the liquidation health theorem, settlement identity and ratio properties, rounding |
| `reference/verify_invariants.py` | Stateful simulation: random sequences of all user actions, oracle staleness, price gaps and liquidations, then full expiry, settlement, ratio, redemption and claims. Asserts every `sim` invariant in [INVARIANTS.md](INVARIANTS.md) after each step |
| `reference/ffi.py` | FFI entry point for Foundry differential fuzz tests: `cdf`, `black76`, `iv` computed by the reference model |
| `reference/gen_vectors.py` | Writes fixed JSON vectors to `reference/vectors/` (CDF, Black-76 incl. every MATH.md example) for Solidity differential tests |
| `reference/check_traceability.py` | Fails if any invariant, function, view, error or event in the spec has no test in [TEST_CASES.md](TEST_CASES.md), or if a test ID cited there doesn't exist |

```bash
python3 reference/verify_math.py --n 3000
python3 reference/verify_invariants.py --runs 400 --steps 200
python3 reference/check_traceability.py
```

All three must pass in CI before any spec change is merged.

**To add for differential testing against Solidity** (Python 3 with `mpmath`, 50-digit precision). Modules:

- `pricing.py`: Black-76, normal CDF, IV interpolation ([MATH.md](MATH.md) §5–§6).
- `margin.py`: equity, scenarios, buckets, IM, MM, stale adjustments (§7–§9).
- `fees.py`, `liquidation.py`, `settlement.py`: §11–§13, with exact integer numerators where the contracts use them.
- `vectors.py`: writes JSON vectors to `reference/vectors/*.json`.

Tolerances for Solidity vs reference:

| Quantity | Tolerance |
|---|---|
| Normal CDF | ≤ 1e-7 absolute |
| Option price | ≤ 1e-6 relative or ≤ 10 wei-WAD absolute |
| IM / MM | Solidity ≥ reference − 1 native unit, and ≤ reference × (1 + 1e-6) |
| Settlement, fees, ratios (integer math) | Exactly equal |

Rule: **margin may never come out below the reference by more than rounding.** Any under-margining beyond that fails
the build. For margin differentials the reference uses the same NR `erfcc` CDF as the contracts (`ffi.py risk`), so
the only differences are fixed-point rounding (tolerance 1e-9 of notional); the CDF approximation itself is checked
separately against the exact CDF (PRC-001/002).

Mutation checks: after each module, deliberately inject bugs and confirm tests fail. The harness must confirm each
mutant **compiles**; a mutant that doesn't compile reports zero failing tests and looks like a survivor.

## 4. Mocks

| Mock | Behavior |
|---|---|
| `MockSpotSource` | Settable price and publish time; can return stale data |
| `MockPublisherSet` | Test keys that sign real EIP-712 reports; builds Merkle trees |
| `MockChainlinkFeed` | Rounds with settable answers and timestamps (round-in-force proofs) |
| `MockVenue` + `MockKuruAdapter` | Fills at a set price with a set fee; can fail or be disabled |
| `MockERC20` (6 and 18 decimals), `FeeOnTransferToken`, `ReentrantToken` | Token edge cases |

## 5. Stateful invariant handlers

Actors: 3 writers, 2 buyers, 1 liquidator, 1 keeper, 1 guardian. Handlers (random inputs, bounded):

```text
createSubAccount, deposit, withdraw, mintExternalLong, wrapLong, unwrapLong,
closeShortWithWrapper, closeShortWithInternalLong, transferWrapper,
moveSpot (±60%), moveSurface (within sanity rules), letSurfaceGoStale, warpTime,
startAuction, liquidateSlice, liquidateWithWrapper,
finalizeGroup, settleAccountGroup, computeRecoveryRatio, redeemWrapper, claimSettlement,
pauseUnpause, setProductCloseOnly, buyThroughVenue (mock), sellThroughVenue (mock)
```

Ghost variables track: total minted, burned and redeemed per series; cumulative fees by destination; cumulative
insurance paid; per-group collected and paid. After each run, assert every invariant in
[INVARIANTS.md](INVARIANTS.md).

Run profiles: CI 256 runs × depth 100; nightly 5,000 runs × depth 300.

**Implementation.** Each module has its own invariant suite (`test/invariant/<Contract>.invariant.t.sol`), and
`test/invariant/System.invariant.t.sol` runs the list above across the whole protocol as deployed by
`script/OptaraDeploy.sol`: 3 writers (one with two accounts), 2 buyers with accounts, a liquidator/keeper and a
guardian; spot moves of −6%..+15% plus rare +40..+80% shocks, IV ±20%, time jumps up to 12 hours, starting 12 hours
before the 30-day group expires so runs reach settlement. Checked after every call: INV-1/2 (before finalization),
INV-7 (custody = Σ cash + pool), INV-26/27/28/29/31/33, INV-50; in handlers: INV-11, 13, 21, 22, 23, 46. A handler
may revert only with `ActionPaused` (anything else counts as a violation), and suites run clean with
`fail_on_revert = true`. Rules for handler suites, learned while building them:

- Measure progress offline (replay a few dozen seeds with `vm.snapshotState`) instead of asserting it per run: a
  per-run progress assertion is flaky and Foundry shrinks and caches its "failure".
- Build anything that makes external calls (oracle updates, view reads) **before** `vm.prank`; a prank applies to the
  next call, including calls inside argument expressions.
- Never add a `uint8` fuzz input to a literal (`(b + 1) % 2` overflows at 255); widen it first.

## 6. Gas benchmarks (launch gate)

| Benchmark | Setup | Target |
|---|---|---|
| Risk check | `maxSeriesPerAccount` positions across `maxBucketsPerAccount` underlyings, 24 + 12 scenarios | ≤ `maxRiskCheckGas` (measured 4.76M) |
| `mintExternalLong` | To 16 legs, including a surface report and 6 leaf proofs | Record (5.80M) |
| `liquidateSlice` | 8-leg bucket of a 16-leg account | Record (12.3M) |
| `settleAccountsGroup` | Batch of 20 accounts × 2 series | Record (3.3M) |
| `finalizeGroup` | 64 series in the group | Record (2.4M) |
| `submitReport` / `proveNodes` | Quorum 2, 32 nodes × 4 tenors; 4 of 128 leaves | Record (1.16M / 0.23M) |

If the risk check exceeds the target: lower `maxSeriesPerAccount`, curate fewer scenarios, or adopt the signed
price-table fallback ([ORACLES.md](ORACLES.md) §3.9) with a spec update.

## 7. Coverage gates

| Area | Line | Branch |
|---|---|---|
| `OptionPricer`, `PortfolioRiskManager`, `SettlementWindow`, `LiquidationModule`, `OptionClearing` | 100% | 100% |
| Other contracts | ≥ 95% | ≥ 90% |
| Every error in [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) §13 | Has a test that triggers it | — |
| Every event | Has an assertion | — |
| Every contract | Has unit, fuzz, invariant-handler and E2E tests per §0.2 | — |
| Every invariant, function, error, event | Mapped in [TEST_CASES.md](TEST_CASES.md) appendices; enforced by `reference/check_traceability.py` | — |

## 8. CI pipeline

```text
forge fmt --check → forge build → slither (triage database; SECURITY.md §8)
→ forge test: unit → fuzz (10,000 runs) → invariant (CI profile) → e2e
→ reference checks (verify_math, verify_invariants, check_traceability) → reference vectors (python) → differential tests → upgrade/storage tests → gas snapshot diff
→ services tests → frontend tests
→ exported ABIs match the build → local deployment on anvil (LocalStack, Verify, Smoke; DEPLOYMENT.md §4.1)
nightly: fuzz 100,000 runs, invariant deep profile, fork tests, deployment rehearsal on a mainnet fork (§4.2)
Any failing stage blocks the merge.
```
