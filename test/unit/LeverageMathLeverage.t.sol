// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {Side} from "../../src/types/StorageTypes.sol";
import {Examples as V} from "../utils/Examples.sol";
import {LeverageMath_Unit_Shared_Test} from "./LeverageMathShared.sol";

// Unit tests for the leverage as an input of the maths: each market has its own leverage L, any whole number from 1x
// to 10,000x. At L, a 1 bp move of the price is worth L bps of the stake; the line must sit closer than 1/L, and a
// short must be able to reach its cap (cap − 1x < L). They are worked examples with hand-checkable values (the
// formulas are in docs/MATH.md), at the 500x and 100x tier settings and at the edges of the range. The examples at
// 1000x are in LeverageMath.t.sol. Design: docs/ARCHITECTURE.md §10.

/// @notice `leverageAllowed`: a leverage is a whole number from 1x to 10,000x.
contract LeverageAllowed_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    function test_BothEndsOfTheRangeAreAllowed() public view {
        assertEq(math.MIN_LEVERAGE(), 1, "MIN_LEVERAGE");
        assertEq(math.MAX_LEVERAGE(), 10_000, "MAX_LEVERAGE");
        assertTrue(math.leverageAllowed(1), "1x");
        assertTrue(math.leverageAllowed(1000), "1000x");
        assertTrue(math.leverageAllowed(10_000), "10,000x");
    }

    function test_ALeverageOutsideTheRangeIsNot() public view {
        assertFalse(math.leverageAllowed(0), "0x");
        assertFalse(math.leverageAllowed(10_001), "10,001x");
        assertFalse(math.leverageAllowed(type(uint16).max), "65,535x");
    }
}

/// @notice `thetaWithinLimit`: the liquidation line must sit closer than 1/leverage, where the payout reaches 0.
contract ThetaWithinLimit_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev The widest θ each leverage allows, the largest with θ × L < 1e7, passes, and one unit wider fails: 9,999
    ///      (9.999 bp) at 1000x, 999 at 10,000x.
    function test_TheWidestLineOfEachLeverage() public view {
        uint16[8] memory leverages = [uint16(1), 4, 15, 100, 500, 1000, 2000, 10_000];
        uint32[8] memory widest = [uint32(9_999_999), 2_499_999, 666_666, 99_999, 19_999, 9999, 4999, 999];
        for (uint256 i; i < leverages.length; ++i) {
            assertTrue(math.thetaWithinLimit(widest[i], leverages[i]), "the widest line");
            assertFalse(math.thetaWithinLimit(widest[i] + 1, leverages[i]), "one unit wider");
        }
    }

    /// @dev At 1000x a line must be below 10 bp. The tiers' widest lines (17.64 bp at 100x, 11.76 bp at 500x) fit their
    ///      own leverage, and 500x's is too wide for 1000x.
    function test_EachTiersWidestLineFitsItsOwnLeverage() public view {
        assertTrue(math.thetaWithinLimit(9999, 1000), "9.999 bp at 1000x");
        assertFalse(math.thetaWithinLimit(10_000, 1000), "10 bp at 1000x");
        assertTrue(math.thetaWithinLimit(17_640, 100), "17.64 bp at 100x");
        assertTrue(math.thetaWithinLimit(11_760, 500), "11.76 bp at 500x");
        assertFalse(math.thetaWithinLimit(11_760, 1000), "11.76 bp at 1000x");
    }

    /// @dev No overflow at the largest θ and leverage: the product is taken in 256 bits.
    function test_TheLargestThetaAndLeverageDoNotOverflow() public view {
        assertFalse(math.thetaWithinLimit(type(uint32).max, 10_000));
        assertFalse(math.thetaWithinLimit(type(uint32).max, type(uint16).max));
    }
}

