"""CI gates that Foundry does not provide directly.

  python3 script/ci_checks.py sizes             # run after `forge build`
  python3 script/ci_checks.py coverage lcov.info

sizes     Monad allows 128 KB runtime code and 256 KB initcode (docs.monad.xyz, "Differences between Monad and
          Ethereum"). `forge build --sizes` always applies Ethereum's EIP-170/3860 limits, so it would reject
          OptaraCore (~30 KB) even though it deploys on Monad. This checks every src/ contract against Monad's limits.
coverage  Requires 100% line, function and branch coverage of src/ (DEPLOYMENT.md section 12 coverage gate) from an
          lcov report produced by `forge coverage --report lcov`.
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = os.path.normpath(os.path.join(HERE, ".."))
MONAD_MAX_RUNTIME = 128 * 1024
MONAD_MAX_INITCODE = 256 * 1024


def sizes() -> int:
    failures = 0
    rows = []
    for src in sorted(glob.glob(os.path.join(CONTRACT, "src", "**", "*.sol"), recursive=True)):
        name = os.path.basename(src)[:-4]
        artifact = os.path.join(CONTRACT, "out", f"{name}.sol", f"{name}.json")
        if not os.path.exists(artifact):
            continue  # interfaces and files without a same-named contract
        j = json.load(open(artifact))
        runtime = (len(j["deployedBytecode"]["object"]) - 2) // 2
        init = (len(j["bytecode"]["object"]) - 2) // 2
        if runtime == 0:
            continue  # abstract contracts / interfaces
        ok = runtime <= MONAD_MAX_RUNTIME and init <= MONAD_MAX_INITCODE
        failures += not ok
        rows.append(f"{'OK ' if ok else 'BIG'} {name:28} runtime {runtime:7,} / {MONAD_MAX_RUNTIME:,}   "
                    f"initcode {init:7,} / {MONAD_MAX_INITCODE:,}")
    if not rows:
        print("no build artifacts found; run `forge build` first")
        return 1
    print("\n".join(rows))
    return 1 if failures else 0


def coverage(lcov_path: str) -> int:
    totals = {"LF": 0, "LH": 0, "FNF": 0, "FNH": 0, "BRF": 0, "BRH": 0}
    current = None
    missing = []
    for line in open(lcov_path):
        line = line.strip()
        if line.startswith("SF:"):
            current = line[3:]
        elif current and "src/" in current and ":" in line:
            key, _, value = line.partition(":")
            if key in totals:
                totals[key] += int(value)
        if line == "end_of_record" and current and "src/" in current:
            current = None
    for label, found, hit in (("lines", "LF", "LH"), ("functions", "FNF", "FNH"), ("branches", "BRF", "BRH")):
        pct = 100.0 if totals[found] == 0 else 100.0 * totals[hit] / totals[found]
        print(f"{label:9} {totals[hit]:5}/{totals[found]:<5} {pct:6.2f}%")
        if totals[hit] != totals[found]:
            missing.append(label)
    if missing:
        print(f"coverage gate failed: src/ must be fully covered ({', '.join(missing)})")
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "sizes":
        sys.exit(sizes())
    if len(sys.argv) >= 3 and sys.argv[1] == "coverage":
        sys.exit(coverage(sys.argv[2]))
    print(__doc__)
    sys.exit(2)
