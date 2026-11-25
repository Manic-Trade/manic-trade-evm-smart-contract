# `model/`: a reference model of the maths

`flash_option_math.py` is a second implementation of [docs/MATH.md](../docs/MATH.md), in Python, written from the
document. It computes everything `LeverageMath` and `ConfigLib` compute: the lines, the payout multiple, the payout
and the maximum profit, the fees, the settlement, sale and repayment splits, and every check (prices and times, the
open gate, sales, withdrawals, a market's settings and a bet's terms).

- **Exact integers only.** Python's integers never overflow, so each rounding and each narrowing to a Solidity type
  is written out, as docs/MATH.md §11 states it.
- **The same refusals, in the same order.** A refusal raises `Revert` with the contract's error name
  (`"MathOverflow"`, `"InvalidLeverageParams"`, ...), or `"Panic(0x11)"` / `"Panic(0x12)"` for Solidity's built-in
  overflow and division-by-zero panics. The checks run in the contract's order, so the first one that fails names
  the error.
- **Where the document is silent,** the model follows the contract, and the docstring says so: a cap at or below 1x
  counts as no gain (`cap_reachable`), a zero duration marks an unused rule (`validate`), the first enabled rule
  with the duration is the one used (`validate_open`), `floorDiv`'s panics, and a sale amount above the valuation
  (`sell_split`).
- **Standard library only,** Python 3.9 or later. `python3 model/flash_option_math.py` checks the model against every
  worked example of docs/MATH.md §12.

## The vectors

`generate_vectors.py` runs the model on about 20,000 inputs and writes what it gives to
`test/fixtures/model/<function>.json`, one file per function (2.8 MB in all). Each file has:

- `cases`: inputs the function accepts, with the outputs the model gives (a check that passes has none);
- `reverts`: inputs it refuses, with `errorName`.

Every file starts with the edge cases: the bounds, zero, one unit past each limit, the rounding boundaries, every
revert and the worked examples of docs/MATH.md §12, each with a `note`. Seeded random inputs follow, over the whole
input domain, at each leverage tier (1000x, 500x, 100x) and at any leverage. The random numbers come from a fixed
seed, so every run writes the same bytes.

To regenerate, or to check that the files are current (from the repository root):

```bash
python3 model/generate_vectors.py           # write the vectors
python3 model/generate_vectors.py --check   # exit 1 if a file differs from what the model gives now
```

Regenerate after any change to the maths or to docs/MATH.md, and change the model first: a vector that changes is a
rule that changed.

## What the test proves

`test/model/ModelVectors.t.sol` feeds every input to the contract's code, through `test/harnesses/`, and requires the
model's outputs exactly, or the model's error (and its arguments) for every refused input. One test per function,
24 in all, run by `forge test` with the rest of the suite.

The model and the contract are written apart, in two languages, from one specification. They agree on every vector,
so a mistake in the maths would have to be made twice, the same way, to go unnoticed. The vectors are not a proof for
all inputs: the fuzz suite (`test/fuzz/`) checks properties over random inputs on every run.

## The scenarios

`scenarios.py` derives every expected number of the scenario tests (`test/scenarios/`) from the model. Each test has a
function of the same name, in a class named after its test contract. The function replays the test from its inputs
(prices, stakes, settings and the pool's starting books), with the model's functions and a small simulation of the
pool's books (docs/MATH.md §6 to §10). It returns the numbers the test asserts, each with a label, and notes that show
the working.

- **The same refusals.** Each step runs the model's checks in the contract's order. A refusal the test expects must be
  the model's refusal too, with the same error name.
- **Every literal accounted for.** `--check` reads each test's body: its own code, the helpers of its file that it
  calls, and its contract's `setUp`. Every derived number must appear there as an integer literal. Literals are
  compared by value: `_` separators, `e` notation and a minus sign are read, and array subscripts are skipped. Every
  other literal must be listed by its test as an input (a price move, a stake, a setting, a count, a time, a top-up or
  a quote), or as not derived, with the reason.
- **The same inputs.** `--check` also compares its base inputs (the entry price, the base bet, the pool floor and the
  starting free money) with the constants of `test/utils/` and `test/SettlementBase.t.sol`.

```bash
python3 model/scenarios.py            # print every test's derivation
python3 model/scenarios.py NAME       # only the tests whose name contains NAME
python3 model/scenarios.py --check    # exit 1 unless every derived number is a literal of its test
```

**Coverage.** The 62 scenario tests hold 588 integer literals, each counted once per file. 316 are derived from the
model, 270 are inputs, and 2 are not derived: the bounds of two inequalities, which are not amounts. Every computed
amount the tests assert is derived: the lines, g, payouts, fees, the splits, owed amounts, repayments and pool fields.
Matching is by value, so an input equal to a derived amount counts as derived: the small pool's $20 seed equals the $20
its first winner is paid, for example. The check runs in a fraction of a second.
