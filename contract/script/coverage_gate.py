#!/usr/bin/env python3
"""Coverage gate (docs/TESTING.md §7). Reads an lcov file produced by `forge coverage --report lcov`.

Core files need 100% line and branch coverage; every other file under src/ needs >= 95% lines and >= 90% branches.

  python3 script/coverage_gate.py lcov.info
"""
import sys

CORE = ("OptionPricer.sol", "FixedPoint.sol", "PortfolioRiskManager.sol", "SettlementWindow.sol",
        "LiquidationModule.sol", "OptionClearing.sol")


def parse(path: str) -> dict:
    files, cur = {}, None
    for line in open(path):
        line = line.strip()
        if line.startswith("SF:"):
            cur = line[3:]
            files[cur] = {"lf": 0, "lh": 0, "brf": 0, "brh": 0}
        elif cur and line.startswith(("LF:", "LH:", "BRF:", "BRH:")):
            k, v = line.split(":")
            files[cur][k.lower()] = int(v)
    return {f: d for f, d in files.items() if f.startswith("src/")}


def pct(hit: int, found: int) -> float:
    return 100.0 if found == 0 else 100.0 * hit / found


def main() -> int:
    files = parse(sys.argv[1] if len(sys.argv) > 1 else "lcov.info")
    if not files:
        print("no src/ files in coverage report")
        return 1
    failed = 0
    for f, d in sorted(files.items()):
        lines, branches = pct(d["lh"], d["lf"]), pct(d["brh"], d["brf"])
        core = f.endswith(CORE)
        need_l, need_b = (100.0, 100.0) if core else (95.0, 90.0)
        ok = lines >= need_l and branches >= need_b
        failed += not ok
        print(f"{'OK  ' if ok else 'FAIL'} {f}: lines {lines:.2f}% (>= {need_l:.0f}), branches {branches:.2f}% "
              f"(>= {need_b:.0f}){'  [core]' if core else ''}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
