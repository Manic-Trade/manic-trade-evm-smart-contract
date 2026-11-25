// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {ConfigParams} from "../../../src/types/ParamTypes.sol";
import {DurationRule} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetConfig_Concrete_Test
/// @notice Every branch of `setConfig`, from test/concrete/setConfig/setConfig.tree, in the contract's check order
///         (docs/ARCHITECTURE.md §8.1): the operator switches the config and recalibrates it, and invalid values
///         change nothing.
/// @dev Each revert test breaks its own check and every later one, so getting its own error proves the order.
contract SetConfig_Concrete_Test is Base_Test {
    function test_RevertWhen_TheCallerIsNotTheOperator() external {
        // it should revert: every user but the operator, on an unknown market with invalid settings too
        address[] memory callers = _everyoneBut(users.operator, users.operator);
        bytes32 operatorRole = flashOption.OPERATOR_ROLE();
        ConfigParams memory c = _invalidConfig();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], operatorRole
                )
            );
            vm.prank(callers[i]);
            flashOption.setConfig(Defaults.ETH, Defaults.LEVERAGE, c);
        }
    }

    modifier whenTheCallerIsTheOperator() {
        vm.startPrank(users.operator);
        _;
        vm.stopPrank();
    }

    function test_RevertGiven_TheMarketDoesNotExist() external whenTheCallerIsTheOperator {
        // it should revert, before looking at the settings: no ETH market, and no BTC market at 500x
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setConfig(Defaults.ETH, Defaults.LEVERAGE, _invalidConfig());
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.setConfig(Defaults.BTC, 500, _invalidConfig());
    }

    modifier givenTheMarketExists() {
        _;
    }

    function test_RevertWhen_TheSettingsAreInvalid() external whenTheCallerIsTheOperator givenTheMarketExists {
        // it should revert, changing nothing
        uint256[8] memory before = _marketWords(0);
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, _invalidConfig());
        // The line limit is the market's leverage's: at 1000x, a line of 10 bp is too wide.
        ConfigParams memory tooWide = Defaults.marketConfig();
        tooWide.durations[0].thetaMaxE7 = 10_000;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, tooWide);
        // The operator can't switch the open gate off or open it above 100%, or widen the clock skew over 30 seconds
        // (ADR 0009).
        ConfigParams memory loose = Defaults.marketConfig();
        loose.maxExposureBps = 0;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, loose);
        loose.maxExposureBps = 10_001;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, loose);
        loose = Defaults.marketConfig();
        loose.clockSkewSecs = 31;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, loose);
        uint256[8] memory afterwards = _marketWords(0);
        for (uint256 i; i < 8; ++i) {
            assertEq(afterwards[i], before[i], "the market is unchanged");
        }
    }

    function test_WhenTheSettingsAreValid() external whenTheCallerIsTheOperator givenTheMarketExists {
        // Pause BTC first, to prove the pause survives a settings change.
        vm.stopPrank();
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        vm.startPrank(users.operator);

        // Switch off, recalibrate θ, narrow the exposure gate to 80%, widen the clock skew to its 30-second limit
        // and drop the 5-minute rule. The 2-minute rule widens to the widest line the market's 1000x allows: 9.999 bp,
        // as 9,999 × 1000 < 1e7.
        ConfigParams memory c = Defaults.marketConfig();
        c.enabled = false;
        c.durations[0] = DurationRule({durationSecs: 60, thetaMinE7: 2500, thetaMaxE7: 3500, enabled: true});
        c.durations[1].thetaMaxE7 = 9999;
        c.durations[4] = DurationRule({durationSecs: 0, thetaMinE7: 0, thetaMaxE7: 0, enabled: false});
        c.maxExposureBps = 8000;
        c.clockSkewSecs = 30;
        c.maxTotalOwed = 1000e6;
        c.minStake = 2e6;

        // it should emit {ConfigUpdated}
        vm.expectEmit(address(flashOption));
        emit Events.ConfigUpdated(Defaults.BTC, Defaults.LEVERAGE, users.operator, c);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);

        // it should replace every setting
        // it should keep the market id, the pause and the price exponent
        _assertMarket(0, Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, true, c);
        assertEq(LayoutReader.marketCount(address(flashOption)), 1, "still one market");
    }

    /// @dev Valid in every field but one: a minimum stake above the maximum.
    function _invalidConfig() private pure returns (ConfigParams memory c) {
        c = Defaults.marketConfig();
        c.minStake = c.maxStake + 1;
    }

    /// @dev Market `index`'s 8 raw slots.
    function _marketWords(uint16 index) private view returns (uint256[8] memory words) {
        for (uint256 i; i < 8; ++i) {
            words[i] = LayoutReader.marketWord(address(flashOption), index, i);
        }
    }
}
