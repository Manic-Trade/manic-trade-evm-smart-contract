// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as E} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {Side, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {Examples as V} from "../utils/Examples.sol";
import {LeverageMath_Unit_Shared_Test} from "./LeverageMathShared.sol";

// Unit tests for LeverageMath part 2, the checks and gates: worked examples with hand-checkable values (the rules are
// in docs/MATH.md), each bound at its edge and one unit past it, and the order in which the checks run. The money
// splits are in LeverageMathSplits.t.sol. Design: docs/ARCHITECTURE.md §8 and §10.

/// @notice `checkEntryTime`: the price tick of an open or a sale must be recent and not from the future.
contract CheckEntryTime_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev The clock: 2026-10-27 00:00:00 UTC.
    uint256 internal constant NOW = 1_793_059_200;

    /// @dev With a 5 s maximum age and a 5 s clock skew, a tick from 5 s ago to 5 s ahead passes.
    function test_AcceptsTicksUpToTheMaxAgeAndTheSkew() public view {
        math.checkEntryTime(NOW, NOW, 5, 5);
        math.checkEntryTime(NOW, NOW - 5, 5, 5); // exactly the max age
        math.checkEntryTime(NOW, NOW + 5, 5, 5); // exactly the clock skew ahead
    }

    function test_RevertWhen_TheTickIsOneSecondTooOld() public {
        vm.expectRevert(E.PriceTooOld.selector);
        math.checkEntryTime(NOW, NOW - 6, 5, 5);
    }

    function test_RevertWhen_TheTickIsOneSecondTooFarAhead() public {
        vm.expectRevert(E.PriceFromFuture.selector);
        math.checkEntryTime(NOW, NOW + 6, 5, 5);
    }

    /// @dev A tick with no time (0) counts as too old.
    function test_RevertWhen_TheTickHasNoTime() public {
        vm.expectRevert(E.PriceTooOld.selector);
        math.checkEntryTime(NOW, 0, 5, 5);
    }

    /// @dev The largest time. The check compares without adding, so even this time can't overflow it.
    function test_RevertWhen_TheTickIsAtTheEndOfTime() public {
        vm.expectRevert(E.PriceFromFuture.selector);
        math.checkEntryTime(NOW, type(uint256).max, 5, 5);
    }

    /// @dev A zero max age and skew accept only the current second.
    function test_AZeroAgeAndSkewAcceptOnlyTheCurrentSecond() public {
        math.checkEntryTime(NOW, NOW, 0, 0);
        vm.expectRevert(E.PriceTooOld.selector);
        math.checkEntryTime(NOW, NOW - 1, 0, 0);
        vm.expectRevert(E.PriceFromFuture.selector);
        math.checkEntryTime(NOW, NOW + 1, 0, 0);
    }
}

