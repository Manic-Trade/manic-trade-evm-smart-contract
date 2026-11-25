// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule} from "../../src/types/StorageTypes.sol";

/// @title MarketSettings
/// @notice The settings Configure.s.sol gives BTC's markets: the values the tests run, at each leverage they plan.
///         - 1000x: the launch config, with the open gate at 100%.
///         - 500x and 100x: the tier floors, caps and lines, with the rest as at 1000x.
///         test/script/Inputs.t.sol proves each equals the tests' `LeverageConfigs.planned`, field by field, so what
///         is deployed is what was tested. A change here must change the tests' values too.
/// @dev Every market is created switched off (`enabled` false), as `createMarket` requires; Configure.s.sol switches
///      on the ones chains.toml lists.
library MarketSettings {
    /// @notice Pyth's BTC/USD feed id, used as BTC's market id.
    bytes32 internal constant BTC = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    /// @notice The exponent of Pyth's BTC/USD prices: a price of 9_500_000_000_000 is $95,000.
    int8 internal constant BTC_PRICE_EXPONENT = -8;

    /// @notice BTC's settings at `leverage`, switched off.
    /// @param leverage 1000, 500 or 100; any other leverage reverts, since no settings were tested there.
    /// @return c The settings.
    function btc(uint16 leverage) internal pure returns (ConfigParams memory c) {
        c = _launch();
        if (leverage == 1000) return c;
        if (leverage == 500) {
            (c.floorMinBps, c.floorMaxBps, c.capMinBps, c.capMaxBps) = (10_250, 12_500, 15_000, 25_000);
            c.durations[0] = _rule(60, 2490, 6750);
            c.durations[1] = _rule(120, 3476, 9430);
            c.durations[2] = _rule(180, 4097, 11_090);
            c.durations[3] = _rule(240, 4547, 10_940);
            c.durations[4] = _rule(300, 4887, 11_760);
            return c;
        }
        if (leverage == 100) {
            (c.floorMinBps, c.floorMaxBps, c.capMinBps, c.capMaxBps) = (10_050, 10_500, 15_000, 20_000);
            c.durations[0] = _rule(60, 2601, 9000);
            c.durations[1] = _rule(120, 3629, 12_570);
            c.durations[2] = _rule(180, 4275, 14_790);
            c.durations[3] = _rule(240, 4743, 16_410);
            c.durations[4] = _rule(300, 5100, 17_640);
            return c;
        }
        revert("MarketSettings: no tested settings at this leverage");
    }

    /// @dev The launch config at 1000x: stakes of $1 to $50, floors 1.1x to 1.5x, caps 1.5x to 4x, a 6% early-sell
    ///      fee cap, 5-second price age and clock skew, sales until 2 seconds before the end, durations of 1 to 5
    ///      minutes with lines ±25% around each duration's reference line, no owed limit, and the open gate at 100%.
    function _launch() private pure returns (ConfigParams memory c) {
        c.entryMaxAgeSecs = 5;
        c.clockSkewSecs = 5;
        (c.floorMinBps, c.floorMaxBps, c.capMinBps, c.capMaxBps) = (11_000, 15_000, 15_000, 40_000);
        c.maxSellFeeBps = 600;
        c.sellMinDelaySecs = 0;
        c.sellCutoffSecs = 2;
        c.maxExposureBps = 10_000;
        c.minStake = 1_000_000;
        c.maxStake = 50_000_000;
        c.maxTotalOwed = type(uint64).max;
        c.durations[0] = _rule(60, 2250, 3750);
        c.durations[1] = _rule(120, 3142, 5237);
        c.durations[2] = _rule(180, 3697, 6162);
        c.durations[3] = _rule(240, 4102, 6837);
        c.durations[4] = _rule(300, 4410, 7350);
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
}
