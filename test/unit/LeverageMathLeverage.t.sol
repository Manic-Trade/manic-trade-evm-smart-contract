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
