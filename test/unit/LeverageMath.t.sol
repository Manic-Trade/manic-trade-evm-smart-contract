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

/// @notice `gBps` and `payout` together: what a position pays at expiry.
contract GBps_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev +$8 at expiry: R = floor(8e8 × 1e7 / P0) = 953, so g = 10,953 (1.0953x), below each floor here. A win pays
    ///      at least the floor: $11 / $14 / $15 on $10 at 1.1x / 1.4x / 1.5x.
    function test_ASmallWinPaysTheFloor() public view {
        uint16[3] memory floors = [uint16(11_000), 14_000, 15_000];
        uint64[3] memory wants = [uint64(11_000_000), 14_000_000, 15_000_000];
        for (uint256 i; i < floors.length; ++i) {
            uint16 g = math.gBps(V.P0, V.priceAt(8), Side.Call, V.L1000, floors[i], V.CAP_4X);
            assertEq(math.payout(V.STAKE, g), wants[i]);
        }
    }

    /// @dev $10 at a 1.3x floor: +$84 is R = 10,013, so g = 2.0013x and $20.013; +$252 is R = 30,041, capped at 4x
    ///      ($40); -$8 is R = -954, so g = 0.9046x and $9.046; flat pays the stake back.
    function test_PayoutsAcrossThePriceRange() public view {
        assertEq(_payAt13(V.priceAt(84)), 20_013_000, "+$84 pays $20.013");
        assertEq(_payAt13(V.priceAt(252)), 40_000_000, ">= +$252 pays the $40 cap");
        assertEq(_payAt13(V.priceAt(-8)), 9_046_000, "-$8 pays $9.046");
        assertEq(_payAt13(V.P0), V.STAKE, "flat pays the stake back");
    }

    /// @dev Why `floorDiv` matters: -$8 on $83,884 is a move of -953.69 in R_e7 units. Floored it is -954, so the
    ///      multiple is 9_046 and the payout $9.046. Rounding toward zero would give 9_047 and pay $0.001 more.
    function test_ALosingMoveRoundsDownNotTowardZero() public view {
        assertEq(math.gBps(V.P0, V.priceAt(-8), Side.Call, V.L1000, 13_000, V.CAP_4X), 9046);
    }

    /// @dev For a short, -$8 is R = +953, a win below the 1.4x floor, so it pays the floor; +$8 is R = -954, 0.9046x.
    function test_AShortWinsWhenThePriceFalls() public view {
        assertEq(math.gBps(V.P0, V.priceAt(-8), Side.Put, V.L1000, 14_000, V.CAP_4X), 14_000);
        assertEq(math.gBps(V.P0, V.priceAt(8), Side.Put, V.L1000, 14_000, V.CAP_4X), 9046);
    }

    /// @dev Over a grid of caps (1.5x, 2.5x, 4x), floors (1.1x, 1.5x) and moves (-$1,000 to +$100,000), g never passes
    ///      the cap, and the payout never passes the stake plus the max profit.
    function test_ThePayoutIsCappedAndNeverAboveStakePlusMaxProfit() public view {
        uint16[3] memory caps = [uint16(15_000), 25_000, V.CAP_4X];
        uint16[2] memory floors = [uint16(11_000), 15_000];
        int64[9] memory moves = [int64(-1000), -10, -1, 0, 1, 10, 100, 1000, 100_000];
        for (uint256 c; c < caps.length; ++c) {
            for (uint256 f; f < floors.length; ++f) {
                if (floors[f] > caps[c]) continue;
                for (uint256 m; m < moves.length; ++m) {
                    uint16 g = math.gBps(V.P0, V.priceAt(moves[m]), Side.Call, V.L1000, floors[f], caps[c]);
                    assertLe(g, caps[c], "never above the cap");
                    uint64 paid = math.payout(V.STAKE, g);
                    assertLe(paid, V.STAKE + math.maxProfit(V.STAKE, caps[c]), "never above stake + max profit");
                }
            }
        }
    }

    /// @dev A price far past the line clamps at 0: half the entry is R = -5,000,000 for a long.
    function test_APriceFarPastTheLineClampsToZero() public view {
        assertEq(math.gBps(V.P0, V.P0 / 2, Side.Call, V.L1000, 11_000, V.CAP_4X), 0);
    }

    /// @dev 256-bit maths can't overflow on any int64 price.
    function test_HugePricesDoNotOverflow() public view {
        int64 big = type(int64).max / 2;
        assertEq(math.gBps(big, big / 3, Side.Put, V.L1000, 15_000, V.CAP_4X), V.CAP_4X, "a huge win is capped");
    }

    /// @dev Both prices must be positive.
    function test_RevertWhen_TheEntryPriceIsZero() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.gBps(0, V.P0, Side.Call, V.L1000, 11_000, V.CAP_4X);
    }

    function test_RevertWhen_ThePriceIsNegative() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidPrice.selector);
        math.gBps(V.P0, -1, Side.Put, V.L1000, 11_000, V.CAP_4X);
    }

    function _payAt13(int64 price) internal view returns (uint64) {
        return math.payout(V.STAKE, math.gBps(V.P0, price, Side.Call, V.L1000, 13_000, V.CAP_4X));
    }
}

