#!/usr/bin/env python3
"""Storage-layout check for upgradeable modules (docs/ACCESS_CONTROL.md §5, TEST_CASES UPG-001).

For every contract under src/ that is upgradeable (inherits OptaraModule, or is ProtocolControl):
  1. `forge inspect <C> storageLayout` must be empty: all state lives in ERC-7201 namespaced structs, so an upgrade
     can never shift a slot.
  2. Every `@custom:storage-location erc7201:<ns>` annotation must be followed by a slot constant equal to
     `cast index-erc7201 <ns>`.

  python3 script/storage_check.py        (run from contract/)
"""
import json
import re
import subprocess
import sys
from pathlib import Path

SRC = Path("src")
UPGRADEABLE_BASES = ("OptaraModule", "Initializable")
NOT_UPGRADEABLE = {"OptaraModule"}  # the abstract base itself is checked through its subclasses


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def upgradeable_contracts() -> list[tuple[str, Path]]:
    out = []
    for f in SRC.rglob("*.sol"):
        for m in re.finditer(r"^(?:abstract\s+)?contract\s+(\w+)\s+is\s+([^{]+)\{", f.read_text(), re.M):
            name, bases = m.group(1), m.group(2)
            if name not in NOT_UPGRADEABLE and any(b in bases for b in UPGRADEABLE_BASES):
                out.append((name, f))
    return out


def check_namespaces() -> list[str]:
    errors = []
    for f in SRC.rglob("*.sol"):
        text = f.read_text()
        for m in re.finditer(r"erc7201:([\w.]+)", text):
            ns = m.group(1)
            after = text[m.end():]
            const = re.search(r"bytes32\s+(?:private|internal)\s+constant\s+\w+\s*=\s*(0x[0-9a-fA-F]{64})", after)
            expected = run("cast", "index-erc7201", ns).strip().lower()
            if not const or const.group(1).lower() != expected:
                errors.append(f"{f}: slot constant for {ns} != {expected}")
    return errors


def main() -> int:
    errors = check_namespaces()
    contracts = upgradeable_contracts()
    if not contracts:
        errors.append("no upgradeable contracts found")
    for name, f in contracts:
        layout = json.loads(run("forge", "inspect", name, "storageLayout", "--json"))
        labels = [s["label"] for s in layout["storage"]]
        if labels:
            errors.append(f"{f}:{name} declares non-namespaced storage: {labels}")
        else:
            print(f"OK   {name}: no plain storage (ERC-7201 only)")
    for e in errors:
        print(f"FAIL {e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
