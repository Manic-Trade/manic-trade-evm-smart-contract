// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {ConfigParams} from "../../../src/types/ParamTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title CreateMarket_Concrete_Test
/// @notice Every branch of `createMarket`, from test/concrete/createMarket/createMarket.tree, in the contract's check
///         order (docs/ARCHITECTURE.md §8.1).
/// @dev BTC already exists at index 0 (`Base_Test`), so these tests create ETH. Several checks share
///      `InvalidLeverageParams`, so to prove the order each revert test also fills the market list (65,535 markets),
///      the one later check with an error of its own (`MathOverflow`). The many ways settings can be invalid are
///      ConfigLib's tests (test/unit/ConfigLib.t.sol, test/fuzz/ConfigLibFuzz.t.sol).
contract CreateMarket_Concrete_Test is Base_Test {
    function test_RevertWhen_TheCallerIsNotTheAdmin() external {
        // it should revert: every user but the admin, with a zero id and a full market list too
        address[] memory callers = _everyoneBut(users.admin, users.admin);
        bytes32 adminRole = flashOption.DEFAULT_ADMIN_ROLE();
        ConfigParams memory c = Defaults.marketConfig();
        _fillMarketList();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], adminRole)
            );
            vm.prank(callers[i]);
            flashOption.createMarket(bytes32(0), Defaults.LEVERAGE, 1, c);
        }
    }

    modifier whenTheCallerIsTheAdmin() {
        vm.startPrank(users.admin);
        _;
        vm.stopPrank();
    }

    function test_RevertWhen_TheMarketIdIsZero() external whenTheCallerIsTheAdmin {
        // it should revert
        _fillMarketList();
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(bytes32(0), Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
    }

    modifier whenTheMarketIdIsNotZero() {
        _;
    }

    function test_RevertGiven_TheMarketAlreadyExists() external whenTheCallerIsTheAdmin whenTheMarketIdIsNotZero {
        // it should revert: BTC exists at 1000x, even with otherwise invalid arguments. A market is a feed at one
        // leverage (ADR 0008), so once BTC has a 500x market, that pair exists too.
        flashOption.createMarket(Defaults.BTC, 500, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        _fillMarketList();
        ConfigParams memory c = Defaults.marketConfig();
        c.enabled = true;
        vm.expectRevert(Errors.MarketExists.selector);
        flashOption.createMarket(Defaults.BTC, Defaults.LEVERAGE, 1, c);
        vm.expectRevert(Errors.MarketExists.selector);
        flashOption.createMarket(Defaults.BTC, 500, 1, c);
    }

    modifier givenTheMarketDoesNotExistYet() {
        _;
    }

    function test_RevertWhen_ThePriceExponentIsOutsideMinus18To0()
        external
        whenTheCallerIsTheAdmin
        whenTheMarketIdIsNotZero
        givenTheMarketDoesNotExistYet
    {
        // it should revert: just outside each end, and both extremes
        _fillMarketList();
        int8[4] memory exponents = [int8(-19), 1, type(int8).min, type(int8).max];
        for (uint256 i; i < exponents.length; ++i) {
            vm.expectRevert(Errors.InvalidLeverageParams.selector);
            flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, exponents[i], Defaults.marketConfig());
        }
    }

    modifier whenThePriceExponentIsMinus18To0() {
        _;
    }

    function test_RevertWhen_TheSettingsSwitchTheMarketOn()
        external
        whenTheCallerIsTheAdmin
        whenTheMarketIdIsNotZero
        givenTheMarketDoesNotExistYet
        whenThePriceExponentIsMinus18To0
    {
        // it should revert: a market is always created switched off
        _fillMarketList();
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, _enabledConfig());
    }

    modifier whenTheSettingsLeaveTheMarketOff() {
        _;
    }

    function test_RevertWhen_TheSettingsAreInvalid()
        external
        whenTheCallerIsTheAdmin
        whenTheMarketIdIsNotZero
        givenTheMarketDoesNotExistYet
        whenThePriceExponentIsMinus18To0
        whenTheSettingsLeaveTheMarketOff
    {
        // it should revert: a zero minimum stake, a duplicate duration, a line of 10 bp, an open gate off or above
        // 100%, and a clock skew over 30 seconds (ADR 0009)
        _fillMarketList();
        ConfigParams memory c = Defaults.marketConfig();
        c.minStake = 0;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        c = Defaults.marketConfig();
        c.durations[1].durationSecs = c.durations[0].durationSecs;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        // The line limit is the market's leverage's: at 1000x, θ × 1000 must stay below 1e7.
        c = Defaults.marketConfig();
        c.durations[0].thetaMaxE7 = 10_000;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        // A leverage outside 1x to 10,000x, with settings that are valid at any leverage in range.
        c = Defaults.marketConfig();
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, 0, Defaults.PRICE_EXPONENT, c);
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, 10_001, Defaults.PRICE_EXPONENT, c);
        // The open gate off or above 100%, and a clock skew over 30 seconds.
        c.maxExposureBps = 0;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        c.maxExposureBps = 10_001;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        c = Defaults.marketConfig();
        c.clockSkewSecs = 31;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
    }

    modifier whenTheSettingsAreValid() {
        _;
    }

    function test_RevertGiven_65535MarketsAlreadyExist()
        external
        whenTheCallerIsTheAdmin
        whenTheMarketIdIsNotZero
        givenTheMarketDoesNotExistYet
        whenThePriceExponentIsMinus18To0
        whenTheSettingsLeaveTheMarketOff
        whenTheSettingsAreValid
    {
        // it should revert: index 65,534 is the last that fits, because index + 1 is stored in a uint16
        _setMarketCount(type(uint16).max - 1);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        assertEq(
            LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.ETH, Defaults.LEVERAGE),
            type(uint16).max,
            "the last index"
        );
        vm.expectRevert(Errors.MathOverflow.selector);
        flashOption.createMarket(
            keccak256("one market too many"), Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig()
        );
    }

    function test_GivenFewerThan65535MarketsExist()
        external
        whenTheCallerIsTheAdmin
        whenTheMarketIdIsNotZero
        givenTheMarketDoesNotExistYet
        whenThePriceExponentIsMinus18To0
        whenTheSettingsLeaveTheMarketOff
        whenTheSettingsAreValid
    {
        ConfigParams memory c = Defaults.marketConfig();

        // it should emit {MarketCreated}, then {ConfigUpdated}
        vm.expectEmit(address(flashOption));
        emit Events.MarketCreated(Defaults.ETH, Defaults.LEVERAGE, 1, Defaults.PRICE_EXPONENT);
        vm.expectEmit(address(flashOption));
        emit Events.ConfigUpdated(Defaults.ETH, Defaults.LEVERAGE, users.admin, c);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);

        // it should store the market, switched off and unpaused
        _assertMarket(1, Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, false, c);

        // it should give it the next index
        assertEq(
            LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.ETH, Defaults.LEVERAGE), 2, "ETH is index 1"
        );
        assertEq(LayoutReader.marketCount(address(flashOption)), 2, "two markets");
        _assertMarket(0, Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, false, _enabledConfig()); // BTC
        // untouched

        // the exponent's limits are accepted too
        flashOption.createMarket(keccak256("exponent -18"), Defaults.LEVERAGE, -18, c);
        flashOption.createMarket(keccak256("exponent 0"), Defaults.LEVERAGE, 0, c);
        assertEq(LayoutReader.marketCount(address(flashOption)), 4, "four markets");

        // and so is the widest line the market's 1000x allows: 9.999 bp, as 9,999 × 1000 < 1e7
        c.durations[0].thetaMaxE7 = 9999;
        flashOption.createMarket(keccak256("the widest line"), Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        assertEq(LayoutReader.marketCount(address(flashOption)), 5, "five markets");

        // The same feed at another leverage is a market of its own: ETH at 500x, at the next index, with its
        // leverage stored and in both events.
        vm.expectEmit(address(flashOption));
        emit Events.MarketCreated(Defaults.ETH, 500, 5, Defaults.PRICE_EXPONENT);
        vm.expectEmit(address(flashOption));
        emit Events.ConfigUpdated(Defaults.ETH, 500, users.admin, c);
        flashOption.createMarket(Defaults.ETH, 500, Defaults.PRICE_EXPONENT, c);
        _assertMarket(5, Defaults.ETH, 500, Defaults.PRICE_EXPONENT, false, c);
        assertEq(LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.ETH, 500), 6, "ETH at 500x is index 5");
        assertEq(LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.ETH, Defaults.LEVERAGE), 2, "1000x: 1");
    }

    /// @dev Makes the market list full (65,535 markets), so the last check fails too.
    function _fillMarketList() private {
        _setMarketCount(type(uint16).max);
    }

    /// @dev Writes `marketCount` (bytes 22-23 of `Layout` slot 0) straight into storage, keeping the rest of the slot.
    function _setMarketCount(uint16 count) private {
        bytes32 slot = bytes32(LayoutReader.ROOT);
        uint256 word = uint256(vm.load(address(flashOption), slot));
        word = (word & ~(uint256(type(uint16).max) << 176)) | (uint256(count) << 176);
        vm.store(address(flashOption), slot, bytes32(word));
    }
}
