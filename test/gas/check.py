#!/usr/bin/env python3
"""The gas benchmarks' checks and tables (docs/gas.md).

`forge test --match-path "test/gas/*"` writes each benchmark's gas into snapshots/*.json. This script:

  --base REF               fails if any number is more than --tolerance % (5) above the same number at git REF, or
                           if a number REF has is gone. --allow-regression reports both but passes (CI passes it when
                           the pull request carries the label gas-regression-accepted).
  --table                  prints docs/gas.md's tables, made from snapshots/.
  --docs                   fails if the tables in docs/gas.md differ from --table; --write-docs rewrites them.

Only the standard library; no network. CI runs it in .github/workflows/gas.yml.
"""
import argparse
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SNAPSHOTS = ROOT / "snapshots"
DOCS = ROOT / "docs" / "gas.md"
BEGIN, END = "<!-- gas-tables:begin -->", "<!-- gas-tables:end -->"
CALLDATA = " (calldata)"
TX_BASE = 21_000

# Each call in the order docs/gas.md lists them: the snapshot name, the call as the docs show it, and who calls it.
CALLS = [
    ("open", "`open`", "opener"),
    ("sell", "`sell`", "opener"),
    ("liquidate 1", "`liquidate`, 1 bet", "settler"),
    ("liquidate 10", "`liquidate`, 10 bets", "settler"),
    ("liquidate 50", "`liquidate`, 50 bets", "settler"),
    ("liquidate 100", "`liquidate`, 100 bets", "settler"),
    ("settle 1", "`settle`, 1 bet", "settler"),
    ("settle 10", "`settle`, 10 bets", "settler"),
    ("settle 50", "`settle`, 50 bets", "settler"),
    ("settle 100", "`settle`, 100 bets", "settler"),
    ("settle 100 at a loss", "`settle`, 100 bets at a loss", "settler"),
    ("repay 1", "`repay`, 1 IOU", "anyone"),
    ("repay 50", "`repay`, 50 IOUs", "anyone"),
    ("refundExpired 1", "`refundExpired`, 1 bet", "anyone"),
    ("refundExpired 50", "`refundExpired`, 50 bets", "anyone"),
    ("claim", "`claim`", "anyone"),
    ("sweepFees", "`sweepFees`", "anyone"),
]

# The batch calls: the snapshot names' prefix, the call, and the sizes measured.
BATCHES = [
    ("liquidate", "`liquidate`", [1, 10, 50, 100]),
    ("settle", "`settle`", [1, 10, 50, 100]),
    ("repay", "`repay`", [1, 50]),
    ("refundExpired", "`refundExpired`", [1, 50]),
]


def load_current():
    """Every number in snapshots/*.json, keyed "<file>: <name>"."""
    numbers = {}
    for path in sorted(SNAPSHOTS.glob("*.json")):
        for name, value in json.loads(path.read_text()).items():
            numbers[f"{path.name}: {name}"] = int(value)
    return numbers


def load_at(ref):
    """The same numbers at git `ref`; empty if `ref` has no snapshots yet."""
    listing = subprocess.run(["git", "ls-tree", "--name-only", ref, "snapshots/"], cwd=ROOT, capture_output=True,
                             text=True)
    if listing.returncode != 0:
        sys.exit(f"git ls-tree {ref} failed: {listing.stderr.strip()}")
    numbers = {}
    for file in listing.stdout.split():
        if not file.endswith(".json"):
            continue
        text = subprocess.run(["git", "show", f"{ref}:{file}"], cwd=ROOT, capture_output=True, text=True, check=True)
        for name, value in json.loads(text.stdout).items():
            numbers[f"{pathlib.Path(file).name}: {name}"] = int(value)
    return numbers


