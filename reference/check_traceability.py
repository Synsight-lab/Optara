#!/usr/bin/env python3
"""Check that docs/TEST_CASES.md covers the whole spec.

Fails (exit 1) if:
  - an invariant in INVARIANTS.md has no test in Appendix A, or Appendix A names an unknown invariant;
  - an appendix cites a test ID that is not defined in the catalog;
  - a function or view in PROTOCOL_SPEC.md §1-§11 is not named by any test or Appendix B;
  - PROTOCOL_SPEC.md §13 differs from contract/src/libraries/Errors.sol (spec and code must declare the same errors);
  - an error in PROTOCOL_SPEC.md §13 has no test in Appendix C;
  - an event in PROTOCOL_SPEC.md §14 is not named by any test case;
  - a contract in ARCHITECTURE.md has no row in TESTING.md §0.2 (unit/fuzz/invariant/E2E per contract).
"""
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
ID = r"[A-Z0-9]{2,4}-\d{3}"


def section(text, start, end=None):
    """Text from the heading matching `start` up to the heading matching `end`."""
    i = re.search(start, text, re.M).start()
    j = re.search(end, text[i + 1:], re.M) if end else None
    return text[i:i + 1 + j.start()] if j else text[i:]


def expand(cell):
    """'A-001, B-002 – B-004' -> ['A-001', 'B-002', 'B-003', 'B-004']."""
    out = []
    for part in cell.split(","):
        m = re.fullmatch(rf"\s*({ID})\s*[–-]\s*({ID})\s*", part)
        if m:
            area, a = m.group(1).rsplit("-", 1)
            b = m.group(2).rsplit("-", 1)[1]
            out += [f"{area}-{n:03d}" for n in range(int(a), int(b) + 1)]
        else:
            out += re.findall(ID, part)
    return out


def appendix(text, title):
    rows = {}
    for line in section(text, rf"^## Appendix {title}", r"^## ").splitlines()[3:]:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 2 and not set(cells[0]) <= set("-"):
            rows[cells[0]] = expand(cells[1])
    return rows


def main():
    inv_text = (DOCS / "INVARIANTS.md").read_text()
    tc_text = (DOCS / "TEST_CASES.md").read_text()
    spec = (DOCS / "PROTOCOL_SPEC.md").read_text()
    errors = []

    catalog = tc_text.split("## Appendix A")[0]
    tests = dict(re.findall(rf"^\| ({ID}) \| (.*) \|$", catalog, re.M))
    test_text = " ".join(tests.values())

    def check_cited(label, rows):
        for key, ids in rows.items():
            if not ids:
                errors.append(f"{label}: {key} has no tests")
            for t in ids:
                if t not in tests:
                    errors.append(f"{label}: {key} cites undefined test {t}")

    # Invariants
    invariants = sorted(set(re.findall(r"\*\*((?:INV|LIV)-\d+)\*\*", inv_text)))
    app_a = appendix(tc_text, "A")
    check_cited("Appendix A", app_a)
    for inv in invariants:
        if inv not in app_a:
            errors.append(f"Appendix A: {inv} missing")
    for inv in app_a:
        if inv not in invariants:
            errors.append(f"Appendix A: {inv} is not in INVARIANTS.md")

    # Functions and views (§1-§11)
    body = section(spec, r"^## 1\. ", r"^## 12\. ")
    names = set(re.findall(r"`(?:\w+\.)?([a-z]\w*)\s*\(", body)) - {"floor", "ceil", "min", "max", "keccak256"}
    names |= set(re.findall(r"`(\w+)`", section(spec, r"^## 10\. ", r"^## 11\. ")))
    names |= set(re.findall(r"\b(addPublisher|removePublisher)\b", body))
    app_b = appendix(tc_text, "B")
    check_cited("Appendix B", app_b)
    covered = " ".join(app_b) + " " + test_text
    for n in sorted(names):
        if not re.search(rf"\b{n}\b", covered):
            errors.append(f"function/view {n} not named in any test or Appendix B")

    # Errors (§13) — must mirror Errors.sol exactly
    spec_errors = re.findall(r"^error (\w+)\(", spec, re.M)
    sol = DOCS.parent / "contract" / "src" / "libraries" / "Errors.sol"
    if sol.exists():
        sig = lambda text: sorted(re.findall(r"^error \w+\([^)]*\);", text, re.M))
        if sig(spec) != sig(sol.read_text()):
            only_spec = set(sig(spec)) - set(sig(sol.read_text()))
            only_sol = set(sig(sol.read_text())) - set(sig(spec))
            errors.append(f"PROTOCOL_SPEC §13 != Errors.sol (spec only: {sorted(only_spec)}; code only: {sorted(only_sol)})")
    app_c = appendix(tc_text, "C")
    check_cited("Appendix C", app_c)
    for e in spec_errors:
        if e not in app_c:
            errors.append(f"Appendix C: error {e} missing")
    for e in app_c:
        if e not in spec_errors:
            errors.append(f"Appendix C: {e} is not an error in PROTOCOL_SPEC.md")

    # Every ARCHITECTURE.md module has a row in TESTING.md §0.2
    arch = (DOCS / "ARCHITECTURE.md").read_text()
    modules = re.findall(r"^\| `(\w+)` \|", section(arch, r"^\| Module \|", r"^\s*$"), re.M)
    testing = section((DOCS / "TESTING.md").read_text(), r"^### 0\.2", r"^### 0\.3")
    for m in modules:
        if not re.search(rf"^\| `{m}`", testing, re.M):
            errors.append(f"contract {m} has no row in TESTING.md §0.2")

    # Events (§14)
    ev_block = section(spec, r"^## 14\. ").split("```")[1]
    for ev in re.findall(r"\w+", ev_block.replace("text", "", 1)):
        if not re.search(rf"\b{ev}\b", test_text):
            errors.append(f"event {ev} not named by any test case")

    if errors:
        print("\n".join(errors))
        print(f"FAIL: {len(errors)} problem(s)")
        return 1
    print(f"OK: {len(tests)} tests; {len(invariants)} invariants, {len(names)} functions/views, "
          f"{len(spec_errors)} errors covered; every event named; {len(modules)} contracts have test rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