/// @notice `checkLiquidation`: a tick liquidates a position only inside its life and only at or past its line.
contract CheckLiquidation_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    // A one-minute position (1000 to 1060), checked at 2000, long after it ended, with a 5 s skew.
    uint256 internal constant START = 1000;
    uint256 internal constant END = 1060;
    uint256 internal constant NOW = 2000;
    bytes32 internal constant ID = keccak256("position-1");

    int64 internal longLiq;
    int64 internal shortLiq;

    function setUp() public override {
        super.setUp();
        (longLiq,) = math.lines(V.P0, Side.Call, V.L1000, 3000, V.CAP_4X);
        (shortLiq,) = math.lines(V.P0, Side.Put, V.L1000, 3000, V.CAP_4X);
    }

    function test_ALongIsLiquidatedAtOrPastItsLineInsideItsLife() public view {
        _long(longLiq, START); // at the line, at the start of the window
        _long(longLiq, END); // at the end of the window
        _long(longLiq - 1, 1030); // beyond the line
    }

    function test_RevertWhen_ThePriceIsOneUnitInsideTheLine() public {
        vm.expectRevert(abi.encodeWithSelector(E.LiquidationPriceNotReached.selector, ID));
        _long(longLiq + 1, 1030);
    }

    function test_RevertWhen_TheTickIsBeforeThePositionOpened() public {
        vm.expectRevert(abi.encodeWithSelector(E.InvalidLiquidationWindow.selector, ID));
        _long(longLiq, START - 1);
    }

    function test_RevertWhen_TheTickIsAfterThePositionEnded() public {
        vm.expectRevert(abi.encodeWithSelector(E.InvalidLiquidationWindow.selector, ID));
        _long(longLiq, END + 1);
    }

    function test_RevertWhen_ThePriceIsNotPositive() public {
        vm.expectRevert(E.InvalidPrice.selector);
        _long(0, 1030);
    }

    /// @dev A tick inside the window may not be ahead of the clock by more than the skew.
    function test_RevertWhen_TheTickIsAheadOfTheClockByMoreThanTheSkew() public {
        math.checkLiquidation(ID, START, END, longLiq, Side.Call, longLiq, 1015, 1010, 5);
        vm.expectRevert(E.PriceFromFuture.selector);
        math.checkLiquidation(ID, START, END, longLiq, Side.Call, longLiq, 1016, 1010, 5);
    }

    /// @dev A short is liquidated at or above its line.
    function test_AShortIsLiquidatedAtOrAboveItsLine() public {
        _short(shortLiq);
        _short(shortLiq + 1);
        vm.expectRevert(abi.encodeWithSelector(E.LiquidationPriceNotReached.selector, ID));
        _short(shortLiq - 1);
    }

    /// @dev The two errors that depend on the position name it, so a reverted batch says which bet broke it. A
    ///      different id gives a different error.
    function test_TheErrorsNameTheFailingPosition() public {
        bytes32 other = keccak256("position-2");
        vm.expectRevert(abi.encodeWithSelector(E.LiquidationPriceNotReached.selector, other));
        math.checkLiquidation(other, START, END, longLiq, Side.Call, longLiq + 1, 1030, NOW, 5);
    }

    function _long(int64 price, uint256 publishTime) internal view {
        math.checkLiquidation(ID, START, END, longLiq, Side.Call, price, publishTime, NOW, 5);
    }

    function _short(int64 price) internal view {
        math.checkLiquidation(ID, START, END, shortLiq, Side.Put, price, 1030, NOW, 5);
    }
}

/// @notice `checkSellWindow`: a sale is allowed from `start + minDelay` until more than `cutoff` before the end.
contract CheckSellWindow_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    // A one-minute position, from 1000 to 1060.
    uint256 internal constant START = 1000;
    uint256 internal constant END = 1060;

    /// @dev The launch values: no minimum delay, closed in the last 2 seconds.
    function test_TheLaunchWindowOpensAtTheStartAndClosesTwoSecondsBeforeTheEnd() public {
        math.checkSellWindow(START, END, START, 0, 2); // the first second
        math.checkSellWindow(START, END, END - 3, 0, 2); // the last second: 3 s left, more than 2
        _expectClosed(START - 1, 0, 2); // before the position started
        _expectClosed(END - 2, 0, 2); // exactly 2 s left
        _expectClosed(END, 0, 2);
    }

    function test_AMinimumDelayHoldsTheWindowShut() public {
        _expectClosed(START + 9, 10, 2);
        math.checkSellWindow(START, END, START + 10, 10, 2);
    }

    /// @dev A window that can't open: the delay reaches the cutoff.
    function test_RevertWhen_TheDelayReachesTheCutoff() public {
        _expectClosed(START + 58, 58, 2);
    }

    /// @dev A cutoff longer than the whole timeline closes the window instead of underflowing `end - cutoff`.
    function test_RevertWhen_TheCutoffIsLongerThanTheTimeline() public {
        vm.expectRevert(E.SellWindowClosed.selector);
        math.checkSellWindow(0, 10, 5, 0, 20);
    }

    function _expectClosed(uint256 publishTime, uint16 minDelay, uint16 cutoff) internal {
        vm.expectRevert(E.SellWindowClosed.selector);
        math.checkSellWindow(START, END, publishTime, minDelay, cutoff);
    }
}

