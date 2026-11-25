# Manic Flash Option

`ManicFlashOption` is the Manic Flash Option contract for **Robinhood Chain**: short, leveraged bets on where a price
goes, staked and paid in USDG from one pool. It is written in Solidity 0.8.38 with Foundry, and runs as one upgradeable
contract behind an ERC-1967 (UUPS) proxy.

> **Status:** v1.0.0. The first testnet deployment from this repository is pending; its addresses will be in
> [`deployments/`](deployments/README.md).

## What it does

- **A bet** says a price will end higher (a call) or lower (a put) after a short duration: 1 to 5 minutes at launch.
- **The user chooses the leverage.** Each market is a price feed at one leverage: BTC at 1000x, 500x and 100x. At
  leverage L, every basis point the price moves is worth L basis points of the stake.
- **Each bet has three limits:**
  - a liquidation line: a price tick that touches it ends the bet, and the stake is lost;
  - a floor: the least a right call pays;
  - a cap: the most a bet pays.
- **The platform is never the counterparty.** One pool, funded by the operator, pays winners, and losers' stakes go
  into it. The platform earns fees only:
  - 2% of a winner's profit;
  - 3% of a loss, while the pool's free money is at or above its floor;
  - on an early sale, 1% + 5% × the time left, capped at 6%: the backend quotes it, and the contract enforces the cap.
- **Commit first, price after.** The user signs an order with no price in it (EIP-712, domain `"Manic Flash Option"`,
  version `"1"`), and a USDG authorisation for exactly the stake. The backend adds the next price tick, sends the
  transaction and pays the gas, so users never need ETH.
- **A bet ends in one of four ways:** liquidated when a tick touches its line, settled at its expiry second, sold
  early, or refunded if the backend never settles it.
- **If the pool can't pay a winner in full,** the rest becomes an IOU, repaid first in, first out.

## Safety features

- **No allowances.** Each stake comes in through USDG's EIP-3009 `receiveWithAuthorization`, for exactly the stake,
  which only the contract can submit. No user ever holds a standing allowance on the contract, and the contract checks
  that its balance rose by exactly the stake ([ADR 0002](docs/adr/0002-eip3009-stake-pull.md)).
- **Separate keys, each with only the power it needs:** opener and settler relayer keys, an operator, a guardian, an
  admin and an upgrader. On mainnet the admin and the upgrader sit behind a 48-hour timelock
  ([ADR 0005](docs/adr/0005-relayer-roles-and-timelock.md)).
- **Brakes.** The guardian can halt every market at once, pause one market, or revoke a relayer key at once. Only the
  operator can release a halt or a pause.
- **A payout circuit breaker.** When the profit paid out in a window beats the losses kept by more than a limit, new
  bets and sales stop until the operator resets it. Liquidations, settlements, repayments, refunds and claims go on
  ([ADR 0003](docs/adr/0003-payout-circuit-breaker.md)).
- **The pool covers every bet.** A bet opens only while free money covers every open bet's maximum profit (the open
  gate, at most 100% of free money). Withdrawals leave every open bet covered, and stop while anyone is owed.
- **Bounded settings.** A market's payout settings, its open gate and its clock skew are checked whenever they are set,
  so not even the operator's key can loosen them past those bounds
  ([ADR 0009](docs/adr/0009-bounded-open-gate-and-clock-skew.md)).
- **Payouts never block a batch.** A payout the token refuses (a frozen address, a paused token) waits in `claimable`
  for its owner, and the rest of the batch is paid.
- **The safety refund.** If the backend stops, anyone can return a bet's whole stake once the refund delay (24 hours at
  launch) has passed since its expiry. No brake stops it.
- **Upgrade safety.** All state lives in one ERC-7201 namespace, `manic.storage.FlashOption`, and its layout is
  append-only. CI checks every change with OpenZeppelin's upgrades plugin
  ([ADR 0001](docs/adr/0001-uups-proxy-with-erc7201-storage.md)).

The full design is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), and the maths in
[`docs/MATH.md`](docs/MATH.md). The reasons behind the main choices are in [`docs/adr/`](docs/adr/README.md)
(architecture decision records).

## Repository map

| Path | Contents |
|---|---|
| [`src/`](src/README.md) | The contract, split into small files by concern (modules, a shared base, libraries, types, interfaces); it compiles to one deployed contract |
| [`test/`](test/README.md) | The tests, by kind (below) |
| [`script/`](script/README.md) | Deploy, configure, upgrade and smoke-test scripts, with their inputs in `script/config/` |
| [`docs/`](docs/) | The design, the maths and the guides (below) |
| [`abi/`](abi/README.md) | The contract's ABI for the backend and the frontend, kept current by CI |
| [`deployments/`](deployments/README.md) | The record of each deployment: addresses, version, start block and build-info |
| [`audit/`](audit/README.md) | Static analysis and coverage: every finding, and how it was resolved |
| `snapshots/` | The gas benchmarks' numbers, checked by CI |
| `lib/` | Dependencies, as git submodules pinned to release tags |

**The tests** ([`test/`](test/README.md)):

