# `test/fixtures/`: shared vectors and test inputs

## `eip712_vectors.json`: the signed orders

What the user signs before a price is known (docs/ARCHITECTURE.md §7). The backend's custody signer must reproduce
**every hash and signature in this file** before it integrates with the contract.

- **The domain:** `Manic Flash Option`, version `1`, chain id `46630` (the Robinhood testnet) and a made-up contract
  address, `0x7357…7357`. On a real deployment, the chain id and the address are the deployment's own; the
  contract's `eip712Domain()` reports them.
- **The type strings,** exactly (field order = struct order; `side` is a `uint8`: 0 = Call, 1 = Put):
  ```text
  OpenOrder(bytes32 positionId,address user,bytes32 marketId,uint16 leverage,uint8 side,uint64 stake,uint16 durationSecs,uint48 notBefore,uint48 deadline)
  SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)
  ```
- **The leverage is signed:** an open order names its leverage (`uint16`, the multiplier) right after the market id,
  so a relayer can't open the bet on another leverage's market (ADR 0008). The open orders are a BTC call at 1000x,
  an ETH put at 500x, a BTC put at 100x, and one with every field at its widest.
- **Each vector** gives the order, its struct hash, its digest (`keccak256(0x1901 ‖ domainSeparator ‖ structHash)`)
  and the signature of Anvil's well-known test key 0. That key is public, so it is only ever used for tests.
- **The signature format the contract accepts:** 65 bytes, `r ‖ s ‖ v`, with `v` = 27 or 28 and a low `s`. It
  refuses a 64-byte compact (EIP-2098) signature, a `v` of 0 or 1, and a high `s`. A contract wallet's signature
  goes to its ERC-1271 `isValidSignature`.

**Where it comes from:** `eip712_vectors.py` makes it with Foundry's `cast` (alloy's EIP-712), never with this
repo's Solidity. Each vector is made two ways, and the script stops if they disagree: alloy signs the typed data
whole, and the digest is also put together step by step and signed raw. To regenerate (the output never changes for
the same inputs):

```bash
python3 test/fixtures/eip712_vectors.py   # from the repo root, with Foundry 1.8.7's cast on PATH
```

**Where it is checked:**
- `test/unit/OrderLib.t.sol`: the type strings, type hashes and struct hashes;
- `test/signing/Eip712Vectors.t.sol`: the contract, deployed at the vectors' address on their chain, gives the
  same domain, digests and signatures, and accepts every signature.

Orders are read with `vm.parseJsonType` and an explicit type string, which keeps the struct's field order
(docs/CONVENTIONS.md §9).

## `model/`: the model's vectors

What the reference model of the maths gives: `model/flash_option_math.py`, a second implementation of docs/MATH.md in
Python ([`model/README.md`](../../model/README.md)). One file per function, 24 in all, with 20,661 inputs (2.8 MB).

- **The header:** the function, its library, the section of docs/MATH.md it follows, the generator, the seed, and
  `caseCount` and `revertCount`.
- **`cases`:** inputs the function accepts, with the outputs the model gives (a check that passes has none).
- **`reverts`:** inputs it refuses, with `errorName`: the contract's error, or `Panic(0x11)` / `Panic(0x12)` for
  Solidity's overflow and division-by-zero panics.
- **The order:** the edge cases first, each with a `note` (the bounds, zero, one unit past each limit, the rounding
  boundaries, every refusal and the worked examples of docs/MATH.md §12), then seeded random inputs over the whole
  input domain, at 1000x, 500x, 100x and any leverage.

**Where it comes from:** `model/generate_vectors.py`. Each file's seed is fixed, so the same model always writes the
same bytes. To regenerate, or to check that the files are current, as CI does on every pull request and push:

```bash
python3 model/generate_vectors.py           # from the repo root
python3 model/generate_vectors.py --check   # exit 1 if a file differs from what the model gives now
```

**Where it is checked:** `test/model/ModelVectors.t.sol`, one test per function. Through `test/harnesses/`, the
contract must give the model's outputs exactly, or refuse with the model's error and its arguments. The files are
read with `vm.parseJsonTypeArray` and an explicit type string, like the EIP-712 vectors.

## `scripts/`: inputs the deploy scripts must refuse

`chains-bad-enabled.toml` is a chains.toml with two broken tables, which `test/script/Base.t.sol` feeds to the scripts'
input reader in place of `script/config/chains.toml`:
- `31337` switches on a leverage it doesn't create (7x): refused, naming the rule;
- `31338` gives `admin_transfer_delay` a value one past a `uint48`: refused by `SafeCast`.