/// @notice `capReachable`: a short must be able to reach its cap before the price reaches 0.
contract CapReachable_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev cap − 1x < leverage, since a short gains at most L × its stake (the price can't fall below 0). At 1x the
    ///      cap stays under 2x, at 2x under 3x, at 3x under 4x; from 4x leverage up, every cap up to the 4x ceiling
    ///      fits.
    function test_TheHighestCapOfEachLeverage() public view {
        uint16[5] memory leverages = [uint16(1), 2, 3, 4, 1000];
        uint16[5] memory highest = [uint16(19_999), 29_999, 39_999, 40_000, 40_000];
        for (uint256 i; i < leverages.length; ++i) {
            assertTrue(math.capReachable(highest[i], leverages[i]), "the highest cap");
            if (highest[i] < 40_000) assertFalse(math.capReachable(highest[i] + 1, leverages[i]), "one bp higher");
        }
    }

    /// @dev A cap of 1x or below gains nothing, so it is reachable at any leverage: it counts as 1x. `lines` and the
    ///      config check reject such a cap anyway.
    function test_ACapOfOneXOrBelowIsReachable() public view {
        assertTrue(math.capReachable(0, 1), "0x at 1x");
        assertTrue(math.capReachable(9999, 1), "0.9999x at 1x");
        assertTrue(math.capReachable(10_000, 1), "1x at 1x");
    }

    /// @dev The largest cap and leverage don't overflow: the product is taken in 256 bits.
    function test_TheLargestCapAndLeverageDoNotOverflow() public view {
        assertTrue(math.capReachable(type(uint16).max, 10_000), "6.5535x at 10,000x");
        assertFalse(math.capReachable(type(uint16).max, 5), "6.5535x at 5x: 5.5535x of gain, more than 5x");
        assertTrue(math.capReachable(type(uint16).max, 6), "6.5535x at 6x");
    }
}

