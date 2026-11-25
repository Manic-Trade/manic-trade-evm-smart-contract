# Runbook: upgrade the contract on the Robinhood testnet

**For:** whoever upgrades the live testnet proxy.
**Takes:** about 15 minutes.
**Rehearse first:** on anvil. The [anvil rehearsal](../../script/README.md#rehearsal-on-anvil) ends with an upgrade, and
`test/script/Sequence.t.sol` runs one through the script's own `run()`.

**On mainnet the upgrader is the 48-hour timelock** (ARCHITECTURE §4.2). There, the Safe schedules the same
`upgradeToAndCall` instead of step 3, and steps 4 to 6 are the checks after it executes.

## 0. Before you start

- Foundry 1.8.7, Node.js 22, and the deployer keystore (`manic-testnet-deployer`), as in
  [`deploy-testnet.md`](deploy-testnet.md) step 0.
- Set the RPC, which the `robinhood_testnet` alias in `foundry.toml` reads:
  `export ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com`.
- **A new version needs:**
  - a new `version()`;
  - a `reinitializer(n)` for any field it adds, called in the same transaction (`runWithCall`);
  - its build-info kept after the upgrade, as `deployments/46630/build-info-v<new version>/`
    ([`deploy-testnet.md`](deploy-testnet.md) step 6).

  A rebuild of the same code needs none of these.

## 1. The layout check

```bash
python3 test/upgrade/layout/check.py      # must end "N of N checks as expected", against deployments/46630/build-info-v*
```

It checks the code against every deployed version's storage layout, with OpenZeppelin's upgrades plugin. If it fails,
stop: the upgrade would corrupt storage.

## 2. A bet across the upgrade, and the snapshot before

```bash
python3 script/smoke.py open --leverage 500 --side put --rpc $ROBINHOOD_TESTNET_RPC_URL --wallets <wallets.json> --out <log.json>
forge script script/Upgrade.s.sol --sig "liveSnapshot()" --rpc-url robinhood_testnet    # note the bytes32
```

`liveSnapshot()` hashes every setting, role, market and the pool's books. Nothing else should trade between this step
and step 4, or the books move.

## 3. The upgrade

```bash
GIT_COMMIT=$(git rev-parse HEAD) forge script script/Upgrade.s.sol --rpc-url robinhood_testnet \
  --account manic-testnet-deployer --broadcast --slow
# with a reinitializer: --sig "runWithCall(bytes)" $(cast calldata "initializeV2(uint64)" 7)
```

It deploys the new implementation and calls `upgradeToAndCall` from the upgrader. Before sending, it runs both on a
fork and checks that nothing but the implementation changed. It updates `deployments/46630.json`.

Only the upgrader can upgrade. To show that, run the call as any other key, without sending it:
`cast call <proxy> "upgradeToAndCall(address,bytes)" <implementation> 0x --from <opener>` → `AccessControlUnauthorizedAccount`.

## 4. The checks on the chain

```bash
forge script script/Upgrade.s.sol --sig "liveSnapshot()" --rpc-url robinhood_testnet    # the same bytes32 as step 2
forge script script/Upgrade.s.sol --sig "verify()" --rpc-url robinhood_testnet          # implementation, lock, size, version
TMP=$(mktemp -d); FOUNDRY_PROFILE=upgrades forge build src --out $TMP/out --cache-path $TMP/cache
cast code $(jq -r .implementation deployments/46630.json) --rpc-url robinhood_testnet > $TMP/d.hex
python3 script/bytecode.py $TMP/d.hex $TMP/out/ManicFlashOption.sol/ManicFlashOption.json
```

## 5. The bet, settled by the new code

```bash
python3 script/smoke.py settle --rpc $ROBINHOOD_TESTNET_RPC_URL --wallets <wallets.json> --out <log.json>
```

## 6. The explorer, and the record

```bash
forge verify-contract $(jq -r .implementation deployments/46630.json) src/ManicFlashOption.sol:ManicFlashOption \
  --chain 46630 --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/ --watch \
  --skip-is-verified-check
```

Commit `deployments/46630.json`, `broadcast/Upgrade.s.sol/46630/`, a report, and the new build-info if the version
changed. Then update the addresses in `deployments/README.md`.
