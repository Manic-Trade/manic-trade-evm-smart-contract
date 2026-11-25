// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {RepaySplit, SellSplit, SettleSplit} from "../../src/types/MathTypes.sol";
import {Side} from "../../src/types/StorageTypes.sol";
import {Examples as V} from "../utils/Examples.sol";
import {LeverageMath_Unit_Shared_Test} from "./LeverageMathShared.sol";

// Unit tests for LeverageMath part 2, the fees and the money splits: worked examples with hand-checkable values (the
// formulas are in docs/MATH.md), loops that check every split conserves money over a grid of inputs, and two worked
// examples end to end. The checks and gates are in LeverageMathChecks.t.sol. Design: docs/ARCHITECTURE.md §9 and §10.

/// @notice Shared assertions that compare a whole split at once, with a message naming each field.
abstract contract LeverageMath_Splits_Shared_Test is LeverageMath_Unit_Shared_Test {
    function _assertSettle(
        SettleSplit memory s,
        uint64 own,
        uint64 paid,
        uint64 owed,
        uint64 winnerFee,
        uint64 loserFee
    )
        internal
        pure
    {
        assertEq(s.own, own, "own");
        assertEq(s.paid, paid, "paid");
        assertEq(s.owed, owed, "owed");
        assertEq(s.winnerFee, winnerFee, "winnerFee");
        assertEq(s.loserFee, loserFee, "loserFee");
    }

    function _assertRepay(
        RepaySplit memory r,
        uint64 amount,
        uint64 winnerFee,
        uint64 toUser,
        uint64 remaining
    )
        internal
        pure
    {
        assertEq(r.amount, amount, "amount");
        assertEq(r.winnerFee, winnerFee, "winnerFee");
        assertEq(r.toUser, toUser, "toUser");
        assertEq(r.remaining, remaining, "remaining");
    }
}

/// @notice `fee`, `winnerFee` and `loserFee`.
contract Fees_LeverageMath_Unit_Test is LeverageMath_Splits_Shared_Test {
    /// @dev The winner fee is 2%, the loser fee 3%, and seed recovery returns at most 500 whole tokens in total.
    function test_TheFeeRatesAndTheSeedRecoveryCap() public view {
        assertEq(math.WINNER_FEE_BPS(), 200, "2% winner fee");
        assertEq(math.LOSER_FEE_BPS(), 300, "3% loser fee");
        assertEq(math.SEED_RECOVERY_CAP_TOKENS(), 500);
    }

    /// @dev 2% of $10.013 is $0.20026. 2% of 49 base units is 0.98, rounded down to 0; of 50, exactly 1.
    function test_FeesRoundDownAndNeverExceedTheAmount() public view {
        assertEq(math.fee(10_013_000, 200), 200_260, "2% of $10.013");
        assertEq(math.fee(49, 200), 0, "0.98 of a base unit rounds down");
        assertEq(math.fee(50, 200), 1);
        assertEq(math.fee(33, 300), 0, "0.99");
        assertEq(math.fee(34, 300), 1, "1.02");
        assertEq(math.fee(0, 300), 0);
        assertEq(math.fee(type(uint64).max, 10_000), type(uint64).max);
        assertEq(math.fee(type(uint64).max, type(uint16).max), type(uint64).max, "the rate is clamped to 100%");
        assertEq(math.winnerFee(V.usdc(30)), 600_000);
        assertEq(math.winnerFee(0), 0);
    }

    /// @dev 3% of a $10 loss is $0.30 while free money is at or above the $500 floor, and nothing one unit below it.
    function test_TheLoserFeeIsTakenOnlyAtOrAboveTheFloor() public view {
        assertEq(math.loserFee(V.STAKE, V.FLOOR, V.FLOOR), 300_000, "exactly at the floor: 3% of $10");
        assertEq(math.loserFee(V.STAKE, V.FLOOR - 1, V.FLOOR), 0, "one unit below: none");
        assertEq(math.loserFee(V.STAKE, 0, V.FLOOR), 0);
        assertEq(math.loserFee(V.STAKE, type(uint64).max, V.FLOOR), 300_000);
        assertEq(math.loserFee(954_000, V.FLOOR, V.FLOOR), 28_620, "the loss on -$8");
        assertEq(math.loserFee(0, V.FLOOR, V.FLOOR), 0);
    }
}

