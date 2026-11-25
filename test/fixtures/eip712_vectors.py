#!/usr/bin/env python3
"""Regenerates test/fixtures/eip712_vectors.json: the EIP-712 vectors shared with the backend (docs/ARCHITECTURE.md §7).

Every hash and signature here comes from Foundry's `cast` (alloy's EIP-712 and secp256k1), never from this repo's
Solidity, so test/signing/Eip712Vectors.t.sol checks the contract against an independent implementation.

Each vector is made two ways, and the script stops if they disagree:
  1. alloy hashes and signs the typed data as a whole (`cast wallet sign --data`);
  2. the digest is put together step by step (`cast keccak`, `cast abi-encode`) and signed as a raw hash
     (`cast wallet sign --no-hash`).
ECDSA signing is deterministic (RFC 6979), so the two signatures must be identical, byte for byte.

Usage, from the repository root, with Foundry 1.8.7's `cast` on PATH:
    python3 test/fixtures/eip712_vectors.py
The output never changes for the same inputs, so CI can rely on the committed file.
"""

import json
import pathlib
import subprocess

# Anvil's well-known test key 0. It is public: never use it for anything but tests.
KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# A fixed domain: the Robinhood testnet's chain id and a made-up proxy address, so the vectors never depend on where
# a test happens to deploy.
DOMAIN = {
    "name": "Manic Flash Option",
    "version": "1",
    "chainId": 46630,
    "verifyingContract": "0x7357000000000000000000000000000000007357",
}
DOMAIN_FIELDS = [("name", "string"), ("version", "string"), ("chainId", "uint256"), ("verifyingContract", "address")]

# Field order = struct order = type string order (src/types/OrderTypes.sol). `side` is a uint8: 0 = Call, 1 = Put.
OPEN_FIELDS = [
    ("positionId", "bytes32"),
    ("user", "address"),
    ("marketId", "bytes32"),
    ("leverage", "uint16"),
    ("side", "uint8"),
    ("stake", "uint64"),
    ("durationSecs", "uint16"),
    ("notBefore", "uint48"),
    ("deadline", "uint48"),
]
SELL_FIELDS = [("positionId", "bytes32"), ("minAmount", "uint64"), ("notBefore", "uint48"), ("deadline", "uint48")]

# Pyth's BTC/USD and ETH/USD feed ids, the market ids (test/utils/Defaults.sol).
BTC = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"
ETH = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"
MAX_BYTES32 = "0x" + "ff" * 32
MAX_UINT64 = 2**64 - 1
MAX_UINT48 = 2**48 - 1


def cast(*args: str) -> str:
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


def type_string(name: str, fields: list) -> str:
    return name + "(" + ",".join(f"{t} {n}" for n, t in fields) + ")"


def abi_encode(types: list, values: list) -> str:
    return cast("abi-encode", "f(" + ",".join(types) + ")", *[str(v) for v in values])


def keccak(data: str) -> str:
    return cast("keccak", data)


SIGNER = cast("wallet", "address", "--private-key", KEY)
DOMAIN_TYPE = type_string("EIP712Domain", DOMAIN_FIELDS)
DOMAIN_TYPEHASH = keccak(DOMAIN_TYPE)
DOMAIN_SEPARATOR = keccak(
    abi_encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [DOMAIN_TYPEHASH, keccak(DOMAIN["name"]), keccak(DOMAIN["version"]), DOMAIN["chainId"],
         DOMAIN["verifyingContract"]],
    )
)


def vector(name: str, primary: str, fields: list, message: dict) -> dict:
    type_hash = keccak(type_string(primary, fields))
    struct_hash = keccak(abi_encode(["bytes32"] + [t for _, t in fields], [type_hash] + [message[n] for n, _ in fields]))
    digest = keccak("0x1901" + DOMAIN_SEPARATOR[2:] + struct_hash[2:])
    by_hand = cast("wallet", "sign", "--no-hash", "--private-key", KEY, digest)

    typed_data = {
        "types": {
            "EIP712Domain": [{"name": n, "type": t} for n, t in DOMAIN_FIELDS],
            primary: [{"name": n, "type": t} for n, t in fields],
        },
        "primaryType": primary,
        "domain": DOMAIN,
        # Integers as strings: alloy reads them exactly, whatever their size.
        "message": {n: (str(v) if isinstance(v, int) else v) for n, v in message.items()},
    }
    by_alloy = cast("wallet", "sign", "--private-key", KEY, "--data", json.dumps(typed_data))
    if by_hand != by_alloy:
        raise SystemExit(f"{name}: alloy's digest differs from the composed one ({by_alloy} != {by_hand})")
    return {"name": name, "order": message, "structHash": struct_hash, "digest": digest, "signature": by_hand}


