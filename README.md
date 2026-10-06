# Optara PM

Uncapped, cash-settled European options on Monad with portfolio margin, liquidation and an insurance fund. Long
claims are ERC-20 wrapper tokens that trade on external venues (Kuru first).

The specification lives in [`docs/`](docs/README.md). The build order and progress are in
[`BUILD_PLAN.md`](BUILD_PLAN.md). The capped V2 design and its code are in git history.

| Folder | What it is |
|---|---|
| [`contract/`](contract/README.md) | Foundry project: on-chain protocol and its tests (in progress) |
| [`reference/`](reference/README.md) | Independent Python reference model, spec verification scripts, test vectors |
| `docs/` | Normative specification |
| `test-vectors/` | V2 reference vectors (kept for history; not used by PM) |

## Checks

```bash
python3 reference/verify_math.py --n 3000
python3 reference/verify_invariants.py --runs 400 --steps 200
python3 reference/check_traceability.py
cd contract && forge test
```
