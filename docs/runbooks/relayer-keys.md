# Runbook: relayer keys on the Robinhood testnet

**For:** the admin, when the backend sends its relayer addresses, or when a key must go.

**The rule:** the backend makes its own keys and sends **addresses only**. A private key never changes hands.

```bash
export ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com
P=$(jq -r .proxy deployments/46630.json)
OPENER=$(cast call $P "OPENER_ROLE()(bytes32)" --rpc-url robinhood_testnet)
SETTLER=$(cast call $P "SETTLER_ROLE()(bytes32)" --rpc-url robinhood_testnet)
```

## Grant

The admin (`DEFAULT_ADMIN_ROLE`; on the testnet the deployer) grants each address one role:

```bash
cast send $P "grantRole(bytes32,address)" $OPENER  <backend opener>  --account manic-testnet-deployer --rpc-url robinhood_testnet
cast send $P "grantRole(bytes32,address)" $SETTLER <backend settler> --account manic-testnet-deployer --rpc-url robinhood_testnet
cast call $P "hasRole(bytes32,address)(bool)" $OPENER <backend opener> --rpc-url robinhood_testnet   # true
```

- **One key, one role.** Never give one address both the opener and the settler role (ARCHITECTURE §4.2).
- **At least two of each.** Then one revoked key can't stop trading.
- **Test ETH:** the backend funds its keys from the faucet; we can send 0.001 ETH each to start.

## Revoke

**At once, by the guardian** (on the testnet the deployer): it can only take power away.

```bash
cast send $P "revokeRelayer(bytes32,address)" $OPENER <address> --account manic-testnet-deployer --rpc-url robinhood_testnet
```

The admin's `revokeRole(role, address)` does the same. Once the backend's keys are live, revoke the contract's own test
relayer keys (`script/config/chains.toml`, `[46630]`), so that only the backend's keys can trade. Then:
- update `openers` and `settlers` in that table, which `Upgrade.liveSnapshot()` reads;
- note the change in `deployments/README.md`.

## Check

```bash
cast call $P "hasRole(bytes32,address)(bool)" $OPENER <address> --rpc-url robinhood_testnet
```

Every grant and revoke also shows on the explorer as `RoleGranted` or `RoleRevoked` on the proxy.
