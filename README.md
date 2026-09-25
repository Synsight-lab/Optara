# Optara V2

Capped, cash-settled European options on Monad with exact worst-case portfolio margin. The specification lives in
[`docs/`](docs/README.md); this repository contains the authoritative contracts and the non-authoritative
indexer and web app. The `@optara/*` SDK packages live in a separate repository and consume `deployments/` and
`test-vectors/`.

| Folder | What it is |
|---|---|
| [`contract/`](contract/README.md) | Foundry project: `OptaraCore`, `OptaraConfig`, `OracleRegistry`, `ChainlinkSettlementAdapter`, `SeriesFactory`, `OptionToken`, deploy scripts, full test suite |
| [`indexer/`](indexer/README.md) | Event indexer, reconciliation monitor, read API, optional permissionless keeper |
| [`frontend/`](frontend/README.md) | Web app (Vite + React + wagmi) with a thin client layer shaped like `@optara/sdk` |
| `deployments/` | Per-network manifests and exported ABIs (JSON + typed TS) |
| `test-vectors/` | Independent exact-rational reference model, JSON math vectors, design regressions |
| `docs/` | Normative specifications |

## Local quickstart

```bash
# 1. chain + contracts (mock stablecoins/feeds; local only)
anvil --code-size-limit 131072
cd contract && forge script script/local/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --code-size-limit 131072
python3 script/export_abis.py

# 2. indexer (API on :8787)
cd ../indexer && npm install && OPTARA_MANIFEST=../deployments/local.json CHAIN_ID=31337 RPC_URL=http://127.0.0.1:8545 CONFIRMATIONS=0 npm start

# 3. web app
cd ../frontend && npm install && VITE_NETWORK=local VITE_INDEXER_URL=http://localhost:8787 npm run dev
```

Open http://localhost:5173. In a browser wallet (MetaMask or similar), add the network `http://127.0.0.1:8545`,
chain id `31337`, and import anvil account #3
(`0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6`, a public test key). It holds 1,000,000 of
each mock stablecoin and test ETH for gas. After restarting anvil, clear the wallet's activity/nonce data for that
network.

To see expiry and settlement without waiting 7 days:

```bash
cd contract && script/local/expire.sh 13   # jump chain time past the first expiry, publish MON/USDT = 13
```

Then press Finalize on the Settlement page (or start the indexer with `npm run keeper` and
`KEEPER_PRIVATE_KEY`), redeem longs, and sync writers' groups.

## Tests

```bash
cd contract && forge test            # unit, fuzz, FFI differential, invariant, deploy (needs python3)
cd contract && forge coverage --no-match-coverage "test/|script/"
python3 test-vectors/design_regressions.py
cd indexer && npm test               # unit + anvil end-to-end
cd frontend && npm test              # unit, component, anvil integration
python3 contract/script/traceability.py   # TEST_CASES.md ID coverage
cd contract && FOUNDRY_PROFILE=fork forge test   # Kuru secondary market on a Monad testnet fork (network)
```

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push, pull request and manual dispatch.
`CI passed` is the single required check for branch protection.

| Job | Gate |
|---|---|
| Contracts | `forge fmt --check`, build, Monad size limits (`script/ci_checks.py sizes`), full suite under the `ci` profile (10k fuzz runs, 512×400 invariants), exact gas snapshot |
| Coverage | `src/` must stay at 100% lines, functions and branches |
| Slither | fails on any High finding; Medium and above are uploaded to code scanning |
| Conformance | reference-model regressions; math vectors, exported ABIs and `TRACEABILITY.md` regenerated from source and required to be committed up to date |
| Indexer / Frontend | typecheck, unit tests, anvil end-to-end against a real local deployment, production build |
| Kuru fork | real Kuru Spot V2 on a Monad testnet fork; non-blocking because it depends on a live RPC (set the `MONAD_TESTNET_RPC` secret to use your own) |

When gas changes on purpose, run `cd contract && forge snapshot` and commit `.gas-snapshot`.
