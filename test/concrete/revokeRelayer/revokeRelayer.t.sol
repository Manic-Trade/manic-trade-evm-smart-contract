// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Vm} from "forge-std/Vm.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {Base_Test} from "../../Base.t.sol";

/// @title RevokeRelayer_Concrete_Test
/// @notice Every branch of `revokeRelayer`, from test/concrete/revokeRelayer/revokeRelayer.tree
///         (docs/ARCHITECTURE.md §8.9b): the guardian's instant answer to a leaked relayer key. It can revoke opener
///         and settler keys, nothing else, and can never grant one back.
contract RevokeRelayer_Concrete_Test is Base_Test {
    function test_RevertWhen_TheCallerIsNotTheGuardian() external {
        // it should revert: every user but the guardian (the admin and the operator included), with a non-relayer role
        address[] memory callers = _everyoneBut(users.guardian, users.guardian);
        bytes32 guardianRole = flashOption.GUARDIAN_ROLE();
        bytes32 upgraderRole = flashOption.UPGRADER_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], guardianRole
                )
            );
            vm.prank(callers[i]);
            flashOption.revokeRelayer(upgraderRole, users.upgrader);
        }
    }

    modifier whenTheCallerIsTheGuardian() {
        vm.startPrank(users.guardian);
        _;
        vm.stopPrank();
    }

    function test_RevertWhen_TheRoleIsNotARelayerRole() external whenTheCallerIsTheGuardian {
        // it should revert, naming the role: every other role, and a made-up one
        bytes32[5] memory roles = [
            flashOption.DEFAULT_ADMIN_ROLE(),
            flashOption.UPGRADER_ROLE(),
            flashOption.OPERATOR_ROLE(),
            flashOption.GUARDIAN_ROLE(),
            keccak256("MINTER_ROLE")
        ];
        for (uint256 i; i < roles.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRelayerRole.selector, roles[i]));
            flashOption.revokeRelayer(roles[i], users.admin);
        }
    }

    modifier whenTheRoleIsARelayerRole() {
        _;
    }

    function test_GivenTheAccountHoldsTheRole() external whenTheCallerIsTheGuardian whenTheRoleIsARelayerRole {
        bytes32 openerRole = flashOption.OPENER_ROLE();
        bytes32 settlerRole = flashOption.SETTLER_ROLE();

        // it should emit {RoleRevoked}
        vm.expectEmit(address(flashOption));
        emit IAccessControl.RoleRevoked(openerRole, users.opener, users.guardian);
        flashOption.revokeRelayer(openerRole, users.opener);
        vm.expectEmit(address(flashOption));
        emit IAccessControl.RoleRevoked(settlerRole, users.settler, users.guardian);
        flashOption.revokeRelayer(settlerRole, users.settler);

        // it should revoke it at once
        assertFalse(flashOption.hasRole(openerRole, users.opener), "opener revoked");
        assertFalse(flashOption.hasRole(settlerRole, users.settler), "settler revoked");

        // ...and the guardian can't grant it back: only the admin (timelocked) can
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                users.guardian,
                flashOption.DEFAULT_ADMIN_ROLE()
            )
        );
        flashOption.grantRole(openerRole, users.opener);
    }

    function test_GivenTheAccountDoesNotHoldTheRole() external whenTheCallerIsTheGuardian whenTheRoleIsARelayerRole {
        // it should do nothing: no event, and every role stays as it was
        bytes32 openerRole = flashOption.OPENER_ROLE();
        vm.recordLogs();
        flashOption.revokeRelayer(openerRole, users.alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event");
        assertTrue(flashOption.hasRole(openerRole, users.opener), "the real opener keeps its key");
        assertFalse(flashOption.hasRole(openerRole, users.alice), "alice still holds nothing");
    }
}
