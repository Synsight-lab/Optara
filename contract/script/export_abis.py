#!/usr/bin/env python3
"""Exports the ABIs the frontend, SDK, indexer and keepers use to deployments/abi/<Contract>.json (DEPLOYMENT.md §3).

Proxies are called with their implementation's ABI, so each module's ABI is exported under the module name the
manifest uses. Run after `forge build`:

    python3 script/export_abis.py           # write
    python3 script/export_abis.py --check   # CI: fail if the committed ABIs differ from the build
"""

import json
import sys
from pathlib import Path

CONTRACT = Path(__file__).resolve().parent.parent
OUT = CONTRACT / "out"
ABI_DIR = CONTRACT.parent / "deployments" / "abi"
BYTECODE_DIR = CONTRACT.parent / "deployments" / "bytecode"

# Contracts the frontend DEPLOYS itself (ABI + creation bytecode), keyed by contract name -> source file. Exported
# from the build so a deploy can never use a stale or hand-copied bytecode.
DEPLOYABLE = {"OptaraDirectMarket": "OptaraDirectAdapter.sol"}

# The 15 proxied modules (manifest `proxies` keys), then the non-proxy contracts users and keepers touch.
CONTRACTS = [
    "ProtocolControl",
    "OptionSeriesRegistry",
    "ExternalOptionFactory",
    "SubAccounts",
    "LiveSpotOracle",
    "VolSurfaceOracle",
    "SettlementOracle",
    "PortfolioRiskManager",
    "InsuranceFund",
    "FeeController",
    "OptionClearing",
    "LiquidationModule",
    "SettlementWindow",
    "VenueRegistry",
    "VenueRouter",
    "UpgradeAdmin",
    "ExternalOptionWrapper",
    "KuruAdapter",
]


def abi_of(name: str) -> list:
    path = OUT / f"{name}.sol" / f"{name}.json"
    if not path.exists():
        sys.exit(f"{path} missing: run `forge build` first")
    return json.loads(path.read_text())["abi"]


def artifact_of(name: str, source: str) -> dict:
    path = OUT / source / f"{name}.json"
    if not path.exists():
        sys.exit(f"{path} missing: run `forge build` first")
    a = json.loads(path.read_text())
    if a["bytecode"].get("linkReferences"):
        sys.exit(f"{name} needs linked libraries; the frontend can't deploy it as-is")
    return {"abi": a["abi"], "bytecode": a["bytecode"]["object"]}


def render(abi: list) -> str:
    return json.dumps(abi, indent=2, sort_keys=True) + "\n"


def main() -> None:
    check = "--check" in sys.argv[1:]
    wanted = {f"{name}.json": render(abi_of(name)) for name in CONTRACTS}
    stale = []
    if not check:
        ABI_DIR.mkdir(parents=True, exist_ok=True)
    for file, text in wanted.items():
        path = ABI_DIR / file
        if check:
            if not path.exists() or path.read_text() != text:
                stale.append(file)
        else:
            path.write_text(text)
    extra = sorted(p.name for p in ABI_DIR.glob("*.json") if p.name not in wanted) if ABI_DIR.exists() else []
    deployable = {f"{n}.json": json.dumps(artifact_of(n, src), indent=2, sort_keys=True) + "\n" for n, src in DEPLOYABLE.items()}
    if not check:
        BYTECODE_DIR.mkdir(parents=True, exist_ok=True)
    for file, text in deployable.items():
        path = BYTECODE_DIR / file
        if check:
            if not path.exists() or path.read_text() != text:
                stale.append(f"bytecode/{file}")
        else:
            path.write_text(text)
    if check:
        if stale or extra:
            sys.exit(f"ABIs out of date: {stale + extra}; run `python3 script/export_abis.py`")
        print(f"{len(wanted)} ABIs and {len(deployable)} deployable artifacts up to date")
    else:
        for name in extra:
            (ABI_DIR / name).unlink()
        print(f"wrote {len(wanted)} ABIs to {ABI_DIR.relative_to(CONTRACT.parent)}")


if __name__ == "__main__":
    main()
