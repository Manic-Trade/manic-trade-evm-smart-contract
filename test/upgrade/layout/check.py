#!/usr/bin/env python3
"""Checks that ManicFlashOption can be upgraded safely, with OpenZeppelin's upgrades plugin.

The plugin's validator (`@openzeppelin/upgrades-core validate`, the same check `Upgrades.validateUpgrade` runs from a
Foundry script) reads a build's `build-info` and reports two kinds of problem: code an upgradeable contract must not
have (a constructor that isn't locked, an immutable, `selfdestruct`, `delegatecall`), and a storage layout that no
longer lines up with the version it replaces (docs/ARCHITECTURE.md §5). This script runs it four ways:

1. The current code on its own: is `ManicFlashOption` upgrade-safe?
2. The current code against a base commit (`--base`, the pull request's base in CI): does this change keep the
   layout of the code it changes? This is what keeps a layout change out of `dev` before anything is deployed.
3. The current code against every deployed version kept in `deployments/<chainId>/build-info-v<version>/`
   (docs/CONVENTIONS.md §10): can the deployed proxies be upgraded to it? There are none until the first deployment.
4. Every variant in `variants/`: a copy of `src/` with one change, each a rule of §5 kept or broken, checked against
   the current code. Each patch file says whether the plugin must pass it, and if not, the reasons it must give. This
   shows the check is live on our storage, and documents what each rule looks like when broken.

The validator needs Node.js (it runs with `npx`) and a build with the AST, the build-info and every contract's storage
layout: foundry.toml's `upgrades` profile. Every build here goes to a temporary folder, so `out/` and `cache/` are never
touched, and FFI is never used.

Usage, from the repository root:
    python3 test/upgrade/layout/check.py                   # checks 1, 3 and 4
    python3 test/upgrade/layout/check.py --base origin/dev # and 2, against dev
    python3 test/upgrade/layout/check.py --only 06         # just the variants whose name contains "06"
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

# The validator's version, pinned exactly. openzeppelin-foundry-upgrades v0.4.4 (lib/) asks for ^1.48.0.
UPGRADES_CORE = "@openzeppelin/upgrades-core@1.48.0"
CONTRACT = "ManicFlashOption"
# The validator reads the AST, the build-info and every contract's storage layout, which foundry.toml's `upgrades`
# profile adds to the default settings. Every commit has that profile, so a base commit builds the same way.
PLUGIN_BUILD = {"FOUNDRY_PROFILE": "upgrades"}
# What a copy of the code needs to build: the sources and the settings. The libraries are linked, not copied.
TREE = ["src", "foundry.toml", "remappings.txt"]

ROOT = Path(__file__).resolve().parents[3]
VARIANTS = Path(__file__).resolve().parent / "variants"


@dataclass
class Variant:
    """One patch in `variants/`, with the result its header expects."""

    name: str
    path: Path
    rule: str
    change: str
    expect_pass: bool
    reasons: list = field(default_factory=list)


@dataclass
class Result:
    """One run of the validator, and whether it matched what was expected."""

    check: str
    expected: str
    got: str
    ok: bool
    output: str


def run(cmd, cwd, env=None):
    """Runs `cmd`, returning its exit code and its output (stdout and stderr together)."""
    p = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def build(tree, out):
    """Builds `tree/src` with the plugin's settings into `out`, and returns its build-info folder."""
    env = dict(os.environ, **PLUGIN_BUILD)
    cmd = ["forge", "build", "src", "--out", str(out / "out"), "--cache-path", str(out / "cache")]
    code, output = run(cmd, tree, env)
    if code != 0:
        sys.exit(f"forge build failed in {tree}:\n{output}")
    return out / "out" / "build-info"


def validate(build_info, reference=None):
    """Runs the validator on `build_info`'s ManicFlashOption, against `reference` (a folder of an older build) if given.

    The validator names a reference build by its folder's name, so `reference` is passed with its folder name as the
    prefix of the contract it holds, e.g. `v1:ManicFlashOption`.
    """
    cmd = ["npx", "--yes", UPGRADES_CORE, "validate", str(build_info), "--contract", CONTRACT]
    if reference is not None:
        cmd += ["--reference", f"{reference.name}:{CONTRACT}", "--referenceBuildInfoDirs", str(reference)]
    return run(cmd, ROOT)


def copy_tree(source, dest):
    """Copies the code `TREE` names from `source` to `dest`, and links the libraries."""
    dest.mkdir(parents=True)
    for item in TREE:
        s = source / item
        if s.is_dir():
            shutil.copytree(s, dest / item)
        else:
            shutil.copy(s, dest / item)
    (dest / "lib").symlink_to(ROOT / "lib")


def as_reference(build_info, folder):
    """Copies a build-info folder to `folder`, whose name becomes its prefix for the validator."""
    shutil.copytree(build_info, folder)
    return folder


