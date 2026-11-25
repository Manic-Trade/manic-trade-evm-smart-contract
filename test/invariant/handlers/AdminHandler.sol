// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionAdmin} from "../../../src/interfaces/IManicFlashOptionAdmin.sol";
import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionPool} from "../../../src/interfaces/IManicFlashOptionPool.sol";
import {IManicFlashOptionSettlement} from "../../../src/interfaces/IManicFlashOptionSettlement.sol";
import {IManicFlashOptionTrading} from "../../../src/interfaces/IManicFlashOptionTrading.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../../src/types/ParamTypes.sol";
import {Breaker, WithdrawPurpose} from "../../../src/types/StorageTypes.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {LayoutWriter} from "../../utils/LayoutWriter.sol";
import {LeverageConfigs} from "../../utils/LeverageConfigs.sol";
import {BaseHandler, HandlerSetup} from "./BaseHandler.sol";

/// @title AdminHandler
/// @notice What changes the rules while bets run (docs/ARCHITECTURE.md §8.1, §8.9b to §8.11): the brakes (the halt,
///         a market's pause and the token's pause), a market's settings, the refund delay, the floor, the payout
///         circuit breaker, the token's freezes, and a stranger trying every role-gated function. A market's pause and
///         settings change one of BTC's three markets at a time, and the others' bets run on.
/// @dev Foundry picks every targeted function with equal odds, so a brake here is put on only some of the time and
///      released the next time its action comes up: bets still open, end and pay out most of the time, and every
///      other handler predicts what each brake stops. The breaker's limits go as low as $5, so it trips within a run.
contract AdminHandler is BaseHandler {
    constructor(HandlerSetup memory s) BaseHandler(s) {}

    /// @notice A brake is released, or, one call in twelve, put on: the halt or a market's pause (by the guardian or
    ///         the operator; only the operator releases them), or the token's pause (by its admin).
    /// @param seed Picks the brake, the market and who puts it on.
    function brake(uint256 seed) external instrumented("brake") {
        uint256 which = seed % 3;
        uint16 marketLeverage = _pickLeverage(_pick(seed, 3, 0, 2));
        bool on;
        if (which == 0) on = LayoutReader.halted(address(flashOption));
        else if (which == 1) on = _market(marketLeverage).paused;
        else on = usdg.paused();
        if (!on && _pick(seed, 1, 0, 11) != 0) {
            _skip();
            return;
        }
        address engager = _pick(seed, 2, 0, 1) == 0 ? users.guardian : users.operator;
        if (which == 0) {
            vm.prank(on ? users.operator : engager);
            flashOption.setHalted(!on);
        } else if (which == 1) {
            vm.prank(on ? users.operator : engager);
            flashOption.setPaused(Defaults.BTC, marketLeverage, !on);
        } else {
            vm.prank(usdgAdmin);
            if (on) usdg.unpause();
            else usdg.pause();
        }
        _done();
    }

    /// @notice The operator or the admin changes a setting: one market switched off (one in five) or on, at its planned
    ///         values (`LeverageConfigs.planned`) with the open gate at 10,000 bps or at 1 bp (one in five); or, one in
    ///         five, out of bounds (the gate off, the gate at 10,001 bps, or a 31-second clock skew), which the
    ///         operator must be refused with `InvalidLeverageParams`; the refund delay, off (one in five), 1 hour or 24
    ///         hours; or the pool's floor, $500, $750 or $1,000. A campaign that keeps the gate off
    ///         (`FlashOptionStore.gateKeptOff`) switches it off again after a change, as only an upgrade could.
    /// @param seed Picks the setting, the market and the new value.
    function configure(uint256 seed) external instrumented("configure") {
        uint256 which = seed % 3;
        if (which == 0) {
            uint16 marketLeverage = _pickLeverage(_pick(seed, 5, 0, 2));
            ConfigParams memory c = LeverageConfigs.planned(marketLeverage);
            c.enabled = _pick(seed, 1, 0, 4) != 0;
            uint256 gate = _pick(seed, 2, 0, 4);
            if (gate == 0) {
                _configureOutOfBounds(seed, marketLeverage, c);
                return;
            }
            if (gate == 1) c.maxExposureBps = 1;
            vm.prank(users.operator);
            flashOption.setConfig(Defaults.BTC, marketLeverage, c);
            if (store.gateKeptOff()) {
                LayoutWriter.switchOffOpenGate(address(flashOption), Defaults.BTC, marketLeverage);
            }
        } else if (which == 1) {
            uint256 r = _pick(seed, 3, 0, 4);
            vm.prank(users.admin);
            flashOption.setRefundDelay(r == 0 ? 0 : r == 4 ? 24 hours : 1 hours);
        } else {
            uint64[3] memory floors = [uint64(500e6), 750e6, 1000e6];
            vm.prank(users.admin);
            flashOption.setPoolFloor(floors[_pick(seed, 4, 0, 2)]);
        }
        _done();
    }

    /// @dev The operator's settings out of bounds, picked by `seed`: the open gate off, at 10,001 bps, or a
    ///      31-second clock skew. `validate` must refuse each with `InvalidLeverageParams`, changing nothing.
    function _configureOutOfBounds(uint256 seed, uint16 marketLeverage, ConfigParams memory c) private {
        uint256 how = _pick(seed, 6, 0, 2);
        if (how == 0) c.maxExposureBps = 0;
        else if (how == 1) c.maxExposureBps = 10_001;
        else c.clockSkewSecs = 31;
        bytes memory data = abi.encodeCall(flashOption.setConfig, (Defaults.BTC, marketLeverage, c));
        (bool ok, bytes memory reason) = _attempt("configure", users.operator, data);
        _checkRefusal(
            13,
            "configure out of validate's bounds",
            ok,
            reason,
            abi.encodeWithSelector(Errors.InvalidLeverageParams.selector)
        );
        _refuse();
    }

    /// @notice The payout circuit breaker. While it is tripped, the operator resets it three calls in four; otherwise
    ///         the operator resets it anyway one call in four (allowed at any time), or the admin sets a new limit and
    ///         window: off (one in four), $5 to $100 (one in two, low enough to trip in a run) or $1,000 (the
    ///         default), over 1 minute, 10 minutes or 1 hour.
    /// @param seed Picks the change.
    function breaker(uint256 seed) external instrumented("breaker") {
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        uint256 r = _pick(seed, 1, 0, 3);
        if ((b.tripped && r < 3) || r == 3) {
            vm.prank(users.operator);
            flashOption.resetBreaker();
            _done();
            return;
        }
        uint256 kind = _pick(seed, 2, 0, 3);
        uint64 limit = kind == 0 ? 0 : kind == 3 ? 1000e6 : uint64(_pick(seed, 3, 5e6, 100e6));
        uint32[3] memory windows = [uint32(60), 600, 3600];
        vm.prank(users.admin);
        flashOption.setBreaker(limit, windows[_pick(seed, 4, 0, 2)]);
        // A limit switched on or lowered may sit under the window's net profit until the next count trips it.
        if (limit > 0 && (b.maxNetProfit == 0 || limit < b.maxNetProfit)) store.setLimitTightened(true);
        _done();
    }

    /// @notice The token's admin freezes a bettor or a recipient (one call in six), or unfreezes one that is frozen.
    ///         A frozen bettor can't open, and their payouts wait in `claimable`; a frozen recipient's fee sweep or
    ///         withdrawal is refused.
    /// @param seed Picks the account, and whether to freeze it.
    function freeze(uint256 seed) external instrumented("freeze") {
        uint256 k = _pick(seed, 1, 0, bettors.length + 1);
        address target =
            k < bettors.length ? bettors[k] : k == bettors.length ? users.feeRecipient : users.rewardsRecipient;
        bool frozen = usdg.isFrozen(target);
        if (!frozen && _pick(seed, 2, 0, 5) != 0) {
            _skip();
            return;
        }
        vm.prank(usdgAdmin);
        if (frozen) usdg.unfreeze(target);
        else usdg.freeze(target);
        _done();
    }

    /// @notice The stranger, who holds no role, calls one of the role-gated functions. Each must be refused for the
    ///         role it lacks (`AccessControlUnauthorizedAccount`), or, to release a brake, with
    ///         `OnlyOperatorCanUnpause` or `OnlyOperatorCanUnhalt` (§12 #10).
    /// @param seed Picks the function.
    function actAsStranger(uint256 seed) external instrumented("actAsStranger") {
        uint256 which = seed % 19;
        (bytes memory data, bytes32 role) = which < 4 ? _relayerCall(which) : _adminCall(which);
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role);
        if (which == 7) expected = abi.encodeWithSelector(Errors.OnlyOperatorCanUnpause.selector);
        if (which == 9) expected = abi.encodeWithSelector(Errors.OnlyOperatorCanUnhalt.selector);
        (bool ok, bytes memory reason) = _attempt("actAsStranger", stranger, data);
        _checkRefusal(10, string.concat("actAsStranger ", vm.toString(which)), ok, reason, expected);
        _refuse();
    }

    /// @dev The relayers' functions, with empty arguments: the role is checked before anything else.
    function _relayerCall(uint256 which) private view returns (bytes memory data, bytes32 role) {
        OpenOrder memory o;
        OpenTerms memory t;
        StakeAuth memory a;
        SellOrder memory s;
        SellTerms memory st;
        bytes32[] memory ids = new bytes32[](1);
        role = which < 2 ? flashOption.OPENER_ROLE() : flashOption.SETTLER_ROLE();
        if (which == 0) {
            data = abi.encodeCall(IManicFlashOptionTrading.open, (o, "", t, a));
        } else if (which == 1) {
            data = abi.encodeCall(IManicFlashOptionTrading.sell, (s, "", st));
        } else if (which == 2) {
            data = abi.encodeCall(IManicFlashOptionSettlement.liquidate, (Defaults.BTC, Defaults.LEVERAGE, 1, 1, ids));
        } else {
            data = abi.encodeCall(IManicFlashOptionSettlement.settle, (Defaults.BTC, Defaults.LEVERAGE, 1, 1, ids));
        }
    }

    /// @dev The admin's, the operator's, the guardian's and the upgrader's functions.
    function _adminCall(uint256 which) private view returns (bytes memory data, bytes32 role) {
        ConfigParams memory c = Defaults.marketConfig();
        bytes32 admin = bytes32(0); // DEFAULT_ADMIN_ROLE
        if (which == 4) return (abi.encodeCall(IManicFlashOptionPool.withdraw, (WithdrawPurpose.Rewards, 1)), admin);
        if (which == 5) {
            return (
                abi.encodeCall(IManicFlashOptionAdmin.setConfig, (Defaults.BTC, Defaults.LEVERAGE, c)),
                flashOption.OPERATOR_ROLE()
            );
        }
        if (which == 6) {
            return (
                abi.encodeCall(IManicFlashOptionAdmin.setPaused, (Defaults.BTC, Defaults.LEVERAGE, true)),
                flashOption.GUARDIAN_ROLE()
            );
        }
        if (which == 7) {
            return (abi.encodeCall(IManicFlashOptionAdmin.setPaused, (Defaults.BTC, Defaults.LEVERAGE, false)), 0);
        }
        if (which == 8) return (abi.encodeCall(IManicFlashOptionAdmin.setHalted, (true)), flashOption.GUARDIAN_ROLE());
        if (which == 9) return (abi.encodeCall(IManicFlashOptionAdmin.setHalted, (false)), 0);
        if (which == 10) return (abi.encodeCall(IManicFlashOptionAdmin.setBreaker, (1, 60)), admin);
        if (which == 11) return (abi.encodeCall(IManicFlashOptionAdmin.resetBreaker, ()), flashOption.OPERATOR_ROLE());
        if (which == 12) return (abi.encodeCall(IManicFlashOptionAdmin.setPoolFloor, (Defaults.POOL_FLOOR)), admin);
        if (which == 13) return (abi.encodeCall(IManicFlashOptionAdmin.setRefundDelay, (1 hours)), admin);
        if (which == 14) return (abi.encodeCall(IManicFlashOptionAdmin.setRecipients, (stranger, stranger)), admin);
        if (which == 15) {
            return (
                abi.encodeCall(IManicFlashOptionAdmin.revokeRelayer, (flashOption.OPENER_ROLE(), users.opener)),
                flashOption.GUARDIAN_ROLE()
            );
        }
        if (which == 16) {
            return (
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(flashOption), ""),
                flashOption.UPGRADER_ROLE()
            );
        }
        if (which == 17) {
            bytes32 opener = flashOption.OPENER_ROLE();
            return (abi.encodeCall(IAccessControl.grantRole, (opener, stranger)), flashOption.getRoleAdmin(opener));
        }
        return (
            abi.encodeCall(
                IManicFlashOptionAdmin.createMarket, (Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c)
            ),
            admin
        );
    }
}
