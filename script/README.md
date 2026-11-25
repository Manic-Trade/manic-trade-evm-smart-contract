# `script/`: deployment and operations

Foundry scripts that deploy, set up and upgrade the contract. Every script checks its result and reverts, naming the
value, on any mismatch. `forge script` runs the whole script on a fork of the chain first and broadcasts only if it
passes, so a failed check sends nothing. After the broadcast, `Deploy` and `Configure` re-check the live chain with
`--sig "verify()"`. That sends nothing and fixes nothing, so it can't hide what is wrong. The step-by-step for a real
chain, with its checks, is [`docs/runbooks/deploy-testnet.md`](../docs/runbooks/deploy-testnet.md).

| Script | Sent by | What it does | What it checks afterwards |
|---|---|---|---|
| `DeployMockUsdg.s.sol` | the deployer | The test token, on a chain with no USDG: `test/mocks/MockUSDG.sol`, the mock every test runs and a weekly fork test holds to the real token. Its admin (mint, pause, freeze) is the deployer. Refuses Robinhood mainnet, and a chain whose `token` is set | admin, decimals, name, symbol, empty supply, not paused |
| `Deploy.s.sol` | the deployer | The implementation, then the ERC-1967 proxy, which calls `initialize` in its constructor: nobody can initialize it first. Refuses a chain whose record has a live proxy | the implementation slot; the implementation's size (≤ 98,304 bytes) and its locked initializers; the proxy initialized once; `version()`; the EIP-712 domain; every role, and no role the deployer wasn't given; the token, floor, recipients, refund delay and breaker; no market, an empty pool, not halted |
| `Configure.s.sol` | the admin and operator | Creates BTC's markets at each listed leverage, switched off, with their tested settings; switches on the ones listed as enabled; funds the pool up to `pool_funding` (minting it first on the mock). Running it again changes nothing that is already right | the number of markets; each market's key, exponent and every setting, field by field; none paused; the pool's total and balance; not halted, breaker not tripped |
| `Upgrade.s.sol` | the upgrader | A new implementation built from this checkout, then `upgradeToAndCall` (`runWithCall(bytes)` for a reinitializer). Run the layout check first (below) | the implementation slot, size and lock; every setting, role, market and book exactly as before. After the broadcast, `liveSnapshot()` (compared with the one taken before) and `verify()` check the live chain |
| `Smoke.s.sol` | an opener, then a settler | One bet the way the backend makes it. `prepareOpen` signs the order and the EIP-3009 stake authorisation (`SMOKE_USER_KEY`) and returns the `open` call, which the first opener sends at once with `cast send`. An open's price may be at most 5 seconds old, and running `open` on a fork of the public RPC takes longer. After expiry, `settle` has the first settler settle it. For the rehearsal and the first bet; the full smoke test is `smoke.py` | the position closed, and what the user was paid |
| `smoke.py` | every role | The smoke test: every way a bet ends, on the live contract, signed and sent as the backend does (Python standard library and `cast`). See below | after every transaction, the step's own effect and that the contract's balance equals its books |

The order on a new chain: `DeployMockUsdg` (only where there is no USDG), `Deploy`, `Configure`.

## Inputs: `config/`

- **`chains.toml`:** one table per chain id. It names the deployer and the role holders, the token (zero = use the
  mock), the pool floor, recipients, refund delay, breaker, the BTC leverages to create and to switch on, and the pool's
  funding. Each field is described in the file's header. A script refuses a chain with no table. Tables:
  - `31337`: anvil, and `forge test`;
  - `46630`: the Robinhood testnet.
- **`MarketSettings.sol`:** the settings of BTC's markets at 1000x (the launch values), 500x and 100x (the tier
  settings).
  - `test/script/Inputs.t.sol` proves each equals the tests' `LeverageConfigs.planned`, field by field, so what is
    deployed is what was tested.
  - Another leverage reverts: nothing was tested there.

## Output: the deployment record

