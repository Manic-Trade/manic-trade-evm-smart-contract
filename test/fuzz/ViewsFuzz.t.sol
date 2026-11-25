// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, OpenTerms} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, Position, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title Views_Fuzz_Test
/// @notice `getPosition` (docs/ARCHITECTURE.md §8.9), for any open bet inside the bounds of a market at any
///         leverage: it returns exactly what storage holds, the bet's leverage included, and the expiry and the cap
///         price `PositionOpened` reported, though the cap price isn't stored and is recomputed
///         (`LeverageMath.capLine`). That cap price is the cap line at the bet's own leverage: (cap − 1x) / L of the
///         entry from it, rounded down, above the entry for a call and below it for a put.
/// @dev The bet is on BTC at the case's leverage (`_leverageFor`), with the launch config fitted to it
///      (`LeverageConfigs.launchAt`). The cap line is computed here independently. Inputs are bounded with `bound`,
///      never `vm.assume`, as in Open_Fuzz_Test. CI runs 10,000 cases.
contract Views_Fuzz_Test is Settlement_Base_Test {
    /// @dev The random terms of a bet, and the seed of its market's leverage.
    struct Terms {
        uint64 stake;
        uint8 ruleIndex;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
        bool isPut;
        int64 entryPrice;
        uint16 leverageSeed;
    }

    function testFuzz_GetPositionReportsWhatOpenReported(Terms memory r) external {
        uint16 marketLeverage = _leverageFor(r.leverageSeed);
        ConfigParams memory c = LeverageConfigs.launchAt(marketLeverage);
        c.maxExposureBps = 10_000;
        _useBtcAt(marketLeverage, c);
        DurationRule memory rule = c.durations[r.ruleIndex % 5];
        OpenOrder memory o = _order(users.alice, keccak256(abi.encode(r)));
        o.leverage = marketLeverage;
        o.stake = uint64(bound(r.stake, c.minStake, c.maxStake));
        o.durationSecs = rule.durationSecs;
        o.side = r.isPut ? Side.Put : Side.Call;
        OpenTerms memory t = _terms();
        t.thetaE7 = uint32(bound(r.thetaE7, rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(bound(r.floorBps, c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(r.capBps, t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
        t.entryPrice = int64(bound(r.entryPrice, 1, type(int64).max / 2));

        OpenedData memory opened = _betRecorded(o, t);
        (Position memory p, uint48 endTime, int64 capPrice) = flashOption.getPosition(o.positionId);
        assertEq(abi.encode(p), abi.encode(LayoutReader.position(address(flashOption), o.positionId)), "as stored");
        assertEq(p.leverage, marketLeverage, "the bet's leverage");
        assertEq(p.liqPrice, opened.liqPrice, "the line PositionOpened reported");
        assertEq(endTime, opened.endTime, "the expiry PositionOpened reported");
        assertEq(capPrice, opened.capPrice, "the cap price PositionOpened reported");
        assertEq(capPrice, _capLine(t.entryPrice, o.side, marketLeverage, t.capBps), "the cap line at its leverage");
    }

    /// @dev The cap line at `marketLeverage`: (cap − 1x) / L of `entry` from it, rounded down, above the entry for a
    ///      call and below it for a put.
    function _capLine(int64 entry, Side side, uint16 marketLeverage, uint16 capBps) private pure returns (int64) {
        int256 distance =
            (int256(entry) * (int256(uint256(capBps)) - 10_000)) / (int256(uint256(marketLeverage)) * 10_000);
        // casting to int64 is safe: the distance is less than the entry, as the cap is below (L + 1)x
        return side == Side.Call ? entry + int64(distance) : entry - int64(distance);
    }
}
