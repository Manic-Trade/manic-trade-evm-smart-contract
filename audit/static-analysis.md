# Static analysis and coverage

**For:** the auditors, and anyone changing the contract.

**Status:** v1.0.0. Every automated finding on `src/` is fixed or accepted here with its reason, and the tests reach every line, function and reachable branch. CI keeps both true (see the end).

## The tools

| Tool | Version | Where it runs | Result |
|---|---|---|---|
| Slither (Trail of Bits) | 0.11.6 | CI's "Static analysis (Slither)" job, with `slither.config.json` | 0 findings: 14 found, 1 fixed, 13 accepted (below) |
| `forge lint` | Foundry 1.8.7 | every build, and CI | clean; 4 lints off for the whole contract, and 11 inline exceptions (below) |
| solhint | 6.2.5 | CI's lint job | 0 warnings, on `src/` and `test/` |
| `forge coverage` | Foundry 1.8.7 | CI's "Coverage" job, with `test/coverage/check.py` | every line and function; every branch but one, which no input can reach (below) |

## Slither: every finding

Slither 0.11.6 ran its 102 detectors on `src/` and found 14 results. The fix comes first, then the findings accepted in the code, then the two detectors excluded for the whole contract.

| # | Detector | Impact / confidence | Where | Verdict | Why it's safe, and what shows it |
|---|---|---|---|---|---|
| 1 | `uninitialized-storage` | High / High | `ConfigLib.enabledRule`'s named storage return | **Fixed** | A false positive: the loop assigned the rule before every return, and the function reverted when none matched. The rule is now a local in the loop, so the pattern is gone. No behaviour change: the ConfigLib unit tests still pass. Cost: 5 bytes, and 10 gas on `open`. |
| 2 | `reentrancy-balance` | High / Medium | `TradingModule._pullStake` | Accepted in the code | Reading the balance around the stake pull is the check itself (TOK-4). Nothing can re-enter, because `open` is `nonReentrant` (`test_RevertWhen_OpenIsEnteredAgainFromItsStakePull`). Any other change to the balance during the call makes `received` differ from the stake, which reverts `TransferAmountMismatch` (`test/concrete/open/`; on the real USDG, `test/fork/RealUsdg.t.sol`). |
| 3 | `uninitialized-local` | Medium / Medium | `SettlementModule._settleOne`'s `Settled memory e` | Accepted in the code | A memory struct starts zeroed, and every field is written before it is used. The settle tests check every field of every `PositionSettled`. |
| 4 | `unused-return` | Medium / Medium | `FlashOptionBase._checkSignature`, the third value of `ECDSA.tryRecoverCalldata` | Accepted in the code | The third value only details why recovery failed (the bad length, or the bad `s`), and every failure ends in `InvalidSignature`. `test/fuzz/SignatureFuzz.t.sol` checks that every malformed signature is refused. |
| 5–8 | `timestamp` | Low / Medium | `_checkOrder` (the deadline), `_refundOne` (the refund delay), `settle` (`NotExpired`), `_checkSale` (the deadline and the sale's cutoff) | Excluded for the whole contract | Every time rule compares a time with `block.timestamp`, by design (ARCHITECTURE §2). On Robinhood Chain, the sequencer sets the timestamp. The clock skew, at most 30 seconds (ADR 0009), bounds how far ahead a price's time may be. `forge lint`'s `block-timestamp` lint is off for the same reason. The boundaries are tested at the edge and one second past it (security checklist ORA-2). |
| 9 | `assembly` | Informational / High | `FlashOptionStorage._getFlashOptionStorage` | Accepted in the code | The ERC-7201 accessor: the assembly only sets a storage pointer's slot, the same idiom as OpenZeppelin 5. `test/unit/FlashOptionStorage.t.sol` proves the slot map. |
| 10–14 | `naming-convention` | Informational / High | the five role-id getters in `IManicFlashOptionRoles` (`OPENER_ROLE()` …) | Excluded for the whole contract | The role ids are `UPPER_CASE` constants, as OpenZeppelin's `DEFAULT_ADMIN_ROLE` is. solhint enforces the naming rules. |

**How an accepted finding is marked:**
- **In the code:** a `// slither-disable-next-line <detector>` comment, with its reason on the comment line just above. Keep each line to 120 characters, or `forge fmt` folds the reason into the directive and breaks it.
- **Where another tool's directive must sit directly above the code:** a `slither-disable-start <detector>` / `slither-disable-end <detector>` pair around it instead. The accessor's assembly uses this, because solhint's `solhint-disable-next-line` has to be the line just above.
- **In `slither.config.json`:** the two detectors excluded for the whole contract. The same file keeps the findings to `src/`, and fails on any finding (`fail_on: pedantic`).

Run it with:

```
pip install "slither-analyzer==0.11.6"   # needs Python 3.10 or newer
slither .
```

## `forge lint` and solhint

- **Four lints are off for the whole contract,** each with its reason in `foundry.toml`:
  - `block-timestamp`: as Slither's `timestamp`, above;
  - `internal-function-used-once`: `LeverageMath` keeps one named function per rule of [`docs/MATH.md`](../docs/MATH.md), so each rule can be read and audited on its own;
  - `reentrancy-events`: it counts the ERC-7201 accessor's assembly as an external call. Slither's reentrancy detectors still run;
  - `require-revert-in-loop`: the batches choose, check by check, whether to skip a position or revert with its id (ARCHITECTURE §8.4, §8.5).
- **11 inline exceptions** sit where they apply, each with its reason in the code:
  - 8 `unsafe-typecast`, each a narrowing cast right after its range check;
  - 1 `mixed-case-function` block, over the role ids;
  - 1 `inline-assembly`, the accessor;
  - 1 `require-revert-in-loop`, in `validate`, where a bad rule anywhere refuses the whole config.
- **solhint** has two exceptions in `src/`: the same assembly line, and the role ids' function names.

## Coverage

`forge coverage` of `src/`, with the whole suite:

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `ManicFlashOption.sol` | 36/36 | 55/55 | 7/7 | 6/6 |
| `base/FlashOptionBase.sol` | 74/74 | 93/93 | 13/13 | 16/16 |
| `base/FlashOptionStorage.sol` | 2/2 | 1/1 | — | 1/1 |
| `libraries/BreakerLib.sol` | 28/28 | 35/35 | 5/5 | 3/3 |
| `libraries/ConfigLib.sol` | 40/40 | 85/85 | 17/17 | 5/5 |
| `libraries/LeverageMath.sol` | 132/132 | 216/217 | 61/62 | 31/31 |
| `libraries/OrderLib.sol` | 4/4 | 4/4 | — | 2/2 |
| `modules/AdminModule.sol` | 72/72 | 79/79 | 13/13 | 13/13 |
| `modules/PoolModule.sol` | 40/40 | 48/48 | 6/6 | 4/4 |
| `modules/SettlementModule.sol` | 155/155 | 183/183 | 23/23 | 14/14 |
| `modules/TradingModule.sol` | 122/122 | 140/140 | 22/22 | 11/11 |
| `modules/ViewsModule.sol` | 44/44 | 41/41 | 3/3 | 15/15 |
| **Total** | **749/749** | **980/981** | **170/171** | **121/121** |

**The one branch no test takes is unreachable by design:** `LeverageMath.toUint16`'s overflow guard. `gBps` clamps the payout multiple to `[0, capBps]` before the cast, so the guard can't trip. The fuzz property `testFuzz_GBpsStaysBetweenZeroAndTheCap` shows the clamp holds. The guard stays, to keep the cast honest. The statement it would run is the one statement not covered.

**How it is measured:**
- The coverage build skips the optimizer, for exact line mapping, so it differs from the deployed build in two ways:
  - the contract is bigger than the 98,304-byte limit, so `--code-size-limit` is lifted. The build job checks the real size;
  - it costs more gas, so the gas limits are lifted.
- Fuzz and invariant runs are fewer (100 and 8), since coverage counts what the tests reach, not how often.
- The gas benchmarks run, but don't write their snapshots (`FORGE_SNAPSHOT_EMIT=false`): unoptimized, their numbers would be wrong.
- `test/coverage/check.py` then reads the lcov report. It requires every line, function and branch of `src/` to be covered, apart from the branches it lists as unreachable, each with its reason.
  - A listed branch is matched by its source text, so it survives edits elsewhere in the file.
  - If a listed branch is ever taken, or can't be found, the check fails, so the list can't go stale.

Run it with:

```
forge build   # two tests read the compiled ABI from out/, which forge coverage doesn't write
FORGE_SNAPSHOT_EMIT=false FOUNDRY_FUZZ_RUNS=100 FOUNDRY_INVARIANT_RUNS=8 FOUNDRY_GAS_LIMIT=9223372036854775807 \
  forge coverage --code-size-limit 1000000 --disable-block-gas-limit --no-match-coverage "(test|script|lib)/" \
  --report summary --report lcov --report-file lcov.info
python3 test/coverage/check.py lcov.info
```

## What CI checks

- **"Static analysis (Slither)":** fails on any finding that isn't accepted in the code or in `slither.config.json`.
- **"Coverage":** fails if any line, function or reachable branch of `src/` goes uncovered, or if the unreachable list goes stale.
- **The lint job and every build:** solhint and `forge lint`.

Both gates were tested with deliberate breakage, each change in a fresh worktree:

| Gate | The change | Result |
|---|---|---|
| Slither | none | passes: 0 results |
| Slither | the `reentrancy-balance` directive removed | fails: that one finding returns |
| Slither | the `unused-return` directive removed | fails: that one finding returns |
| Coverage | none | passes |
| Coverage | a new branch no test takes, in `setRefundDelay` | fails, naming the line |
| Coverage | the unreachable line reshaped over three lines | fails: the branch shows as untaken, and the list's entry is not found |