def open_order(position_id, market_id, leverage, side, stake, duration, not_before, deadline) -> dict:
    return {
        "positionId": position_id,
        "user": SIGNER,
        "marketId": market_id,
        "leverage": leverage,
        "side": side,
        "stake": stake,
        "durationSecs": duration,
        "notBefore": not_before,
        "deadline": deadline,
    }


def sell_order(position_id, min_amount, not_before, deadline) -> dict:
    return {"positionId": position_id, "minAmount": min_amount, "notBefore": not_before, "deadline": deadline}


OPEN_1 = keccak("ManicFlashOption eip712 vector: open 1")
OPEN_2 = keccak("ManicFlashOption eip712 vector: open 2")
OPEN_3 = keccak("ManicFlashOption eip712 vector: open 3")

vectors = {
    "about": "EIP-712 vectors for OpenOrder and SellOrder (docs/ARCHITECTURE.md §7). The backend's custody signer must "
    "reproduce every hash and signature here before integration. Integers in orders are plain JSON numbers.",
    "generator": "test/fixtures/eip712_vectors.py, with Foundry 1.8.7's cast (alloy's EIP-712)",
    "signer": {"key": KEY, "address": SIGNER, "note": "Anvil's well-known test key 0: public, tests only"},
    "domain": DOMAIN,
    "domainType": DOMAIN_TYPE,
    "domainTypeHash": DOMAIN_TYPEHASH,
    "domainSeparator": DOMAIN_SEPARATOR,
    "openOrderType": type_string("OpenOrder", OPEN_FIELDS),
    "openOrderTypeHash": keccak(type_string("OpenOrder", OPEN_FIELDS)),
    "sellOrderType": type_string("SellOrder", SELL_FIELDS),
    "sellOrderTypeHash": keccak(type_string("SellOrder", SELL_FIELDS)),
    "openOrders": [
        vector("a $25 BTC call for 60 seconds at 1000x", "OpenOrder", OPEN_FIELDS,
               open_order(OPEN_1, BTC, 1000, 0, 25_000_000, 60, 1_794_000_000, 1_794_000_030)),
        vector("a $50 ETH put for 300 seconds at 500x", "OpenOrder", OPEN_FIELDS,
               open_order(OPEN_2, ETH, 500, 1, 50_000_000, 300, 1_794_000_123, 1_794_000_153)),
        vector("a $10 BTC put for 120 seconds at 100x", "OpenOrder", OPEN_FIELDS,
               open_order(OPEN_3, BTC, 100, 1, 10_000_000, 120, 1_794_000_200, 1_794_000_230)),
        vector("every field at its widest", "OpenOrder", OPEN_FIELDS,
               open_order(MAX_BYTES32, MAX_BYTES32, 2**16 - 1, 1, MAX_UINT64, 2**16 - 1, MAX_UINT48, MAX_UINT48)),
    ],
    "sellOrders": [
        vector("sell the $25 BTC call for at least $12", "SellOrder", SELL_FIELDS,
               sell_order(OPEN_1, 12_000_000, 1_794_000_045, 1_794_000_075)),
        vector("every field at its widest", "SellOrder", SELL_FIELDS,
               sell_order(MAX_BYTES32, MAX_UINT64, MAX_UINT48, MAX_UINT48)),
    ],
}

out = pathlib.Path(__file__).with_name("eip712_vectors.json")
out.write_text(json.dumps(vectors, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"wrote {out}: {len(vectors['openOrders'])} open and {len(vectors['sellOrders'])} sell vectors, all agreed")