/// @notice `settleSplit`, `toUser` and `outOfPool`: how an expiry payout splits.
contract SettleSplit_LeverageMath_Unit_Test is LeverageMath_Splits_Shared_Test {
    /// @dev A $40 payout on $10 with $30 free: the stake back, the $30 profit paid, and 2% of it ($0.60) as the winner
    ///      fee.
    function test_ThePoolCoversTheProfitInFull() public view {
        SettleSplit memory s = math.settleSplit(V.usdc(40), V.STAKE, V.usdc(30), 0, V.FLOOR);
        _assertSettle(s, V.STAKE, V.usdc(30), 0, 600_000, 0);
    }

    /// @dev The pool is short: the own stake back, what fits now (fee on that part only), the rest owed.
    function test_AShortPoolPaysWhatFitsAndOwesTheRest() public view {
        _assertSettle(math.settleSplit(V.usdc(40), V.STAKE, 0, 0, V.FLOOR), V.STAKE, 0, V.usdc(30), 0, 0);
        _assertSettle(
            math.settleSplit(V.usdc(40), V.STAKE, V.usdc(12), 0, V.FLOOR), V.STAKE, V.usdc(12), V.usdc(18), 240_000, 0
        );
    }

    /// @dev Someone is already queued: the whole profit joins the queue, even with free money. Nobody jumps it.
    function test_NobodyJumpsTheQueue() public view {
        _assertSettle(math.settleSplit(V.usdc(40), V.STAKE, V.usdc(1000), 1, V.FLOOR), V.STAKE, 0, V.usdc(30), 0, 0);
    }

    /// @dev A losing bet: part of the stake back; 3% of the loss only at or above the floor.
    function test_ALosingBetPaysTheLoserFeeOnlyAtOrAboveTheFloor() public view {
        _assertSettle(math.settleSplit(9_046_000, V.STAKE, V.FLOOR, 0, V.FLOOR), 9_046_000, 0, 0, 0, 28_620);
        _assertSettle(math.settleSplit(9_046_000, V.STAKE, V.FLOOR - 1, 0, V.FLOOR), 9_046_000, 0, 0, 0, 0);
        _assertSettle(math.settleSplit(0, V.STAKE, V.FLOOR, 0, V.FLOOR), 0, 0, 0, 0, 300_000);
    }

    /// @dev Flat: the stake back and no fee either way.
    function test_AFlatBetGetsItsStakeBackWithNoFee() public view {
        _assertSettle(math.settleSplit(V.STAKE, V.STAKE, V.FLOOR, 0, V.FLOOR), V.STAKE, 0, 0, 0, 0);
    }

    /// @dev Over a grid of payouts, free money and queue states: the payout splits exactly into own + paid + owed;
    ///      what leaves the pool is exactly what the user and the fee recipient get; it never exceeds the stake plus
    ///      free money; and each fee is at its rate on the right base.
    function test_EverySettleConservesMoney() public view {
        uint64[8] memory payouts = [uint64(0), 1, 9_046_000, V.STAKE - 1, V.STAKE, V.STAKE + 1, 20_013_000, V.usdc(40)];
        uint64[6] memory frees = [uint64(0), 1, V.usdc(12), V.FLOOR - 1, V.FLOOR, V.usdc(10_000)];
        for (uint256 p; p < payouts.length; ++p) {
            for (uint256 f; f < frees.length; ++f) {
                for (uint64 totalOwed; totalOwed <= 1; ++totalOwed) {
                    SettleSplit memory s = math.settleSplit(payouts[p], V.STAKE, frees[f], totalOwed, V.FLOOR);
                    assertEq(s.own + s.paid + s.owed, payouts[p], "own + paid + owed = payout");
                    assertEq(math.toUser(s) + s.winnerFee + s.loserFee, math.outOfPool(s), "out of pool = paid out");
                    assertLe(math.outOfPool(s), V.STAKE + frees[f], "never more than stake + free money");
                    assertLe(s.paid, frees[f]);
                    assertTrue(totalOwed == 0 || s.paid == 0, "nobody jumps the queue");
                    assertEq(s.winnerFee, math.fee(s.paid, 200));
                    uint64 loss = V.STAKE - s.own;
                    assertEq(s.loserFee, frees[f] >= V.FLOOR ? math.fee(loss, 300) : 0);
                    assertTrue(s.winnerFee == 0 || s.loserFee == 0, "a bet pays one fee, never both");
                }
            }
        }
    }
}

