// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Base_Test} from "../../Base.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetPaused_Concrete_Test
/// @notice Every branch of `setPaused`, from test/concrete/setPaused/setPaused.tree (docs/ARCHITECTURE.md §8.1,
///         §8.10). The guardian or the operator can pause; only the operator can unpause. Pausing again succeeds and
///         changes nothing else, and the releasing role can pause too.
/// @dev The role checks run before the market lookup, so every role test targets an unknown market as well.
contract SetPaused_Concrete_Test is Base_Test {
    modifier whenPausing() {
        _;
    }

    function test_RevertWhen_TheCallerIsNeitherTheGuardianNorTheOperator() external whenPausing {
        // it should revert, naming the guardian's role
        address[] memory callers = _everyoneBut(users.guardian, users.operator);
        bytes32 guardianRole = flashOption.GUARDIAN_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], guardianRole
                )
            );
            vm.prank(callers[i]);
            flashOption.setPaused(Defaults.ETH, Defaults.LEVERAGE, true);
        }
    }

    modifier whenTheCallerIsTheGuardianOrTheOperator() {
        _;
    }

    function test_RevertGiven_TheMarketToPauseDoesNotExist()
        external
        whenPausing
        whenTheCallerIsTheGuardianOrTheOperator
    {
        // it should revert, for either caller: no ETH market, and no BTC market at 500x
        vm.prank(users.guardian);
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setPaused(Defaults.ETH, Defaults.LEVERAGE, true);
        vm.prank(users.operator);
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setPaused(Defaults.ETH, Defaults.LEVERAGE, true);
        vm.prank(users.guardian);
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setPaused(Defaults.BTC, 500, true);
    }

    function test_GivenTheMarketToPauseExists() external whenPausing whenTheCallerIsTheGuardianOrTheOperator {
        uint256 slot1 = LayoutReader.marketWord(address(flashOption), 0, 1);

        // it should emit {PauseChanged}
        vm.expectEmit(address(flashOption));
        emit Events.PauseChanged(Defaults.BTC, Defaults.LEVERAGE, users.guardian, true);
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);

        // it should pause the market, even one already paused: only the pause byte (byte 1 of slot 1) changes
        assertTrue(LayoutReader.market(address(flashOption), 0).paused, "paused");
        assertEq(
            LayoutReader.marketWord(address(flashOption), 0, 1), slot1 | (1 << 8), "nothing else in slot 1 changed"
        );
        vm.expectEmit(address(flashOption));
        emit Events.PauseChanged(Defaults.BTC, Defaults.LEVERAGE, users.operator, true);
        vm.prank(users.operator);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        assertEq(LayoutReader.marketWord(address(flashOption), 0, 1), slot1 | (1 << 8), "re-pausing changes nothing");
    }

    modifier whenUnpausing() {
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        _;
    }

    function test_RevertWhen_TheCallerIsNotTheOperator() external whenUnpausing {
        // it should revert: the guardian included, on an unknown market too
        address[] memory callers = _everyoneBut(users.operator, users.operator);
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(Errors.OnlyOperatorCanUnpause.selector);
            vm.prank(callers[i]);
            flashOption.setPaused(Defaults.ETH, Defaults.LEVERAGE, false);
        }
    }

    modifier whenTheCallerIsTheOperator() {
        vm.startPrank(users.operator);
        _;
        vm.stopPrank();
    }

    function test_RevertGiven_TheMarketToUnpauseDoesNotExist() external whenUnpausing whenTheCallerIsTheOperator {
        // it should revert: no ETH market, and no BTC market at 500x
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setPaused(Defaults.ETH, Defaults.LEVERAGE, false);
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setPaused(Defaults.BTC, 500, false);
    }

    function test_GivenTheMarketToUnpauseExists() external whenUnpausing whenTheCallerIsTheOperator {
        uint256 paused = LayoutReader.marketWord(address(flashOption), 0, 1);

        // it should emit {PauseChanged}
        vm.expectEmit(address(flashOption));
        emit Events.PauseChanged(Defaults.BTC, Defaults.LEVERAGE, users.operator, false);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);

        // it should unpause the market
        assertFalse(LayoutReader.market(address(flashOption), 0).paused, "unpaused");
        assertEq(LayoutReader.marketWord(address(flashOption), 0, 1), paused & ~uint256(1 << 8), "only the pause byte");
    }
}
