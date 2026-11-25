// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors} from "../interfaces/IManicFlashOptionErrors.sol";
import {ConfigParams} from "../types/ParamTypes.sol";
import {DurationRule, Market} from "../types/StorageTypes.sol";
import {LeverageMath} from "./LeverageMath.sol";

/// @title ConfigLib
/// @author Manic
/// @notice The checks on a market's settings, and on each new bet's terms against them. `validate` checks the
///         settings at the market's leverage.
/// @dev `validate` runs in `createMarket` and `setConfig` before anything is stored. `validateOpen` checks each new
///      bet's terms against the stored settings.
/// @custom:security-contact See SECURITY.md
library ConfigLib {
    /// @notice The widest clock skew `validate` accepts, in seconds (ADR 0009): 6 times the launch value (5) and half
    ///         the shortest bet (60). A skew lets a tick be that far ahead of the chain's clock, so a bet can be
    ///         settled that early; a lower one only delays opens and settles while the chain's clock lags.
    uint8 internal constant MAX_CLOCK_SKEW_SECS = 30;

    /// @notice Reverts unless a new bet's terms fit its market's settings.
    /// @dev The checks, in this order:
    ///      - minStake ≤ stake ≤ maxStake (`InvalidAmount`);
    ///      - the duration is an enabled rule's (`InvalidLeverageParams`). `validate` keeps an unused rule all zero, so
    ///        it is never enabled and never matches, not even a zero duration;
    ///      - that rule's thetaMinE7 ≤ thetaE7 ≤ thetaMaxE7 (`InvalidLeverageParams`);
    ///      - floorMinBps ≤ floorBps ≤ floorMaxBps (`InvalidLeverageParams`);
    ///      - max(capMinBps, floorBps) ≤ capBps ≤ capMaxBps (`InvalidLeverageParams`): a right call must be able to
    ///        pay at least the floor.
    /// @param m The market's settings, as stored.
    /// @param stake The margin, in base units.
    /// @param durationSecs The bet's length.
    /// @param thetaE7 The liquidation distance θ × 1e7.
    /// @param floorBps The least a right call pays, in bps of the stake.
    /// @param capBps The most the bet pays, in bps of the stake.
    function validateOpen(
        Market storage m,
        uint64 stake,
        uint16 durationSecs,
        uint32 thetaE7,
        uint16 floorBps,
        uint16 capBps
    )
        internal
        view
    {
        if (stake < m.minStake || stake > m.maxStake) revert IManicFlashOptionErrors.InvalidAmount();
        DurationRule storage rule = enabledRule(m, durationSecs);
        if (thetaE7 < rule.thetaMinE7 || thetaE7 > rule.thetaMaxE7) {
            revert IManicFlashOptionErrors.InvalidLeverageParams();
        }
        if (floorBps < m.floorMinBps || floorBps > m.floorMaxBps) {
            revert IManicFlashOptionErrors.InvalidLeverageParams();
        }
        uint16 capMinBps = m.capMinBps > floorBps ? m.capMinBps : floorBps;
        if (capBps < capMinBps || capBps > m.capMaxBps) revert IManicFlashOptionErrors.InvalidLeverageParams();
    }

    /// @notice Reverts `InvalidLeverageParams` unless every bound in `p` is consistent at the market's leverage.
    /// @dev The checks, in this order:
    ///      - the leverage is 1x to 10,000x (`LeverageMath.leverageAllowed`);
    ///      - 0 < minStake ≤ maxStake;
    ///      - 10_000 < floorMinBps ≤ floorMaxBps: a floor must pay back more than the stake;
    ///      - 10_000 < capMinBps ≤ capMaxBps ≤ 40_000, and floorMaxBps ≤ capMaxBps: every floor fits under a cap;
    ///        and a short can reach the highest cap (`LeverageMath.capReachable`), which only binds below 4x;
    ///      - maxSellFeeBps ≤ 10_000: an early-sell fee can never take more than the valuation;
    ///      - each duration rule is either all zero (an unused slot), or has 0 < thetaMinE7 ≤ thetaMaxE7, a widest
    ///        line below 1/leverage (`LeverageMath.thetaWithinLimit`: under 10 bp at 1000x, 20 bp at 500x, 100 bp
    ///        at 100x), and a duration no earlier rule has. A disabled rule is still checked, so it can be switched
    ///        on later safely.
    ///      Then three more bounds, last (`withinEvmBounds`):
    ///      - entryMaxAgeSecs > 0: a market accepting no price age could never open a bet;
    ///      - 0 < maxExposureBps ≤ 10_000: the open gate is on, at 100% of free money at most. Then free money
    ///        always covers the open bets' max profit, so an IOU can't form (docs/ARCHITECTURE.md §12, invariant 5).
    ///        Only an upgrade could switch the gate off (0) or set it above 100%;
    ///      - clockSkewSecs ≤ `MAX_CLOCK_SKEW_SECS`, so no bet can be settled more than 30 seconds early.
    ///      The last two keep a leaked operator key, which acts at once, from loosening what pays out (ADR 0009).
    ///      The sell window, the owed limit (`maxTotalOwed`) and `enabled` are left unbounded. Every refusal is the
    ///      same error, so the order only matters for gas.
    /// @param p The settings to check.
    /// @param leverage The market's leverage L.
    function validate(ConfigParams calldata p, uint16 leverage) internal pure {
        if (!LeverageMath.leverageAllowed(leverage)) revert IManicFlashOptionErrors.InvalidLeverageParams();
        if (p.minStake == 0 || p.minStake > p.maxStake) revert IManicFlashOptionErrors.InvalidLeverageParams();
        if (p.floorMinBps <= LeverageMath.BPS || p.floorMinBps > p.floorMaxBps) {
            revert IManicFlashOptionErrors.InvalidLeverageParams();
        }
        if (
            p.capMinBps <= LeverageMath.BPS || p.capMinBps > p.capMaxBps
                || p.capMaxBps > LeverageMath.MAX_LEVERAGE_CAP_BPS || p.floorMaxBps > p.capMaxBps
                || !LeverageMath.capReachable(p.capMaxBps, leverage)
        ) revert IManicFlashOptionErrors.InvalidLeverageParams();
        if (p.maxSellFeeBps > LeverageMath.BPS) revert IManicFlashOptionErrors.InvalidLeverageParams();
        for (uint256 i; i < p.durations.length; ++i) {
            // A setting that is wrong anywhere rejects the whole config; reverting inside the loop is the point.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (!isValidRule(p.durations, i, leverage)) revert IManicFlashOptionErrors.InvalidLeverageParams();
        }
        if (!withinEvmBounds(p)) revert IManicFlashOptionErrors.InvalidLeverageParams();
    }

    /// @notice The market's enabled duration rule for `durationSecs`.
    /// @dev Reverts `InvalidLeverageParams` when there is none. `validate` allows no two rules with the same duration,
    ///      so the first match is the only one.
    /// @param m The market's settings.
    /// @param durationSecs The bet's length.
    /// @return The matching rule.
    function enabledRule(Market storage m, uint16 durationSecs) private view returns (DurationRule storage) {
        for (uint256 i; i < m.durations.length; ++i) {
            DurationRule storage rule = m.durations[i];
            if (rule.enabled && rule.durationSecs == durationSecs) return rule;
        }
        revert IManicFlashOptionErrors.InvalidLeverageParams();
    }

    /// @notice Whether duration rule `i` is valid: all zero if unused, otherwise a θ range above 0 and below
    ///         1/leverage, and a duration no earlier rule has.
    /// @param rules The market's five duration rules.
    /// @param i The rule to check.
    /// @param leverage The market's leverage, which sets the widest line.
    /// @return Whether the rule is valid.
    function isValidRule(DurationRule[5] calldata rules, uint256 i, uint16 leverage) private pure returns (bool) {
        DurationRule calldata rule = rules[i];
        if (rule.durationSecs == 0) return rule.thetaMinE7 == 0 && rule.thetaMaxE7 == 0 && !rule.enabled;
        if (
            rule.thetaMinE7 == 0 || rule.thetaMinE7 > rule.thetaMaxE7
                || !LeverageMath.thetaWithinLimit(rule.thetaMaxE7, leverage)
        ) return false;
        for (uint256 j; j < i; ++j) {
            if (rules[j].durationSecs == rule.durationSecs) return false;
        }
        return true;
    }

    /// @notice Whether `p` passes the three bounds `validate` checks last: a price age above 0, the open gate on at
    ///         100% at most, and a clock skew of at most `MAX_CLOCK_SKEW_SECS` (ADR 0009).
    /// @param p The settings to check.
    /// @return Whether all three hold.
    function withinEvmBounds(ConfigParams calldata p) private pure returns (bool) {
        return p.entryMaxAgeSecs > 0 && p.maxExposureBps > 0 && p.maxExposureBps <= LeverageMath.BPS
            && p.clockSkewSecs <= MAX_CLOCK_SKEW_SECS;
    }
}
