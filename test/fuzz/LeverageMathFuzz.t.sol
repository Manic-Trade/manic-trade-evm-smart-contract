// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {Side} from "../../src/types/StorageTypes.sol";
import {LeverageMathHarness} from "../harnesses/LeverageMathHarness.sol";
import {Calculations} from "../utils/Calculations.sol";

/// @title LeverageMath_Fuzz_Test
/// @notice Property tests for LeverageMath part 1, at any leverage: for random inputs, the functions keep the
///         properties the design relies on. The worked examples are in test/unit/LeverageMath.t.sol (at 1000x) and
///         test/unit/LeverageMathLeverage.t.sol (the leverage as an input).
/// @dev Inputs are bounded with `bound` (not `vm.assume`) so every run counts. Prices range over all positive
///      `int64` values unless a property needs headroom, and the leverage over the whole allowed range, 1x to
///      10,000x, with θ and the cap inside the limits it sets. CI runs 10,000 cases per property (FOUNDRY_PROFILE=ci).
contract LeverageMath_Fuzz_Test is Test {
    LeverageMathHarness internal math;

    function setUp() public {
        math = new LeverageMathHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // floorDiv
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The definition of the floor: the remainder `a - q × b` has the sign of `b` (or is 0) and is smaller than
    ///      `|b|`. Bounds keep `q × b` far from overflow.
    function testFuzz_FloorDivIsTheMathematicalFloor(int256 a, int256 b) public view {
        a = bound(a, -1e60, 1e60);
        b = bound(b, -1e30, 1e30);
        if (b == 0) b = 1;
        int256 q = math.floorDiv(a, b);
        int256 remainder = a - q * b;
        if (b > 0) {
            assertGe(remainder, 0);
            assertLt(remainder, b);
        } else {
            assertLe(remainder, 0);
            assertGt(remainder, b);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // gBps
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Differential: `gBps` equals `Calculations.gBps`, which reaches the same floor through `ceilDiv` instead of
    ///      `floorDiv`. A wrong rounding direction in either one fails this, at any leverage.
    function testFuzz_GBpsMatchesAnIndependentFormula(
        int64 entry,
        int64 price,
        bool isCall,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        public
        view
    {
        entry = int64(bound(entry, 1, type(int64).max));
        price = int64(bound(price, 1, type(int64).max));
        leverage = _leverage(leverage);
        Side side = isCall ? Side.Call : Side.Put;
        assertEq(
            math.gBps(entry, price, side, leverage, floorBps, capBps),
            Calculations.gBps(entry, price, side, leverage, floorBps, capBps)
        );
    }

    /// @dev The multiple never leaves [0, cap], for any inputs.
    function testFuzz_GBpsStaysBetweenZeroAndTheCap(
        int64 entry,
        int64 price,
        bool isCall,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        public
        view
    {
        entry = int64(bound(entry, 1, type(int64).max));
        price = int64(bound(price, 1, type(int64).max));
        uint16 g = math.gBps(entry, price, isCall ? Side.Call : Side.Put, _leverage(leverage), floorBps, capBps);
        assertLe(g, capBps);
    }

    /// @dev Monotonic in the price: as the price rises, a long's multiple never falls and a short's never rises. The
    ///      floor jump keeps this true, because it only ever raises g on a winning move.
    function testFuzz_GBpsMovesWithThePrice(
        int64 entry,
        int64 lower,
        int64 higher,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        public
        view
    {
        entry = int64(bound(entry, 1, type(int64).max));
        lower = int64(bound(lower, 1, type(int64).max));
        higher = int64(bound(higher, lower, type(int64).max));
        leverage = _leverage(leverage);
        assertLe(
            math.gBps(entry, lower, Side.Call, leverage, floorBps, capBps),
            math.gBps(entry, higher, Side.Call, leverage, floorBps, capBps)
        );
        assertGe(
            math.gBps(entry, lower, Side.Put, leverage, floorBps, capBps),
            math.gBps(entry, higher, Side.Put, leverage, floorBps, capBps)
        );
    }

    /// @dev Monotonic in the leverage: for the same price, a higher leverage never pays a winning bet less, and never
    ///      pays a losing one more. The floor and the cap keep the order, since both apply to every leverage alike.
    function testFuzz_GBpsMovesWithTheLeverage(
        int64 entry,
        int64 price,
        bool isCall,
        uint16 lower,
        uint16 higher,
        uint16 floorBps,
        uint16 capBps
    )
        public
        view
    {
        entry = int64(bound(entry, 1, type(int64).max));
        price = int64(bound(price, 1, type(int64).max));
        lower = _leverage(lower);
        higher = uint16(bound(higher, lower, 10_000));
        Side side = isCall ? Side.Call : Side.Put;
        bool winning = isCall ? price > entry : price < entry;
        uint16 atLower = math.gBps(entry, price, side, lower, floorBps, capBps);
        uint16 atHigher = math.gBps(entry, price, side, higher, floorBps, capBps);
        if (winning) assertLe(atLower, atHigher, "a win pays at least as much at a higher leverage");
        else assertGe(atLower, atHigher, "a loss pays at most as much at a higher leverage");
    }

    /// @dev A short at `entry - delta` is worth exactly what a long at `entry + delta` is worth.
    function testFuzz_AShortMirrorsALong(
        int64 entry,
        int64 delta,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        public
        view
    {
        entry = int64(bound(entry, 2, type(int64).max / 2));
        delta = int64(bound(delta, -(entry - 1), entry - 1));
        leverage = _leverage(leverage);
        assertEq(
            math.gBps(entry, entry + delta, Side.Call, leverage, floorBps, capBps),
            math.gBps(entry, entry - delta, Side.Put, leverage, floorBps, capBps)
        );
    }

    /// @dev Any winning move with R > 0 pays at least the floor (when the floor fits under the cap). That is, any price
    ///      at least one R unit above entry for a long: ceil(entry / (L × 10,000)) price units, since R is the move ×
    ///      L × 10,000 / entry.
    function testFuzz_AnyWinPaysAtLeastTheFloor(
        int64 entry,
        uint64 up,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        public
        view
    {
        entry = int64(bound(entry, 1, 1e15));
        leverage = _leverage(leverage);
        capBps = uint16(bound(capBps, 10_001, 40_000));
        floorBps = uint16(bound(floorBps, 10_001, capBps));
        int64 scale = int64(uint64(leverage)) * 10_000;
        int64 minWinningMove = (entry + scale - 1) / scale;
        int64 price = entry + minWinningMove + int64(uint64(bound(up, 0, 1e15)));
        assertGe(math.gBps(entry, price, Side.Call, leverage, floorBps, capBps), floorBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // lines and touched
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Each offset is exactly the floor of its formula: the line `entry × θ / 1e7` and the cap line
    ///      `entry × (cap − 1x) / (L × 10,000)`. Writing each back gives a remainder in [0, divisor). θ and
    ///      the cap range over everything `lines` takes at the leverage; entry up to half of `int64`'s range, where
    ///      both lines fit even at 1x.
    function testFuzz_TheLinesSitWhereTheFormulaSays(
        int64 entry,
        uint16 leverage,
        uint32 thetaE7,
        uint16 capBps,
        bool isCall
    )
        public
        view
    {
        entry = int64(bound(entry, 1, type(int64).max / 2));
        leverage = _leverage(leverage);
        thetaE7 = uint32(bound(thetaE7, 1, _widestTheta(leverage)));
        capBps = uint16(bound(capBps, 10_001, _highestCap(leverage)));
        (int64 liq, int64 cap) = math.lines(entry, isCall ? Side.Call : Side.Put, leverage, thetaE7, capBps);

        int256 capDivisor = int256(uint256(leverage)) * 10_000;
        int256 liqOffset = isCall ? int256(entry) - liq : int256(liq) - entry;
        int256 capOffset = isCall ? int256(cap) - entry : int256(entry) - cap;
        int256 liqRemainder = int256(entry) * int256(uint256(thetaE7)) - liqOffset * 1e7;
        int256 capRemainder = int256(entry) * (int256(uint256(capBps)) - 10_000) - capOffset * capDivisor;
        assertGe(liqRemainder, 0);
        assertLt(liqRemainder, 1e7);
        assertGe(capRemainder, 0);
        assertLt(capRemainder, capDivisor);
    }

    /// @dev `lines` takes the widest line and the highest cap the leverage allows, and refuses one step past either:
    ///      θ × L < 1e7, and cap − 1x < L (which only binds below 4x; above it the 4x ceiling does).
    function testFuzz_TheLimitsOfTheLeverageAtTheirEdges(int64 entry, uint16 leverage, bool isCall) public {
        entry = int64(bound(entry, 1, type(int64).max / 2));
        leverage = _leverage(leverage);
        Side side = isCall ? Side.Call : Side.Put;
        uint32 widest = _widestTheta(leverage);
        uint16 highest = _highestCap(leverage);
        math.lines(entry, side, leverage, widest, highest);
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(entry, side, leverage, widest + 1, highest);
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(entry, side, leverage, widest, highest + 1);
    }

    /// @dev `capLine` is `lines`' cap price for every entry up to half of `int64`'s range (where both of `lines`'
    ///      lines fit), any side, leverage, θ and cap.
    function testFuzz_CapLineIsTheCapPriceOfLines(
        int64 entry,
        uint16 leverage,
        uint32 thetaE7,
        uint16 capBps,
        bool isCall
    )
        public
        view
    {
        entry = int64(bound(entry, 1, type(int64).max / 2));
        leverage = _leverage(leverage);
        thetaE7 = uint32(bound(thetaE7, 1, _widestTheta(leverage)));
        capBps = uint16(bound(capBps, 10_001, _highestCap(leverage)));
        Side side = isCall ? Side.Call : Side.Put;
        (, int64 cap) = math.lines(entry, side, leverage, thetaE7, capBps);
        assertEq(math.capLine(entry, side, leverage, capBps), cap, "the same cap price");
    }

    /// @dev `capLine` refuses what `lines` refuses for the price, the leverage and the cap, with the same error and in
    ///      the same order: a bad price (with anything else) is `InvalidPrice`; a good price with a leverage outside
    ///      1x to 10,000x, or a cap of at most 1x, above 4x or out of a short's reach, is `InvalidLeverageParams`.
    ///      (Near `int64`'s top, `lines` can also overflow on a short's liquidation line, which `capLine` doesn't
    ///      compute.)
    function testFuzz_CapLineRefusesWhatLinesRefuses(
        int64 entry,
        uint16 leverage,
        uint16 capBps,
        bool isCall,
        uint8 what
    )
        public
    {
        Side side = isCall ? Side.Call : Side.Put;
        bytes4 expected = IManicFlashOptionErrors.InvalidLeverageParams.selector;
        if (what % 3 == 0) {
            entry = int64(bound(entry, type(int64).min, 0));
            expected = IManicFlashOptionErrors.InvalidPrice.selector;
        } else if (what % 3 == 1) {
            entry = int64(bound(entry, 1, type(int64).max / 2));
            leverage = leverage % 2 == 0 ? 0 : uint16(bound(leverage, 10_001, type(uint16).max));
        } else {
            entry = int64(bound(entry, 1, type(int64).max / 2));
            leverage = _leverage(leverage);
            capBps = capBps % 2 == 0
                ? uint16(bound(capBps, 0, 10_000))
                : uint16(bound(capBps, uint256(_highestCap(leverage)) + 1, type(uint16).max));
        }
        vm.expectRevert(expected);
        math.lines(entry, side, leverage, 1, capBps);
        vm.expectRevert(expected);
        math.capLine(entry, side, leverage, capBps);
    }

    /// @dev At the line itself the position is touched, and one unit on the safe side it is not.
    function testFuzz_TheLineIsTouchedAtEquality(
        int64 entry,
        uint16 leverage,
        uint32 thetaE7,
        bool isCall
    )
        public
        view
    {
        entry = int64(bound(entry, 1e7, type(int64).max / 2));
        leverage = _leverage(leverage);
        thetaE7 = uint32(bound(thetaE7, 1, _widestTheta(leverage)));
        Side side = isCall ? Side.Call : Side.Put;
        (int64 liq,) = math.lines(entry, side, leverage, thetaE7, _highestCap(leverage));
        assertTrue(math.touched(liq, liq, side));
        assertFalse(math.touched(isCall ? liq + 1 : liq - 1, liq, side));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 1000x: the formulas with the leverage fixed
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev At 1000x, L × 10,000 is 1e7, so the maths gives exactly the numbers of the formulas with the leverage
    ///      fixed at 1000x and written with 1e7: `gBps` against `_gBpsE7`, and `lines` against `_linesE7`, refusals
    ///      included. Half the cases put θ and the cap next to the fixed bounds (0 and 10 bp; 1x and 4x).
    function testFuzz_1000xMatchesTheFixedLeverageFormulas(
        int64 entry,
        int64 price,
        bool isCall,
        uint16 floorBps,
        uint16 capBps,
        uint32 thetaE7
    )
        public
    {
        entry = int64(bound(entry, 1, type(int64).max / 2));
        price = int64(bound(price, 1, type(int64).max));
        Side side = isCall ? Side.Call : Side.Put;
        assertEq(math.gBps(entry, price, side, 1000, floorBps, capBps), _gBpsE7(entry, price, side, floorBps, capBps));

        if (thetaE7 % 2 == 0) {
            thetaE7 = uint32(bound(thetaE7, 0, 10_010));
            capBps = uint16(bound(capBps, 9990, 40_010));
        }
        (bool accepted, int64 wantLiq, int64 wantCap) = _linesE7(entry, side, thetaE7, capBps);
        if (!accepted) vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        (int64 liq, int64 cap) = math.lines(entry, side, 1000, thetaE7, capBps);
        if (accepted) {
            assertEq(liq, wantLiq, "the fixed-1000x liquidation line");
            assertEq(cap, wantCap, "the fixed-1000x cap line");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // payout and maxProfit
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev At the cap a position pays exactly its stake plus its max profit, the amount opening it reserved. So the
    ///      exposure the pool tracks is never smaller than what a winner can take.
    function testFuzz_PayoutAtTheCapIsStakePlusMaxProfit(uint64 stake, uint16 capBps) public view {
        stake = uint64(bound(stake, 0, type(uint64).max / 4));
        capBps = uint16(bound(capBps, 10_000, 40_000));
        assertEq(math.payout(stake, capBps), stake + math.maxProfit(stake, capBps));
    }

    /// @dev Below the cap, a payout is never above stake + max profit.
    function testFuzz_PayoutNeverExceedsStakePlusMaxProfit(
        uint64 stake,
        uint16 multipleBps,
        uint16 capBps
    )
        public
        view
    {
        stake = uint64(bound(stake, 0, type(uint64).max / 4));
        capBps = uint16(bound(capBps, 10_000, 40_000));
        multipleBps = uint16(bound(multipleBps, 0, capBps));
        assertLe(math.payout(stake, multipleBps), stake + math.maxProfit(stake, capBps));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A leverage in the allowed range, 1x to 10,000x.
    function _leverage(uint16 leverage) private pure returns (uint16) {
        return uint16(bound(leverage, 1, 10_000));
    }

    /// @dev The widest line `lines` takes at `leverage`: the largest θ with θ × L < 1e7.
    function _widestTheta(uint16 leverage) private pure returns (uint32) {
        return uint32((1e7 - 1) / uint256(leverage));
    }

    /// @dev The highest cap `lines` takes at `leverage`: the 4x ceiling or, below 4x leverage, the highest a short can
    ///      reach, (L + 1) × 1x less one bp.
    function _highestCap(uint16 leverage) private pure returns (uint16) {
        uint256 reachable = (uint256(leverage) + 1) * 10_000 - 1;
        return uint16(reachable < 40_000 ? reachable : 40_000);
    }

    /// @dev `gBps` with the leverage fixed at 1000x: `R_e7 = floor(move × 1e7 / entry)`, the floor on a win, then the
    ///      cap and 0. Entry and price must be positive.
    function _gBpsE7(int64 entry, int64 price, Side side, uint16 floorBps, uint16 capBps)
        private
        pure
        returns (uint16)
    {
        int256 move = side == Side.Call ? int256(price) - entry : int256(entry) - price;
        int256 numerator = move * 1e7;
        int256 rE7 = numerator / entry;
        if (numerator % entry != 0 && numerator < 0) rE7 -= 1; // floor, as entry > 0
        int256 g = 10_000 + rE7;
        if (rE7 > 0 && g < int256(uint256(floorBps))) g = int256(uint256(floorBps));
        if (g > int256(uint256(capBps))) g = int256(uint256(capBps));
        if (g < 0) g = 0;
        return uint16(uint256(g));
    }

    /// @dev `lines` with the leverage fixed at 1000x: θ below 10 bp, the cap above 1x and at most 4x, and both offsets
    ///      over 1e7. For entries up to half of `int64`'s range both lines fit.
    function _linesE7(
        int64 entry,
        Side side,
        uint32 thetaE7,
        uint16 capBps
    )
        private
        pure
        returns (bool accepted, int64 liq, int64 cap)
    {
        if (!(entry > 0 && thetaE7 > 0 && thetaE7 < 10_000 && capBps > 10_000 && capBps <= 40_000)) {
            return (false, 0, 0);
        }
        int256 e = entry;
        int256 liqOffset = e * int256(uint256(thetaE7)) / 1e7;
        int256 capOffset = e * (int256(uint256(capBps)) - 10_000) / 1e7;
        (int256 liqLine, int256 capLineAt) =
            side == Side.Call ? (e - liqOffset, e + capOffset) : (e + liqOffset, e - capOffset);
        return (true, int64(liqLine), int64(capLineAt));
    }
}
