# Gas: what each call costs

**For:** the backend, to size its batches and set its gas limits, and anyone changing the contract.

**Measured** on `MockUSDG`, by the benchmarks in `test/gas/Gas.t.sol`. They write `snapshots/ManicFlashOption.json`, and the tables below are made from it. CI keeps both current (see the end).

## How the numbers are measured

- **One call per benchmark.** Each benchmark sets up the state a call needs, then makes the call and records two numbers:
  - **execution:** the call's own gas (`vm.snapshotGasLastFrame`);
  - **calldata:** what its calldata costs, 16 gas per non-zero byte and 4 per zero byte.
  
  A transaction costs both, plus 21,000. That sum is the **Transaction** column.
- **Cold state, as in a real transaction.** Foundry 1.8.7 starts each call a test makes with every account and slot cold. This was checked: a view called twice in one test costs the same both times, at the cold price. The benchmarks also cool the proxy, the implementation and the token before each call, as a guard.
- **The worst case:**
  - every bet in a batch belongs to its own user, so every payout is a transfer of its own;
  - each user staked their whole balance, so each payout writes an empty token balance, the dearest kind of transfer;
  - the bet is the base bet: a $10 BTC call for a minute at 1000x.
- **Not included:**
  - **the parent chain's data fee.** Robinhood Chain charges none today: ArbGasInfo's price for L1 calldata is 0. If that changes, `eth_estimateGas` includes it;
  - **the real USDG's extra cost** (see the last section).

## The numbers

<!-- gas-tables:begin -->
| Call | Who calls | Execution | Calldata | Transaction |
|---|---|---:|---:|---:|
| `open` | opener | 191,278 | 6,400 | 218,678 |
| `sell` | opener | 155,933 | 3,108 | 180,041 |
| `liquidate`, 1 bet | settler | 96,119 | 1,848 | 118,967 |
| `liquidate`, 10 bets | settler | 243,248 | 6,444 | 270,692 |
| `liquidate`, 50 bets | settler | 909,752 | 26,900 | 957,652 |
| `liquidate`, 100 bets | settler | 1,755,687 | 52,452 | 1,829,139 |
| `settle`, 1 bet | settler | 142,875 | 1,848 | 165,723 |
| `settle`, 10 bets | settler | 607,521 | 6,444 | 634,965 |
| `settle`, 50 bets | settler | 2,676,030 | 26,900 | 2,723,930 |
| `settle`, 100 bets | settler | 5,262,336 | 52,452 | 5,335,788 |
| `settle`, 100 bets at a loss | settler | 5,268,768 | 52,452 | 5,342,220 |
| `repay`, 1 IOU | anyone | 90,703 | 204 | 111,907 |
| `repay`, 50 IOUs | anyone | 1,671,186 | 204 | 1,692,390 |
| `refundExpired`, 1 bet | anyone | 113,786 | 856 | 135,642 |
| `refundExpired`, 50 bets | anyone | 2,140,885 | 25,908 | 2,187,793 |
| `claim` | anyone | 76,502 | 432 | 97,934 |
| `sweepFees` | anyone | 77,290 | 64 | 98,354 |

| Batch call | Transaction, per bet, at each size | Each bet more |
|---|---|---:|
| `liquidate` | 1: 118,967, 10: 27,069, 50: 19,153, 100: 18,291 | 17,274 |
| `settle` | 1: 165,723, 10: 63,496, 50: 54,478, 100: 53,357 | 52,222 |
| `repay` | 1: 111,907, 50: 33,847 | 32,254 |
| `refundExpired` | 1: 135,642, 50: 43,755 | 41,880 |
<!-- gas-tables:end -->

"Each bet more" is what one more bet adds to a batch: the cost difference between the largest and the smallest batch measured, divided by the difference in bets. A settled bet costs more than a liquidated one because it pays out: one token transfer each.

## Robinhood Chain's limits

These were read on 2026-11-19 from the ArbGasInfo precompile (`0x6c`), at block 118,397,220:
- **32,000,000 gas per transaction, and per block** (`getMaxTxGasLimit`, `getMaxBlockGasLimit`). The block header shows 2^50, which is Arbitrum's nominal value, not the real limit.
- **A speed limit of 7,000,000 gas a second** (`getGasAccountingParams`). Above it, the base fee rises.
- **A gas price of 0.02124 gwei:** the 0.02 gwei minimum plus 0.00124 for congestion. At that price, a settle of 100 bets (5,335,788 gas) costs about 0.000113 ETH.

## For the backend

- **Every batch the contract accepts fits.**
  - The contract caps a `liquidate` or `settle` batch at 100 bets, and `repay` at 50 IOUs.
  - The dearest full batch, `settle` of 100 winners, uses 5,335,788 gas: 17% of a transaction's limit.
- **There's no need to wait to fill a batch.**
  - Past about 10 bets, a batch saves little per bet: a settled bet costs 63,496 gas in a batch of 10, and 53,357 in a batch of 100.
  - Send each expiry second's bets as soon as they're due, up to 100 per call.
- **Sustained throughput:** at the 7,000,000-gas-a-second speed limit, about 130 settled bets a second (7,000,000 / 53,357). Bursts above it go through; they just pay a higher base fee for a while.
- **Gas limits:** use `eth_estimateGas` and add a margin, say 20%.
  - `_pay` checks it has 60,000 gas left before each transfer.
  - So a limit that's too tight reverts the whole call with `InsufficientGasForPayout`. It never moves a payout to `claimable` for lack of gas.
- **An `open` is one transaction per bet:** 218,678 gas, about 0.0000046 ETH at the price above.

## The real USDG

The real USDG costs about 7,000 gas more per transfer to a new holder: 46,720 against the mock's 39,731, measured on a fork of mainnet (`test/fork/RealUsdg.t.sol`).
- A call pays that once per transfer.
- So a settle of 100 winners costs about 6,034,688 gas on mainnet (5,335,788 + 100 × 6,989), still under a fifth of the limit.
- Liquidations make no transfer, so they cost the same.

## Keeping the numbers current

- **Locally:**
  - `forge test --match-path "test/gas/*"` rewrites `snapshots/ManicFlashOption.json`. Run the whole folder: Foundry rewrites the file with only the benchmarks that ran;
  - `python3 test/gas/check.py --write-docs` rewrites the tables above;
  - `python3 test/gas/check.py --base dev` shows every change against `dev`.
- **In CI** (`.github/workflows/gas.yml`), the job fails if:
  - the committed snapshots don't match a fresh run;
  - these tables don't match the snapshots;
  - on a pull request, any number is more than 5% above the base branch's, or a benchmark has gone.
- **A deliberate rise:** say why in the pull request and add the label `gas-regression-accepted`.
