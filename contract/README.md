# Optara V2 contracts

Immutable, versioned financial core (ACCESS_CONTROL.md section 40). Targets Monad (128 KB code size limit:
`OptaraCore` is ~30 KB, so local tools run with `--code-size-limit 131072`).

| Contract | Role |
|---|---|
| `core/OptaraCore.sol` (+ `OptaraCoreBase.sol`) | Accounts, stablecoin custody, bounded position indexes, exact margin, write/close/cancel/lock/unlock, finalize/sync/redeem, exposure caps, containment and verified-shortfall resolution |
| `config/OptaraConfig.sol` | Roles (GOVERNANCE, CONFIG, SERIES_CREATOR, ORACLE_CONFIG, PAUSER, UNPAUSER), asset/underlying/pair approvals, series bounds, exposure caps, position limits, scoped pauses |
| `oracle/OracleRegistry.sol` | Immutable oracle configs with signed-offset validation and new-series status |
| `oracle/ChainlinkSettlementAdapter.sol` | Round-in-force settlement rule, direct and derived (U/USD ÷ S/USD) sources, precommitted primary→secondary selection |
| `factory/SeriesFactory.sol` | Series validation, deterministic ids, CREATE2 option tokens with deterministic metadata |
| `token/OptionToken.sol` | 18-decimal ERC-20 long claim; mint/burn only by the core |
| `libraries/*` | Exact payoff numerators, critical-point worst case, single-rounding fixed point |

Key properties: exact integer payoff numerators with one rounding per accounting boundary (MATH.md section 24),
same-asset margin only, locked hedges only in custody, atomic group settlement, lazy sync, O(1) exposure release at
finalization, asset-wide containment and a timelocked uniform recovery ratio, no upgrade or rescue path.

## Tests

`forge test` runs 350+ tests: unit tests named by TEST_CASES.md id, fuzz tests, FFI differential tests against
`../test-vectors/optara_ref.py`, shared JSON vectors, a weighted stateful invariant campaign (supply identities,
exact pooled-vault identity, cap counters, solvency), hostile-token and reentrancy tests, max-portfolio gas tests,
and deployment tests. Coverage of production contracts is 100% lines/statements/branches/functions.
`test/TRACEABILITY.md` maps every TEST_CASES.md id.

## Deploy

See [`deploy/README.md`](deploy/README.md). Production values are never defaulted: templates mark them `REQUIRED`.
