// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionErrors as E} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {RepaySplit, SellSplit, SettleSplit} from "../../src/types/MathTypes.sol";
import {WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {LeverageMathHarness} from "../harnesses/LeverageMathHarness.sol";

/// @title LeverageMathMoney_Fuzz_Test
/// @notice Property tests for LeverageMath part 2: for random inputs, every money split conserves money to the base
///         unit, fees never exceed what they are taken from, and every check accepts or rejects exactly what its
///         definition says. The worked examples are in test/unit/LeverageMathChecks.t.sol and
///         test/unit/LeverageMathSplits.t.sol.
/// @dev The check properties compare the library with the definition written in signed 256-bit arithmetic (where
///      "end - cutoff" may go negative), so they also prove the overflow-free rewrites are equivalent. Inputs are
///      bounded with `bound`, never `vm.assume`. CI runs 10,000 cases per property.
contract LeverageMathMoney_Fuzz_Test is Test {
    LeverageMathHarness internal math;

    function setUp() public {
        math = new LeverageMathHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fees
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A fee is the rounded-down share of the amount, at most 100%, so it can never exceed the amount.
    function testFuzz_AFeeNeverExceedsTheAmount(uint64 amount, uint16 feeBps) public view {
        uint64 charged = math.fee(amount, feeBps);
        uint256 rate = feeBps < 10_000 ? feeBps : 10_000;
        assertEq(charged, (uint256(amount) * rate) / 10_000);
        assertLe(charged, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Money splits
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A settle conserves money for any inputs, not only the unit tests' grid.
    function testFuzz_EverySettleConservesMoney(
        uint64 payoutAmount,
        uint64 stake,
        uint64 freeBefore,
        bool someoneIsOwed,
        uint64 poolFloor
    )
        public
        view
    {
        uint64 totalOwed = someoneIsOwed ? 1 : 0;
        SettleSplit memory s = math.settleSplit(payoutAmount, stake, freeBefore, totalOwed, poolFloor);
        assertEq(uint256(s.own) + s.paid + s.owed, payoutAmount, "own + paid + owed = payout");
        assertEq(uint256(math.toUser(s)) + s.winnerFee + s.loserFee, math.outOfPool(s), "out of pool = paid out");
        assertLe(math.outOfPool(s), uint256(stake) + freeBefore, "never more than stake + free money");
        assertLe(s.paid, freeBefore);
        assertTrue(totalOwed == 0 || s.paid == 0, "nobody jumps the queue");
        assertEq(s.winnerFee, math.fee(s.paid, 200));
        assertEq(s.loserFee, freeBefore >= poolFloor ? math.fee(stake - s.own, 300) : 0);
        assertTrue(s.winnerFee == 0 || s.loserFee == 0, "one fee, never both");
    }

    /// @dev A sale conserves money for any accepted sale (`sellAmount <= valuation`), not only the unit tests' grid.
    function testFuzz_EverySaleConservesMoney(
        uint64 stake,
        uint64 valuation,
        uint64 sellAmount,
        uint64 freeBefore,
        uint64 poolFloor
    )
        public
        view
    {
        sellAmount = uint64(bound(sellAmount, 0, valuation));
        SellSplit memory s = math.sellSplit(stake, valuation, sellAmount, freeBefore, poolFloor);
        assertEq(uint256(math.outOfPool(s)), uint256(valuation) + s.loserFee, "out of pool = valuation + loser fee");
        assertEq(uint256(s.toUser) + s.winnerFee, sellAmount, "user + winner fee = sale amount");
        assertEq(uint256(s.sellFee) + sellAmount, valuation, "sell fee = valuation - sale amount");
        assertTrue(s.winnerFee == 0 || s.loserFee == 0, "one fee, never both");
    }

    /// @dev A repayment conserves money for any IOU and any free money.
    function testFuzz_EveryRepaymentConservesMoney(uint64 owed, uint64 free) public view {
        RepaySplit memory r = math.repaySplit(owed, free);
        assertEq(uint256(r.amount) + r.remaining, owed, "amount + remaining = owed");
        assertEq(uint256(r.toUser) + r.winnerFee, r.amount, "user + fee = amount");
        assertLe(r.amount, free, "never more than free money");
        assertEq(r.amount, owed < free ? owed : free, "as much as free money allows");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Checks, against their definitions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `checkEntryTime` rejects exactly: no time; ahead of the clock by more than the skew; older than the max
    ///      age, in that order.
    function testFuzz_CheckEntryTimeMatchesItsDefinition(
        uint64 currentTime,
        uint64 publishTime,
        uint8 maxAgeSecs,
        uint8 clockSkewSecs
    )
        public
        view
    {
        int256 nowSigned = int256(uint256(currentTime));
        int256 publish = int256(uint256(publishTime));
        bytes4 expected;
        if (publishTime == 0) expected = E.PriceTooOld.selector;
        else if (publish > nowSigned + int256(uint256(clockSkewSecs))) expected = E.PriceFromFuture.selector;
        else if (nowSigned - publish > int256(uint256(maxAgeSecs))) expected = E.PriceTooOld.selector;

        try math.checkEntryTime(currentTime, publishTime, maxAgeSecs, clockSkewSecs) {
            assertEq(expected, bytes4(0), "accepted a tick its definition rejects");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), expected, "rejected for the wrong reason, or rejected a valid tick");
        }
    }

    /// @dev `checkSellWindow` accepts exactly `start + minDelay <= publish < end - cutoff`, computed in signed
    ///      arithmetic where `end - cutoff` may go negative. Equal results prove the overflow-free rewrite is exact.
    function testFuzz_CheckSellWindowMatchesItsDefinition(
        uint64 startTime,
        uint64 endTime,
        uint64 publishTime,
        uint16 minDelaySecs,
        uint16 cutoffSecs
    )
        public
        view
    {
        int256 start = int256(uint256(startTime));
        int256 end = int256(uint256(endTime));
        int256 publish = int256(uint256(publishTime));
        bool open = publish >= start + int256(uint256(minDelaySecs)) && publish < end - int256(uint256(cutoffSecs));

        try math.checkSellWindow(startTime, endTime, publishTime, minDelaySecs, cutoffSecs) {
            assertTrue(open, "accepted a sale outside the window");
        } catch (bytes memory reason) {
            assertFalse(open, "rejected a sale inside the window");
            assertEq(bytes4(reason), E.SellWindowClosed.selector);
        }
    }

    /// @dev A withdrawal that passes always leaves free money of at least the floor plus every open bet's max profit,
    ///      and seed recovery never passes 500 whole tokens. This is the guarantee that withdrawals can't leave open
    ///      bets unpayable.
    function testFuzz_AWithdrawalNeverLeavesOpenBetsUncovered(
        bool isSeed,
        uint64 amount,
        uint64 free,
        uint64 poolFloor,
        uint64 openMaxProfit,
        uint64 seedRecovered
    )
        public
        view
    {
        WithdrawPurpose purpose = isSeed ? WithdrawPurpose.SeedRecovery : WithdrawPurpose.Rewards;
        try math.checkWithdraw(purpose, amount, free, 0, poolFloor, openMaxProfit, seedRecovered, 6) {
            assertGt(amount, 0);
            assertGe(uint256(free) - amount, uint256(poolFloor) + openMaxProfit, "left the open bets uncovered");
            if (isSeed) assertLe(uint256(seedRecovered) + amount, 500 * 1e6, "recovered more than the seed cap");
        } catch {
            // Rejections are covered by the unit tests; this property is about what passes.
        }
    }

    /// @dev `openGate` accepts exactly: total owed within its limit, and, with the exposure limit on, the open max
    ///      profit plus the new bet's at most `free × bps / 10_000` rounded down. In integers that is
    ///      `exposure × 10_000 <= free × bps`, which this compares exactly, so rounding the limit up fails it.
    function testFuzz_TheOpenGateMatchesItsDefinition(
        uint64 totalOwed,
        uint64 maxTotalOwed,
        uint64 openMaxProfit,
        uint64 newMaxProfit,
        uint64 free,
        uint32 maxExposureBps
    )
        public
        view
    {
        uint256 exposure = uint256(openMaxProfit) + newMaxProfit;
        bytes4 expected;
        if (totalOwed > maxTotalOwed) {
            expected = E.OpenBlockedTotalOwed.selector;
        } else if (maxExposureBps > 0 && exposure * 10_000 > uint256(free) * maxExposureBps) {
            expected = E.OpenBlockedExposure.selector;
        }
        try math.openGate(totalOwed, maxTotalOwed, openMaxProfit, newMaxProfit, free, maxExposureBps) {
            assertEq(expected, bytes4(0), "accepted an open its definition rejects");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), expected, "rejected for the wrong reason, or rejected an open that fits");
        }
    }

    /// @dev At the launch setting (100% exposure), an open that passes never commits more max profit than the pool
    ///      has free, so every winner can be paid in full.
    function testFuzz_AtFullExposureAnOpenNeverOverCommits(
        uint64 openMaxProfit,
        uint64 newMaxProfit,
        uint64 free
    )
        public
        view
    {
        try math.openGate(0, type(uint64).max, openMaxProfit, newMaxProfit, free, 10_000) {
            assertLe(uint256(openMaxProfit) + newMaxProfit, free, "committed more than free money");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), E.OpenBlockedExposure.selector);
            assertGt(uint256(openMaxProfit) + newMaxProfit, free, "blocked an open that fits");
        }
    }
}