/// @notice Two worked examples, end to end.
contract DesignExamples_LeverageMath_Unit_Test is LeverageMath_Splits_Shared_Test {
    /// @dev Example 1: a $10 long at $83,884 with a 1.3x floor and the 4x cap, the pool well funded. +$84 pays $20.013
    ///      less 2% of the $10.013 profit; +$252 pays the $40 cap less 2% of $30; -$8 pays back $9.046, and 3% of the
    ///      $0.954 loss is the loser fee.
    function test_Example1_AWellFundedPoolPaysWinnersMinusTwoPercent() public view {
        SettleSplit memory up84 = _settleAt(V.priceAt(84));
        assertEq(math.toUser(up84), 19_812_740, "$20.013 pays $19.81");
        assertEq(up84.winnerFee, 200_260);

        SettleSplit memory up252 = _settleAt(V.priceAt(252));
        assertEq(math.toUser(up252), 39_400_000, "$40 pays $39.40");
        assertEq(up252.winnerFee, 600_000);

        SettleSplit memory down8 = _settleAt(V.priceAt(-8));
        assertEq(math.toUser(down8), 9_046_000, "$9.046 back");
        assertEq(down8.loserFee, 28_620, "3% of the $0.954 loss");
    }

    /// @dev Example 2: a $20 buffer, below the $500 floor, so no loser fee is taken. Ali, Sara and Ben stake $10 each;
    ///      Sara is liquidated; Ali and Ben each win $40; later Dan's liquidated $10 repays Ben.
    function test_Example2_AnIouIsRepaidFromTheNextLosersMoney() public view {
        (uint64 total, uint64 locked) = (V.usdc(20) + 3 * V.STAKE, 3 * V.STAKE);

        // Sara is liquidated: her stake becomes free money, with no fee below the floor.
        assertEq(math.loserFee(V.STAKE, total - locked, V.FLOOR), 0);
        locked -= V.STAKE;

        SettleSplit memory ali = math.settleSplit(V.usdc(40), V.STAKE, total - locked, 0, V.FLOOR);
        _assertSettle(ali, V.STAKE, V.usdc(30), 0, 600_000, 0);
        assertEq(math.toUser(ali), 39_400_000, "Ali receives $39.40");
        (total, locked) = (total - math.outOfPool(ali), locked - V.STAKE);

        SettleSplit memory ben = math.settleSplit(V.usdc(40), V.STAKE, total - locked, 0, V.FLOOR);
        _assertSettle(ben, V.STAKE, 0, V.usdc(30), 0, 0);
        assertEq(math.toUser(ben), V.STAKE, "Ben gets his stake back now and is owed $30");
        (total, locked) = (total - math.outOfPool(ben), locked - V.STAKE);
        assertEq(total, 0);
        assertEq(locked, 0);

        // Dan's $10 bet is liquidated, still below the floor: no fee, and it all becomes free money.
        (total, locked) = (total + V.STAKE, locked + V.STAKE);
        assertEq(math.loserFee(V.STAKE, total - locked, V.FLOOR), 0);
        locked -= V.STAKE;

        // Repay sends it to Ben minus 2%: Ben receives $9.80 and is still owed $20.
        RepaySplit memory repay = math.repaySplit(ben.owed, total - locked);
        _assertRepay(repay, V.STAKE, 200_000, 9_800_000, V.usdc(20));
    }

    function _settleAt(int64 price) internal view returns (SettleSplit memory) {
        uint16 g = math.gBps(V.P0, price, Side.Call, V.L1000, 13_000, V.CAP_4X);
        return math.settleSplit(math.payout(V.STAKE, g), V.STAKE, V.usdc(10_000), 0, V.FLOOR);
    }
}

