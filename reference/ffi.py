#!/usr/bin/env python3
"""FFI entry point for Foundry differential tests (contract/test/differential/).

Each command prints one ABI-encoded uint256 as 0x-hex, computed by the independent reference model (pm_model.py)
with math.erfc as the normal CDF. WAD integers in, WAD integer out.

  cdf <x>                                       N(x)
  black76 <isCall 0|1> <F> <K> <sigma> <T>      Black-76 price (T in WAD years)
  iv <K> <S> <expiry> <reportTime> <tenors,> <kNodes,> <w row-major,> <minIv> <maxIv>
                                                surface IV (MATH.md section 5); w has len(tenors) x len(kNodes)
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
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv[1:])
