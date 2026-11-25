# `abi/`: the contract's ABI

`IManicFlashOption.json` is the Manic Flash Option contract's full ABI. The backend and the frontend build against
it. It is generated from [`src/interfaces/IManicFlashOption.sol`](../src/interfaces/IManicFlashOption.sol):

```bash
forge inspect IManicFlashOption abi --json > abi/IManicFlashOption.json
```

CI regenerates it on every pull request and fails if the committed file differs, so it always matches the code
beside it.

- **What it holds (the whole interface):**
  - Our functions: `initialize`, the admin functions (`createMarket`, `setConfig`, `setPaused`, `setHalted`,
    `setPoolFloor`, `setRecipients`, `setRefundDelay`, `setBreaker`, `resetBreaker`, `revokeRelayer`), the trading
    functions (`open`, `sell`), the settlement functions (`liquidate`, `settle`, `refundExpired`, `repay`), the pool
    functions (`fund`, `withdraw`, `claim`, `sweepFees`), the getters, the EIP-712 hash helpers (`hashOpenOrder`,
    `hashSellOrder`), `version` and the five role ids.
  - OpenZeppelin's role management (`IAccessControlDefaultAdminRules`) and EIP-712 domain (`eip712Domain`).
  - 58 functions, 30 events and 57 errors, OpenZeppelin's included.
- **For the integrators:** [`docs/integration.md`](../docs/integration.md) says what to call and sign, and
  [`docs/abi-reference.md`](../docs/abi-reference.md) lists every selector, topic and error id, generated from the
  compiler and checked by CI like this file.
- **Not in it:** the upgrade functions (`upgradeToAndCall`, `proxiableUUID`, `UPGRADE_INTERFACE_VERSION`) and
  ERC-165's `supportsInterface`. Only deploy and upgrade scripts call them, and they are in the implementation's
  own artifact (`out/ManicFlashOption.sol/ManicFlashOption.json`).
- **How to read it:**
  - Entries are sorted by name.
  - Enums appear as `uint8`; `internalType` gives the Solidity type.
  - Structs appear as tuples, field by field.
- **Changes:** changing an existing event or error is an ABI change.
  - [`test/unit/IManicFlashOptionAbi.t.sol`](../test/unit/IManicFlashOptionAbi.t.sol) pins every signature.
  - Every such change is called out in [`CHANGELOG.md`](../CHANGELOG.md).
