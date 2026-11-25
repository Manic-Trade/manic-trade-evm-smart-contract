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
