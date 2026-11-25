#!/usr/bin/env python3
"""Checks that a deployed contract's code is a build's (docs/runbooks/deploy-testnet.md, step 6).

  python3 script/bytecode.py <deployed code file> <the build's artifact json>
  (the file holds `cast code <address>`'s output)

A deployed contract's runtime code differs from its artifact only at its immutables, which the constructor fills in:
ManicFlashOption has one, OpenZeppelin's `UUPSUpgradeable.__self`, its own address, used three times. This blanks every
immutable position the artifact lists (`immutableReferences`) in both, then requires the rest to be equal byte for byte,
the metadata hash at the end included (it covers every source file and compiler setting). Only the standard library.
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    deployed = bytearray.fromhex(open(sys.argv[1]).read().strip().removeprefix("0x"))
    artifact = json.load(open(sys.argv[2]))["deployedBytecode"]
    built = bytearray.fromhex(artifact["object"].removeprefix("0x"))
    if not deployed:
        sys.exit("FAIL: no code at that address")
    blanked = 0
    for refs in artifact.get("immutableReferences", {}).values():
        for ref in refs:
            start, end = ref["start"], ref["start"] + ref["length"]
            deployed[start:end] = built[start:end] = bytes(ref["length"])
            blanked += 1
    if deployed != built:
        sys.exit(f"FAIL: the deployed code is not this build ({len(deployed)} bytes deployed, {len(built)} built)")
    print(f"The deployed code is this build: {len(built)} bytes, equal outside its {blanked} immutable position(s).")


if __name__ == "__main__":
    main()
