#!/usr/bin/env python3
"""Keeps the build machine's paths out of a committed build-info (docs/runbooks/deploy-testnet.md, step 6).

  python3 script/build_info.py deployments/<chainId>/build-info-v<version>

Foundry records the project's absolute root in each build-info's compiler input: `input.basePath`, `input.allowPaths`
and `input.includePaths`. This rewrites that root to `.` in every build-info file of the folder, in place. The source
names are already relative, so nothing else changes: the compiler's output, the metadata hash and the upgrade check
read the same. It fails if the root is still anywhere in a file, or if any of those paths is still absolute. Running it
again changes nothing. Only the standard library.
"""
import json
import pathlib
import re
import sys


def clean(path):
    """Rewrites the recorded root to `.` in one build-info file, and returns how many paths it changed."""
    data = path.read_bytes()
    root = json.loads(data)["input"].get("basePath", "")
    if root in ("", "."):
        return 0
    # Only a JSON string that is the root, or starts with the root and a slash.
    data, n = re.subn(b'"' + re.escape(root.encode()) + b'(?=["/])', b'".', data)
    if root.encode() in data:
        sys.exit("FAIL: %s still holds the build root elsewhere; nothing was written" % path)
    after = json.loads(data)["input"]
    for p in [after.get("basePath", "")] + after.get("allowPaths", []) + after.get("includePaths", []):
        if p.startswith(("/", "\\")) or re.match(r"[A-Za-z]:[\\/]", p):
            sys.exit("FAIL: %s still has an absolute path, %s; nothing was written" % (path, p))
    path.write_bytes(data)
    return n


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    files = sorted(pathlib.Path(sys.argv[1]).glob("*.json"))
    if not files:
        sys.exit("FAIL: no build-info file in %s" % sys.argv[1])
    for f in files:
        n = clean(f)
        print("%s: %s" % (f, "%d path(s) made relative" % n if n else "no absolute path"))


if __name__ == "__main__":
    main()
