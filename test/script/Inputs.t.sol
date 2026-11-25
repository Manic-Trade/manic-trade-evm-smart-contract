// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {BaseScript} from "../../script/Base.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployMockUsdg} from "../../script/DeployMockUsdg.s.sol";
import {MarketSettings} from "../../script/config/MarketSettings.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title Scripts_Inputs_Test
/// @notice The inputs: the chains the scripts accept, and the market settings they deploy.
contract Scripts_Inputs_Test is Test {
    function test_TheMarketSettingsAreTheTestedValues() public pure {
        uint16[3] memory leverages = [uint16(1000), 500, 100];
        for (uint256 j; j < leverages.length; ++j) {
            assertEq(
                abi.encode(MarketSettings.btc(leverages[j])),
                abi.encode(LeverageConfigs.planned(leverages[j])),
                "the deployed settings are the tested ones"
            );
            assertFalse(MarketSettings.btc(leverages[j]).enabled, "created switched off");
        }
    }

    function test_RevertWhen_NoSettingsWereTestedAtTheLeverage() public {
        vm.expectRevert(bytes("MarketSettings: no tested settings at this leverage"));
        this.settingsAt(200);
    }

    function test_TheTestnetTableIsReadable() public {
        vm.chainId(46_630);
        BaseScript.Inputs memory i = Deploy(vm.deployCode("Deploy.s.sol:Deploy")).inputs();
        assertEq(i.name, "Robinhood testnet", "name");
        assertEq(i.openers.length, 2, "two openers");
        assertEq(i.settlers.length, 2, "two settlers");
        assertEq(i.token, address(0), "no USDG: the mock");
        assertEq(i.leverages.length, 3, "three markets");
        assertEq(i.poolFloor, 500e6, "the lowest floor");
        assertEq(i.refundDelaySecs, 24 hours, "a day's refund delay");
        assertEq(i.breakerMaxNetProfit, 1000e6, "$1,000");
        assertEq(i.breakerWindowSecs, 1 hours, "an hour");
    }

    function test_RevertWhen_TheChainHasNoTable() public {
        vm.chainId(1);
        Deploy deploy = Deploy(vm.deployCode("Deploy.s.sol:Deploy"));
        vm.expectRevert(bytes("chains.toml has no table for chain 1"));
        deploy.run();
    }

    function test_RevertWhen_TheMockWouldGoToMainnet() public {
        vm.chainId(4663);
        DeployMockUsdg script = DeployMockUsdg(vm.deployCode("DeployMockUsdg.s.sol:DeployMockUsdg"));
        vm.expectRevert(bytes("DeployMockUsdg: mainnet has the real USDG"));
        script.run();
    }

    /// @dev An external call into the library, so a test can expect its revert.
    function settingsAt(uint16 leverage) external pure returns (ConfigParams memory) {
        return MarketSettings.btc(leverage);
    }
}
