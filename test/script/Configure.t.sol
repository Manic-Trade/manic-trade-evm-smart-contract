// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BaseScript} from "../../script/Base.s.sol";
import {Configure} from "../../script/Configure.s.sol";
import {Upgrade} from "../../script/Upgrade.s.sol";
import {MarketSettings} from "../../script/config/MarketSettings.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";
import {Scripts_Shared} from "./ScriptsShared.sol";

/// @title Configure_Script_Test
/// @notice `Configure.configure` creates and switches on the listed markets with their tested settings and funds the
///         pool, once; `Configure.check` names each way the result can be wrong.
contract Configure_Script_Test is Scripts_Shared {
    Configure internal script;
    BaseScript.Inputs internal inputs;

    function setUp() public {
        script = Configure(vm.deployCode("Configure.s.sol:Configure"));
        inputs = _deployFor(address(script));
        script.configure(proxy, inputs, true);
    }

    function test_TheListedMarketsAreSetUpAndThePoolFunded() public view {
        script.check(proxy, inputs);
        assertEq(proxy.marketCount(), 3, "three markets");
        for (uint256 j; j < inputs.leverages.length; ++j) {
            assertTrue(proxy.getMarket(MarketSettings.BTC, inputs.leverages[j]).enabled, "switched on");
        }
        assertEq(proxy.getPool().total, inputs.poolFunding, "funded to the target");
    }

    function test_ConfiguringAgainChangesNothing() public {
        bytes32 before = Upgrade(vm.deployCode("Upgrade.s.sol:Upgrade")).snapshot(proxy, inputs);
        uint256 supply = token.totalSupply();
        script.configure(proxy, inputs, true);
        assertEq(Upgrade(vm.deployCode("Upgrade.s.sol:Upgrade")).snapshot(proxy, inputs), before, "the same state");
        assertEq(token.totalSupply(), supply, "nothing minted");
    }

    function test_OnlyTheListedMarketsAreSwitchedOn() public {
        BaseScript.Inputs memory i = _deployFor(address(script));
        i.enabled = new uint16[](1);
        i.enabled[0] = 500;
        script.configure(proxy, i, true);
        script.check(proxy, i);
        assertFalse(proxy.getMarket(MarketSettings.BTC, 1000).enabled, "1000x stays off");
        assertTrue(proxy.getMarket(MarketSettings.BTC, 500).enabled, "500x on");
        assertFalse(proxy.getMarket(MarketSettings.BTC, 100).enabled, "100x stays off");
    }

    function test_ThePoolIsToppedUpToTheTarget() public {
        BaseScript.Inputs memory i = inputs;
        i.poolFunding += 250e6;
        script.configure(proxy, i, true);
        assertEq(proxy.getPool().total, i.poolFunding, "topped up");
    }

    function test_RevertWhen_AMarketsSettingsDiffer() public {
        ConfigParams memory c = MarketSettings.btc(500);
        c.enabled = true;
        c.maxSellFeeBps -= 1;
        vm.prank(address(script));
        proxy.setConfig(MarketSettings.BTC, 500, c);
        _expectCheckFails(inputs, "Configure check: the settings of BTC at 500x");
    }

    function test_RevertWhen_AListedMarketIsOff() public {
        vm.prank(address(script));
        proxy.setConfig(MarketSettings.BTC, 1000, MarketSettings.btc(1000));
        _expectCheckFails(inputs, "Configure check: the settings of BTC at 1000x");
    }

    function test_RevertWhen_AMarketIsPaused() public {
        vm.prank(address(script));
        proxy.setPaused(MarketSettings.BTC, 100, true);
        _expectCheckFails(inputs, "Configure check: a market is paused");
    }

    function test_RevertWhen_ThereIsAnotherMarket() public {
        vm.prank(address(script));
        proxy.createMarket(MarketSettings.BTC, 10, MarketSettings.BTC_PRICE_EXPONENT, LeverageConfigs.launchAt(10));
        _expectCheckFails(inputs, "Configure check: the number of markets");
    }

    function test_RevertWhen_ThePoolIsShort() public {
        BaseScript.Inputs memory i = inputs;
        i.poolFunding += 1;
        _expectCheckFails(i, "Configure check: the pool's funding");
    }

    function test_RevertWhen_Halted() public {
        vm.prank(address(script));
        proxy.setHalted(true);
        _expectCheckFails(inputs, "Configure check: halted, or the breaker tripped");
    }

    function _expectCheckFails(BaseScript.Inputs memory i, string memory reason) private {
        vm.expectRevert(bytes(reason));
        script.check(proxy, i);
    }
}
