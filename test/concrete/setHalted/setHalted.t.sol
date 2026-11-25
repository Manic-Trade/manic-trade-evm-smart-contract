// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Base_Test} from "../../Base.t.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetHalted_Concrete_Test
/// @notice Every branch of `setHalted`, from test/concrete/setHalted/setHalted.tree (docs/ARCHITECTURE.md §8.1,
///         §8.10): the guardian or the operator can halt the whole contract; only the operator can resume it.
/// @dev `halted` is byte 21 of `Layout` slot 0. What a halt stops (open, sell, liquidate, settle, repay) is tested with
///      those functions.
contract SetHalted_Concrete_Test is Base_Test {
    /// @dev The `halted` byte in `Layout` slot 0.
    uint256 internal constant HALTED_BIT = 1 << 168;

    modifier whenHalting() {
        _;
    }

    function test_RevertWhen_TheCallerIsNeitherTheGuardianNorTheOperator() external whenHalting {
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
            flashOption.setHalted(true);
        }
    }

    function test_WhenTheCallerIsTheGuardianOrTheOperator() external whenHalting {
        uint256 slot0 = LayoutReader.word(address(flashOption), 0);

        // it should emit {HaltChanged}
        vm.expectEmit(address(flashOption));
        emit Events.HaltChanged(users.guardian, true);
        vm.prank(users.guardian);
        flashOption.setHalted(true);

        // it should halt the contract, even one already halted: only the halted byte changes
        assertTrue(LayoutReader.halted(address(flashOption)), "halted");
        assertEq(LayoutReader.word(address(flashOption), 0), slot0 | HALTED_BIT, "nothing else in slot 0 changed");
        vm.expectEmit(address(flashOption));
        emit Events.HaltChanged(users.operator, true);
        vm.prank(users.operator);
        flashOption.setHalted(true);
        assertEq(LayoutReader.word(address(flashOption), 0), slot0 | HALTED_BIT, "halting again changes nothing");
    }

    modifier whenResuming() {
        vm.prank(users.guardian);
        flashOption.setHalted(true);
        _;
    }

    function test_RevertWhen_TheCallerIsNotTheOperator() external whenResuming {
        // it should revert: the guardian included
        address[] memory callers = _everyoneBut(users.operator, users.operator);
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(Errors.OnlyOperatorCanUnhalt.selector);
            vm.prank(callers[i]);
            flashOption.setHalted(false);
        }
    }

    function test_WhenTheCallerIsTheOperator() external whenResuming {
        uint256 halted = LayoutReader.word(address(flashOption), 0);

        // it should emit {HaltChanged}
        vm.expectEmit(address(flashOption));
        emit Events.HaltChanged(users.operator, false);
        vm.prank(users.operator);
        flashOption.setHalted(false);

        // it should resume the contract
        assertFalse(LayoutReader.halted(address(flashOption)), "resumed");
        assertEq(LayoutReader.word(address(flashOption), 0), halted & ~HALTED_BIT, "only the halted byte changed");
    }
}