def compare(base, current, tolerance, allow):
    """Prints every change against `base`, and returns the exit code."""
    if not base:
        print("The base has no gas snapshots yet: nothing to compare.")
        return 0
    worse, better, gone, new = [], [], [], []
    for key, before in sorted(base.items()):
        if key not in current:
            gone.append(key)
            continue
        now = current[key]
        change = (now - before) / before * 100 if before else 0.0
        if now > before * (1 + tolerance / 100):
            worse.append((key, before, now, change))
        elif now < before * (1 - tolerance / 100):
            better.append((key, before, now, change))
    new = sorted(set(current) - set(base))
    for title, rows in (("More than {t}% dearer", worse), ("More than {t}% cheaper", better)):
        if rows:
            print(title.format(t=tolerance) + ":")
            for key, before, now, change in rows:
                print(f"  {key}: {before:,} -> {now:,} ({change:+.1f}%)")
    for title, keys in (("Gone", gone), ("New", new)):
        if keys:
            print(f"{title}: " + ", ".join(keys))
    unchanged = len(base) - len(worse) - len(better) - len(gone)
    print(f"{len(base)} numbers at the base: {unchanged} within {tolerance}%, {len(worse)} dearer, {len(better)} "
          f"cheaper, {len(gone)} gone; {len(new)} new.")
    if (worse or gone) and not allow:
        print(f"FAIL: a call is more than {tolerance}% dearer than at the base, or a benchmark is gone. If that is "
              "deliberate, say why in the pull request and add the label gas-regression-accepted.")
        return 1
    if worse or gone:
        print("Accepted: the pull request carries the label gas-regression-accepted.")
    return 0


def tables(current):
    """docs/gas.md's tables, from the ManicFlashOption group."""
    gas = {key.split(": ", 1)[1]: value for key, value in current.items() if key.startswith("ManicFlashOption.json: ")}
    missing = [name for name, _, _ in CALLS if name not in gas or name + CALLDATA not in gas]
    if missing:
        sys.exit("Missing from snapshots/ManicFlashOption.json: " + ", ".join(missing))

    def tx(name):
        return gas[name] + gas[name + CALLDATA] + TX_BASE

    lines = ["| Call | Who calls | Execution | Calldata | Transaction |", "|---|---|---:|---:|---:|"]
    for name, call, caller in CALLS:
        lines.append(f"| {call} | {caller} | {gas[name]:,} | {gas[name + CALLDATA]:,} | {tx(name):,} |")
    lines += ["", "| Batch call | Transaction, per bet, at each size | Each bet more |", "|---|---|---:|"]
    for prefix, call, sizes in BATCHES:
        per_bet = ", ".join(f"{size}: {tx(f'{prefix} {size}') // size:,}" for size in sizes)
        first, last = sizes[0], sizes[-1]
        marginal = (tx(f"{prefix} {last}") - tx(f"{prefix} {first}")) // (last - first)
        lines.append(f"| {call} | {per_bet} | {marginal:,} |")
    return "\n".join(lines) + "\n"


def docs(current, write):
    """Checks (or rewrites) the tables between the markers in docs/gas.md."""
    text = DOCS.read_text()
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        sys.exit(f"{DOCS.relative_to(ROOT)} needs one {BEGIN} and one {END}")
    head, rest = text.split(BEGIN)
    _, tail = rest.split(END)
    fresh = f"{head}{BEGIN}\n{tables(current)}{END}{tail}"
    if fresh == text:
        print(f"{DOCS.relative_to(ROOT)}: the tables are current.")
        return 0
    if write:
        DOCS.write_text(fresh)
        print(f"{DOCS.relative_to(ROOT)}: tables rewritten.")
        return 0
    print(f"FAIL: {DOCS.relative_to(ROOT)}'s tables differ from snapshots/. Run: python3 test/gas/check.py --write-docs")
    return 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", help="the git ref to compare with")
    p.add_argument("--tolerance", type=float, default=5.0, help="the allowed rise, in percent (default 5)")
    p.add_argument("--allow-regression", action="store_true", help="report a rise or a gone benchmark, but pass")
    p.add_argument("--table", action="store_true", help="print docs/gas.md's tables")
    p.add_argument("--docs", action="store_true", help="check docs/gas.md's tables are current")
    p.add_argument("--write-docs", action="store_true", help="rewrite docs/gas.md's tables")
    args = p.parse_args()
    current = load_current()
    if not current:
        sys.exit('No snapshots: run forge test --match-path "test/gas/*" first.')
    code = 0
    if args.table:
        print(tables(current), end="")
    if args.docs or args.write_docs:
        code |= docs(current, args.write_docs)
    if args.base:
        code |= compare(load_at(args.base), current, args.tolerance, args.allow_regression)
    if not (args.table or args.docs or args.write_docs or args.base):
        p.print_help()
    sys.exit(code)


if __name__ == "__main__":
    main()
