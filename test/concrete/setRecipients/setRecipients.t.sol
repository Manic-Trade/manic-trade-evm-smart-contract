// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Base_Test} from "../../Base.t.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetRecipients_Concrete_Test
/// @notice Every branch of `setRecipients`, from test/concrete/setRecipients/setRecipients.tree: only the admin (the
///         timelock on mainnet) can redirect fees and rewards, and never to the zero address.
contract SetRecipients_Concrete_Test is Base_Test {
    function test_RevertWhen_TheCallerIsNotTheAdmin() external {
        // it should revert: every user but the admin, with zero addresses as well
        address[] memory callers = _everyoneBut(users.admin, users.admin);
        bytes32 adminRole = flashOption.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], adminRole)
            );
            vm.prank(callers[i]);
            flashOption.setRecipients(address(0), address(0));
        }
    }

    modifier whenTheCallerIsTheAdmin() {
        vm.startPrank(users.admin);
        _;
        vm.stopPrank();
    }

    function test_RevertWhen_EitherRecipientIsTheZeroAddress() external whenTheCallerIsTheAdmin {
        // it should revert: the fee recipient, the rewards recipient, or both
        vm.expectRevert(Errors.ZeroAddress.selector);
        flashOption.setRecipients(address(0), users.bob);
        vm.expectRevert(Errors.ZeroAddress.selector);
        flashOption.setRecipients(users.alice, address(0));
        vm.expectRevert(Errors.ZeroAddress.selector);
        flashOption.setRecipients(address(0), address(0));
    }

    function test_WhenBothRecipientsAreSet() external whenTheCallerIsTheAdmin {
        // it should emit {RecipientsUpdated}
        vm.expectEmit(address(flashOption));
        emit Events.RecipientsUpdated(users.alice, users.bob);
        flashOption.setRecipients(users.alice, users.bob);

        // it should store both: slots 1 and 2 hold nothing else
        assertEq(LayoutReader.word(address(flashOption), 1), uint256(uint160(users.alice)), "fee recipient");
        assertEq(LayoutReader.word(address(flashOption), 2), uint256(uint160(users.bob)), "rewards recipient");
    }
}