/// @notice `gBps` at any leverage: a 1 bp move is worth L bps of the stake.
contract GBpsAtAnyLeverage_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev With no floor (1x) and the 4x cap, 1 bp in the user's favour adds L bps of the stake, and 1 bp against
    ///      takes as much away, down to 0: at 1000x, +1 bp is g = 1.1x; at 10,000x, -1 bp is 0.
    function test_OneBpIsWorthLBpsOfTheStake() public view {
        uint16[8] memory leverages = _leverages();
        for (uint256 i; i < leverages.length; ++i) {
            uint16 leverage = leverages[i];
            uint16 down = leverage < 10_000 ? 10_000 - leverage : 0;
            assertEq(
                math.gBps(V.P0, V.P0 + V.BP, Side.Call, leverage, 10_000, V.CAP_4X), 10_000 + leverage, "a long, +1 bp"
            );
            assertEq(
                math.gBps(V.P0, V.P0 - V.BP, Side.Put, leverage, 10_000, V.CAP_4X), 10_000 + leverage, "a short, -1 bp"
            );
            assertEq(math.gBps(V.P0, V.P0 - V.BP, Side.Call, leverage, 10_000, V.CAP_4X), down, "a long, -1 bp");
            assertEq(math.gBps(V.P0, V.P0 + V.BP, Side.Put, leverage, 10_000, V.CAP_4X), down, "a short, +1 bp");
            assertEq(math.gBps(V.P0, V.P0, Side.Call, leverage, 10_000, V.CAP_4X), 10_000, "a long, flat");
            assertEq(math.gBps(V.P0, V.P0, Side.Put, leverage, 10_000, V.CAP_4X), 10_000, "a short, flat");
        }
    }

    /// @dev Half a bp, ±7.5 bps of the stake at 15x: a win rounds down (+7), and a loss rounds down too (-8), never in
    ///      the user's favour.
    function test_HalfABpRoundsDownBothWays() public view {
        assertEq(math.gBps(V.P0, V.P0 + V.BP / 2, Side.Call, 15, 10_000, V.CAP_4X), 10_007, "15x: +7.5 -> +7");
        assertEq(math.gBps(V.P0, V.P0 - V.BP / 2, Side.Call, 15, 10_000, V.CAP_4X), 9992, "15x: -7.5 -> -8");
        assertEq(math.gBps(V.P0, V.P0 + V.BP / 2, Side.Call, 1, 10_000, V.CAP_4X), 10_000, "1x: +0.5 -> 0");
        assertEq(math.gBps(V.P0, V.P0 - V.BP / 2, Side.Call, 1, 10_000, V.CAP_4X), 9999, "1x: -0.5 -> -1");
        // A move that rounds to 0 is not a win, so it doesn't pay the floor either.
        assertEq(math.gBps(V.P0, V.P0 + V.BP / 2, Side.Call, 1, 10_050, V.CAP_4X), 10_000, "1x: no 1.005x floor");
    }

    /// @dev The floor and the cap at the 100x and 500x tier settings (100x: floor 1.005x, cap 2x; 500x: floor 1.025x,
    ///      cap 2.5x). At 100x, +1 bp is +100 bps, so +100 bp reaches the 2x cap; at 500x, +30 bp is +15,000 bps,
    ///      exactly the 2.5x cap.
    function test_TheTierFloorAndCapAt100xAnd500x() public view {
        assertEq(_g100(V.P0 + V.BP / 10), 10_050, "+0.1 bp is +10: the 1.005x floor");
        assertEq(_g100(V.P0 + V.BP), 10_100, "+1 bp");
        assertEq(_g100(V.P0 + 99 * V.BP), 19_900, "+99 bp");
        assertEq(_g100(V.P0 + 100 * V.BP), 20_000, "+100 bp reaches the 2x cap");
        assertEq(_g100(V.P0 + 150 * V.BP), 20_000, "+150 bp stays at the cap");
        assertEq(math.gBps(V.P0, V.P0 + V.BP, Side.Call, 500, 10_250, 25_000), 10_500, "500x, +1 bp");
        assertEq(math.gBps(V.P0, V.P0 + 30 * V.BP, Side.Call, 500, 10_250, 25_000), 25_000, "500x, +30 bp: the cap");
    }

    /// @dev The widest moves fit the 256-bit maths at every leverage, then clamp to the cap or to 0.
    function test_TheWidestMovesClampAtAnyLeverage() public view {
        uint16[8] memory leverages = _leverages();
        int64 top = type(int64).max;
        for (uint256 i; i < leverages.length; ++i) {
            uint16 leverage = leverages[i];
            assertEq(math.gBps(1, top, Side.Call, leverage, 15_000, V.CAP_4X), V.CAP_4X, "a long's widest win, capped");
            assertEq(math.gBps(1, top, Side.Put, leverage, 15_000, V.CAP_4X), 0, "a short's widest loss: 0");
            assertEq(math.gBps(top, 1, Side.Call, leverage, 15_000, V.CAP_4X), 0, "a long's widest loss: 0");
            assertLe(math.gBps(top, 1, Side.Put, leverage, 15_000, V.CAP_4X), V.CAP_4X, "a short's widest win");
        }
    }

    function test_RevertWhen_TheLeverageIsOutsideTheRange() public {
        uint16[3] memory bad = [uint16(0), 10_001, type(uint16).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.gBps(V.P0, V.P0 + V.BP, Side.Call, bad[i], 11_000, V.CAP_4X);
        }
    }

    /// @dev The checks run in order: with a bad price and a bad leverage, the price error wins.
    function test_RevertWhen_PriceAndLeverageAreBothBad_ThePriceErrorComesFirst() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.gBps(0, V.P0, Side.Call, 0, 11_000, V.CAP_4X);
    }

    function _g100(int64 price) private view returns (uint16) {
        return math.gBps(V.P0, price, Side.Call, 100, 10_050, 20_000);
    }
}