/// @notice `openGate`: the total-owed limit and the exposure limit.
contract OpenGate_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev With no owed limit and the exposure limit off (0), anything passes.
    function test_WithBothLimitsOffAnythingPasses() public view {
        uint64 max = type(uint64).max;
        math.openGate(max, max, max, max, 0, 0);
    }

    /// @dev Total owed at the limit passes; above it is blocked. A limit of 0 blocks only while anyone is owed.
    function test_TheTotalOwedLimitIsInclusive() public {
        math.openGate(100, 100, 0, 0, 0, 0);
        math.openGate(0, 0, 0, 0, 0, 0);
        vm.expectRevert(E.OpenBlockedTotalOwed.selector);
        math.openGate(101, 100, 0, 0, 0, 0);
        vm.expectRevert(E.OpenBlockedTotalOwed.selector);
        math.openGate(1, 0, 0, 0, 0, 0);
    }

    /// @dev Exposure: open max profit + this bet's <= free × bps / 10_000. With $510 free at 3x, $1,530 fits.
    function test_TheExposureLimitIsInclusive() public {
        uint64 free = V.usdc(510);
        math.openGate(0, type(uint64).max, V.usdc(1000), V.usdc(530), free, 30_000);
        vm.expectRevert(E.OpenBlockedExposure.selector);
        math.openGate(0, type(uint64).max, V.usdc(1000), V.usdc(530) + 1, free, 30_000);
    }

    /// @dev No free money means no exposure at all once the gate is on.
    function test_NoFreeMoneyAllowsNoExposure() public {
        math.openGate(0, type(uint64).max, 0, 0, 0, 1);
        vm.expectRevert(E.OpenBlockedExposure.selector);
        math.openGate(0, type(uint64).max, 0, 1, 0, 1);
    }

    /// @dev The limit rounds down, in the pool's favour: 1 base unit free at 1.5x allows 1.5 units of exposure, which
    ///      rounds down to 1, so 2 is blocked. Rounding up would allow 2.
    function test_TheExposureLimitRoundsDownInThePoolsFavour() public {
        math.openGate(0, type(uint64).max, 0, 1, 1, 15_000);
        vm.expectRevert(E.OpenBlockedExposure.selector);
        math.openGate(0, type(uint64).max, 0, 2, 1, 15_000);
    }

    /// @dev The launch setting, 100%: the open max profit can never exceed free money, so every winner is paid.
    function test_AtOneHundredPercentExposureNeverExceedsFreeMoney() public {
        uint64 free = V.usdc(1000);
        math.openGate(0, type(uint64).max, V.usdc(970), V.usdc(30), free, 10_000);
        vm.expectRevert(E.OpenBlockedExposure.selector);
        math.openGate(0, type(uint64).max, V.usdc(970), V.usdc(30) + 1, free, 10_000);
    }
}

