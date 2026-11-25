// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigLib} from "../../src/libraries/ConfigLib.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Market} from "../../src/types/StorageTypes.sol";

/// @title ConfigLibHarness
/// @notice Exposes `ConfigLib`'s internal checks as external calls, so tests can call them without a proxy and assert
///         their reverts.
/// @dev `validateOpen` reads a stored market, so the harness keeps one: `setMarket` stores settings the way
///      `AdminModule` does (every setting; the id, pause and price exponent are not settings).
contract ConfigLibHarness {
    Market internal market;

    function validate(ConfigParams calldata p, uint16 leverage) external pure {
        ConfigLib.validate(p, leverage);
    }

    function setMarket(ConfigParams calldata p) external {
        market.enabled = p.enabled;
        market.entryMaxAgeSecs = p.entryMaxAgeSecs;
        market.clockSkewSecs = p.clockSkewSecs;
        market.floorMinBps = p.floorMinBps;
        market.floorMaxBps = p.floorMaxBps;
        market.capMinBps = p.capMinBps;
        market.capMaxBps = p.capMaxBps;
        market.maxSellFeeBps = p.maxSellFeeBps;
        market.sellMinDelaySecs = p.sellMinDelaySecs;
        market.sellCutoffSecs = p.sellCutoffSecs;
        market.maxExposureBps = p.maxExposureBps;
        market.minStake = p.minStake;
        market.maxStake = p.maxStake;
        market.maxTotalOwed = p.maxTotalOwed;
        for (uint256 i; i < p.durations.length; ++i) {
            market.durations[i] = p.durations[i];
        }
    }

    function validateOpen(
        uint64 stake,
        uint16 durationSecs,
        uint32 thetaE7,
        uint16 floorBps,
        uint16 capBps
    )
        external
        view
    {
        ConfigLib.validateOpen(market, stake, durationSecs, thetaE7, floorBps, capBps);
    }
}
