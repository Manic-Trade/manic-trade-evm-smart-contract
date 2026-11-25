#!/usr/bin/env python3
"""The coverage check (audit/static-analysis.md).

  forge coverage ... --report lcov --report-file lcov.info     (the command is in .github/workflows/ci.yml)
  python3 test/coverage/check.py lcov.info

Fails unless every line, function and branch of src/ is covered, apart from the branches listed in UNREACHABLE.
Those are matched by their source line's text, not its number, so they survive edits elsewhere in the file. Each
entry says why no test can take the branch. A listed branch that a test does take fails too, so the list can't go
stale. Only the standard library.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# (file, the source line's text, stripped) -> why no test can reach the branch.
UNREACHABLE = {
    (
        "src/libraries/LeverageMath.sol",
        "if (value < 0 || value > int256(uint256(type(uint16).max))) revert IManicFlashOptionErrors.MathOverflow();",
    ): "toUint16's overflow guard: gBps clamps g to [0, capBps] before the cast, so it can't trip "
    "(testFuzz_GBpsStaysBetweenZeroAndTheCap); the check keeps the cast honest.",
}


def parse(path):
    """Per src/ file: the lines, the functions and the branches, each with its hit count."""
    files, current = {}, None
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            name = line[3:]
            current = files.setdefault(name, {"lines": {}, "functions": {}, "branches": []}) if name.startswith(
                "src/") else None
        elif current is None:
            continue
        elif line.startswith("DA:"):
            number, hits = line[3:].split(",")[:2]
            current["lines"][int(number)] = int(hits)
        elif line.startswith("FNDA:"):
            hits, name = line[5:].split(",", 1)
            current["functions"][name] = int(hits)
        elif line.startswith("BRDA:"):
            number, block, branch, taken = line[5:].split(",")
            current["branches"].append((int(number), block, branch, 0 if taken == "-" else int(taken)))
    return files


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    files = parse(sys.argv[1])
    if not files:
        sys.exit("No src/ files in the report.")
    problems, seen = [], set()
    totals = {"lines": [0, 0], "functions": [0, 0], "branches": [0, 0]}
    for name, data in sorted(files.items()):
        source = (ROOT / name).read_text().splitlines()
        for kind in ("lines", "functions"):
            for key, hits in data[kind].items():
                totals[kind][1] += 1
                totals[kind][0] += hits > 0
                if hits == 0:
                    problems.append(f"{name}: {kind[:-1]} {key} never runs")
        for number, block, branch, taken in data["branches"]:
            totals["branches"][1] += 1
            totals["branches"][0] += taken > 0
            text = source[number - 1].strip()
            if (name, text) in UNREACHABLE:
                seen.add((name, text))
                if taken > 0:
                    problems.append(f"{name}:{number}: listed as unreachable, but a test takes it; remove it from the list")
            elif taken == 0:
                problems.append(f"{name}:{number}: branch {block}.{branch} never taken: {text}")
    for name, text in sorted(set(UNREACHABLE) - seen):
        problems.append(f"{name}: listed as unreachable but not found (moved or gone?): {text}")
    for kind, (hit, total) in totals.items():
        print(f"{kind}: {hit} of {total} covered")
    print(f"unreachable by design: {len(seen)} branch(es), listed in test/coverage/check.py")
    if problems:
        print("FAIL:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print("Every line, function and reachable branch of src/ is covered.")


if __name__ == "__main__":
    main()