/// @notice `checkSell`: an early sale's amounts, checked in order.
contract CheckSell_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    uint64 internal constant FREE = 1_000_000_000; // $1,000

    /// @dev $10 at g = 1.3x can be valued up to $13; the fee cap is 6%.
    function test_EveryBoundAtItsEdgePasses() public view {
        _sell(V.usdc(13), V.usdc(13), V.usdc(13), 0, FREE);
    }

    function test_RevertWhen_TheValuationIsAboveThePayoutAtThisPrice() public {
        vm.expectRevert(E.ValuationAboveCurrentPayout.selector);
        _sell(V.usdc(13) + 1, V.usdc(13), 0, 0, FREE);
    }

    function test_RevertWhen_TheSaleAmountIsAboveTheValuation() public {
        vm.expectRevert(E.SellAmountExceedsValuation.selector);
        _sell(V.usdc(12), V.usdc(12) + 1, 0, 0, FREE);
    }

    /// @dev The fee cap: 6% of $12.50 is $0.75, so a sale for $11.75 passes and one base unit less doesn't.
    function test_TheSellFeeCapIsInclusive() public {
        _sell(12_500_000, 11_750_000, 0, 0, FREE);
        vm.expectRevert(E.SellFeeTooHigh.selector);
        _sell(12_500_000, 11_750_000 - 1, 0, 0, FREE);
    }

    function test_RevertWhen_TheSaleAmountIsBelowTheUsersMinimum() public {
        vm.expectRevert(E.SellAmountBelowMin.selector);
        _sell(V.usdc(12), V.usdc(12), V.usdc(12) + 1, 0, FREE);
    }

    /// @dev Payable only while nobody is owed.
    function test_RevertWhen_AnyoneIsOwed() public {
        vm.expectRevert(E.QueueNotEmpty.selector);
        _sell(V.usdc(12), V.usdc(12), 0, 1, FREE);
    }

    /// @dev Payable only within free money plus the position's own stake: $12 fits $2 free + $10 stake.
    function test_ThePoolMustPayTheSaleInFull() public {
        _sell(V.usdc(12), V.usdc(12), 0, 0, V.usdc(2));
        vm.expectRevert(E.SellNotPayable.selector);
        _sell(V.usdc(12), V.usdc(12), 0, 0, V.usdc(2) - 1);
    }

    /// @dev The order: the valuation bound comes before payability.
    function test_TheValuationIsCheckedBeforePayability() public {
        vm.expectRevert(E.ValuationAboveCurrentPayout.selector);
        _sell(V.usdc(13) + 1, V.usdc(13), 0, 1, 0);
    }

    /// @dev A zero fee cap allows only sales at the full valuation.
    function test_AZeroFeeCapAllowsOnlyTheFullValuation() public {
        math.checkSell(V.STAKE, 13_000, V.usdc(12), V.usdc(12), 0, 0, 0, FREE);
        vm.expectRevert(E.SellFeeTooHigh.selector);
        math.checkSell(V.STAKE, 13_000, V.usdc(12), V.usdc(12) - 1, 0, 0, 0, FREE);
    }

    function _sell(uint64 valuation, uint64 sellAmount, uint64 minAmount, uint64 totalOwed, uint64 free) internal view {
        math.checkSell(V.STAKE, 13_000, valuation, sellAmount, minAmount, 600, totalOwed, free);
    }
}

