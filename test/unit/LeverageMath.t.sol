// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {stdError} from "forge-std/StdError.sol";

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {Side} from "../../src/types/StorageTypes.sol";
import {Examples as V} from "../utils/Examples.sol";
import {LeverageMath_Unit_Shared_Test} from "./LeverageMathShared.sol";

// Unit tests for LeverageMath part 1: `floorDiv`, `lines`, `capLine`, `gBps`, `payout`, `maxProfit` and `touched`, at
// 1000x. They are worked examples with hand-checkable values (the formulas are in docs/MATH.md): most use a $10 bet
// at the example entry price of $83,884 (`Examples`), so a calculator is enough to check each number. Property tests
// are in test/fuzz/LeverageMathFuzz.t.sol, and the leverage as an input in LeverageMathLeverage.t.sol. Design:
// docs/ARCHITECTURE.md §10.

/// @notice `capLine`: `lines`' cap line on its own, for the `getPosition` view. It is checked against `lines`' examples
///         and errors.
contract CapLine_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev At 1000x the 4x cap line is (4 − 1) / 1000 = 0.3% from the entry: $251.652 above $83,884 for a long, and
    ///      as much below it for a short.
    function test_TheCapLinesOfALongAndAShort() public view {
        assertEq(math.capLine(V.P0, Side.Call, V.L1000, V.CAP_4X), 8_413_565_200_000, "a long's: $84,135.652");
        assertEq(math.capLine(V.P0, Side.Put, V.L1000, V.CAP_4X), 8_363_234_800_000, "a short's: $83,632.348");
    }

    function test_RevertWhen_TheEntryPriceIsNotPositive() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.capLine(0, Side.Call, V.L1000, V.CAP_4X);
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.capLine(-1, Side.Put, V.L1000, 10_000); // the price error comes first, as in `lines`
    }

    function test_RevertWhen_TheCapIsOneXOrAboveFourX() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.capLine(V.P0, Side.Call, V.L1000, 10_000);
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.capLine(V.P0, Side.Call, V.L1000, 40_001);
    }

    /// @dev A long's cap line above `type(int64).max` is an error, never a wrap.
    function test_RevertWhen_TheCapLineDoesNotFitInt64() public {
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        math.capLine(type(int64).max, Side.Call, V.L1000, V.CAP_4X);
    }
}

/// @notice The constants: the scales of basis points and of θ, the 4x ceiling on caps, and the range of leverages.
contract Constants_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    function test_Constants() public view {
        assertEq(math.BPS(), 10_000, "BPS: basis points in 1x");
        assertEq(math.E7(), 10_000_000, "E7: the scale of theta");
        assertEq(math.MAX_LEVERAGE_CAP_BPS(), 40_000, "MAX_LEVERAGE_CAP_BPS");
        assertEq(math.MIN_LEVERAGE(), 1, "MIN_LEVERAGE");
        assertEq(math.MAX_LEVERAGE(), 10_000, "MAX_LEVERAGE");
    }
}

/// @notice `floorDiv` rounds toward minus infinity, where Solidity's `/` rounds toward zero.
contract FloorDiv_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    function test_FloorsInEverySignCombination() public view {
        assertEq(math.floorDiv(7, 2), 3);
        assertEq(math.floorDiv(-7, 2), -4, "Solidity's -7 / 2 is -3");
        assertEq(math.floorDiv(7, -2), -4);
        assertEq(math.floorDiv(-7, -2), 3);
    }

    function test_ExactDivisionsAreUnchanged() public view {
        assertEq(math.floorDiv(6, 3), 2);
        assertEq(math.floorDiv(-6, 3), -2);
        assertEq(math.floorDiv(0, 5), 0);
    }

    /// @dev A long's -$8 move from $83,884 at 1000x: -8e8 × 1e7 / P0 = -953.69..., floored to -954.
    function test_FloorsAnEightDollarFall() public view {
        assertEq(math.floorDiv(-8 * 1e8 * 1e7, V.P0), -954);
    }

    function test_RevertWhen_TheDivisorIsZero() public {
        vm.expectRevert(stdError.divisionError);
        math.floorDiv(1, 0);
    }
}

/// @notice `lines`: where the liquidation and cap lines sit, and which inputs it rejects.
contract Lines_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev A long at $83,884 with θ = 2.627 bp and the 4x cap: the line is 83,884 × 2.627 / 10,000 = $22.0363268
    ///      below the entry, and the cap line 83,884 × (4 − 1) / 1000 = $251.652 above it.
    function test_WhereALongsLinesSit() public view {
        (int64 liq, int64 cap) = math.lines(V.P0, Side.Call, V.L1000, V.THETA_1M, V.CAP_4X);
        assertEq(liq, 8_386_196_367_320, "$83,861.9636732");
        assertEq(cap, 8_413_565_200_000, "$84,135.652");
    }

    /// @dev A short mirrors the long: its line $22.0363268 above the entry, its cap line $251.652 below it.
    function test_AShortMirrorsTheLong() public view {
        (int64 liq, int64 cap) = math.lines(V.P0, Side.Put, V.L1000, V.THETA_1M, V.CAP_4X);
        assertEq(liq, 8_390_603_632_680);
        assertEq(cap, 8_363_234_800_000);
    }

    /// @dev The largest θ and cap on a huge price still fit.
    function test_TheLargestParametersOnAHugePriceStillFit() public view {
        int64 big = type(int64).max / 2;
        // The widest line at 1000x (9.999 bp) and the 4x ceiling.
        (int64 liq, int64 cap) = math.lines(big, Side.Call, V.L1000, 9999, math.MAX_LEVERAGE_CAP_BPS());
        assertLt(liq, big);
        assertGt(cap, big);
    }

    /// @dev A long's cap line above `type(int64).max` is an error, never a wrap.
    function test_RevertWhen_TheCapLineDoesNotFitInt64() public {
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        math.lines(type(int64).max, Side.Call, V.L1000, V.THETA_1M, V.CAP_4X);
    }

    /// @dev At 1000x, θ must be above 0 and below 10 bp (θ × L < 1e7).
    function test_RevertWhen_ThetaIsZero() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(V.P0, Side.Call, V.L1000, 0, V.CAP_4X);
    }

    function test_RevertWhen_ThetaIsTheExclusiveMaximum() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(V.P0, Side.Call, V.L1000, 10_000, V.CAP_4X);
    }

    /// @dev A 10x units mistake (26.27 bp passed for 2.627 bp) is caught.
    function test_RevertWhen_ThetaIsTenTimesTooLarge() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(V.P0, Side.Call, V.L1000, V.THETA_1M * 10, V.CAP_4X);
    }

    function test_RevertWhen_TheCapIsOneX() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(V.P0, Side.Call, V.L1000, V.THETA_1M, 10_000);
    }

    function test_RevertWhen_TheCapIsAboveFourX() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.lines(V.P0, Side.Call, V.L1000, V.THETA_1M, 40_001);
    }

    function test_RevertWhen_TheEntryPriceIsZero() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.lines(0, Side.Call, V.L1000, V.THETA_1M, V.CAP_4X);
    }

    function test_RevertWhen_TheEntryPriceIsNegative() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.lines(-1, Side.Put, V.L1000, V.THETA_1M, V.CAP_4X);
    }

    /// @dev The checks run in order: with a bad price and bad parameters, the price error wins.
    function test_RevertWhen_PriceAndParametersAreBothBad_ThePriceErrorComesFirst() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.lines(0, Side.Call, V.L1000, 0, 10_000);
    }
}
