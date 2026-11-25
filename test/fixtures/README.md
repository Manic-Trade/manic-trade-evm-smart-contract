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

## `scripts/`: inputs the deploy scripts must refuse

`chains-bad-enabled.toml` is a chains.toml with two broken tables, which `test/script/Base.t.sol` feeds to the scripts'
input reader in place of `script/config/chains.toml`:
- `31337` switches on a leverage it doesn't create (7x): refused, naming the rule;
- `31338` gives `admin_transfer_delay` a value one past a `uint48`: refused by `SafeCast`.
