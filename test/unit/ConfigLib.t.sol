// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {IManicFlashOptionErrors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule} from "../../src/types/StorageTypes.sol";
import {ConfigLibHarness} from "../harnesses/ConfigLibHarness.sol";
import {Examples} from "../utils/Examples.sol";

/// @title ConfigLib_Unit_Test
/// @notice `ConfigLib.validate`, which checks a market's settings, and `ConfigLib.validateOpen`, which checks a bet's
///         terms against them: each bound at its edge and one step past it, and `validate` at the market's leverage,
///         from 1x to 10,000x.
/// @dev The `validate` tests change one field of the launch config and ask whether it is still accepted; `_accepts`
///      does so at 1000x, `_acceptsAt` at any leverage, and both assert that every rejection is
///      `InvalidLeverageParams`. The `validateOpen` tests change one field of the base terms (a $10 one-minute bet at
///      θ 3.00 bp, floor 1.3x, cap 4x) against the launch config, and `_openError` returns the error each gets.
contract ConfigLib_Unit_Test is Test {
    ConfigLibHarness internal lib;

    /// @dev The terms of a bet that `validateOpen` checks.
    struct Terms {
        uint64 stake;
        uint16 durationSecs;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
    }

    function setUp() public {
        lib = new ConfigLibHarness();
        lib.setMarket(_launch());
    }

    function test_ValidateAcceptsTheLaunchValues() public view {
        assertTrue(_accepts(_launch()));
    }

    /// @dev The minimum stake must be above 0 and at most the maximum.
    function test_ValidateStakeBounds() public view {
        ConfigParams memory c = _launch();
        c.minStake = 0;
        assertFalse(_accepts(c), "a zero minimum stake");
        c = _launch();
        c.minStake = c.maxStake + 1;
        assertFalse(_accepts(c), "a minimum above the maximum");
        c = _launch();
        c.minStake = c.maxStake;
        assertTrue(_accepts(c), "minimum = maximum");
    }

    /// @dev The lowest floor must be above 1x and at most the highest: exactly 1x is not a floor.
    function test_ValidateFloorBounds() public view {
        ConfigParams memory c = _launch();
        c.floorMinBps = 10_000;
        assertFalse(_accepts(c), "a floor of exactly 1x");
        c = _launch();
        c.floorMinBps = 10_001;
        assertTrue(_accepts(c), "a floor just above 1x");
        c = _launch();
        c.floorMinBps = c.floorMaxBps + 1;
        assertFalse(_accepts(c), "a minimum floor above the maximum");
        c = _launch();
        c.floorMinBps = c.floorMaxBps;
        assertTrue(_accepts(c), "minimum floor = maximum");
    }

    /// @dev The caps must be above 1x and at most 4x, the lowest at most the highest, and the highest floor must fit
    ///      under the highest cap.
    function test_ValidateCapBounds() public view {
        ConfigParams memory c = _launch();
        c.capMinBps = 10_000;
        assertFalse(_accepts(c), "a cap of exactly 1x");
        c = _launch();
        c.capMinBps = c.capMaxBps + 1;
        assertFalse(_accepts(c), "a minimum cap above the maximum");
        c = _launch();
        c.capMinBps = c.capMaxBps;
        assertTrue(_accepts(c), "minimum cap = maximum");
        c = _launch();
        c.capMaxBps = 40_001;
        assertFalse(_accepts(c), "a cap above 4x");
        c = _launch();
        c.capMinBps = 12_000;
        c.capMaxBps = 14_000;
        assertFalse(_accepts(c), "the highest floor (1.5x) above the highest cap (1.4x)");
        c.floorMaxBps = 14_000;
        assertTrue(_accepts(c), "the highest floor at the highest cap");
    }

    /// @dev The cap on the early-sell fee is at most 100%.
    function test_ValidateSellFeeBound() public view {
        ConfigParams memory c = _launch();
        c.maxSellFeeBps = 10_001;
        assertFalse(_accepts(c), "a sell fee above 100%");
        c.maxSellFeeBps = 10_000;
        assertTrue(_accepts(c), "a sell fee of 100%");
    }

    /// @dev Each rule's θ range must be above 0 and below 10 bp at 1000x, its minimum at most its maximum, and no
    ///      duration may repeat. A disabled rule is still checked, and an unused slot must be empty.
    function test_ValidateDurationRules() public view {
        ConfigParams memory c = _launch();
        c.durations[0].thetaMinE7 = 0;
        assertFalse(_accepts(c), "a zero theta minimum");
        c = _launch();
        c.durations[0].thetaMaxE7 = 10_000;
        assertFalse(_accepts(c), "a theta maximum of 10 bp");
        c = _launch();
        c.durations[0].thetaMaxE7 = 9999;
        assertTrue(_accepts(c), "a theta maximum just under 10 bp");
        c = _launch();
        c.durations[0].thetaMaxE7 = 30_000;
        assertFalse(_accepts(c), "a 10x units mistake");
        c = _launch();
        c.durations[0].thetaMinE7 = c.durations[0].thetaMaxE7 + 1;
        assertFalse(_accepts(c), "a theta minimum above the maximum");
        c = _launch();
        c.durations[1].durationSecs = 60;
        assertFalse(_accepts(c), "a duplicate duration");
        c = _launch();
        c.durations[2].enabled = false;
        c.durations[2].thetaMinE7 = 0;
        assertFalse(_accepts(c), "a disabled rule is still checked");
        c = _launch();
        c.durations[4] = DurationRule({durationSecs: 0, thetaMinE7: 0, thetaMaxE7: 0, enabled: false});
        assertTrue(_accepts(c), "an empty unused slot");
        c.durations[4].enabled = true;
        assertFalse(_accepts(c), "an unused slot switched on");
        c.durations[4].enabled = false;
        c.durations[4].thetaMaxE7 = 1;
        assertFalse(_accepts(c), "an unused slot with a theta");
    }

    /// @dev A market that accepts no price age could never open a bet.
    function test_ValidateNeedsAPriceAgeAboveZero() public view {
        ConfigParams memory c = _launch();
        c.entryMaxAgeSecs = 0;
        assertFalse(_accepts(c), "no price age");
        c.entryMaxAgeSecs = 1;
        assertTrue(_accepts(c), "one second");
    }

    /// @dev The open gate must be on, at 1 bp to 100% of free money (ADR 0009). Off (0) or above 100%, bets could
    ///      promise more than the pool holds.
    function test_ValidateNeedsTheOpenGateOnAtMost100Percent() public view {
        ConfigParams memory c = _launch();
        c.maxExposureBps = 0;
        assertFalse(_accepts(c), "the gate off");
        c.maxExposureBps = 1;
        assertTrue(_accepts(c), "1 bp");
        c.maxExposureBps = 10_000;
        assertTrue(_accepts(c), "100%");
        c.maxExposureBps = 10_001;
        assertFalse(_accepts(c), "just over 100%");
        c.maxExposureBps = type(uint32).max;
        assertFalse(_accepts(c), "the largest");
    }

    /// @dev A clock skew of at most 30 seconds (ADR 0009), so no bet can be settled more than 30 seconds early.
    function test_ValidateBoundsTheClockSkewAt30Seconds() public view {
        ConfigParams memory c = _launch();
        c.clockSkewSecs = 0;
        assertTrue(_accepts(c), "none");
        c.clockSkewSecs = 30;
        assertTrue(_accepts(c), "30 seconds");
        c.clockSkewSecs = 31;
        assertFalse(_accepts(c), "31 seconds");
        c.clockSkewSecs = type(uint8).max;
        assertFalse(_accepts(c), "255 seconds");
    }

    /// @dev The sell window, the owed limit and `enabled` have no bounds: any value passes.
    function test_ValidateLeavesTheSellWindowAndTheOwedLimitUnbounded() public view {
        ConfigParams memory c = _launch();
        c.sellMinDelaySecs = type(uint16).max;
        c.sellCutoffSecs = type(uint16).max;
        c.maxTotalOwed = 0;
        c.enabled = true;
        assertTrue(_accepts(c));
    }

    function test_ValidateOpenAcceptsTheBaseTerms() public view {
        assertEq(_openError(_base()), bytes4(0));
    }

    /// @dev The stake must be within the market's bounds, $1 to $50. A zero stake is below every minimum.
    function test_ValidateOpenStakeBounds() public view {
        Terms memory t = _base();
        t.stake = 1_000_000;
        assertEq(_openError(t), bytes4(0), "the minimum stake");
        t.stake = 50_000_000;
        assertEq(_openError(t), bytes4(0), "the maximum stake");
        t.stake = 999_999;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidAmount.selector, "below the minimum");
        t.stake = 50_000_001;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidAmount.selector, "above the maximum");
        t.stake = 0;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidAmount.selector, "zero");
    }

    /// @dev The duration needs an enabled rule. An unused slot (all zero) never matches, even for a zero duration.
    function test_ValidateOpenNeedsAnEnabledDurationRule() public {
        Terms memory t = _base();
        t.durationSecs = 300;
        t.thetaE7 = 5880;
        assertEq(_openError(t), bytes4(0), "five minutes, at its own theta");
        t = _base();
        t.durationSecs = 90;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "a duration with no rule");
        t.durationSecs = 0;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "a zero duration");

        ConfigParams memory c = _launch();
        c.durations[4].enabled = false;
        lib.setMarket(c);
        t = _base();
        t.durationSecs = 300;
        t.thetaE7 = 5880;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "a disabled rule");
        c.durations[4] = DurationRule({durationSecs: 0, thetaMinE7: 0, thetaMaxE7: 0, enabled: false});
        lib.setMarket(c);
        t.durationSecs = 0;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "an unused slot");
    }

    /// @dev θ must be within its duration's rule. The one-minute rule allows 2,250 to 3,750 (±25% around 3,000), and
    ///      another duration's theta isn't accepted for it.
    function test_ValidateOpenThetaWithinTheRule() public view {
        Terms memory t = _base();
        t.thetaE7 = 2250;
        assertEq(_openError(t), bytes4(0), "the narrowest");
        t.thetaE7 = 3750;
        assertEq(_openError(t), bytes4(0), "the widest");
        t.thetaE7 = 2249;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "too narrow");
        t.thetaE7 = 3751;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "too wide");
        t.thetaE7 = 5880;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "five minutes' theta");
    }

    /// @dev The floor must be within the market's floors, 1.1x to 1.5x.
    function test_ValidateOpenFloorBounds() public view {
        Terms memory t = _base();
        t.floorBps = 11_000;
        assertEq(_openError(t), bytes4(0), "the lowest floor");
        t.floorBps = 15_000;
        assertEq(_openError(t), bytes4(0), "the highest floor");
        t.floorBps = 10_999;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "below");
        t.floorBps = 15_001;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "above");
    }

    /// @dev The cap must be at least the 1.5x cap minimum and at most the maximum; and when the cap minimum is below
    ///      the floor, the floor is the lower bound.
    function test_ValidateOpenCapBounds() public {
        Terms memory t = _base();
        t.capBps = 15_000;
        assertEq(_openError(t), bytes4(0), "the lowest cap");
        t.capBps = 40_000;
        assertEq(_openError(t), bytes4(0), "the highest cap");
        t.capBps = 14_999;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "below the minimum");
        t.capBps = 40_001;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "above the maximum");

        ConfigParams memory c = _launch();
        c.capMinBps = 12_000;
        lib.setMarket(c);
        t.capBps = 13_000;
        assertEq(_openError(t), bytes4(0), "the floor (1.3x) as the bound");
        t.capBps = 12_999;
        assertEq(_openError(t), IManicFlashOptionErrors.InvalidLeverageParams.selector, "below the floor");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // validate at the market's leverage
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The leverage must be 1x to 10,000x.
    function test_ValidateTheLeverageIs1xTo10000x() public view {
        assertTrue(_acceptsAt(_atLeverage(999), 1), "1x");
        assertTrue(_acceptsAt(_atLeverage(999), 10_000), "10,000x");
        uint16[3] memory bad = [uint16(0), 10_001, type(uint16).max];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(_acceptsAt(_atLeverage(1), bad[i]), "a leverage outside 1x to 10,000x");
        }
    }

    /// @dev The widest line each leverage allows is the largest θ with θ × L < 1e7. One rule past the limit is
    ///      enough, even a disabled one.
    function test_ValidateTheLineLimitFollowsTheLeverage() public view {
        uint16[5] memory leverages = [uint16(1), 100, 500, 1000, 10_000];
        uint32[5] memory widest = [uint32(9_999_999), 99_999, 19_999, 9999, 999];
        for (uint256 i; i < leverages.length; ++i) {
            assertTrue(_acceptsAt(_atLeverage(widest[i]), leverages[i]), "the widest line");
            assertFalse(_acceptsAt(_atLeverage(widest[i] + 1), leverages[i]), "one unit wider");
            ConfigParams memory c = _atLeverage(widest[i]);
            c.durations[3].enabled = false;
            c.durations[3].thetaMaxE7 = widest[i] + 1;
            assertFalse(_acceptsAt(c, leverages[i]), "one disabled rule one unit wider");
        }
        assertFalse(_acceptsAt(_atLeverage(19_999), 1000), "500x's widest line is too wide for 1000x");
    }

    /// @dev A short must be able to reach the highest cap: cap − 1x < leverage. 1x allows caps under 2x, 2x under 3x
    ///      and 3x under 4x. From 4x every cap up to the 4x ceiling passes.
    function test_ValidateAShortMustReachTheHighestCap() public view {
        uint16[3] memory leverages = [uint16(1), 2, 3];
        uint16[3] memory highest = [uint16(19_999), 29_999, 39_999];
        for (uint256 i; i < leverages.length; ++i) {
            ConfigParams memory c = _atLeverage(999);
            c.capMaxBps = highest[i];
            assertTrue(_acceptsAt(c, leverages[i]), "the highest reachable cap");
            c.capMaxBps = highest[i] + 1;
            assertFalse(_acceptsAt(c, leverages[i]), "one bp higher");
        }
        ConfigParams memory atFourX = _atLeverage(999);
        atFourX.capMaxBps = 40_000;
        assertTrue(_acceptsAt(atFourX, 4), "4x reaches the 4x ceiling");
    }

    /// @dev The 100x and 500x tier settings, each duration's lowest line 15% below the tier's: both pass, and the 500x
    ///      lines don't fit 1000x.
    function test_ValidateAcceptsThe100xAnd500xConfigs() public view {
        ConfigParams memory x100 = _launch();
        (x100.floorMinBps, x100.floorMaxBps, x100.capMinBps, x100.capMaxBps) = (10_050, 10_500, 15_000, 20_000);
        x100.durations[0] = _rule(60, 2601, 9000);
        x100.durations[1] = _rule(120, 3629, 12_570);
        x100.durations[2] = _rule(180, 4275, 14_790);
        x100.durations[3] = _rule(240, 4743, 16_410);
        x100.durations[4] = _rule(300, 5100, 17_640);
        assertTrue(_acceptsAt(x100, 100), "100x");

        ConfigParams memory x500 = _launch();
        (x500.floorMinBps, x500.floorMaxBps, x500.capMinBps, x500.capMaxBps) = (10_250, 12_500, 15_000, 25_000);
        for (uint256 i; i < x500.durations.length; ++i) {
            x500.durations[i] = _rule(uint16(60 * (i + 1)), 2490, 11_760);
        }
        assertTrue(_acceptsAt(x500, 500), "500x");
        assertFalse(_acceptsAt(x500, 1000), "the 500x lines at 1000x");
    }

    /// @dev The launch config with every duration's θ range set to 1 to `thetaMaxE7`, and a cap every leverage can
    ///      reach (just under 2x).
    function _atLeverage(uint32 thetaMaxE7) internal pure returns (ConfigParams memory c) {
        c = _launch();
        c.capMaxBps = 19_999;
        for (uint256 i; i < c.durations.length; ++i) {
            c.durations[i].thetaMinE7 = 1;
            c.durations[i].thetaMaxE7 = thetaMaxE7;
        }
    }

    /// @dev An enabled duration rule.
    function _rule(
        uint16 durationSecs,
        uint32 thetaMinE7,
        uint32 thetaMaxE7
    )
        internal
        pure
        returns (DurationRule memory)
    {
        return DurationRule(durationSecs, thetaMinE7, thetaMaxE7, true); // in field order
    }

    /// @dev The launch config (`Examples.launchConfig`) with the open gate at 100%, as `validate` requires (ADR 0009);
    ///      `Defaults.marketConfig` is the same config.
    function _launch() internal pure returns (ConfigParams memory c) {
        c = Examples.launchConfig();
        c.maxExposureBps = 10_000;
    }

    /// @dev The base terms: a $10 one-minute bet at θ 3.00 bp, floor 1.3x, cap 4x.
    function _base() internal pure returns (Terms memory) {
        return Terms({stake: 10_000_000, durationSecs: 60, thetaE7: 3000, floorBps: 13_000, capBps: 40_000});
    }

    /// @dev The error `validateOpen` gives `t` on the harness's market, or none.
    function _openError(Terms memory t) internal view returns (bytes4) {
        try lib.validateOpen(t.stake, t.durationSecs, t.thetaE7, t.floorBps, t.capBps) {
            return bytes4(0);
        } catch (bytes memory reason) {
            return bytes4(reason);
        }
    }

    /// @dev Whether `validate` accepts `c` at 1000x, the leverage of most examples.
    function _accepts(ConfigParams memory c) internal view returns (bool) {
        return _acceptsAt(c, Examples.L1000);
    }

    /// @dev Whether `validate` accepts `c` at `leverage`; every rejection must be `InvalidLeverageParams`.
    function _acceptsAt(ConfigParams memory c, uint16 leverage) internal view returns (bool) {
        try lib.validate(c, leverage) {
            return true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IManicFlashOptionErrors.InvalidLeverageParams.selector, "another error");
            return false;
        }
    }
}
