# Optara PM — Reference Model and Verification

Executable checks of the specification in [`../docs`](../docs). Standard library only (Python ≥ 3.10).

| File | Purpose |
|---|---|
| `pm_model.py` | Independent model of `docs/MATH.md`: pricing, IV interpolation, margin, fees, liquidation, exact-integer settlement |
| `verify_math.py` | 24 property checks and every worked example in MATH.md |
| `verify_invariants.py` | Stateful simulation of all actions, liquidations and full settlement; asserts the `sim` invariants in `docs/INVARIANTS.md` after every step |
| `ffi.py` | Called by Foundry differential fuzz tests (`contract/test/differential/`) through FFI |
| `gen_vectors.py` | Regenerates `vectors/*.json`, the fixed vectors the Solidity differential tests read |
| `check_traceability.py` | Checks `docs/TEST_CASES.md` maps every invariant, function, view, error and event in the spec to existing tests |

```bash
python3 reference/verify_math.py --n 3000            # ~10 s
python3 reference/verify_invariants.py --runs 400 --steps 200   # ~65 s
python3 reference/check_traceability.py                        # instant
python3 reference/gen_vectors.py                               # regenerate vectors/ (commit the result)
```

All exit non-zero on any failure and print the seed, so the failing case can be replayed.

These scripts verify the **spec**. When the Solidity contracts exist, the same model serves as the reference for
differential and Foundry invariant tests (`docs/TESTING.md`).