/// @notice `sellSplit`, `fees` and `outOfPool`: how an early sale splits.
contract SellSplit_LeverageMath_Unit_Test is LeverageMath_Splits_Shared_Test {
    /// @dev A profitable sale: a $12.50 valuation sold for $12, so the sell fee is $0.50; the winner fee is 2% of the
    ///      $2 profit ($0.04), and the user gets $11.96.
    function test_AProfitableSale() public view {
        SellSplit memory won = math.sellSplit(V.STAKE, 12_500_000, V.usdc(12), V.FLOOR, V.FLOOR);
        assertEq(won.toUser, 11_960_000);
        assertEq(won.sellFee, 500_000);
        assertEq(won.winnerFee, 40_000);
        assertEq(won.loserFee, 0);
    }

    /// @dev A losing sale: $9 valuation sold for $8.60; 3% of the $1 loss at the floor, none below it.
    function test_ALosingSale() public view {
        SellSplit memory lost = math.sellSplit(V.STAKE, V.usdc(9), 8_600_000, V.FLOOR, V.FLOOR);
        assertEq(lost.toUser, 8_600_000);
        assertEq(lost.sellFee, 400_000);
        assertEq(lost.winnerFee, 0);
        assertEq(lost.loserFee, 30_000);
        assertEq(math.sellSplit(V.STAKE, V.usdc(9), 8_600_000, V.FLOOR - 1, V.FLOOR).loserFee, 0);
    }

    /// @dev The capped region: no sell fee; the winner fee on the $30 profit.
    function test_ASaleAtTheCap() public view {
        SellSplit memory capped = math.sellSplit(V.STAKE, V.usdc(40), V.usdc(40), V.FLOOR, V.FLOOR);
        assertEq(capped.toUser, 39_400_000);
        assertEq(math.fees(capped), 600_000);
    }

    /// @dev Sold at the stake: no fee at all. A valuation above the stake with a sale below it pays only the sell fee.
    function test_SalesAroundTheStake() public view {
        assertEq(math.fees(math.sellSplit(V.STAKE, V.STAKE, V.STAKE, V.FLOOR, V.FLOOR)), 0);
        SellSplit memory between = math.sellSplit(V.STAKE, 10_200_000, 9_900_000, V.FLOOR, V.FLOOR);
        assertEq(between.winnerFee, 0);
        assertEq(between.loserFee, 0);
        assertEq(between.sellFee, 300_000);
    }

    /// @dev Over a grid of valuations, sale amounts and free money: everything a sale moves comes out of the valuation
    ///      plus the loser fee, and the user's part plus the winner fee is the sale amount.
    function test_EverySaleConservesMoney() public view {
        uint64[4] memory frees = [uint64(0), V.FLOOR - 1, V.FLOOR, V.usdc(10_000)];
        for (uint64 valuation; valuation <= V.usdc(40); valuation += 1_234_567) {
            uint64[5] memory feeParts = [uint64(0), 1, 99, valuation / 20, valuation];
            for (uint256 p; p < feeParts.length; ++p) {
                uint64 sellAmount = valuation - (feeParts[p] < valuation ? feeParts[p] : valuation);
                for (uint256 f; f < frees.length; ++f) {
                    SellSplit memory s = math.sellSplit(V.STAKE, valuation, sellAmount, frees[f], V.FLOOR);
                    assertEq(math.outOfPool(s), valuation + s.loserFee, "out of pool = valuation + loser fee");
                    assertEq(s.toUser + s.winnerFee, sellAmount, "user + winner fee = sale amount");
                    assertTrue(s.winnerFee == 0 || s.loserFee == 0, "one fee, never both");
                    assertEq(s.winnerFee, math.fee(sellAmount > V.STAKE ? sellAmount - V.STAKE : 0, 200));
                }
            }
        }
    }
}

/// @notice `repaySplit`: repaying an IOU from free money.
contract RepaySplit_LeverageMath_Unit_Test is LeverageMath_Splits_Shared_Test {
    /// @dev A $10 IOU with $40 free: paid in full, $9.80 to the user and 2% ($0.20) as the winner fee.
    function test_PaidInFullWhenFreeMoneyCoversIt() public view {
        _assertRepay(math.repaySplit(V.usdc(10), V.usdc(40)), V.usdc(10), 200_000, 9_800_000, 0);
    }

    /// @dev As in Example 2: Ben is owed $30 and Dan's $10 loss is all the free money.
    function test_PartlyPaidWhenFreeMoneyIsShort() public view {
        _assertRepay(math.repaySplit(V.usdc(30), V.usdc(10)), V.usdc(10), 200_000, 9_800_000, V.usdc(20));
    }

    /// @dev Exactly enough, and nothing at all.
    function test_ExactlyEnoughAndNothingAtAll() public view {
        assertEq(math.repaySplit(V.usdc(3), V.usdc(3)).remaining, 0);
        _assertRepay(math.repaySplit(V.usdc(3), 0), 0, 0, 0, V.usdc(3));
    }

    /// @dev The fee rounds down: 2% of 49 base units is 0, of 50 is 1.
    function test_TheFeeRoundsDown() public view {
        assertEq(math.repaySplit(49, 49).winnerFee, 0);
        assertEq(math.repaySplit(50, type(uint64).max).winnerFee, 1);
    }

    /// @dev Nothing owed: nothing moves, whatever is free.
    function test_NothingOwedMovesNothing() public view {
        _assertRepay(math.repaySplit(0, V.usdc(1)), 0, 0, 0, 0);
    }

    /// @dev Over a grid of IOUs and free money, from 0 to the top of `uint64`.
    function test_EveryRepaymentConservesMoney() public view {
        uint64[7] memory oweds = [uint64(0), 1, 49, 50, V.usdc(3), V.usdc(30), type(uint64).max];
        uint64[7] memory frees = [uint64(0), 1, 50, V.usdc(3), V.usdc(10), V.usdc(1000), type(uint64).max];
        for (uint256 o; o < oweds.length; ++o) {
            for (uint256 f; f < frees.length; ++f) {
                RepaySplit memory r = math.repaySplit(oweds[o], frees[f]);
                assertEq(r.amount + r.remaining, oweds[o], "amount + remaining = owed");
                assertEq(r.toUser + r.winnerFee, r.amount, "user + fee = amount");
                assertLe(r.amount, frees[f], "never more than free money");
                assertEq(r.winnerFee, math.fee(r.amount, 200));
            }
        }
    }
}