/// @notice `lines` at any leverage: the line limit and the reachable cap, and where the lines sit.
contract LinesAtAnyLeverage_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev 500x with the tier's widest line (11.76 bp) and the 2.5x cap. The line is 83,884 × 11.76 / 10,000 =
    ///      $98.647584 below the entry; the cap line (2.5 − 1) / 500 = 0.3% above it, the same move as 1000x at 4x
    ///      ($84,135.652).
    function test_At500xWithTheTiersWidestLine() public view {
        (int64 liq, int64 cap) = math.lines(V.P0, Side.Call, 500, 11_760, 25_000);
        assertEq(liq, 8_378_535_241_600, "$83,785.352416");
        assertEq(cap, 8_413_565_200_000, "$84,135.652, as 1000x at 4x");
        assertEq(math.gBps(V.P0, liq, Side.Call, 500, 10_250, 25_000), 4120, "at the line the bet has lost 58.8%");
        assertEq(
            math.gBps(V.P0, cap, Side.Call, 500, 10_250, 25_000), 25_000, "the cap line is where g reaches the cap"
        );
        assertEq(math.gBps(V.P0, cap - 1, Side.Call, 500, 10_250, 25_000), 24_999, "one unit short of it");
    }

    /// @dev 100x with the tier's widest line (17.64 bp) and the 2x cap: the line is 83,884 × 17.64 / 10,000 =
    ///      $147.971376 away, and the cap line (2 − 1) / 100 = 1% away. A short mirrors it.
    function test_At100xWithTheTiersWidestLine() public view {
        (int64 liq, int64 cap) = math.lines(V.P0, Side.Call, 100, 17_640, 20_000);
        assertEq(liq, 8_373_602_862_400, "a long's line");
        assertEq(cap, 8_472_284_000_000, "a long's cap line, 1% up");
        assertEq(math.gBps(V.P0, liq, Side.Call, 100, 10_050, 20_000), 8236, "lost 17.64% at the line");
        assertEq(math.gBps(V.P0, cap, Side.Call, 100, 10_050, 20_000), 20_000, "the cap at the cap line");
        assertEq(math.gBps(V.P0, cap - 1, Side.Call, 100, 10_050, 20_000), 19_999, "one unit short of it");

        (liq, cap) = math.lines(V.P0, Side.Put, 100, 17_640, 20_000);
        assertEq(liq, 8_403_197_137_600, "a short's line");
        assertEq(cap, 8_304_516_000_000, "a short's cap line, 1% down");
        assertEq(math.gBps(V.P0, liq, Side.Put, 100, 10_050, 20_000), 8236, "a short at its line");
        assertEq(math.gBps(V.P0, cap, Side.Put, 100, 10_050, 20_000), 20_000, "a short at its cap line");
    }

    /// @dev `lines` takes each leverage's widest line and refuses one unit wider, on both sides.
    function test_TheWidestLineOfEachLeverage() public {
        uint16[8] memory leverages = _leverages();
        uint32[8] memory widest = [uint32(9_999_999), 2_499_999, 666_666, 99_999, 19_999, 9999, 4999, 999];
        for (uint256 i; i < leverages.length; ++i) {
            math.lines(V.P0, Side.Call, leverages[i], widest[i], 15_000);
            math.lines(V.P0, Side.Put, leverages[i], widest[i], 15_000);
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.lines(V.P0, Side.Call, leverages[i], widest[i] + 1, 15_000);
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.lines(V.P0, Side.Put, leverages[i], widest[i] + 1, 15_000);
        }
    }

    /// @dev `lines` takes each leverage's highest reachable cap and refuses one bp higher. Both sides follow the same
    ///      rule.
    function test_TheHighestReachableCapOfEachLeverage() public {
        uint16[5] memory leverages = [uint16(1), 2, 3, 4, 1000];
        uint16[5] memory highest = [uint16(19_999), 29_999, 39_999, 40_000, 40_000];
        for (uint256 i; i < leverages.length; ++i) {
            math.lines(V.P0, Side.Put, leverages[i], 1, highest[i]);
            math.lines(V.P0, Side.Call, leverages[i], 1, highest[i]);
            if (highest[i] == 40_000) continue; // above 4x is the ceiling's refusal, tested in LeverageMath.t.sol
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.lines(V.P0, Side.Put, leverages[i], 1, highest[i] + 1);
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.lines(V.P0, Side.Call, leverages[i], 1, highest[i] + 1);
        }
    }

    /// @dev At 1x, a short's 1.9999x cap line is 0.9999 of the entry below it, so it sits 1 bp of the entry above 0.
    function test_AtOneXAShortsHighestCapLineSitsOneBpAboveZero() public view {
        (, int64 cap) = math.lines(V.P0, Side.Put, 1, 1, 19_999);
        assertEq(cap, V.BP);
    }

    function test_RevertWhen_TheLeverageIsOutsideTheRange() public {
        uint16[3] memory bad = [uint16(0), 10_001, type(uint16).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.lines(V.P0, Side.Call, bad[i], 1, 15_000);
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.lines(V.P0, Side.Put, bad[i], 1, 15_000);
        }
    }

    /// @dev The checks run in order: with a bad price and a bad leverage, the price error wins.
    function test_RevertWhen_PriceAndLeverageAreBothBad_ThePriceErrorComesFirst() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.lines(0, Side.Call, 0, 1, 15_000);
    }

    /// @dev At 1x, the widest line on the largest price is beyond `int64` on a short (its line) and on a long (its cap
    ///      line): an error, never a wrap.
    function test_RevertWhen_ALineDoesNotFitInt64() public {
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        math.lines(type(int64).max, Side.Put, 1, 9_999_999, 15_000);
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        math.lines(type(int64).max, Side.Call, 1, 9_999_999, 15_000);
    }

    /// @dev At 10,000x, the widest line and the 4x cap on half the largest price still fit.
    function test_AHugePriceStillFitsAt10000x() public view {
        int64 big = type(int64).max / 2;
        (int64 liq, int64 cap) = math.lines(big, Side.Call, 10_000, 999, V.CAP_4X);
        assertLt(liq, big);
        assertGt(cap, big);
        (liq, cap) = math.lines(big, Side.Put, 10_000, 999, V.CAP_4X);
        assertGt(liq, big);
        assertLt(cap, big);
    }
}

