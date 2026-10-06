# Optara PM — Contracts

Foundry project for the on-chain protocol specified in [`../docs`](../docs/README.md). Build order and status:
[`../BUILD_PLAN.md`](../BUILD_PLAN.md).

## Layout

```text
src/
  accounts/SubAccounts.sol        the ledger: cash, signed balances, totals, indexes, participants (PROTOCOL_SPEC §1)
  governance/ProtocolControl.sol  roles, scoped pause bits, manual close-only flags (PROTOCOL_SPEC §11.1)
  governance/UpgradeAdmin.sol     proxy deployment, implementation allowlist, timelocked upgrades (§11.2)
  governance/OptaraModule.sol     base for every upgradeable module (ERC-7201, role/pause checks, reentrancy)
  governance/Roles.sol, PauseBits.sol
  libraries/Errors.sol     every custom error (mirrored in PROTOCOL_SPEC §13)
  libraries/OptaraTypes.sol  shared structs and enums (series terms, products, groups)
  series/OptionSeriesRegistry.sol   settlement assets, products, write-once series terms (PROTOCOL_SPEC §2)
  series/ExternalOptionFactory.sol  one wrapper clone per series at a deterministic address
  series/ExternalOptionWrapper.sol  ERC-20 + permit long token; fixed minter and burners
  series/SeriesNaming.sol           display names and symbols
  oracle/LiveSpotOracle.sol       Pyth spot prices per product (ORACLES §2)
  oracle/VolSurfaceOracle.sol     signed IV surfaces, Merkle leaves, status (ORACLES §3)
  oracle/SettlementOracle.sol     immutable configs, Chainlink round-in-force settlement (ORACLES §5)
  risk/FixedPoint.sol      units, conversions, rounding (MATH.md §1–§2)
  risk/OptionPricer.sol    normal CDF, Black-76, surface IV, stale IV, position value (MATH.md §3, §5–§7)
test/
  unit/          per-function behavior, reverts, events, worked examples
  fuzz/          properties over random inputs
  invariant/     stateful random action sequences against a ghost model
  differential/  Solidity vs the Python reference model (vectors + FFI)
  gas/           gas benchmarks with regression ceilings
  harness/       external wrappers around internal libraries (so tests can catch reverts)
  mocks/, utils/ mock modules (V1/V2 upgrades) and the governance deployment fixture
script/
  coverage_gate.py   TESTING.md §7 thresholds on an lcov report
  storage_check.py   upgradeable modules use ERC-7201 storage only; slot constants correct
```

## Commands

```bash
git submodule update --init --recursive     # forge-std, OpenZeppelin (+ upgradeable), Solady
forge build
forge test                                  # default profile (fuzz 1,000 runs; FFI tests 200)
FOUNDRY_PROFILE=ci forge test               # CI depth (fuzz 10,000 runs; FFI tests 2,000)
forge test --match-path 'test/gas/*' -vv    # print gas benchmarks
```

Differential tests run `python3 ../reference/ffi.py` (standard library only) and read `../reference/vectors/`.
Regenerate the vectors with `python3 ../reference/gen_vectors.py` after changing the reference model.
