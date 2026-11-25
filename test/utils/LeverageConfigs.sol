// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule} from "../../src/types/StorageTypes.sol";
import {Defaults} from "./Defaults.sol";

/// @title LeverageConfigs
/// @notice Market settings for leverages other than the launch's 1000x, for the tests that run a market there: the
///         launch config fitted to any leverage, and the 500x and 100x tier settings for BTC.
library LeverageConfigs {
    /// @notice The planned settings of BTC's markets, which the stateful suites start from: 1000x at the launch
    ///         values (`Defaults.marketConfig`), 500x and 100x at the tier settings (`tierConfig`), each with the open
    ///         gate at 100% (ADR 0009), and switched off, as `createMarket` takes them.
    /// @param leverage 1000, 500 or 100.
    /// @return c The settings.
    function planned(uint16 leverage) internal pure returns (ConfigParams memory c) {
        return leverage == Defaults.LEVERAGE ? Defaults.marketConfig() : tierConfig(leverage);
    }

    /// @notice The 500x and 100x tier settings: the launch config with the tier's floors and caps (`tierBounds`), and
    ///         per duration the lines from 15% below the tier's lowest (rounded down) to its highest. The open gate is
    ///         at 100%, as `validate` requires (ADR 0009), and the market switched off.
    /// @param leverage 500 or 100.
    /// @return c The settings.
    function tierConfig(uint16 leverage) internal pure returns (ConfigParams memory c) {
        c = tierBounds(leverage);
        if (leverage == 500) {
            c.durations[0] = _rule(60, 2490, 6750);
            c.durations[1] = _rule(120, 3476, 9430);
            c.durations[2] = _rule(180, 4097, 11_090);
            c.durations[3] = _rule(240, 4547, 10_940);
            c.durations[4] = _rule(300, 4887, 11_760);
        } else {
            c.durations[0] = _rule(60, 2601, 9000);
            c.durations[1] = _rule(120, 3629, 12_570);
            c.durations[2] = _rule(180, 4275, 14_790);
            c.durations[3] = _rule(240, 4743, 16_410);
            c.durations[4] = _rule(300, 5100, 17_640);
        }
    }

    /// @notice The launch config with the tier's floors and caps: at 500x, floors 1.025x to 1.25x and caps 1.5x to
    ///         2.5x; at 100x, floors 1.005x to 1.05x and caps 1.5x to 2x.
    /// @param leverage 500 or 100.
    /// @return c The settings.
    function tierBounds(uint16 leverage) internal pure returns (ConfigParams memory c) {
        require(leverage == 500 || leverage == 100, "only the 500x and 100x tiers");
        c = Defaults.marketConfig();
        (c.floorMinBps, c.floorMaxBps, c.capMinBps, c.capMaxBps) = leverage == 500
            ? (uint16(10_250), uint16(12_500), uint16(15_000), uint16(25_000))
            : (uint16(10_050), uint16(10_500), uint16(15_000), uint16(20_000));
    }

    /// @notice The launch config fitted to `leverage`, so `validate` accepts it there: each rule's θ range scaled by
    ///         1000 / L, which keeps its lines as far inside the limit (θ × L < 1e7) as at 1000x, and below 4x the
    ///         highest cap lowered to the highest a short can reach ((L + 1)x less 1 bp). At 1000x it is the launch
    ///         config itself. Out of range (0x, or above 10,000x) it stays the launch config.
    /// @param leverage The market's leverage.
    /// @return c The settings, with the open gate at 100%, as `validate` requires (ADR 0009), and switched off.
    function launchAt(uint16 leverage) internal pure returns (ConfigParams memory c) {
        c = Defaults.marketConfig();
        if (leverage == 0 || leverage > 10_000) return c;
        for (uint256 i; i < c.durations.length; ++i) {
            c.durations[i].thetaMinE7 = _scaled(c.durations[i].thetaMinE7, leverage);
            c.durations[i].thetaMaxE7 = _scaled(c.durations[i].thetaMaxE7, leverage);
        }
        uint256 highestReachable = (uint256(leverage) + 1) * 10_000 - 1;
        if (highestReachable < c.capMaxBps) c.capMaxBps = uint16(highestReachable);
    }

    /// @dev An enabled duration rule.
    function _rule(
        uint16 durationSecs,
        uint32 thetaMinE7,
        uint32 thetaMaxE7
    )
        private
        pure
        returns (DurationRule memory)
    {
        return DurationRule(durationSecs, thetaMinE7, thetaMaxE7, true); // in field order
    }

    /// @dev `thetaE7` × 1000 / `leverage`, rounded down, and at least 1 (a line of 0 is refused).
    function _scaled(uint32 thetaE7, uint16 leverage) private pure returns (uint32) {
        uint256 scaled = uint256(thetaE7) * 1000 / leverage;
        // casting to uint32 is safe: θ is at most 7,350 here, so the scaled line is at most 7,350,000
        return scaled == 0 ? 1 : uint32(scaled);
    }
}
