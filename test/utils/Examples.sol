// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule} from "../../src/types/StorageTypes.sol";

/// @title Examples
/// @author Manic
/// @notice The shared example values of the test suite, so the worked examples all start from the same numbers: the
///         example entry price $83,884, a $10 stake, θ for one minute, a 4x cap, 1000x, 1 bp of the price, the $500
///         floor, and the launch config.
/// @dev Prices are at exponent -8 (BTC), amounts in 6-decimal token units (USDG).
library Examples {
    /// @notice $83,884 at exponent -8: the example entry price.
    int64 internal constant P0 = 8_388_400_000_000;
    /// @notice $1 at exponent -8.
    int64 internal constant USD = 100_000_000;
    /// @notice A $10 stake (6 decimals).
    uint64 internal constant STAKE = 10_000_000;
    /// @notice θ = 2.627 bp (× 1e7): an example liquidation distance for a one-minute bet.
    uint32 internal constant THETA_1M = 2627;
    /// @notice A 4x payout cap, in bps.
    uint16 internal constant CAP_4X = 40_000;
    /// @notice 1000x, the leverage of BTC's launch market, at which most examples run.
    uint16 internal constant L1000 = 1000;
    /// @notice 1 bp of P0 (P0 / 10_000, exactly): the leverage tests move the price in whole bps of it.
    int64 internal constant BP = 838_840_000;
    /// @notice The $500 launch pool floor (used by the part 2 examples).
    uint64 internal constant FLOOR = 500_000_000;

    /// @notice `dollars` whole tokens in 6-decimal base units.
    function usdc(uint64 dollars) internal pure returns (uint64) {
        return dollars * 1_000_000;
    }

    /// @notice The price `dollars` away from P0.
    function priceAt(int64 dollars) internal pure returns (int64) {
        return P0 + dollars * USD;
    }

    /// @notice The launch config: θ ranges of ±25% around 3.00 / 4.19 / 4.93 / 5.47 / 5.88 bp for bets of 1 to 5
    ///         minutes, and the open gate off. `validate` refuses the gate off (ADR 0009), so a market takes
    ///         `Defaults.marketConfig()`: this config with the gate at 100%.
    function launchConfig() internal pure returns (ConfigParams memory c) {
        c.minStake = 1_000_000;
        c.maxStake = 50_000_000;
        c.floorMinBps = 11_000;
        c.floorMaxBps = 15_000;
        c.capMinBps = 15_000;
        c.capMaxBps = 40_000;
        c.maxSellFeeBps = 600;
        c.entryMaxAgeSecs = 5;
        c.clockSkewSecs = 5;
        c.sellMinDelaySecs = 0;
        c.sellCutoffSecs = 2;
        c.durations[0] = rule(60, 3000);
        c.durations[1] = rule(120, 4190);
        c.durations[2] = rule(180, 4930);
        c.durations[3] = rule(240, 5470);
        c.durations[4] = rule(300, 5880);
        c.maxTotalOwed = type(uint64).max;
        c.maxExposureBps = 0;
    }

    /// @notice A duration rule whose θ range is ±25% around `thetaE7`, rounded down (`thetaE7 * 3 / 4`,
    ///         `thetaE7 * 5 / 4`).
    function rule(uint16 durationSecs, uint32 thetaE7) internal pure returns (DurationRule memory) {
        return DurationRule({
            durationSecs: durationSecs, thetaMinE7: thetaE7 * 3 / 4, thetaMaxE7: thetaE7 * 5 / 4, enabled: true
        });
    }
}