Each script reads `deployments/<chainId>.json` and writes it back:
- `token` and whether it is the mock;
- `proxy` (the contract's address for the backend and the app) and `implementation`;
- `version`, `startBlock` (index events from here), `deployer` and `commit` (from `GIT_COMMIT`).

See [`deployments/README.md`](../deployments/README.md). The anvil record, `31337.json`, is git-ignored. `forge test`
writes it too (its chain id is anvil's), so run the tests after a rehearsal, not during one.

## Keys

- **Every script sends from the chain's `deployer`**, or from its `upgrader`, or its first opener and settler
  (`vm.startBroadcast(address)`).
  - The wallet given to `forge script` must be that account: `--account <keystore name>` on the testnet, never a key
    in `.env` (docs/CONVENTIONS.md §10).
  - A test runs the same `run()` with no key at all.
- **On anvil, the well-known test keys** are fine with `--private-key`. They come from anvil's mnemonic, `test test
  test test test test test test test test test junk`, accounts 0 to 5.

## Upgrades: the layout check first

The steps: [`docs/runbooks/upgrade-testnet.md`](../docs/runbooks/upgrade-testnet.md).

Before `Upgrade.s.sol`, run `python3 test/upgrade/layout/check.py`.
- It runs OpenZeppelin's upgrades plugin against every deployed version's build-info, kept in
  `deployments/<chainId>/build-info-v<version>/`.
- It runs outside Foundry, so no script needs FFI.
- On mainnet the upgrader is the 48-hour timelock, so the Safe schedules the upgrade. This script's checks show what to
  verify after it (ARCHITECTURE §4.2).

## The smoke test: `smoke.py`

`python3 script/smoke.py run` (then `refund` an hour later, and `report`) makes every kind of bet and step on the
deployed contract:
- **At each leverage:** a win and a loss.
- **The other endings:** a liquidation batch, a sale, the safety refund.
- **The money paths:** a payout deferred to a frozen user and claimed; the fees swept; `repay` on an empty queue.
- **The breaker:** lowered to $1 for the test, then a trip, an open refused, the reset, and the limit restored.
- **Refused:** a batch mixing two leverages.
- **Timing:** a burst of 12 opens from both openers at once, ended by one liquidation batch, and the chain's clock
  sampled against this machine's.

How it works:
- **Signing and sending:** the user signs with `cast wallet sign` and a relayer sends with `cast send` at once. An open's
  or a sale's price may be at most 5 seconds old, too little for `forge script` on a public RPC.
- **Checks:** after every transaction it checks the step's own effect, and that the contract's token balance equals its
  books (the pool's total, the pending fees and the claimable payouts).
- **What it changes:** the refund delay and the breaker's limit are shortened for the test and restored. The originals
  are kept in the log, and `restore` puts them back after a run that failed partway.

Two smaller commands: `open` (one bet, left open, for example across an upgrade) and `settle` (settles the log's open
bets, each at its expiry).

`--wallets` is a JSON file, kept out of git, with `cast`'s wallet arguments per role: deployer, opener1, opener2,
settler1, settler2, user. The output log (`--out`) holds every step, its transaction, gas and checks, and the timing
samples; `report` turns it into Markdown, kept beside the deployment's record (`deployments/<chainId>/`).

## Rehearsal on anvil

```bash
anvil --code-size-limit 98304 &          # Robinhood Chain's size limit; anvil's default is 24,576
M="test test test test test test test test test test test junk"
K() { cast wallet private-key --mnemonic "$M" --mnemonic-index "$1"; }
RPC=http://127.0.0.1:8545
for s in DeployMockUsdg Deploy Configure; do
  GIT_COMMIT=$(git rev-parse HEAD) forge script script/$s.s.sol --rpc-url $RPC --private-key "$(K 0)" --broadcast
done
TOKEN=$(jq -r .token deployments/31337.json)
cast send $TOKEN "mint(address,uint256)" $(cast wallet address "$(K 5)") 10000000 --private-key "$(K 0)" --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC         # a fresh block: the open's price must be at most 5 seconds old
OUT=$(SMOKE_USER_KEY=$(K 5) forge script script/Smoke.s.sol --sig "prepareOpen(uint16,int64)" 1000 9500000000000 \
  --rpc-url $RPC --json | grep '^{"logs"')
cast send $(jq -r .proxy deployments/31337.json) $(echo "$OUT" | jq -r .returns.openCall.value) \
  --private-key "$(K 1)" --rpc-url $RPC
cast rpc evm_increaseTime 61 --rpc-url $RPC && cast rpc evm_mine --rpc-url $RPC
forge script script/Smoke.s.sol --sig "settle(bytes32,int64)" $(echo "$OUT" | jq -r .returns.id.value) 9500950000000 \
  --rpc-url $RPC --private-key "$(K 3)" --broadcast
forge script script/Upgrade.s.sol --rpc-url $RPC --private-key "$(K 0)" --broadcast
```

The tests in `test/script/` run the same scripts in-process:
- `Sequence.t.sol`: the whole sequence through each `run()`;
- `Deploy.t.sol`, `Configure.t.sol` and `Upgrade.t.sol`: each check fails on each value it guards;
- `Inputs.t.sol`: the chains and the market settings.

Lint: `script/.solhint.json` is the test rule set with `reason-string` off. An operator reads these revert messages to
learn which value is wrong, so they say it in full.
