# Mutation testing: how well the tests catch real bugs

A mutation run puts one realistic bug at a time into `src/` (a *mutant*: a flipped comparison, a constant off by one, a
dropped check, a wrong variable, the wrong rounding or the wrong role) and runs the whole test suite against it. The
mutant is **caught** when at least one test fails, and **survives** when every test still passes. A survivor is either
**equivalent** (no input can tell it from the real code, so no test could catch it) or a **gap** in the tests.

## Result: v1.0.0, 2026-11-26

- **35 of 35 mutants caught.** Every mutant compiled.
- **The first pass caught 33.** Its two survivors were one gap, in two places: `open` and `fund` require the contract's
  balance to rise by *exactly* the amount they pull, but the tests only ever made less arrive. Both trees now have a
  "more" branch, and its test catches each mutant ([below](#the-gap-the-first-pass-found)).
- **No catch depends on random inputs.** The four mutants a fuzz test caught first (LM02, LM04, LM08 and AC02) are each
  caught by a deterministic test as well.

## What was mutated

- 17 on the maths (`LeverageMath`): rounding, floor division, the lines, the payout curve's floor and cap, max profit,
  `touched`, the fees, the settle, sale and repayment splits, the open gate, the price-age and sell-window checks, and
  the withdrawal checks (LM01 to LM17).
- 3 on the settings checks (`ConfigLib`): the open gate's bound, the clock-skew bound and a bet's cap bound (CL01 to
  CL03).
- 3 on the payout circuit breaker (`BreakerLib`): the window, the trip and the reset (BL01 to BL03).
- 4 on trading (`TradingModule`): the order's deadline, a sale's notBefore and expiry checks, and the exact-stake pull
  (TR01 to TR04).
- 4 on settlement (`SettlementModule`): the expiry and skew check, skipping ended bets, the IOU queue's head and the
  refund delay (ST01 to ST04).
- 2 on the pool: `_pay`'s fallback to `claimable`, and `fund`'s exact-amount check (PL01 and PL02).
- 2 on access control: releasing the halt, and the role on `withdraw` (AC01 and AC02).

Each is a single change a developer could plausibly make: comparison flips (`<` and `<=`, `>` and `>=`), dropped checks
and statements, a wrong variable, the wrong rounding, swapped statements and a wrong role.

## How it was run

- On a copy of the repository, never the working tree. Solidity 0.8.38, Foundry 1.8.7, the default profile: 1,000 runs
  per fuzz property, and each invariant campaign 32 runs of 100 calls.
- Before the first mutant and after the last, the unmutated suite (`forge test`): 676 passed, 0 failed, 2 skipped (the
  fork suites, which need an RPC URL).
- For each mutant: the change applied as an exact-once text replacement, then `forge build`, then
  `forge test --fail-fast --no-match-path 'test/fork/*'`, then the file restored and checked byte-identical (SHA-256) to
  the original. Foundry's saved fuzz and invariant failures are cleared first, so no mutant's result depends on
  another's.
- A mutant survives only if its run executed the whole suite, 676 tests, and every one passed.
- `--fail-fast` stops at the first failure, so *caught by* names the first test to fail, not every test that would.
  Where that was a fuzz or invariant test, the mutant was run again with every randomized test left out, and the table
  also names the deterministic test that catches it.

## A trap in `--fail-fast`

Without an RPC URL the two fork suites skip themselves in `setUp`, and Foundry 1.8.7's `--fail-fast` treats that skip
like a failure: every suite still running is cut short, yet the run exits 0. On the unmutated code, with 674 tests
then, two runs of `forge test --fail-fast` executed 499 and then 228 of them, both "passing". So the fork suites are
left out of every mutant's run (`--no-match-path 'test/fork/*'`), and a run that ends early without a failure is never
counted as a survivor. CI doesn't use `--fail-fast`.

## Results

`seconds` is the whole cycle: the build (about 30 seconds, since a change in `src/` recompiles every test) and the test
run, which stops at the first failure. The run took 21 minutes in all.

| id | area | file:line | change | bug it models | caught by | seconds |
|---|---|---|---|---|---|---|
| LM01 | Maths: payout multiple (floor division for negatives) | `src/libraries/LeverageMath.sol:212` | `floorDiv(move × L × 10_000, entry)` → `(move × L × 10_000) / entry` | The payout multiple uses Solidity's truncating signed division, so a losing move rounds toward zero: the loss rounds in the user's favour instead of the pool's. | `Settle_Scenario_Test::test_ALongAndAShortLoser` | 36.1 |
| LM02 | Maths: the lines (rounding direction) | `src/libraries/LeverageMath.sol:146` | liquidation offset `/ 1e7` (down) → `(x + 1e7 − 1) / 1e7` (up) | The liquidation offset rounds up, so the line sits one price unit further from entry than the rule allows: a position survives a tick that should liquidate it. | `LeverageMath_Fuzz_Test::testFuzz_1000xMatchesTheFixedLeverageFormulas`; deterministically also `LeverageMath_ModelVectors_Test::test_LinesMatchTheModel` | 36.4 |
| LM03 | Maths: payout curve floor clamp | `src/libraries/LeverageMath.sol:216` | `r > 0 && g < floor` → `r >= 0 && g < floor` | The floor also applies to a flat price (no move): a bet that neither won nor lost pays the floor (e.g. 1.3x) instead of 1x. | `GBps_LeverageMath_Unit_Test::test_PayoutsAcrossThePriceRange` | 39.7 |
| LM04 | Maths: payout curve cap clamp | `src/libraries/LeverageMath.sol:216` | cap clamp moved before the floor clamp | The cap is applied before the floor, so a floor above the cap is no longer limited by the cap: the payout multiple can exceed the cap. | `LeverageMath_Fuzz_Test::testFuzz_1000xMatchesTheFixedLeverageFormulas`; deterministically also `LeverageMath_ModelVectors_Test::test_GBpsMatchesTheModel` | 36.9 |
| LM05 | Maths: max profit | `src/libraries/LeverageMath.sol:237` | `capBps < 10_000` → `capBps <= 10_000` | The max-profit bound is aligned with the lines' strict bound by mistake: a 1x cap (max profit 0), which the documented rule accepts, is refused. | `MaxProfit_LeverageMath_Unit_Test::test_FollowsTheCap` | 36.3 |
| LM06 | Maths: touched (liquidation trigger) | `src/libraries/LeverageMath.sol:247` | Put: `price >= liqPrice` → `price > liqPrice` | A short whose line is touched exactly (equality) is not liquidated: it is settled or sold instead. | `Touched_LeverageMath_Unit_Test::test_EqualityCountsAndOneUnitAwayDoesNot` | 36.5 |
| LM07 | Maths: fees (loser fee at the floor) | `src/libraries/LeverageMath.sol:369` | `freeBefore >= poolFloor` → `freeBefore > poolFloor` | No loser fee is taken when free money is exactly at the floor, where the rule says the fee applies. | `LeverageMath_ModelVectors_Test::test_LoserFeeMatchesTheModel` | 36.4 |
| LM08 | Maths: settle split (repay queue order) | `src/libraries/LeverageMath.sol:395` | `if (totalOwed == 0) paid = min(profit, free)` → `paid = min(profit, free)` | A new winner is paid from free money while earlier winners are still owed: it jumps the IOU queue. | `LeverageMathMoney_Fuzz_Test::testFuzz_EverySettleConservesMoney`; deterministically also `Leverage_Upgrade_Test::test_RollingBackToV1KeepsEveryValue` | 36.8 |
| LM09 | Maths: sell split (winner fee base) | `src/libraries/LeverageMath.sol:494` | winner fee on `sellAmount − stake` → on `valuation − stake` | The sale's winner fee is charged on the valuation's profit instead of the profit the user actually takes (the sale amount), overcharging every profitable sale that carries an early-sell fee. | `Sell_Concrete_Test::test_GivenTheTokenPays` | 36.5 |
| LM10 | Maths: repay split (winner fee base) | `src/libraries/LeverageMath.sol:521` | winner fee on `amount` (repaid now) → on `owed` (whole IOU) | A partial repayment charges the winner fee on the whole IOU instead of the part repaid now: what is still owed is charged again at every later repayment, and a repayment smaller than 2% of the IOU reverts. | `Getters_Concrete_Test::test_QueueHeadFollowsTheQueue` | 36.8 |
| LM11 | Maths: the open gate | `src/libraries/LeverageMath.sol:337` | `exposure > limit` → `exposure >= limit` | An open that brings the exposure exactly to the limit is refused, though the rule allows it. | `OpenGate_LeverageMath_Unit_Test::test_AtOneHundredPercentExposureNeverExceedsFreeMoney` | 36.5 |
| LM12 | Maths: price-age check (entry time) | `src/libraries/LeverageMath.sol:305` | `age > maxAgeSecs` → `age >= maxAgeSecs` | A tick exactly the maximum age old is refused (PriceTooOld) for opens and sales. | `CheckEntryTime_LeverageMath_Unit_Test::test_AcceptsTicksUpToTheMaxAgeAndTheSkew` | 36.3 |
| LM13 | Maths: the sell window | `src/libraries/LeverageMath.sol:435` | `publishTime >= end − cutoff` → `publishTime > end − cutoff` | A sale priced exactly at the cutoff second is allowed: the window closes one second late. | `CheckSellWindow_LeverageMath_Unit_Test::test_RevertWhen_TheDelayReachesTheCutoff` | 41.6 |
| LM14 | Trading: the user's minAmount | `src/libraries/LeverageMath.sol:468` | `sellAmount < minAmount` → `sellAmount <= minAmount` | A sale paying exactly the user's signed minimum is refused. | `CheckSell_LeverageMath_Unit_Test::test_EveryBoundAtItsEdgePasses` | 38.2 |
| LM15 | Settings: θ × L < 10^7 | `src/libraries/LeverageMath.sol:92` | `θ × L < 1e7` → `θ × L <= 1e7` | A liquidation distance with θ × L = 1 is accepted: the payout at the line is 0, so the whole stake can be lost before liquidation. | `CreateMarket_Concrete_Test::test_RevertWhen_TheSettingsAreInvalid` | 38.8 |
| LM16 | Pool: withdrawal coverage check | `src/libraries/LeverageMath.sol:555` | `OpenExposureNotCovered` check dropped | An admin withdrawal may leave the open bets' max profit uncovered by the money above the floor. | `CheckWithdraw_LeverageMath_Unit_Test::test_AWithdrawalMustLeaveOpenBetsCovered` | 38.0 |
| LM17 | Pool: seed-recovery cap (500 whole tokens) | `src/libraries/LeverageMath.sol:560` | `recovered + amount > cap` → `>= cap` | Seed recovery can never reach the full 500-token cap: recovering exactly the cap is refused. | `CheckWithdraw_LeverageMath_Unit_Test::test_SeedRecoveryIsCappedAtFiveHundredTokensInTotal` | 36.2 |
| CL01 | Settings: open gate bound (1 to 10,000) | `src/libraries/ConfigLib.sol:141` | `maxExposureBps > 0 &&` dropped | The operator can set maxExposureBps to 0, which switches the exposure gate off, so IOUs can form. | `ConfigLib_Unit_Test::test_ValidateNeedsTheOpenGateOnAtMost100Percent` | 37.6 |
| CL02 | Settings: clock skew ≤ 30 s | `src/libraries/ConfigLib.sol:142` | `clockSkewSecs <= 30` → `clockSkewSecs < 30` | The documented widest clock skew, 30 seconds, is refused. | `ConfigLib_Unit_Test::test_ValidateBoundsTheClockSkewAt30Seconds` | 33.8 |
| CL03 | Settings: validateOpen cap bound | `src/libraries/ConfigLib.sol:56` | cap lower bound `max(capMinBps, floorBps)` → `capMinBps` | A bet may carry a cap below its own floor, so a right call can't pay the floor it was offered. | `ConfigLib_Unit_Test::test_ValidateOpenCapBounds` | 33.8 |
| BL01 | Breaker: fixed windows | `src/libraries/BreakerLib.sol:39` | `now >= start + window` → `now > start + window` | A window lasts one second too long: a call at exactly start + window still counts in the old window. | `Breaker_Concrete_Test::test_TheWindowRestartsAtItsEndAndNotASecondBefore` | 36.2 |
| BL02 | Breaker: the trip comparison | `src/libraries/BreakerLib.sol:51` | `profitOut <= lossIn + limit` → `profitOut < lossIn + limit` | The breaker trips when the net profit equals the limit, though only going over it should trip. | `FakePriceLoop_Test::test_TheSettlerAloneIsStoppedAcrossThreeLeveragesSharingOneBreaker` | 33.5 |
| BL03 | Breaker: reset | `src/libraries/BreakerLib.sol:63` | `windowStart = now` dropped from `reset` | A reset clears the counters but keeps the old window start, so the fresh window ends early. | `BreakerLib_Unit_Test::test_TheResetClearsATripZeroesTheCountersAndStartsTheWindow` | 33.3 |
| TR01 | Orders: deadline comparison | `src/modules/TradingModule.sol:255` | open: `now > deadline` → `now >= deadline` | An open order is refused in its deadline second, which the order still covers. | `Open_Concrete_Test::test_RevertWhen_TheOrderHasExpired` | 35.5 |
| TR02 | Orders: notBefore check on a sale | `src/modules/TradingModule.sol:369` | sell: `PriceBeforeOrder` check dropped | A sale can be priced with a tick older than the user's signed notBefore (a price from before the user decided to sell). | `Sell_Concrete_Test::test_RevertWhen_TheTickIsBeforeTheOrder` | 33.6 |
| TR03 | Trading: the exact-stake balance check | `src/modules/TradingModule.sol:236` | `received != stake` → `received < stake` | The pull accepts a balance rise above the stake, so tokens that arrive during the pull from elsewhere are silently absorbed instead of refused. | `Open_Concrete_Test::test_RevertWhen_MoreThanTheStakeArrives` | 37.0 |
| TR04 | Trading: a check dropped in sell | `src/modules/TradingModule.sol:367` | sell: `now >= endTime` check dropped | A sale priced inside the window can land after the bet's expiry, racing a settle of the same bet. | `Sell_Concrete_Test::test_RevertWhen_TheSaleLandsAtOrAfterTheEndOfTheBet` | 35.6 |
| ST01 | Settlement: expiry / clock-skew check | `src/modules/SettlementModule.sol:120` | settle: `tick > now + skew` → `tick >= now + skew` | A settle tick exactly clockSkewSecs ahead of the chain's clock is refused, though the rule allows it (with skew 0, a tick at the current second is refused). | `Settle_Concrete_Test::test_RevertWhen_TheTickIsMoreThanTheClockSkewAhead` | 36.9 |
| ST02 | Settlement: skipping ended bets | `src/modules/SettlementModule.sol:123` | settle: skip `status != Open` → skip `status == Closed` | Settle forgets the Owed status: an IOU sent again in a batch is settled a second time. | `Settle_Scenario_Test::test_TheIouQueue` | 31.5 |
| ST03 | Settlement: IOU queue head advance | `src/modules/SettlementModule.sol:336` | `nextRepaySeq = seq + 1` → `nextRepaySeq = seq` | A fully repaid IOU stays at the head of the queue, so the queue never moves on to the next winner. | `Getters_Concrete_Test::test_GetPositionOfAnIouThenOfItsClosedRecord` | 30.9 |
| ST04 | Settlement: refund delay comparison | `src/modules/SettlementModule.sol:297` | `now < end + delay` → `now <= end + delay` | The safety refund is refused at exactly expiry + delay, one second later than the rule says. | `Gas_Test::test_RefundExpired1` | 31.0 |
| PL01 | Pool: _pay's fallback to claimable | `src/base/FlashOptionBase.sol:187` | `if (trySafeTransfer(..)) return;` → `trySafeTransfer(..); return;` | The transfer's result is ignored: a refused payout is neither paid nor kept in claimable, so the winner's money is lost. | `Gas_Test::test_Claim` | 31.3 |
| PL02 | Pool: fund's exact-amount balance check | `src/modules/PoolModule.sol:35` | fund: `received != amount` → `received < amount` | Funding accepts a balance rise above the amount: tokens that arrive during the pull from elsewhere are silently absorbed instead of refused. | `Fund_Concrete_Test::test_RevertWhen_MoreThanTheAmountArrives` | 31.5 |
| AC01 | Access: releasing the halt | `src/modules/AdminModule.sol:97` | unhalt: operator only → guardian or operator | The guardian, which may only engage brakes, can also release the halt. | `KeyBlastRadius_Test::test_ALeakedGuardianKeyCanOnlyStopThingsAndUsersStillGetTheirMoney` | 30.2 |
| AC02 | Access: wrong role on withdraw | `src/modules/PoolModule.sol:49` | withdraw: `onlyRole(DEFAULT_ADMIN_ROLE)` → `onlyRole(OPERATOR_ROLE)` | Pool withdrawals are gated by the instant operator key instead of the delayed admin. | `AccessMatrix_Test::testFuzz_AnAddressWithoutARoleIsRefusedEverywhere`; deterministically also `Leverage_Upgrade_Test::setUp` | 37.7 |

## The gap the first pass found

**TR03** (`src/modules/TradingModule.sol`, `_pullStake`) and **PL02** (`src/modules/PoolModule.sol`, `fund`) weaken the
same check: `received != amount` → `received < amount`. Each function reads the contract's balance around the token's
pull and must see it rise by exactly the amount (docs/ARCHITECTURE.md §8.2, step 13, and §8.8). With `<`, a rise above
the amount passes, and the surplus sits outside every book.

- **Not equivalent.** A token that lets one more unit reach the contract while the pull runs tells them apart: the
  real code refuses with `TransferAmountMismatch(amount, amount + 1)`; the mutant opens the bet, or funds the pool.
- **Why the first pass missed it.** `open`'s tree branch was "the stake does not arrive in full", tested with the
  token's silent no-op (0 arrives); `fund`'s was "a different amount than asked", tested with a token that keeps a fee
  (99 of 100 arrive). Nothing made more arrive. The invariants can't see a surplus either: the books invariant is
  `balance >= total + feesPending + totalClaimable`, which an extra unit only makes truer.
- **What it would cost.** Nothing with USDG: its pulls move 0 or exactly the amount. What went untested was half of a
  documented check.
- **The fix.** Each tree now says less, more and exactly (`test/concrete/open/open.tree`,
  `test/concrete/fund/fund.tree`). The new "more" tests use `MockReentrantToken`, armed to mint one extra unit to the
  contract from inside the pull: `Open_Concrete_Test::test_RevertWhen_MoreThanTheStakeArrives` and
  `Fund_Concrete_Test::test_RevertWhen_MoreThanTheAmountArrives`. Each is refused, and the same call, disarmed, goes
  through. In this run they catch TR03 and PL02.

## Reproducing

Each row names the file, the line and the exact change. To re-run a mutant: in a copy of the repository, make the
change, then run `forge build` and `forge test --fail-fast --no-match-path 'test/fork/*'`. It is caught if a test fails.
A run that ends early without a failure proves nothing, so check that it ran the whole suite.
