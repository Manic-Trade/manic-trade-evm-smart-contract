# Manic Flash Options

Manic.trade is the trading app for the next minute: 0DTE-style options on crypto, stocks and oil that expire in 1 to 5
minutes. Flash Options lets you trade synthetic BTC options like perps: pick Long or Short and a leverage tier up to
1000x, get paid by how far the price moves, and never lose more than your stake. In Higher/Lower, you pick a direction
and a duration and see your fixed payout before you trade (Coming Soon).

**Try it:** [options.manic.trade](https://options.manic.trade)

This repository holds the Flash Options contract, `ManicFlashOption`, for **Robinhood Chain**: short, leveraged trades
on where a price goes, staked and paid in USDG from one pool. It is written in Solidity 0.8.38 with Foundry, and runs as
one upgradeable contract behind an ERC-1967 (UUPS) proxy.

## Why Robinhood Chain

- **Stakes and payouts in USDG,** Paxos's Global Dollar on Robinhood Chain, from one pool.
- **No gas for users.** A user only signs; the backend sends each transaction and pays its gas, so users never need ETH.
- **Ready for tokenized stocks.** A market is a price feed at a leverage, so stock markets can follow BTC, in step with
  Robinhood Chain's focus on tokenized stocks.

## Status

v1.0.0, live on the Robinhood testnet (chain id 46630). The testnet has no USDG, so stakes and payouts there use a mock
with USDG's behaviour. The contract, the proxy every call and event uses:
[`0x97087017226BE5169CB719035eeF55400ccfC615`][testnet-proxy]. Every address is in
[`deployments/`](deployments/README.md).

[testnet-proxy]: https://explorer.testnet.chain.robinhood.com/address/0x97087017226BE5169CB719035eeF55400ccfC615

## What it does

- **A trade** says a price will end higher (Long, a call) or lower (Short, a put) after a short duration: 1 to 5 minutes
  at launch.
- **The user chooses the leverage.** Each market is a price feed at one leverage: BTC at 1000x, 500x and 100x. At
  leverage L, every basis point the price moves is worth L basis points of the stake.
- **Each position has three limits:**
  - a liquidation line: a price tick that touches it ends the position, and the stake is lost;
  - a floor: the least a winning position pays;
  - a cap: the most a position pays.
- **The platform is never the counterparty.** One pool, funded by the operator, pays winners, and losers' stakes go
  into it. The platform earns fees only and never takes the other side of a trade.
- **Commit first, price after.** The user signs an order with no price in it (EIP-712), and a USDG authorisation for
  exactly the stake. The backend adds the next price tick, sends the transaction and pays the gas, so users never need
  ETH.
- **A position ends in one of four ways:** liquidated when a tick touches its line, settled at its expiry second, sold
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
  trades and sales stop until the operator resets it. Liquidations, settlements, repayments, refunds and claims go on
  ([ADR 0003](docs/adr/0003-payout-circuit-breaker.md)).
- **The pool covers every position.** A trade opens only while free money covers every open position's maximum profit
  (the open gate, at most 100% of free money). Withdrawals leave every open position covered, and stop while anyone is
  owed.
- **Bounded settings.** A market's payout settings, its open gate and its clock skew are checked whenever they are set,
  so not even the operator's key can loosen them past those bounds
  ([ADR 0009](docs/adr/0009-bounded-open-gate-and-clock-skew.md)).
- **Payouts never block a batch.** A payout the token refuses (a frozen address, a paused token) waits in `claimable`
  for its owner, and the rest of the batch is paid.
- **The safety refund.** If the backend stops, anyone can return a position's whole stake once the refund delay (24
  hours at launch) has passed since its expiry. No brake stops it.
- **Upgrade safety.** All state lives in one ERC-7201 namespace, `manic.storage.FlashOption`, and its layout is
  append-only. CI checks every change with OpenZeppelin's upgrades plugin
  ([ADR 0001](docs/adr/0001-uups-proxy-with-erc7201-storage.md)).

The full design is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), and the maths in [`docs/MATH.md`](docs/MATH.md),
with a second implementation in Python in [`model/`](model/README.md) that the contract is tested against. The reasons
behind the main choices are in [`docs/adr/`](docs/adr/README.md) (architecture decision records).

## Repository map

| Path | Contents |
|---|---|
| [`src/`](src/README.md) | The contract, split into small files by concern (modules, a shared base, libraries, types, interfaces); it compiles to one deployed contract |
| [`test/`](test/README.md) | The tests, by kind (below) |
| [`model/`](model/README.md) | The maths again, in Python, written from `docs/MATH.md`, and the generator of the vectors the contract is tested against |
| [`script/`](script/README.md) | Deploy, configure, upgrade and smoke-test scripts, with their inputs in `script/config/` |
| [`docs/`](docs/) | The design, the maths and the guides (below) |
| [`abi/`](abi/README.md) | The contract's ABI for the backend and the frontend, kept current by CI |
| [`deployments/`](deployments/README.md) | The record of each deployment: addresses, version, start block and build-info |
| [`audit/`](audit/README.md) | Static analysis, coverage and mutation testing: every finding, and how it was resolved |
| `snapshots/` | The gas benchmarks' numbers, checked by CI |
| `lib/` | Dependencies, as git submodules pinned to release tags |

**The tests** ([`test/`](test/README.md)):

| Folder | What it covers |
|---|---|
| `unit/` | The libraries (the maths, the settings checks, the order hashes, the breaker), the storage layout and the ABI, without a proxy |
| `model/` | The maths against the Python model, on 20,661 vectors (`fixtures/model/`): the same outputs, or the same error |
| `concrete/` | One folder per function: a `.tree` file of its checks in order, and the tests made from it; plus the rules that cross functions (the brakes, the breaker, reentrancy, the views) |
| `fuzz/` | Properties over random inputs: the maths, signatures, the order rules, rounding, and each function at any leverage |
| `invariant/` | Random sequences of actions on BTC at 1000x, 500x and 100x on one pool, with every invariant checked after every call |
| `access/` | Who may call what; what each key can do alone if it leaks; the fake-price loop the breaker stops |
| `scenarios/` | Whole flows with exact numbers, to the base unit: liquidations, settlements, sales, the IOU queue, and trading at three leverages on one pool. Each number is derived again by the model (`model/scenarios.py`) |
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

## Build and test

```bash
git clone --recurse-submodules https://github.com/Manic-Trade/manic-trade-evm-smart-contract.git
cd manic-trade-evm-smart-contract
forge build && forge test
```

It needs Foundry 1.8.7. The toolchain, every command and how we work are in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

How to report a vulnerability: [`SECURITY.md`](SECURITY.md). The pitfalls checklist that the design answers:
[`docs/security-checklist.md`](docs/security-checklist.md). Static analysis, coverage and mutation testing:
[`audit/`](audit/README.md).
