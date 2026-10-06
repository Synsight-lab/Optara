#!/usr/bin/env python3
"""FFI entry point for Foundry differential tests (contract/test/differential/).

Each command prints one ABI-encoded uint256 as 0x-hex, computed by the independent reference model (pm_model.py)
with math.erfc as the normal CDF. WAD integers in, WAD integer out.

  cdf <x>                                       N(x)
  black76 <isCall 0|1> <F> <K> <sigma> <T>      Black-76 price (T in WAD years)
  iv <K> <S> <expiry> <reportTime> <tenors,> <kNodes,> <w row-major,> <minIv> <maxIv>
                                                surface IV (MATH.md section 5); w has len(tenors) x len(kNodes)
  risk <cashWad> <spot> <now> <legs>            (equity int256, IM, MM) with the default stress sets and the NR
                                                CDF; legs = "isCall:K:CS:expiry:q:sigma;..." (WAD ints, q signed)
"""
import sys

import pm_model as m

WAD = 10**18


def out(x: float) -> None:
    v = max(0, round(x * WAD))
    sys.stdout.write("0x" + v.to_bytes(32, "big").hex())


def ints(csv: str) -> list[int]:
    return [int(v) for v in csv.split(",") if v != ""]


def main(argv: list[str]) -> None:
    cmd = argv[0]
    if cmd == "cdf":
        out(m.ncdf_ref(int(argv[1]) / WAD))
    elif cmd == "black76":
        is_call, F, K, sigma, T = argv[1] == "1", *(int(a) / WAD for a in argv[2:6])
        out(m.black76(is_call, F, K, sigma, T))
    elif cmd == "iv":
        K, S = int(argv[1]) / WAD, int(argv[2]) / WAD
        expiry, report_time = float(argv[3]), float(argv[4])
        tenors = [float(t) for t in ints(argv[5])]
        knodes = [k / WAD for k in ints(argv[6])]
        flat = [w / WAD for w in ints(argv[7])]
        n = len(knodes)
        grid = [flat[i * n:(i + 1) * n] for i in range(len(tenors))]
        min_iv, max_iv = int(argv[8]) / WAD, int(argv[9]) / WAD
        out(m.iv_from_surface(K, S, expiry, report_time, tenors, knodes, grid, min_iv, max_iv))
    elif cmd == "risk":
        m.DEFAULT_CDF = m.ncdf_nr
        cash, S, now = int(argv[1]) / WAD, int(argv[2]) / WAD, float(argv[3])
        legs = []
        for item in argv[4].split(";"):
            if not item:
                continue
            c, K, cs, expiry, q, sigma = item.split(":")
            legs.append(m.Leg("X", c == "1", int(K) / WAD, int(cs) / WAD, float(expiry), int(q) / WAD,
                              int(sigma) / WAD))
        r = m.account_risk(cash, legs, {"X": S}, now, m.RiskParams())
        words = [round(r.equity * WAD) % 2**256, max(0, round(r.im * WAD)), max(0, round(r.mm * WAD))]
        sys.stdout.write("0x" + "".join(w.to_bytes(32, "big").hex() for w in words))
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv[1:])