| Folder | What it covers |
|---|---|
| `unit/` | The libraries (the maths, the settings checks, the order hashes, the breaker), the storage layout and the ABI, without a proxy |
| `concrete/` | One folder per function: a `.tree` file of its checks in order, and the tests made from it; plus the rules that cross functions (the brakes, the breaker, reentrancy, the views) |
| `fuzz/` | Properties over random inputs: the maths, signatures, the order rules, rounding, and each function at any leverage |
| `invariant/` | Random sequences of actions on BTC at 1000x, 500x and 100x on one pool, with every invariant checked after every call |
| `access/` | Who may call what; what each key can do alone if it leaks; the fake-price loop the breaker stops |
| `scenarios/` | Whole flows with exact numbers, to the base unit: liquidations, settlements, sales, the IOU queue, and trading at three leverages on one pool |
| `signing/` | The EIP-712 vectors the backend's signer must reproduce |
| `gas/` | The gas benchmarks behind [`docs/gas.md`](docs/gas.md) |
| `fork/` | The contract and the mock token against the real USDG, on a fork of Robinhood Chain mainnet |
| `upgrade/` | An upgrade over real state, and the storage-layout check with OpenZeppelin's upgrades plugin |
| `script/` | The deploy scripts, run in-process: each check fails on the value it guards |

**The docs** ([`docs/`](docs/)):

| File | What it holds |
|---|---|
| [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) | The full design |
| [`MATH.md`](docs/MATH.md) | The maths the contract computes, with worked examples |
| [`integration.md`](docs/integration.md) | For the backend and the frontend: what to call and sign, the events, and every error |
| [`abi-reference.md`](docs/abi-reference.md) | Every selector, event topic and error id, generated from the compiler |
| [`gas.md`](docs/gas.md) | What each call costs, and how to size batches |
| [`storage-layout.md`](docs/storage-layout.md) | The storage slot map, field by field |
| [`security-checklist.md`](docs/security-checklist.md) | Each pitfall, the rule that answers it, and the test that proves it |
| [`CONVENTIONS.md`](docs/CONVENTIONS.md) | The coding, NatSpec, test and git rules |
| [`adr/`](docs/adr/README.md) | The decision records |
| [`runbooks/`](docs/runbooks/) | Deploying, upgrading, and granting relayer keys |

## Quick start

You need [Foundry](https://getfoundry.sh) **1.8.7**: every tool version is pinned
([ADR 0004](docs/adr/0004-toolchain.md)).

```bash
# Foundry, pinned
curl -L https://foundry.paradigm.xyz | bash
foundryup --install v1.8.7

# The repository and its pinned dependencies
git clone --recurse-submodules git@github.com:Manic-Trade/manic-trade-evm-smart-contract.git
cd manic-trade-evm-smart-contract

forge build
forge test
```

The fork tests need an RPC URL (`cp .env.example .env`, then fill it in), and skip themselves without one.

## Toolchain

| Tool | Version |
|---|---|
| Foundry | v1.8.7 |
| Solidity | 0.8.38, EVM target `cancun`, optimizer 200 runs, no via-IR |
| OpenZeppelin Contracts + Contracts-Upgradeable | 5.6.1 |
| forge-std | 1.17.0 |
| openzeppelin-foundry-upgrades | 0.4.4 (needs Node.js ≥ 18 for upgrade checks) |
| bulloak | v0.8.1, the release binary from [github.com/alexfertel/bulloak](https://github.com/alexfertel/bulloak) (the tree tests; CI checks the release's SHA-256; locally it is optional) |

## Commands

| Task | Command |
|---|---|
| Build, with contract sizes | `forge build --sizes` |
| Run all tests | `forge test` |
| Run one test file, verbose | `forge test --match-path test/Toolchain.t.sol -vvv` |
| Lint | `forge lint` (src) and `npx solhint@6.2.5 -c test/.solhint.json 'test/**/*.sol'` |
| CI-strength fuzzing | `FOUNDRY_PROFILE=ci forge test` |
| Deep fuzzing (100,000 cases per property; CI runs it each week `dev` changed) | `FOUNDRY_PROFILE=deep forge test --match-path 'test/fuzz/*'` |
| Deep invariant runs (1,000 runs of 100 calls per campaign; CI runs them each week `dev` changed) | `FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'` |
| Upgrade-safety check: the layout against `dev`, and the 15 variants (needs Node.js 22; CI runs it on every change) | `python3 test/upgrade/layout/check.py --base origin/dev` |
| Format / check formatting | `forge fmt` / `forge fmt --check` |
| Coverage | `forge coverage` |
| Gas snapshot | `forge snapshot` |
| Regenerate the committed ABI | `forge inspect IManicFlashOption abi --json > abi/IManicFlashOption.json` |
| Check the tree tests | `bulloak check 'test/concrete/**/*.tree'` |
| Start a new tree's tests | `bulloak scaffold -s 0.8.38 -w test/concrete/<fn>/<fn>.tree` |

## How we work

- **Branches:**
  - `dev` is the default branch and always holds stable, tested code.
  - `main` only receives code that is deployed to mainnet.
- **One branch per change,** branched from `dev`:
  1. The work is developed and fully tested there.
  2. It goes into `dev` through a pull request.
  3. Each pull request includes its own tests and documentation.
- **Commits** are small and explain what changed and why.
- Pull requests are merged with a merge commit (not squashed), so every commit stays readable in the history.
- The coding, documentation, test and commit rules are in [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).

## Security

How to report a vulnerability: [`SECURITY.md`](SECURITY.md). The pitfalls checklist that the design answers:
[`docs/security-checklist.md`](docs/security-checklist.md). Static analysis and coverage:
[`audit/static-analysis.md`](audit/static-analysis.md).
