// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Base_Test} from "../../Base.t.sol";
import {ManicFlashOptionV2Mock} from "../../mocks/ManicFlashOptionV2Mock.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title UpgradeToAndCall_Concrete_Test
/// @notice The upgrade gate, from test/concrete/upgradeToAndCall/upgradeToAndCall.tree: only `UPGRADER_ROLE` can
///         upgrade, only to another UUPS implementation, and only through the proxy (docs/ARCHITECTURE.md §4.2,
///         security checklist UPG-4).
/// @dev `upgradeToAndCall` is OpenZeppelin's. Our part is `_authorizeUpgrade`, the gate it calls first. The V1 → V2
///      upgrade over real state, with an appended field and its reinitializer, is test/upgrade/Upgrade.t.sol, and the
///      upgrades plugin's layout check is test/upgrade/layout/.
contract UpgradeToAndCall_Concrete_Test is Base_Test {
    ManicFlashOptionV2Mock internal v2;

    function setUp() public override {
        super.setUp();
        v2 = new ManicFlashOptionV2Mock();
    }

    function test_RevertWhen_CalledOnTheImplementationDirectly() external {
        // it should revert: the implementation only upgrades the proxy that delegates to it
        vm.prank(users.upgrader);
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(v2), "");
    }

    modifier whenCalledThroughTheProxy() {
        _;
    }

    function test_RevertWhen_TheCallerIsNotTheUpgrader() external whenCalledThroughTheProxy {
        // it should revert: every other role holder (the admin and the operator included), the recipients, a user and
        // an attacker
        address[9] memory callers = [
            users.admin,
            users.operator,
            users.guardian,
            users.opener,
            users.settler,
            users.feeRecipient,
            users.rewardsRecipient,
            users.alice,
            users.eve
        ];
        // Read the role id first: a prank applies to the very next call, and reading the id is a call too.
        bytes32 upgraderRole = flashOption.UPGRADER_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], upgraderRole
                )
            );
            vm.prank(callers[i]);
            flashOption.upgradeToAndCall(address(v2), "");
        }
    }

    modifier whenTheCallerIsTheUpgrader() {
        vm.startPrank(users.upgrader);
        _;
        vm.stopPrank();
    }

    function test_RevertWhen_TheNewImplementationIsNotUUPS()
        external
        whenCalledThroughTheProxy
        whenTheCallerIsTheUpgrader
    {
        // it should revert: a contract with no `proxiableUUID` (here the token) could never be upgraded again
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(usdg)));
        flashOption.upgradeToAndCall(address(usdg), "");
    }

    function test_WhenTheNewImplementationIsUUPS() external whenCalledThroughTheProxy whenTheCallerIsTheUpgrader {
        uint256[9] memory before;
        for (uint256 i; i < before.length; ++i) {
            before[i] = LayoutReader.word(address(flashOption), i);
        }

        // it should emit {Upgraded}
        vm.expectEmit(address(flashOption));
        emit IERC1967.Upgraded(address(v2));
        flashOption.upgradeToAndCall(address(v2), "");

        // it should point the proxy at the new implementation
        assertEq(UnsafeUpgrades.getImplementationAddress(address(flashOption)), address(v2), "implementation slot");
        assertTrue(ManicFlashOptionV2Mock(address(flashOption)).isV2(), "the proxy runs the new code");

        // it should keep every stored setting and role
        for (uint256 i; i < before.length; ++i) {
            assertEq(LayoutReader.word(address(flashOption), i), before[i], "every value slot unchanged");
        }
        assertEq(flashOption.defaultAdmin(), users.admin, "default admin");
        assertTrue(flashOption.hasRole(flashOption.UPGRADER_ROLE(), users.upgrader), "upgrader");
        assertTrue(flashOption.hasRole(flashOption.OPERATOR_ROLE(), users.operator), "operator");
        assertTrue(flashOption.hasRole(flashOption.GUARDIAN_ROLE(), users.guardian), "guardian");
        assertTrue(flashOption.hasRole(flashOption.OPENER_ROLE(), users.opener), "opener");
        assertTrue(flashOption.hasRole(flashOption.SETTLER_ROLE(), users.settler), "settler");
    }
}
