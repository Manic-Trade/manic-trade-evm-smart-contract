// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BaseScript} from "../../script/Base.s.sol";
import {Configure} from "../../script/Configure.s.sol";
import {Upgrade} from "../../script/Upgrade.s.sol";
import {MarketSettings} from "../../script/config/MarketSettings.sol";
import {ManicFlashOptionV2Mock} from "../mocks/ManicFlashOptionV2Mock.sol";
import {Scripts_Shared} from "./ScriptsShared.sol";

/// @title Upgrade_Script_Test
/// @notice `Upgrade.check` passes when an upgrade changed only the implementation, and fails on anything else.
contract Upgrade_Script_Test is Scripts_Shared {
    Upgrade internal script;
    BaseScript.Inputs internal inputs;
    bytes32 internal before;

    function setUp() public {
        script = Upgrade(vm.deployCode("Upgrade.s.sol:Upgrade"));
        Configure configure = Configure(vm.deployCode("Configure.s.sol:Configure"));
        inputs = _deployFor(address(configure));
        configure.configure(proxy, inputs, true);
        before = script.snapshot(proxy, inputs);
    }

    function test_AnUpgradeToTheSameCodeKeepsEverything() public {
        address next = vm.deployCode("ManicFlashOption.sol:ManicFlashOption");
        _upgrade(next, "");
        script.check(proxy, next, before, inputs);
    }

    function test_AnUpgradeToTheNextVersionKeepsEverything() public {
        address next = vm.deployCode("ManicFlashOptionV2Mock.sol:ManicFlashOptionV2Mock");
        _upgrade(next, abi.encodeCall(ManicFlashOptionV2Mock.initializeV2, (7)));
        script.check(proxy, next, before, inputs);
        assertEq(ManicFlashOptionV2Mock(address(proxy)).newSetting(), 7, "the reinitializer ran");
    }

    function test_RevertWhen_ASettingChanged() public {
        address next = vm.deployCode("ManicFlashOption.sol:ManicFlashOption");
        _upgrade(next, "");
        vm.prank(inputs.admin);
        proxy.setRefundDelay(inputs.refundDelaySecs + 1);
        vm.expectRevert(bytes("Upgrade check: a setting, role, market or book changed"));
        script.check(proxy, next, before, inputs);
    }

    function test_RevertWhen_ARoleChanged() public {
        address next = vm.deployCode("ManicFlashOption.sol:ManicFlashOption");
        _upgrade(next, "");
        bytes32 role = proxy.SETTLER_ROLE();
        vm.prank(inputs.guardian);
        proxy.revokeRelayer(role, inputs.settlers[1]);
        vm.expectRevert(bytes("Upgrade check: a setting, role, market or book changed"));
        script.check(proxy, next, before, inputs);
    }

    function test_RevertWhen_AMarketChanged() public {
        address next = vm.deployCode("ManicFlashOption.sol:ManicFlashOption");
        _upgrade(next, "");
        vm.prank(inputs.operator);
        proxy.setPaused(MarketSettings.BTC, 500, true);
        vm.expectRevert(bytes("Upgrade check: a setting, role, market or book changed"));
        script.check(proxy, next, before, inputs);
    }

    function test_RevertWhen_TheProxyPointsElsewhere() public {
        address next = vm.deployCode("ManicFlashOption.sol:ManicFlashOption");
        vm.expectRevert(bytes("Upgrade check: the proxy's implementation"));
        script.check(proxy, next, before, inputs);
    }

    function _upgrade(address next, bytes memory data) private {
        vm.prank(inputs.upgrader);
        proxy.upgradeToAndCall(next, data);
    }
}
