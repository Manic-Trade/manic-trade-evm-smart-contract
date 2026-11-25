// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ManicFlashOption} from "../../src/ManicFlashOption.sol";
import {IManicFlashOptionEvents as Events} from "../../src/interfaces/IManicFlashOptionEvents.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, Market, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title FlashOption_Scenario_Shared_Test
/// @notice What the scenario tests of the 500x and 100x markets share: BTC at 500x and 100x beside the 1000x test
///         market, all on one pool, their settings, and a bet at any leverage.
/// @dev The 500x and 100x settings start from the launch config, with its exposure gate off, as does the empty pool's
///      1000x market (`Examples.launchConfig()`). `validate` refuses the gate off since the open gate is bounded
///      (ADR 0009), so `_createMarket` and `_setConfig` set such a config with the gate at 100% and then switch it off
///      in storage (`_switchOffOpenGate`), a state only an upgrade could reach. The base bet is $10 for a minute,
///      θ 3 bp, floor 1.3x, cap 4x, at $83,884, and its trader is alice. Each test starts from a fresh deployment, so
///      a test that needs another's state rebuilds it with the helpers below.
abstract contract FlashOption_Scenario_Shared_Test is Settlement_Base_Test {
    uint16 internal constant L1000 = Defaults.LEVERAGE;
    uint16 internal constant L500 = 500;
    uint16 internal constant L100 = 100;
    /// @dev The entry price, $83,884.00, and 1 bp of it, $8.3884, exactly.
    int64 internal constant P0 = Defaults.ENTRY_PRICE;
    int64 internal constant BP = Examples.BP;

    /// @dev One bet: its order and terms (`_orderAndTerms`), with the user, the id and the leverage the user picks.
    struct Bet {
        address user;
        bytes32 id;
        uint16 leverage;
        Side side;
        uint64 stake;
        uint16 durationSecs;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Markets
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Creates BTC at `marketLeverage` with `p` and switches it on: created switched off (`MarketCreated`, with
    ///      the leverage), then switched on by `_setConfig`. A gate-off `p` is created with the gate at 100%, which
    ///      `_setConfig` then switches off.
    function _createMarket(uint16 marketLeverage, ConfigParams memory p) internal {
        uint16 index = flashOption.marketCount();
        p.enabled = false;
        uint32 exposure = p.maxExposureBps;
        if (exposure == 0) p.maxExposureBps = 10_000;
        vm.expectEmit(address(flashOption));
        emit Events.MarketCreated(Defaults.BTC, marketLeverage, index, Defaults.PRICE_EXPONENT);
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, marketLeverage, Defaults.PRICE_EXPONENT, p);
        p.maxExposureBps = exposure;
        _setConfig(marketLeverage, p);
    }

    /// @dev Replaces every setting of BTC at `marketLeverage` with `p`, switched on, as the operator, and checks the
    ///      event (`ConfigUpdated`, with the leverage) and every stored field. A `p` with the gate off is set with the
    ///      gate at 100% (the event carries that), then switched off in storage, and the stored fields are checked
    ///      against `p`, the gate off included.
    function _setConfig(uint16 marketLeverage, ConfigParams memory p) internal {
        p.enabled = true;
        bool gateOff = p.maxExposureBps == 0;
        if (gateOff) p.maxExposureBps = 10_000;
        vm.expectEmit(address(flashOption));
        emit Events.ConfigUpdated(Defaults.BTC, marketLeverage, users.operator, p);
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, marketLeverage, p);
        if (gateOff) {
            _switchOffOpenGate(address(flashOption), Defaults.BTC, marketLeverage);
            p.maxExposureBps = 0;
        }
        _assertMarketHas(marketLeverage, p);
    }

    /// @dev BTC at `marketLeverage` holds every setting of `p`, its own leverage, and nothing else changed.
    function _assertMarketHas(uint16 marketLeverage, ConfigParams memory p) internal view {
        Market memory m = flashOption.getMarket(Defaults.BTC, marketLeverage);
        ConfigParams memory stored = ConfigParams({
            enabled: m.enabled,
            entryMaxAgeSecs: m.entryMaxAgeSecs,
            clockSkewSecs: m.clockSkewSecs,
            floorMinBps: m.floorMinBps,
            floorMaxBps: m.floorMaxBps,
            capMinBps: m.capMinBps,
            capMaxBps: m.capMaxBps,
            maxSellFeeBps: m.maxSellFeeBps,
            sellMinDelaySecs: m.sellMinDelaySecs,
            sellCutoffSecs: m.sellCutoffSecs,
            maxExposureBps: m.maxExposureBps,
            minStake: m.minStake,
            maxStake: m.maxStake,
            maxTotalOwed: m.maxTotalOwed,
            durations: m.durations
        });
        assertEq(abi.encode(stored), abi.encode(p), "every setting");
        assertEq(m.marketId, Defaults.BTC, "BTC");
        assertEq(m.leverage, marketLeverage, "its own leverage");
        assertEq(m.priceExponent, Defaults.PRICE_EXPONENT, "the exponent");
        assertFalse(m.paused, "not paused");
    }

    /// @dev Moves every helper to a new deployment with a second, empty pool (one contract holds one pool): BTC at
    ///      1000x on the launch config with a 5-second rule in its 5-minute slot, and at 500x and 100x with the tier
    ///      settings, each with a 5-second rule up to the widest line its leverage allows.
    function _useEmptyPool() internal {
        flashOption = ManicFlashOption(_deployProxy(_defaultInitParams()));
        ConfigParams memory x1000 = Examples.launchConfig();
        x1000.durations[4] = _rule(5, 1000, 5000);
        _createMarket(L1000, x1000);
        _createMarket(L500, _tierConfigWithFiveSeconds(L500));
        _createMarket(L100, _tierConfigWithFiveSeconds(L100));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The market settings
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Settings for BTC at 500x and 100x with the tier floors and caps: at 500x every duration's lines from 2,490
    ///      to 11,760, at 100x the tier lines per duration; and in the 4-minute slot a 5-second rule (θ 0.1 to
    ///      0.5 bp), so a bet ends at once. The exposure gate is off.
    function _options(uint16 marketLeverage) internal pure returns (ConfigParams memory c) {
        c = LeverageConfigs.tierBounds(marketLeverage);
        c.maxExposureBps = 0; // the gate off
        if (marketLeverage == L500) {
            c.durations[0] = _rule(60, 2490, 11_760);
            c.durations[1] = _rule(120, 2490, 11_760);
            c.durations[2] = _rule(180, 2490, 11_760);
            c.durations[4] = _rule(300, 2490, 11_760);
        } else {
            c.durations[0] = _rule(60, 2601, 9000);
            c.durations[1] = _rule(120, 3629, 12_570);
            c.durations[2] = _rule(180, 4275, 14_790);
            c.durations[4] = _rule(300, 5100, 17_640);
        }
        c.durations[3] = _rule(5, 1000, 5000);
    }

    /// @dev The 500x and 100x tier settings (`LeverageConfigs.tierConfig`): the tier floors and caps, and per duration
    ///      the lines from 15% below the tier's lowest line (rounded down) to its highest, with the exposure gate off.
    function _tierConfig(uint16 marketLeverage) internal pure returns (ConfigParams memory c) {
        c = LeverageConfigs.tierConfig(marketLeverage);
        c.maxExposureBps = 0; // the gate off
    }

    /// @dev The tier settings with the 4-minute rule turned into a 5-second one, up to the widest line the leverage
    ///      allows.
    function _tierConfigWithFiveSeconds(uint16 marketLeverage) internal pure returns (ConfigParams memory c) {
        c = _tierConfig(marketLeverage);
        c.durations[3] = _rule(5, 1000, _widestLine(marketLeverage));
    }

    /// @dev The widest line `marketLeverage` allows, θ × 1e7: the largest with θ × leverage < 1e7 (9,999 at 1000x,
    ///      19,999 at 500x, 99,999 at 100x).
    function _widestLine(uint16 marketLeverage) internal pure returns (uint32) {
        return uint32((10_000_000 + uint256(marketLeverage) - 1) / marketLeverage - 1);
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

    // ---------------------------------------------------------------------------------------------------------------
    // Bets
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `user`'s base bet named `name` at `marketLeverage` on `side` ($10 for a minute, θ 3 bp, floor 1.3x, cap
    ///      4x).
    function _baseBet(
        address user,
        string memory name,
        uint16 marketLeverage,
        Side side
    )
        internal
        pure
        returns (Bet memory)
    {
        return Bet({
            user: user,
            id: keccak256(bytes(name)),
            leverage: marketLeverage,
            side: side,
            stake: Defaults.STAKE,
            durationSecs: Defaults.DURATION,
            thetaE7: Defaults.THETA,
            floorBps: Defaults.FLOOR_BPS,
            capBps: Defaults.CAP_BPS
        });
    }

    /// @dev The tier example bet at 500x or 100x, $10 for a minute: θ 5.25 bp, floor 1.15x and cap 2.5x at 500x;
    ///      θ 6.60 bp, floor 1.03x and cap 2x at 100x.
    function _example(
        address user,
        string memory name,
        uint16 marketLeverage,
        Side side
    )
        internal
        pure
        returns (Bet memory b)
    {
        b = _baseBet(user, name, marketLeverage, side);
        (b.thetaE7, b.floorBps, b.capBps) = marketLeverage == L500
            ? (uint32(5250), uint16(11_500), uint16(25_000))
            : (uint32(6600), uint16(10_300), uint16(20_000));
    }

    /// @dev Opens `b`, signed by its user and checked by `_betRecorded` (the stored bet keeps the leverage its order
    ///      names), and returns what `PositionOpened` reported.
    function _open(Bet memory b) internal returns (OpenedData memory) {
        (OpenOrder memory o, OpenTerms memory t) = _orderAndTerms(b);
        return _betRecorded(o, t);
    }

    /// @dev Expects the opener's open of `b`, signed by its user and with its stake authorised, to revert `reason`.
    function _expectOpenRejected(Bet memory b, bytes4 reason) internal {
        (OpenOrder memory o, OpenTerms memory t) = _orderAndTerms(b);
        uint256 key = _keyFor(o.user);
        _mintUsdg(o.user, o.stake);
        bytes memory signature = _signOrder(flashOption, key, o);
        StakeAuth memory a = _stakeAuth(flashOption, key, o);
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
    }

    /// @dev `b` as an order signed now and terms at a tick published now.
    function _orderAndTerms(Bet memory b) internal view returns (OpenOrder memory o, OpenTerms memory t) {
        o = _order(b.user, b.id);
        (o.leverage, o.side, o.stake, o.durationSecs) = (b.leverage, b.side, b.stake, b.durationSecs);
        t = _terms();
        (t.thetaE7, t.floorBps, t.capBps) = (b.thetaE7, b.floorBps, b.capBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Prices
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `bps` whole bps above the entry.
    function _up(int64 bps) internal pure returns (int64) {
        return P0 + bps * BP;
    }

    /// @dev `bps` whole bps below the entry.
    function _down(int64 bps) internal pure returns (int64) {
        return P0 - bps * BP;
    }

    /// @dev The price `move` bp from the entry in `side`'s favour, or against it when `move` is negative.
    function _favour(Side side, int64 move) internal pure returns (int64) {
        return side == Side.Call ? _up(move) : _down(move);
    }
}
