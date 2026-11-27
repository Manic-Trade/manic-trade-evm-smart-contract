# `deployments/`: what is deployed where

The committed record of every real deployment, written by the scripts in [`script/`](../script/README.md). Each
deployed chain has these files:

```text
deployments/
├── <chainId>.json                     the record: token, proxy, implementation, version, start block, deployer, commit
├── <chainId>/build-info-v<version>/   compiler build-info of each deployed implementation
└── <chainId>/smoke-<date>.md          the smoke test's report on that deployment
```

**The record**, `<chainId>.json`, is what the backend and the app read. Each script reads it and writes it back:

| Field | What it is |
|---|---|
| `chainId` | the chain |
| `proxy` | the contract's address: the one every call and every event uses |
| `implementation` | the code behind the proxy now; `Upgrade.s.sol` updates it |
| `version` | the implementation's `version()` |
| `token` | the stablecoin the pool holds |
| `tokenIsMock` | whether `token` is our mock (`DeployMockUsdg.s.sol`, chains without USDG) |
| `startBlock` | the chain's latest block before the deployment, from its RPC: index the contract's events from here. Not `block.number`, which on Robinhood Chain (Arbitrum Orbit) is the parent chain's |
| `deployer` | the account that sent the scripts' transactions |
| `commit` | the git commit the implementation was built from |

Every transaction is also in `broadcast/<script>/<chainId>/`, committed with the record. Local anvil runs and the
script tests write `31337.json`, which is git-ignored, like `broadcast/*/31337/`.

**The build-info** is the compiler's full input and output for the deployed implementation, built with the `upgrades`
profile, so it carries the AST and storage layouts:
- The upgrade checker compares each new version against the build-info of the version it replaces, so that folder is
  kept for every deployed version.
- Its name must be unique per version (`build-info-v<version>`).
- Foundry records the build folder's absolute path in it. `script/build_info.py` makes that path relative before the
  folder is committed, so no local path is published.
- CI's upgrade-safety job checks the code against every `deployments/*/build-info-v*/` folder it finds, with no change
  to the job ([`test/upgrade/layout/`](../test/upgrade/layout/README.md)).
- How to make it: [`docs/runbooks/deploy-testnet.md`](../docs/runbooks/deploy-testnet.md), step 6.

## Deployments

### Robinhood testnet (chain id 46630)

Deployed on 2026-11-26 from commit `e45376d`, following
[`docs/runbooks/deploy-testnet.md`](../docs/runbooks/deploy-testnet.md); the source is verified on the explorer.

| | Address |
|---|---|
| **The contract** (the proxy: every call and event) | [`0x97087017226BE5169CB719035eeF55400ccfC615`](https://explorer.testnet.chain.robinhood.com/address/0x97087017226BE5169CB719035eeF55400ccfC615) |
| Implementation, v1.0.0 | [`0x7205A88a5827c3E06514eB93B276Ddd8C0a3e97b`](https://explorer.testnet.chain.robinhood.com/address/0x7205A88a5827c3E06514eB93B276Ddd8C0a3e97b) |
| Test USDG (the mock) | [`0x6adb64CD5c282Cec956D286e44Ee937C759C114A`](https://explorer.testnet.chain.robinhood.com/address/0x6adb64CD5c282Cec956D286e44Ee937C759C114A) |
| Start block (read events from here) | 158053747 |

The relayer keys and the admin roles are the `[46630]` table of
[`script/config/chains.toml`](../script/config/chains.toml). The smoke test on this deployment, every way a bet ends:
[`46630/smoke-2026-11-26.md`](46630/smoke-2026-11-26.md).

**Relayer keys, changed on 2026-11-27:** the backend's own keys took over. The admin granted its two openers and two
settlers, then the guardian revoked the deployment's four test keys with `revokeRelayer`. Running the smoke test on
this deployment again now needs a temporary grant to a test key.

| Change | Account | Transaction |
|---|---|---|
| Opener granted | `0x0B60B48f61447145A82BAe418752583E8Ff39f66` | [`0xb84fd3c1…`](https://explorer.testnet.chain.robinhood.com/tx/0xb84fd3c17d5232ce881d8eb131fce005efdb36e5a30f231cdc74bfe6cf4a51b9) |
| Opener granted | `0xb5557f7dDEf40084736E1d6ADd6AdBcfd2542371` | [`0xc5d164d0…`](https://explorer.testnet.chain.robinhood.com/tx/0xc5d164d04d3b41e52f2b8a7aad28eeae32fa8ed79aed0d0623e827217637b913) |
| Settler granted | `0x2406C2041E81bF230400e35F969aB67A7B861189` | [`0xba2307d6…`](https://explorer.testnet.chain.robinhood.com/tx/0xba2307d679295ca446668973e8b9e9cb3036a074e9865efc767eee6e956a93e1) |
| Settler granted | `0x4F72be39E1E593A92a58465f3B55afcf1DCF992F` | [`0xb3cbbd73…`](https://explorer.testnet.chain.robinhood.com/tx/0xb3cbbd73d81d8eee60b5baf35fe6e1a0bcb814cd62117ba18d00de4a7d4d8325) |
| Opener revoked (test key) | `0x0E247eeD7dab2fa2320eb58385b420d9586f0396` | [`0x80d6eb64…`](https://explorer.testnet.chain.robinhood.com/tx/0x80d6eb649fd0be77f746e287e5d3800af88cf37050c015715cc6bb9395f4bc04) |
| Opener revoked (test key) | `0x1D72314DD87c447f3D9158da2D2467e94De760F9` | [`0x407c9d48…`](https://explorer.testnet.chain.robinhood.com/tx/0x407c9d48b90f3f69bcbaa44d3c836d134d0ae8216d1a08e54dd2b505dce5afd2) |
| Settler revoked (test key) | `0xC479AA8d7132CdbC1C9278FAFdd54dFBF01f740C` | [`0xf12ecd77…`](https://explorer.testnet.chain.robinhood.com/tx/0xf12ecd77ed3474fff40d7d3cca1a06bfcb1ab87e9e80b0c40dd0f7301d895682) |
| Settler revoked (test key) | `0x703625616852869Fa51d9Ead8074BB8dFc161f6d` | [`0x9d9f593c…`](https://explorer.testnet.chain.robinhood.com/tx/0x9d9f593c8720dc8c8a735dbeded3fa71beab2242ba78d11d340d94f993d92482) |

**Test USDG:** the testnet has no USDG, so there the scripts deploy a mock with USDG's behaviour
(`script/DeployMockUsdg.s.sol`): 6 decimals, and the same EIP-712 domain ("Global Dollar", version 1) for permits and
EIP-3009 authorisations. Only its admin, the deployer, can mint it.