/// @notice `checkWithdraw`: an admin withdrawal, checked in order, including the open-exposure check.
contract CheckWithdraw_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    WithdrawPurpose internal constant REWARDS = WithdrawPurpose.Rewards;
    WithdrawPurpose internal constant SEED = WithdrawPurpose.SeedRecovery;

    // $1,500 free over the $500 floor, a 6-decimal token: $1,000 can go, and the seed at most $500. Unless a test says
    // otherwise, no bets are open (openMaxProfit = 0), so the open-exposure check can't fail.

    /// @dev Rewards: down to the floor exactly, not one unit past it, and no cap of their own.
    function test_RewardsCanGoDownToTheFloorExactly() public {
        _withdraw(REWARDS, V.usdc(1000), 0, 0);
        _withdraw(REWARDS, V.usdc(1000), 0, V.usdc(500)); // the seed cap is not theirs
        vm.expectRevert(E.BelowPoolFloor.selector);
        _withdraw(REWARDS, V.usdc(1000) + 1, 0, 0);
        vm.expectRevert(E.BelowPoolFloor.selector);
        _withdraw(REWARDS, V.usdc(1500) + 1, 0, 0); // more than free
        vm.expectRevert(E.BelowPoolFloor.selector);
        _withdraw(REWARDS, type(uint64).max, 0, 0);
    }

    /// @dev Seed recovery: $500 in total, in one go or in parts, never one unit more.
    function test_SeedRecoveryIsCappedAtFiveHundredTokensInTotal() public {
        _withdraw(SEED, V.usdc(500), 0, 0);
        _withdraw(SEED, V.usdc(200), 0, V.usdc(300));
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        _withdraw(SEED, V.usdc(500) + 1, 0, 0);
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        _withdraw(SEED, V.usdc(200) + 1, 0, V.usdc(300));
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        _withdraw(SEED, 1, 0, V.usdc(500));
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        _withdraw(SEED, 1, 0, type(uint64).max); // no overflow
    }

    /// @dev ...and the floor binds seed recovery too: $900 free leaves $400 to recover.
    function test_TheFloorAlsoBindsSeedRecovery() public {
        math.checkWithdraw(SEED, V.usdc(400), V.usdc(900), 0, V.FLOOR, 0, 0, 6);
        vm.expectRevert(E.BelowPoolFloor.selector);
        math.checkWithdraw(SEED, V.usdc(400) + 1, V.usdc(900), 0, V.FLOOR, 0, 0, 6);
    }

    /// @dev The order: the amount, then the queue, then the floor, then the seed cap.
    function test_ChecksRunInOrder() public {
        WithdrawPurpose[2] memory purposes = [SEED, REWARDS];
        for (uint256 i; i < purposes.length; ++i) {
            vm.expectRevert(E.InvalidAmount.selector);
            _withdraw(purposes[i], 0, 1, 0);
            vm.expectRevert(E.OwedOutstanding.selector);
            _withdraw(purposes[i], type(uint64).max, 1, type(uint64).max);
            _withdraw(purposes[i], V.usdc(100), 0, 0);
            vm.expectRevert(E.OwedOutstanding.selector);
            _withdraw(purposes[i], V.usdc(100), 1, 0);
        }
        vm.expectRevert(E.BelowPoolFloor.selector);
        _withdraw(SEED, V.usdc(1000) + 1, 0, V.usdc(500));
    }

    /// @dev The seed cap follows the token's decimals. 500 × 10^17 doesn't fit `uint64`, so 17 decimals overflow (a
    ///      pool can't be created with such a token anyway).
    function test_TheSeedCapFollowsTheDecimals() public {
        uint64 max = type(uint64).max;
        math.checkWithdraw(SEED, 500, max, 0, 0, 0, 0, 0);
        math.checkWithdraw(SEED, 500_000_000_000, max, 0, 0, 0, 0, 9);
        math.checkWithdraw(REWARDS, 1, max, 0, 0, 0, 0, 17); // rewards don't compute the cap
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        math.checkWithdraw(SEED, 501, max, 0, 0, 0, 0, 0);
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        math.checkWithdraw(SEED, 500_000_000_001, max, 0, 0, 0, 0, 9);
        vm.expectRevert(E.MathOverflow.selector);
        math.checkWithdraw(SEED, 1, max, 0, 0, 0, 0, 17);
        vm.expectRevert(E.MathOverflow.selector);
        math.checkWithdraw(SEED, 1, max, 0, 0, 0, 0, 255); // no 256-bit overflow either
    }

    /// @dev What stays above the floor must still cover every open bet's max profit. With $1,500 free, a $500 floor and
    ///      $300 of open max profit, $700 can go and one base unit more can't.
    function test_AWithdrawalMustLeaveOpenBetsCovered() public {
        uint64 openMaxProfit = V.usdc(300);
        math.checkWithdraw(REWARDS, V.usdc(700), V.usdc(1500), 0, V.FLOOR, openMaxProfit, 0, 6);
        vm.expectRevert(E.OpenExposureNotCovered.selector);
        math.checkWithdraw(REWARDS, V.usdc(700) + 1, V.usdc(1500), 0, V.FLOOR, openMaxProfit, 0, 6);
    }

    /// @dev The open-exposure check's place in the order: after the floor check, before the seed cap.
    function test_TheExposureCheckRunsAfterTheFloorAndBeforeTheSeedCap() public {
        // Past the floor: the floor error wins, whatever the exposure.
        vm.expectRevert(E.BelowPoolFloor.selector);
        math.checkWithdraw(SEED, V.usdc(1000) + 1, V.usdc(1500), 0, V.FLOOR, type(uint64).max, 0, 6);
        // Within the floor but over the exposure and over the seed cap: the exposure error wins.
        vm.expectRevert(E.OpenExposureNotCovered.selector);
        math.checkWithdraw(SEED, V.usdc(600), V.usdc(1500), 0, V.FLOOR, V.usdc(500), 0, 6);
        // Within the exposure, over the seed cap: the seed error.
        vm.expectRevert(E.SeedRecoveryExceeded.selector);
        math.checkWithdraw(SEED, V.usdc(600), V.usdc(1500), 0, V.FLOOR, V.usdc(400), 0, 6);
    }

    function _withdraw(WithdrawPurpose purpose, uint64 amount, uint64 totalOwed, uint64 seedRecovered) internal view {
        math.checkWithdraw(purpose, amount, V.usdc(1500), totalOwed, V.FLOOR, 0, seedRecovered, 6);
    }
}
