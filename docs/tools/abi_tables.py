#!/usr/bin/env python3
"""Prints docs/abi-reference.md: every function, event and error of the contract's ABI, with its selector.

Everything comes from the compiler, through `forge inspect`, so the reference can't drift from the code:

    python3 docs/tools/abi_tables.py > docs/abi-reference.md       # regenerate (from the repo root)
    python3 docs/tools/abi_tables.py | diff - docs/abi-reference.md  # what CI runs: fails if it is stale

Functions, events and errors are grouped by the interface that declares them; whatever is in `IManicFlashOption` but in
none of ours comes from OpenZeppelin. Within a group, entries are sorted by name, so the output never changes for the
same code.
"""

import json
import subprocess
import sys

AGGREGATE = "IManicFlashOption"
# Our function slices, in the order `IManicFlashOption` lists them, then the role ids.
FUNCTION_SLICES = [
    ("IManicFlashOptionAdmin", "Admin"),
    ("IManicFlashOptionTrading", "Trading"),
    ("IManicFlashOptionSettlement", "Settlement"),
    ("IManicFlashOptionPool", "Pool"),
    ("IManicFlashOptionViews", "Views"),
    ("IManicFlashOptionRoles", "Role ids"),
]


def inspect(contract, field):
    """`forge inspect <contract> <field> --json`, parsed."""
    out = subprocess.run(
        ["forge", "inspect", contract, field, "--json"], capture_output=True, text=True, check=True
    ).stdout
    return json.loads(out[min(i for i in (out.find("{"), out.find("[")) if i >= 0):])


def canonical(param):
    """A parameter's canonical ABI type: a struct is the tuple of its fields' types, arrays keep their suffix."""
    kind = param["type"]
    if kind.startswith("tuple"):
        return "(" + ",".join(canonical(c) for c in param["components"]) + ")" + kind[len("tuple"):]
    return kind


def signature(entry):
    return entry["name"] + "(" + ",".join(canonical(p) for p in entry["inputs"]) + ")"


def code(text):
    return "`" + text + "`"


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(row) + " |" for row in rows]
    return "\n".join(lines)


def main():
    abi = inspect(AGGREGATE, "abi")
    selectors = {**inspect(AGGREGATE, "methodIdentifiers"), **inspect(AGGREGATE, "errors")}
    # `forge inspect ... events` writes a struct parameter by its struct's name, not as a tuple, so events are matched
    # by name, which is unique in this ABI. The topic itself is the hash of the canonical (tuple) signature.
    topics = {}
    for key, topic in inspect(AGGREGATE, "events").items():
        name = key.split("(")[0]
        assert name not in topics, f"two events named {name}"
        topics[name] = topic
    entries = {}
    for entry in abi:
        if entry["type"] in ("function", "event", "error"):
            entries[(entry["type"], signature(entry))] = entry

    out = [
        "# ABI reference",
        "",
        "Every function, event and error of the contract, with the selector or topic it is called, logged and",
        "reverted by. **Generated** by `docs/tools/abi_tables.py` from the compiled `IManicFlashOption`, so do not edit it",
        "by hand: CI fails if it is stale. The JSON ABI is `abi/IManicFlashOption.json`; what each entry does is in",
        "[integration.md](integration.md) and in the interfaces' NatSpec. Struct parameters are written as the tuple of",
        "their fields, in order, as the selector hashes them.",
        "",
        "## Functions",
    ]
    seen = set()
    groups = [(name, title, set(inspect(name, "methodIdentifiers"))) for name, title in FUNCTION_SLICES]
    groups.append((None, "OpenZeppelin (roles and the EIP-712 domain)", None))
    for name, title, members in groups:
        rows = []
        for (kind, sig), entry in sorted(entries.items(), key=lambda kv: kv[0][1]):
            if kind != "function" or sig in seen or (members is not None and sig not in members):
                continue
            seen.add(sig)
            rows.append([code(sig), code("0x" + selectors[sig]), entry["stateMutability"]])
        out += ["", f"### {title}" + (f" (`{name}`)" if name else ""), "", table(["Function", "Selector", "Kind"], rows)]

    for kind, title, ours in (("event", "Events", "IManicFlashOptionEvents"), ("error", "Errors", "IManicFlashOptionErrors")):
        field = "events" if kind == "event" else "errors"
        members = {key.split("(")[0] for key in inspect(ours, field)}
        out += ["", f"## {title}"]
        for label, mine in ((f"Ours (`{ours}`)", True), ("OpenZeppelin", False)):
            rows = []
            for (k, sig), entry in sorted(entries.items(), key=lambda kv: kv[0][1]):
                if k != kind or (entry["name"] in members) != mine:
                    continue
                if kind == "event":
                    indexed = ", ".join(p["name"] for p in entry["inputs"] if p["indexed"]) or "none"
                    rows.append([code(sig), code(topics[entry["name"]]), indexed])
                else:
                    rows.append([code(sig), code("0x" + selectors[sig])])
            header = ["Event", "Topic 0", "Indexed"] if kind == "event" else ["Error", "Selector"]
            out += ["", f"### {label}", "", table(header, rows)]

    counts = {k: sum(1 for (kind, _) in entries if kind == k) for k in ("function", "event", "error")}
    out += ["", f"{counts['function']} functions, {counts['event']} events and {counts['error']} errors in all.", ""]
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
