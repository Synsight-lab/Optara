# Optara PM

Uncapped, cash-settled European options on Monad with portfolio margin, liquidation and an insurance fund. Long
claims are ERC-20 wrapper tokens that trade on external venues (Kuru first).

The specification lives in [`docs/`](docs/README.md). The build order and progress are in
[`BUILD_PLAN.md`](BUILD_PLAN.md). The capped V2 design and its code are in git history.

| Folder | What it is |
|---|---|
| [`contract/`](contract/README.md) | Foundry project: on-chain protocol, its tests and deployment scripts |
| [`reference/`](reference/README.md) | Independent Python reference model, spec verification scripts, test vectors |
| `deployments/` | Per-network configs, manifests, listing proposals and exported ABIs ([DEPLOYMENT.md](docs/DEPLOYMENT.md)) |
| `sdk/` | Shared TypeScript client code (manifests, ABIs, surface reports, oracle updates, settlement proofs) and the local-stack test helpers |
| `publisher/` | Volatility surface publisher service |
| `keepers/` | Oracle pusher, settlement keeper, reference liquidation bot |
| `indexer/` | Envio indexer plus the health worker / monitoring API |
| `docs/` | Normative specification |
| `test-vectors/` | V2 reference vectors (kept for history; not used by PM) |

## Checks

```bash
python3 reference/verify_math.py --n 3000
python3 reference/verify_invariants.py --runs 400 --steps 200
python3 reference/check_traceability.py
cd contract && forge test
```

Services ([INDEXER_AND_KEEPERS.md](docs/INDEXER_AND_KEEPERS.md) §7; Node ≥ 22.15, pnpm, Foundry, and for the indexer
tests Postgres via `pnpm --filter @optara/indexer exec envio local docker up`):

```bash
pnpm install
(cd contract && forge build)
pnpm --filter @optara/indexer codegen
pnpm -r typecheck
pnpm -r --workspace-concurrency=1 test
```