/// @notice `capLine` at any leverage: the same checks and the same cap line as `lines`.
contract CapLineAtAnyLeverage_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev The cap lines of the 500x and 100x tier examples above, and of 1x's highest cap.
    function test_TheCapLinesOfTheTierExamples() public view {
        assertEq(math.capLine(V.P0, Side.Call, 500, 25_000), 8_413_565_200_000, "500x, 2.5x, a long");
        assertEq(math.capLine(V.P0, Side.Call, 100, 20_000), 8_472_284_000_000, "100x, 2x, a long");
        assertEq(math.capLine(V.P0, Side.Put, 100, 20_000), 8_304_516_000_000, "100x, 2x, a short");
        assertEq(math.capLine(V.P0, Side.Put, 1, 19_999), V.BP, "1x, 1.9999x, a short: 1 bp above 0");
    }

    function test_RevertWhen_TheLeverageIsOutsideTheRange() public {
        uint16[3] memory bad = [uint16(0), 10_001, type(uint16).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
            math.capLine(V.P0, Side.Call, bad[i], 15_000);
        }
    }

    function test_RevertWhen_AShortCouldNotReachTheCap() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.capLine(V.P0, Side.Put, 1, 20_000);
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.capLine(V.P0, Side.Call, 3, 40_000); // the rule doesn't depend on the side, as in `lines`
    }

    function test_RevertWhen_PriceAndLeverageAreBothBad_ThePriceErrorComesFirst() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.capLine(0, Side.Call, 0, 15_000);
    }
}