/// @notice `payout` on its own: rounding and overflow.
contract Payout_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    function test_OneXPaysTheStakeBack() public view {
        assertEq(math.payout(V.STAKE, 10_000), V.STAKE);
    }

    function test_RoundsDownInThePoolsFavour() public view {
        assertEq(math.payout(1, 9999), 0, "0.9999 base units rounds down to 0");
        assertEq(math.payout(3, 13_333), 3, "3.9999 rounds down to 3");
    }

    /// @dev The largest stake whose 4x payout still fits a `uint64`.
    function test_TheLargestFourXPayoutThatFits() public view {
        uint64 stake = type(uint64).max / 4;
        assertEq(math.payout(stake, V.CAP_4X), stake * 4);
    }

    /// @dev A 4x payout on the largest stake doesn't fit a `uint64`: an error, never a wrap.
    function test_RevertWhen_ThePayoutDoesNotFitUint64() public {
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        math.payout(type(uint64).max, V.CAP_4X);
    }
}

/// @notice `maxProfit`: the exposure a position adds to the pool.
contract MaxProfit_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev The max profit is the stake × (cap − 1x): $30 on $10 at 4x, $5 at 1.5x, and 0 at 1x.
    function test_FollowsTheCap() public view {
        assertEq(math.maxProfit(V.STAKE, V.CAP_4X), V.usdc(30), "4x: up to $30 profit on $10");
        assertEq(math.maxProfit(V.STAKE, 15_000), V.usdc(5));
        assertEq(math.maxProfit(V.STAKE, 10_000), 0, "a 1x cap is allowed here and has no profit");
    }

    function test_RevertWhen_TheCapIsBelowOneX() public {
        vm.expectRevert(IManicFlashOptionErrors.InvalidLeverageParams.selector);
        math.maxProfit(V.STAKE, 9999);
    }

    function test_RevertWhen_TheMaxProfitDoesNotFitUint64() public {
        vm.expectRevert(IManicFlashOptionErrors.MathOverflow.selector);
        math.maxProfit(type(uint64).max, V.CAP_4X);
    }
}

/// @notice `touched`: equality counts on both sides.
contract Touched_LeverageMath_Unit_Test is LeverageMath_Unit_Shared_Test {
    /// @dev A price exactly on the line touches it; one price unit on the safe side doesn't.
    function test_EqualityCountsAndOneUnitAwayDoesNot() public view {
        (int64 shortLiq,) = math.lines(V.P0, Side.Put, V.L1000, V.THETA_1M, V.CAP_4X);
        assertTrue(math.touched(shortLiq, shortLiq, Side.Put), "a short is touched at its line");
        assertFalse(math.touched(shortLiq - 1, shortLiq, Side.Put), "one unit below a short's line is safe");

        (int64 longLiq,) = math.lines(V.P0, Side.Call, V.L1000, V.THETA_1M, V.CAP_4X);
        assertTrue(math.touched(longLiq, longLiq, Side.Call), "a long is touched at its line");
        assertFalse(math.touched(longLiq + 1, longLiq, Side.Call), "one unit above a long's line is safe");
    }

    function test_BeyondTheLineIsTouched() public view {
        assertTrue(math.touched(V.P0 / 2, V.P0, Side.Call));
        assertTrue(math.touched(V.P0 * 2, V.P0, Side.Put));
    }
}
