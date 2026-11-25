# Changelog

Every contract version is listed here, with its **ABI** and **storage** changes called out, so the backend and
the upgrade reviewer can see at a glance what changed. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-25

The first release: the whole contract, with its tests, scripts and documentation. Nothing is deployed from this
repository yet.

### Added

- **The contract:** `ManicFlashOption`, one contract behind an ERC-1967 (UUPS) proxy, built from abstract modules over
  a shared base (ADR 0001, ADR 0006). `version()` returns `"1.0.0"`. It fits Robinhood Chain's 98,304-byte code-size
  limit (ADR 0007).
- **Markets:** a market is a Pyth price feed at one leverage, any whole number from 1x to 10,000x (ADR 0008). Each has
  its own settings (stakes, durations and their line ranges, floors, caps, the early-sell fee's cap, the price age, the
  clock skew, the sell window, the open gate and the owed limit) and its own pause. `ConfigLib.validate` checks the
  settings at the market's leverage whenever they are set.
- **Trading,** by the opener relayer:
  - `open`: the user's signed `OpenOrder` (EIP-712, domain `"Manic Flash Option"`, version `"1"`, the leverage
    included) and USDG EIP-3009 stake authorisation, with the relayer's price tick and the bet's terms. The checks run
    in a fixed order, then the stake is pulled and must arrive in full (ADR 0002).
  - `sell`: an early exit, at the user's signed `SellOrder` and the relayer's tick and quote, which the contract bounds
    with its own maths. A sale is paid in full or not at all.
- **Endings and repayments:**
  - `liquidate` and `settle`, by the settler relayer: batches of 1 to 100 bets of one market at one tick. A bet that
    has already ended is skipped (`PositionSkipped`), so a batch never gets stuck.
  - `repay`, by anyone: pays the IOU queue in order from free money, up to 50 IOUs a call.
  - `refundExpired`, by anyone: the safety refund. It returns a bet's whole stake, with no fee, once the refund delay
    (24 hours at launch) has passed since its expiry. No brake stops it.
- **The pool:** `fund` (anyone), `withdraw` (admin: seed recovery, at most 500 whole tokens in all, or rewards; only
  while nobody is owed and every open bet stays covered above the floor), `claim` (anyone, paid to the account itself
  only) and `sweepFees` (anyone, paid to the fee recipient).
- **Fees:** 2% of a winner's profit; 3% of a loss while free money is at or above the pool's floor; an early-sell fee
  of 1% + 5% × the time left, capped at 6%, which the backend quotes and the contract caps (the market's
  `maxSellFeeBps`).
- **Settings and brakes:** `initialize`, `createMarket`, `setConfig`, `setPaused`, `setHalted`, `setPoolFloor`,
  `setRecipients`, `setRefundDelay`, `setBreaker`, `resetBreaker` and `revokeRelayer`.
- **Roles** (ADR 0005):
  - `DEFAULT_ADMIN_ROLE` (markets, the pool's settings, withdrawals, role grants) and `UPGRADER_ROLE` (upgrades only),
    both held by a 48-hour timelock on mainnet;
  - `OPERATOR_ROLE`: market settings, releasing a pause or the halt, resetting the breaker; it moves no money;
  - `GUARDIAN_ROLE`: the halt, a market's pause, revoking a relayer key; it can only take power away;
  - `OPENER_ROLE` and `SETTLER_ROLE`: the backend's relayer keys.
- **Safety features:**
  - the halt, and a pause per market;
  - the payout circuit breaker: when a window's profit paid out beats its losses kept by more than the limit, `open`
    and `sell` stop until the operator's `resetBreaker` (ADR 0003);
  - the open gate, at most 100% of free money, and a clock skew of at most 30 seconds (ADR 0009);
  - the IOU queue: winnings the pool can't pay now are owed and repaid first in, first out;
  - a payout the token refuses waits in `claimable`, and a payout without enough gas reverts the call
    (`InsufficientGasForPayout`) instead of being deferred;
  - a reentrancy guard on every state-changing function, and on every getter that reads the books;
  - signatures checked with ECDSA first, then ERC-1271; only 65-byte signatures with a low `s` from an EOA.
- **Views:** `getPosition`, `getMarket`, `marketIdAt`, `marketCount`, `getPool`, `freeMoney`, `claimableOf`,
  `queueHead`, `getBreaker`, `token`, `halted`, `refundDelaySecs` and `recipients`, and the digest helpers
  `hashOpenOrder` and `hashSellOrder`.
- **Tests:**
  - unit tests of the libraries, the storage layout (every slot and offset) and the ABI (every signature);
  - tree tests of every function with ordered checks, checked by bulloak: each revert test breaks its own check,
    which also proves the order;
  - fuzz properties, with a deep profile of 100,000 runs per property that CI runs each week `dev` changed;
  - invariant tests: every invariant of ARCHITECTURE §12 after every call, in two campaigns (the launch pool, and a
    small pool whose winners are owed);
  - the access-control matrix, each key's blast radius, and the fake-price loop the breaker stops;
  - scenarios with exact numbers, to the base unit, each number derived again by the model (`model/scenarios.py`);
  - the maths against a second implementation in Python (`model/`): 20,661 vectors of 24 functions
    (`test/fixtures/model/`), replayed by `test/model/ModelVectors.t.sol`;
  - EIP-712 signing vectors for the backend's signer (`test/fixtures/eip712_vectors.json`);
  - fork tests against the real USDG on Robinhood Chain mainnet, run weekly;
  - an upgrade over real state, and OpenZeppelin's layout check against 15 variant patches;
  - gas benchmarks (`snapshots/ManicFlashOption.json`, `docs/gas.md`);
  - the deploy scripts' own tests;
  - a mutation run: 35 single-point bugs put into `src/`, each caught by the tests (`audit/mutation.md`).
- **Scripts:** `DeployMockUsdg`, `Deploy`, `Configure`, `Upgrade` and `Smoke`, each checking its result on chain;
  `smoke.py`, every way a bet ends on a live chain; `bytecode.py`, which checks the deployed code is the build;
  `build_info.py`, which keeps the build machine's paths out of a committed build-info. Inputs in `script/config/`,
  outputs in `deployments/<chainId>.json`.
- **CI:** formatting, the build and its size check, the tests, the committed ABI and ABI reference, the model's
  vectors and scenario derivations, the layout check, Slither, coverage (every line, function and reachable branch of
  `src/`), solhint and bulloak, a gas check (no call more than 5% dearer than on the base branch), and weekly deep
  fuzz, invariant and fork runs.
- **Documentation:** the README, the architecture, the maths, the integration guide, the ABI reference, gas costs,
  the storage layout, the security checklist, the conventions, nine decision records, the runbooks (deploy, upgrade,
  relayer keys), the static-analysis report and the security policy.

ABI:
- 58 functions: ours (`initialize`, the 10 admin functions, `open`, `sell`, `liquidate`, `settle`, `refundExpired`,
  `repay`, the 4 pool functions, the 13 getters, `hashOpenOrder`, `hashSellOrder`, `version`, the 5 role ids), plus
  OpenZeppelin's role management and `eip712Domain`. `upgradeToAndCall` is only in the implementation's ABI.
- 30 events and 57 errors, OpenZeppelin's included.
- All in `abi/IManicFlashOption.json`.

Storage: the `Layout` of 14 slots in the ERC-7201 namespace `manic.storage.FlashOption`
([docs/storage-layout.md](docs/storage-layout.md)).
