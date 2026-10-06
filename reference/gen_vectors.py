#!/usr/bin/env python3
"""Generate JSON test vectors for the Solidity differential tests from the reference model.

  python3 reference/gen_vectors.py          # writes reference/vectors/pricing.json

Vectors are deterministic (fixed seed). Integers are written as decimal strings so no JSON parser loses precision.
"""
import json
import math
import random
from pathlib import Path

import pm_model as m

WAD = 10**18
OUT = Path(__file__).resolve().parent / "vectors"


def wad(x: float) -> int:
    return max(0, round(x * WAD))


def s(values: list[int]) -> list[str]:
    return [str(v) for v in values]


def cdf_vectors() -> dict:
    xs = [i / 100 for i in range(-1000, 1001, 7)] + [-38.0, -12.0, -9.0, 9.0, 12.0, 38.0]
    x = [round(v * WAD) for v in xs]
    return {"x": s(x), "n": s([wad(m.ncdf_ref(v / WAD)) for v in x])}


def black76_vectors(rng: random.Random) -> dict:
    cases = []
    # MATH.md section 10 worked examples: ETH 4,000, 30 days.
    t30 = 30 * 86400 * WAD // m.YEAR
    cases += [(True, 4000 * WAD, 4500 * WAD, wad(0.60), t30), (True, 4000 * WAD, 5000 * WAD, wad(0.62), t30),
              (False, 4000 * WAD, 3500 * WAD, wad(0.65), t30)]
    # MATH.md section 12.1: ETH 6,200, 20 days, 4,500 call at 60%.
    cases.append((True, 6200 * WAD, 4500 * WAD, wad(0.60), 20 * 86400 * WAD // m.YEAR))
    # Random grid: spot 0.001 to 1e7, moneyness 0.05x to 20x, IV 1% to 500%, T 1 second to 2 years.
    for _ in range(600):
        F = wad(10 ** rng.uniform(-3, 7))
        K = max(1, wad(F / WAD * math.exp(rng.uniform(-3, 3))))
        sigma = wad(rng.uniform(0.01, 5.0))
        T = rng.choice([rng.randint(1, 3600), rng.randint(3600, 2 * m.YEAR)]) * WAD // m.YEAR
        cases.append((rng.random() < 0.5, F, K, sigma, T))
    cols = list(zip(*cases))
    price = [wad(m.black76(c, F / WAD, K / WAD, sg / WAD, T / WAD)) for c, F, K, sg, T in cases]
    return {"isCall": list(cols[0]), "F": s(cols[1]), "K": s(cols[2]), "sigma": s(cols[3]), "T": s(cols[4]),
            "price": s(price)}


def main() -> None:
    rng = random.Random(20261006)
    OUT.mkdir(exist_ok=True)
    data = {"cdf": cdf_vectors(), "black76": black76_vectors(rng)}
    (OUT / "pricing.json").write_text(json.dumps(data, indent=1) + "\n")
    print(f"wrote {OUT / 'pricing.json'}: {len(data['cdf']['x'])} cdf, {len(data['black76']['F'])} black76")


if __name__ == "__main__":
    main()
