# Runbook: deploy to the Robinhood testnet

**For:** whoever deploys or redeploys the contract on the Robinhood testnet (chain id 46630).
**Takes:** about 30 minutes, the explorer verification included.
**Rehearse first:** the same sequence on anvil, from [`script/README.md`](../../script/README.md#rehearsal-on-anvil).

Every script checks its own result and reverts, naming the value, if anything is off:
- before broadcasting: `forge script` runs it on a fork first, and a failed check sends nothing;
- after: `--sig "verify()"` re-checks the live chain, sending nothing.

The `cast` lines after each step check the same things a third way.

## 0. Before you start

- **Foundry 1.8.7** (`forge --version`), and Node.js 22 for the layout check.
- **`.env`:** `ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com`. Then `source .env`.
- **The deployer key, in Foundry's encrypted keystore**, never in `.env`:
  `cast wallet import manic-testnet-deployer --interactive`.
  - Its address must be the `deployer` of the `[46630]` table in `script/config/chains.toml`.
- **Test ETH:** about 0.01 ETH, from [faucet.testnet.chain.robinhood.com](https://faucet.testnet.chain.robinhood.com).
  - The whole deployment costs about 0.0002 ETH: about 13M gas at 0.01 gwei.
  - Step 5 sends 0.001 ETH to each relayer key.
- **The inputs are right:** read the `[46630]` table, then print what the scripts will use:

  ```bash
  forge script script/Deploy.s.sol --sig "inputs()" --rpc-url robinhood_testnet
  ```

Shorthand used below: `S="--rpc-url robinhood_testnet --account manic-testnet-deployer --broadcast"`.

## 1. The test token

```bash
forge script script/DeployMockUsdg.s.sol $S
TOKEN=$(jq -r .token deployments/46630.json)
cast call $TOKEN "admin()(address)" --rpc-url robinhood_testnet        # the deployer
cast call $TOKEN "decimals()(uint8)" --rpc-url robinhood_testnet       # 6
```

## 2. The contract

```bash
GIT_COMMIT=$(git rev-parse HEAD) forge script script/Deploy.s.sol $S
forge script script/Deploy.s.sol --sig "verify()" --rpc-url robinhood_testnet   # every check again, on the chain
PROXY=$(jq -r .proxy deployments/46630.json)
cast call $PROXY "version()(string)" --rpc-url robinhood_testnet       # "1.0.0"
cast storage $PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url robinhood_testnet                                          # the implementation in the record
```

## 3. The markets and the pool

```bash
forge script script/Configure.s.sol $S
forge script script/Configure.s.sol --sig "verify()" --rpc-url robinhood_testnet   # every market and the pool
cast call $PROXY "marketCount()(uint16)" --rpc-url robinhood_testnet   # 3
cast call $TOKEN "balanceOf(address)(uint256)" $PROXY --rpc-url robinhood_testnet   # the pool_funding
```

Running it again is safe: it creates, switches on or funds only what is missing.

## 4. The roles, from the chain

```bash
OPENER=$(cast call $PROXY "OPENER_ROLE()(bytes32)" --rpc-url robinhood_testnet)
SETTLER=$(cast call $PROXY "SETTLER_ROLE()(bytes32)" --rpc-url robinhood_testnet)
cast call $PROXY "hasRole(bytes32,address)(bool)" $OPENER <each opener> --rpc-url robinhood_testnet    # true
cast call $PROXY "hasRole(bytes32,address)(bool)" $SETTLER <each settler> --rpc-url robinhood_testnet  # true
```

## 5. Gas for the relayer keys

```bash
for a in <opener 1> <opener 2> <settler 1> <settler 2>; do
  cast send $a --value 0.001ether --rpc-url robinhood_testnet --account manic-testnet-deployer
done
```

## 6. Keep the build-info

The upgrade checker needs the deployed version's build-info: the compiler's input and output, with the AST and the
storage layout. Build it with the `upgrades` profile into a temporary folder, check that it is the deployed code, and
keep it:

```bash
TMP=$(mktemp -d)
FOUNDRY_PROFILE=upgrades forge build src --out $TMP/out --cache-path $TMP/cache
IMPL=$(jq -r .implementation deployments/46630.json)
cast code $IMPL --rpc-url robinhood_testnet > $TMP/deployed.hex
python3 script/bytecode.py $TMP/deployed.hex $TMP/out/ManicFlashOption.sol/ManicFlashOption.json
mkdir -p deployments/46630 && cp -R $TMP/out/build-info deployments/46630/build-info-v1.0.0
python3 test/upgrade/layout/check.py                                   # now also checks against it
```

`script/bytecode.py` blanks the immutables before comparing. The deployed code differs from the build only at
`UUPSUpgradeable.__self`, which holds the implementation's own address. The rest must be equal byte for byte, metadata
hash included.

## 7. Verify the source on the explorer

The explorer is Blockscout ([explorer.testnet.chain.robinhood.com](https://explorer.testnet.chain.robinhood.com)), so
no API key is needed. Verification publishes the source of each contract.

```bash
V="--chain 46630 --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/ --watch"
forge verify-contract $IMPL src/ManicFlashOption.sol:ManicFlashOption $V
forge verify-contract $TOKEN test/mocks/MockUSDG.sol:MockUSDG $V \
  --constructor-args $(cast abi-encode "f(string,string,address)" "Global Dollar" "USDG" <deployer>)
INIT=$(jq -r '.transactions[] | select(.contractName=="ERC1967Proxy") | .arguments[1]' broadcast/Deploy.s.sol/46630/run-latest.json)
forge verify-contract $PROXY lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy $V \
  --skip-is-verified-check --constructor-args $(cast abi-encode "f(address,bytes)" $IMPL $INIT)
curl -s https://explorer.testnet.chain.robinhood.com/api/v2/smart-contracts/$PROXY | jq '{is_verified, name, proxy_type}'
```

The proxy needs `--skip-is-verified-check`. Once the implementation is verified, Blockscout's Etherscan-style API
reports the proxy under the implementation's name, so forge takes it as verified and skips it. The last line must show
`"is_verified": true, "name": "ERC1967Proxy", "proxy_type": "eip1967"`.

## 8. The first bet

A throwaway user key (never a real wallet's) signs. The deployer mints its stake, the first opener opens, and after 60
seconds the first settler settles. Prices are at BTC's exponent, -8.

An open's price may be at most 5 seconds old. Running `open` on a fork of the public RPC takes longer than that, because
it fetches the contract's storage slot by slot. So `prepareOpen` only signs and returns the `open` call, and the opener
sends it at once with `cast send`, as the backend does.

```bash
cast send $TOKEN "mint(address,uint256)" <user> 10000000 --rpc-url robinhood_testnet --account manic-testnet-deployer
OUT=$(SMOKE_USER_KEY=... forge script script/Smoke.s.sol --sig "prepareOpen(uint16,int64)" 1000 <price> \
  --rpc-url robinhood_testnet --json | grep '^{"logs"')
cast send $PROXY $(echo "$OUT" | jq -r .returns.openCall.value) --rpc-url robinhood_testnet --account <opener 1>
# 60 seconds later
forge script script/Smoke.s.sol --sig "settle(bytes32,int64)" $(echo "$OUT" | jq -r .returns.id.value) <price at expiry> \
  --rpc-url robinhood_testnet --account <settler 1> --broadcast
```

## 9. The smoke test

Every way a bet ends, on the live contract (`script/smoke.py`). It takes about 5 minutes, then the refund an hour
later. The relayers and the user sign through Foundry keystores, listed in a wallets file kept out of git:
`{"deployer": ["--account", "manic-testnet-deployer", "--password-file", "<pw>"], "opener1": [...], ...}`.

```bash
python3 script/smoke.py run --rpc $ROBINHOOD_TESTNET_RPC_URL --wallets <wallets.json> --out <log.json>
# an hour after the refund bet's expiry (the log's state.refund.dueAt)
python3 script/smoke.py refund --rpc $ROBINHOOD_TESTNET_RPC_URL --wallets <wallets.json> --out <log.json>
python3 script/smoke.py report --out <log.json> > deployments/46630/smoke-<date>.md
```

If `run` stops partway, `restore` (same arguments) puts the breaker's limit and the refund delay back, and clears a
trip.

## 10. Commit

Commit these on a branch and open a pull request:
- `deployments/46630.json`;
- `deployments/46630/build-info-v1.0.0/`;
- `broadcast/*/46630/`.

Then hand over the addresses, the ABI (`abi/IManicFlashOption.json`) and the signing details ([`docs/integration.md`](../integration.md)).

## If something fails

- **A script's check reverts:** nothing after it ran. Read the message: it names the value. Fix the input or the
  chain's state, then run the same script again.
  - `Configure` and the checks can run any number of times.
  - `Deploy` refuses a chain whose record has a live proxy: that proxy is upgraded, never replaced.
- **To start over on the testnet:** delete `deployments/46630.json`, which loses the old addresses, and run from step 1.
  The old contracts stay on the chain, unused.
