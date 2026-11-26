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

**Test USDG:** the testnet has no USDG, so there the scripts deploy a mock with USDG's behaviour
(`script/DeployMockUsdg.s.sol`): 6 decimals, and the same EIP-712 domain ("Global Dollar", version 1) for permits and
EIP-3009 authorisations. Only its admin, the deployer, can mint it.
