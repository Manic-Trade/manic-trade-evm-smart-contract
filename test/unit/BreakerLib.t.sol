// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {Breaker} from "../../src/types/StorageTypes.sol";
import {BreakerLibHarness} from "../harnesses/BreakerLibHarness.sol";

/// @title BreakerLib_Unit_Test
/// @notice `BreakerLib` without a proxy (docs/ARCHITECTURE.md §8.11): a count of nothing, the fixed window's end, the
///         trip at one unit over the limit and only once, the limit at 0, the largest limit, a counter's overflow,
///         and the reset. A fuzz property checks `count` against the rule, for any breaker, amounts and time.
/// @dev Each test starts from a window opened at second 1,000, with a $10 limit per hour, $5 out and $2 in so far.
contract BreakerLib_Unit_Test is Test {
    uint48 internal constant START = 1000;
    uint32 internal constant WINDOW = 1 hours;

    BreakerLibHarness internal lib;

    function setUp() public {
        lib = new BreakerLibHarness();
        lib.set(_breaker(5e6, 2e6, 10e6));
    }

    function test_ACountOfNothingChangesNothing() external {
        // Not even a window long past its end restarts.
        Breaker memory before = lib.get();
        assertFalse(lib.count(0, 0, START + 10 * WINDOW), "nothing tripped");
        assertEq(abi.encode(lib.get()), abi.encode(before), "nothing changed");
    }

    function test_TheWindowRestartsAtItsEndAndNotASecondBefore() external {
        assertFalse(lib.count(1e6, 0, START + WINDOW - 1), "a second before the end");
        _assertState(6e6, 2e6, START, false); // added to the same window
        assertFalse(lib.count(1e6, 3e6, START + WINDOW), "at the end");
        _assertState(1e6, 3e6, START + WINDOW, false); // a new window, from this second, holding this count only
    }

    function test_ItTripsOneUnitOverTheLimitAndNotAtIt() external {
        // $5 out and $2 in with a $10 limit: $7 more out is $12, exactly $2 + $10.
        assertFalse(lib.count(7e6, 0, START + 1), "at the limit, it holds");
        assertTrue(lib.count(1, 0, START + 2), "one unit over, it trips");
        _assertState(12e6 + 1, 2e6, START, true);
    }

    function test_ItTripsOnceAndKeepsCountingWhileTripped() external {
        assertTrue(lib.count(100e6, 0, START + 1), "trips");
        assertFalse(lib.count(100e6, 0, START + 2), "doesn't trip again");
        _assertState(205e6, 2e6, START, true);
        // A new window restarts the counters, and the trip stays until a reset.
        assertFalse(lib.count(1e6, 0, START + WINDOW), "a new window");
        _assertState(1e6, 0, START + WINDOW, true);
    }

    function test_WithTheLimitAtZeroItNeverTrips() external {
        lib.set(_breaker(5e6, 2e6, 0));
        assertFalse(lib.count(type(uint64).max - 5e6, 0, START + 1), "never trips");
        _assertState(type(uint64).max, 2e6, START, false); // but still counts
    }

    function test_TheLargestLimitCannotOverflowTheCheck() external {
        // `lossIn + maxNetProfit` doesn't fit 64 bits; the check sums in 256.
        lib.set(_breaker(0, type(uint64).max - 1, type(uint64).max));
        assertFalse(lib.count(type(uint64).max, 1, START + 1), "the most out is less than the sum");
        _assertState(type(uint64).max, type(uint64).max, START, false);
    }

    function test_RevertWhen_ACounterWouldOverflow() external {
        lib.set(_breaker(type(uint64).max, 2e6, 10e6));
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        lib.count(1, 0, START + 1);
        lib.set(_breaker(5e6, type(uint64).max, 10e6));
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        lib.count(0, 1, START + 1);
    }

    function test_TheResetClearsATripZeroesTheCountersAndStartsTheWindow() external {
        assertTrue(lib.count(100e6, 0, START + 1), "tripped");
        lib.reset(START + 5);
        _assertState(0, 0, START + 5, false);
        Breaker memory b = lib.get();
        assertEq(b.windowSecs, WINDOW, "the window's length stays");
        assertEq(b.maxNetProfit, 10e6, "and the limit");
    }

    /// @dev For any breaker, amounts and time: `count` does exactly what §8.11 says, or reverts `MathOverflow` when a
    ///      counter would overflow.
    function testFuzz_CountFollowsTheRule(Breaker memory b, uint64 profit, uint64 loss, uint48 currentTime) external {
        lib.set(b);
        if (profit == 0 && loss == 0) {
            assertFalse(lib.count(profit, loss, currentTime), "nothing trips");
            assertEq(abi.encode(lib.get()), abi.encode(b), "nothing changes");
            return;
        }
        Breaker memory e = Breaker(b.profitOut, b.lossIn, b.windowStart, b.tripped, b.windowSecs, b.maxNetProfit);
        if (currentTime >= uint256(e.windowStart) + e.windowSecs) {
            e.profitOut = 0;
            e.lossIn = 0;
            e.windowStart = currentTime;
        }
        if (uint256(e.profitOut) + profit > type(uint64).max || uint256(e.lossIn) + loss > type(uint64).max) {
            vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
            lib.count(profit, loss, currentTime);
            return;
        }
        e.profitOut += profit;
        e.lossIn += loss;
        bool trips = !e.tripped && e.maxNetProfit > 0 && uint256(e.profitOut) > uint256(e.lossIn) + e.maxNetProfit;
        if (trips) e.tripped = true;
        assertEq(lib.count(profit, loss, currentTime), trips, "tripped now");
        assertEq(abi.encode(lib.get()), abi.encode(e), "the breaker");
    }

    /// @dev A breaker whose window started at `START`, with these counters and limit.
    function _breaker(uint64 profitOut, uint64 lossIn, uint64 maxNetProfit) private pure returns (Breaker memory) {
        return Breaker({
            profitOut: profitOut,
            lossIn: lossIn,
            windowStart: START,
            tripped: false,
            windowSecs: WINDOW,
            maxNetProfit: maxNetProfit
        });
    }

    /// @dev The breaker's counters, window start and trip are these.
    function _assertState(uint64 profitOut, uint64 lossIn, uint48 windowStart, bool tripped) private view {
        Breaker memory b = lib.get();
        assertEq(b.profitOut, profitOut, "profit out");
        assertEq(b.lossIn, lossIn, "losses in");
        assertEq(b.windowStart, windowStart, "the window start");
        assertEq(b.tripped, tripped, "tripped");
    }
}
