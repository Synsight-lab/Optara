"""Generate contract/test/TRACEABILITY.md: every TEST_CASES.md ID -> implementing test(s), or N/A with a reason.

Run: python3 script/traceability.py   (exits non-zero if any in-scope ID has no test)

Strict rule: an ID is covered only by an executable test that NAMES it -- a Solidity test/invariant function
whose name contains the ID (single IDs, "X_001_002" lists and "X_001_to_004" ranges), or a vitest it()/describe()
title in the frontend/indexer that contains it. Comments never count. Anything else is MISSING unless listed as
N/A below with the reason.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
TEST_DIR = os.path.join(ROOT, "contract", "test")
FRONTEND_TEST_DIRS = [os.path.join(ROOT, "frontend", "src"), os.path.join(ROOT, "indexer", "test")]
SPEC = os.path.join(ROOT, "docs", "TEST_CASES.md")
OUT = os.path.join(TEST_DIR, "TRACEABILITY.md")

ID_RE = re.compile(r"\b([A-Z]{2,6})[-_](\d{3})\b")
FN_RE = re.compile(r"function\s+(test\w*|invariant\w*|testFuzz\w*)\s*\(")
TS_TEST_RE = re.compile(r"""\b(?:it|test|describe)\(\s*["'`]([^"'`]+)["'`]""")

# IDs outside this repository or not applicable to canonical immutable V2, with the reason.
NOT_APPLICABLE = {
    **{f"SDK-{i:03d}": "@optara/sdk lives in the separate SDK repo; its suite runs there against deployments/ and test-vectors/" for i in range(1, 24)},
    **{f"MTH-{i:03d}": "@optara/math lives in the separate SDK repo; it runs test-vectors/vectors/*.json" for i in range(1, 10)},
    **{f"UPG-{i:03d}": "canonical V2 cores are immutable (ACCESS_CONTROL.md section 43); VER-001/002 prove no upgrade path" for i in range(1, 11)},
    **{f"FEE-{i:03d}": "no issuance-fee code exists in the MVP core (FEES.md section 24); fees cannot be enabled on this core" for i in range(4, 11)},
    "ORN-010": "Chainlink feeds publish no confidence interval; maxConfidenceBps is unused (ORACLE_AND_SETTLEMENT.md section 22)",
    "REE-007": "canonical V2 ships no router",
    "SAL-003": "no issuance router exists (USER_FLOWS.md section 37: not an MVP workflow)",
    "SDK-017": "@optara/sdk preview wording lives in the SDK repo; the contract side (a stale preview cannot bypass execution) is WRT-018 and INV-014",
    "SAL-002": "the SDK advertising rule is enforced in the SDK repo; the frontend never offers prepaid issuance",
}

def spec_ids():
    ids = []
    seen = set()
    for m in re.finditer(r"^#+\s+([A-Z]{2,6}-\d{3})\b|^\|\s*([A-Z]{2,6}-\d{3})\s*\|", open(SPEC).read(), re.M):
        i = m.group(1) or m.group(2)
        if i not in seen:
            seen.add(i)
            ids.append(i)
    return ids


def expand_name(name):
    """test_SER_016_to_020_x -> SER-016..SER-020; test_RED_010_011_012_x -> RED-010, RED-011, RED-012."""
    out = []
    tokens = name.split("_")
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if re.fullmatch(r"[A-Z]{2,6}", t) and i + 1 < len(tokens) and re.fullmatch(r"\d{3}", tokens[i + 1]):
            prefix = t
            j = i + 1
            nums = []
            while j < len(tokens):
                if re.fullmatch(r"\d{3}", tokens[j]):
                    nums.append(int(tokens[j]))
                    j += 1
                elif tokens[j] == "to" and j + 1 < len(tokens) and re.fullmatch(r"\d{3}", tokens[j + 1]):
                    start, end = nums[-1], int(tokens[j + 1])
                    nums.extend(range(start + 1, end + 1))
                    j += 2
                else:
                    break
            out.extend(f"{prefix}-{n:03d}" for n in nums)
            i = j
        else:
            i += 1
    return out


def collect():
    found = {}
    for base in [TEST_DIR] + FRONTEND_TEST_DIRS:
        if not os.path.isdir(base):
            continue
        for dirpath, _, files in os.walk(base):
            if "node_modules" in dirpath:
                continue
            for fn in files:
                is_sol = fn.endswith(".t.sol")
                if not (is_sol or fn.endswith(".test.ts") or fn.endswith(".test.tsx")):
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, os.path.join(ROOT, "contract")) if base == TEST_DIR else os.path.relpath(path, ROOT)
                for line in open(path):
                    if is_sol:
                        m = FN_RE.search(line)
                        if m:
                            for i in expand_name(m.group(1)):
                                found.setdefault(i, set()).add(f"{rel}::{m.group(1)}")
                    else:
                        m = TS_TEST_RE.search(line)
                        if m:
                            for pm in ID_RE.finditer(m.group(1)):
                                found.setdefault(f"{pm.group(1)}-{pm.group(2)}", set()).add(f"{rel}::{m.group(1)}")
    return found


def main():
    ids = spec_ids()
    found = collect()
    lines = [
        "# Test traceability (TEST_CASES.md)",
        "",
        "Generated by `contract/script/traceability.py`. Every TEST_CASES.md ID maps to at least one executable test",
        "whose name carries the ID (comments never count), or is marked N/A with the reason.",
        "Regenerate after renaming tests (TEST_CASES.md Appendix A rule).",
        "",
        "| ID | Status | Tests / reason |",
        "|---|---|---|",
    ]
    missing = []
    for i in ids:
        tests = sorted(found.get(i, set()))
        if tests:
            lines.append(f"| {i} | covered | {'<br>'.join(tests)} |")
        elif i in NOT_APPLICABLE:
            lines.append(f"| {i} | N/A | {NOT_APPLICABLE[i]} |")
        else:
            lines.append(f"| {i} | MISSING | |")
            missing.append(i)
    covered = sum(1 for l in lines if "| covered |" in l)
    na = sum(1 for l in lines if "| N/A |" in l)
    lines[5:5] = [f"Totals: {len(ids)} IDs, {covered} covered, {na} N/A, {len(missing)} missing.", ""]
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(ids)} IDs: {covered} covered, {na} N/A, {len(missing)} missing")
    if missing:
        print("MISSING:", " ".join(missing))
        sys.exit(1)


if __name__ == "__main__":
    main()