def parse_variant(path):
    """Reads a patch's header: the `# Key: value` lines before its first `diff --git`."""
    rule = change = expect = None
    reasons = []
    for line in path.read_text().splitlines():
        if line.startswith("diff --git"):
            break
        m = re.match(r"#\s*(\w+):\s*(.*)$", line)
        if not m:
            continue
        key, value = m.group(1).lower(), m.group(2).strip()
        if key == "rule":
            rule = value
        elif key == "change":
            change = value
        elif key == "expect":
            expect = value
        elif key == "reason":
            reasons.append(value)
    if expect not in ("pass", "fail") or rule is None or change is None:
        sys.exit(f"{path.name}: the header needs `# Rule:`, `# Change:` and `# Expect: pass` or `fail`")
    if expect == "fail" and not reasons:
        sys.exit(f"{path.name}: a variant that must fail names at least one `# Reason:` the validator gives")
    if expect == "pass" and reasons:
        sys.exit(f"{path.name}: a variant that must pass has no `# Reason:`")
    return Variant(path.stem, path, rule, change, expect == "pass", reasons)


def judge(check, code, output, expect_pass, reasons=()):
    """Compares a validator run with what was expected: a pass, or a failure that gives every reason."""
    passed = code == 0 and "SUCCESS" in output
    failed = code != 0 and "FAILED" in output
    missing = [r for r in reasons if r not in output]
    if expect_pass:
        return Result(check, "pass", "pass" if passed else "fail", passed, output)
    ok = failed and not missing
    got = "fail" if failed else ("pass" if passed else "error")
    if failed and missing:
        got = "fail, without: " + "; ".join(missing)
    return Result(check, "fail: " + "; ".join(reasons), got, ok, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="a git ref whose layout the current code must keep (CI: the PR's base)")
    parser.add_argument("--only", help="run only the variants whose file name contains this")
    parser.add_argument("--keep", action="store_true", help="keep the temporary builds, and print where")
    args = parser.parse_args()
    for tool in ("forge", "npx", "git"):
        if shutil.which(tool) is None:
            sys.exit(f"{tool} is not on PATH")

    work = Path(tempfile.mkdtemp(prefix="manic-layout-"))
    results = []
    try:
        print("Building the current code...", flush=True)
        current = build(ROOT, work / "current")

        # 1. The current code on its own.
        code, output = validate(current)
        results.append(judge("current: upgrade-safe", code, output, True))

        # 2. The current code against the base commit's layout.
        if args.base:
            base = work / "base-tree"
            base.mkdir()
            archive = subprocess.run(["git", "archive", args.base, *TREE], cwd=ROOT, stdout=subprocess.PIPE, check=True)
            subprocess.run(["tar", "-x", "-C", str(base)], input=archive.stdout, check=True)
            (base / "lib").symlink_to(ROOT / "lib")
            print(f"Building the base, {args.base}...", flush=True)
            reference = as_reference(build(base, work / "base"), work / "refs" / "base")
            code, output = validate(current, reference)
            results.append(judge(f"current against the base ({args.base})", code, output, True))

        # 3. The current code against every deployed version.
        deployed = sorted(ROOT.glob("deployments/*/build-info-v*"))
        for folder in deployed:
            code, output = validate(current, folder)
            results.append(judge(f"current against {folder.relative_to(ROOT)}", code, output, True))
        if not deployed:
            print("No deployed version is recorded in deployments/ yet; nothing to check against.")

        # 4. The variants, each against the current code as V1.
        v1 = as_reference(current, work / "refs" / "v1")
        variants = [parse_variant(p) for p in sorted(VARIANTS.glob("*.patch"))]
        if args.only:
            variants = [v for v in variants if args.only in v.name]
        for v in variants:
            print(f"Variant {v.name}...", flush=True)
            tree = work / "variants" / v.name
            copy_tree(ROOT, tree)
            code, output = run(["git", "apply", "--whitespace=nowarn", str(v.path)], tree)
            if code != 0:
                results.append(Result(f"variant {v.name}", "applies", "does not apply", False, output))
                continue
            built = build(tree, work / "variant-builds" / v.name)
            code, output = validate(built, v1)
            results.append(judge(f"variant {v.name}", code, output, v.expect_pass, v.reasons))
    finally:
        if args.keep:
            print(f"Builds kept in {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)

    print()
    width = max(len(r.check) for r in results)
    for r in results:
        print(f"{'ok  ' if r.ok else 'FAIL'}  {r.check.ljust(width)}  expected {r.expected}; got {r.got}")
    bad = [r for r in results if not r.ok]
    for r in bad:
        print(f"\n--- {r.check}: the validator said ---\n{r.output.strip()}")
    print(f"\n{len(results) - len(bad)} of {len(results)} checks as expected.")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
