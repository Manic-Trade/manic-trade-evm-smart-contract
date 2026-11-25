// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {InitParams} from "../../src/types/ParamTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {MockDecimalsToken} from "../mocks/MockDecimalsToken.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Initialize_Fuzz_Test
/// @notice `initialize` accepts every setting inside the documented ranges, stores it exactly, and rejects every
///         setting outside them with its own error. The concrete tests (test/concrete/initialize/) pin the exact
///         boundaries and the check order; these properties cover every value in between.
/// @dev Inputs are bounded with `bound`, never `vm.assume`. CI runs 10,000 cases per property.
contract Initialize_Fuzz_Test is Base_Test {
    /// @dev Any decimals from 6 to 9, any floor from 500 whole tokens up, any refund delay that is 0 or at least an
    ///      hour, any window from 60 s to a day, any limit and any admin delay: accepted and stored as given.
    function testFuzz_EveryValidSettingIsAcceptedAndStored(
        uint8 decimals,
        uint64 poolFloor,
        uint48 refundDelaySecs,
        bool refundOff,
        uint32 windowSecs,
        uint64 maxNetProfit,
        uint48 adminTransferDelay
    )
        external
    {
        decimals = uint8(bound(decimals, 6, 9));
        poolFloor = uint64(bound(poolFloor, 500 * 10 ** decimals, type(uint64).max));
        refundDelaySecs = refundOff ? 0 : uint48(bound(refundDelaySecs, 1 hours, type(uint48).max));
        windowSecs = uint32(bound(windowSecs, 60, 86_400));

        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(new MockDecimalsToken(decimals)));
        p.poolFloor = poolFloor;
        p.refundDelaySecs = refundDelaySecs;
        p.breakerWindowSecs = windowSecs;
        p.breakerMaxNetProfit = maxNetProfit;
        p.adminTransferDelay = adminTransferDelay;
        address proxy = _deployProxy(p);

        assertEq(LayoutReader.tokenDecimals(proxy), decimals, "decimals");
        assertEq(LayoutReader.pool(proxy).poolFloor, poolFloor, "floor");
        assertEq(LayoutReader.refundDelaySecs(proxy), refundDelaySecs, "refund delay");
        assertEq(LayoutReader.breaker(proxy).windowSecs, windowSecs, "window");
        assertEq(LayoutReader.breaker(proxy).maxNetProfit, maxNetProfit, "limit");
    }

    /// @dev Decimals outside 6 to 9 are rejected, naming the decimals.
    function testFuzz_DecimalsOutsideSixToNineAreRejected(uint8 decimals) external {
        if (decimals >= 6 && decimals <= 9) decimals += 4; // moves 6-9 onto 10-13
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(new MockDecimalsToken(decimals)));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenDecimals.selector, decimals));
        _deployProxy(p);
    }

    /// @dev Any floor under 500 whole tokens is rejected, whatever the decimals.
    function testFuzz_AFloorUnderFiveHundredTokensIsRejected(uint8 decimals, uint64 poolFloor) external {
        decimals = uint8(bound(decimals, 6, 9));
        poolFloor = uint64(bound(poolFloor, 0, 500 * 10 ** decimals - 1));
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(new MockDecimalsToken(decimals)));
        p.poolFloor = poolFloor;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        _deployProxy(p);
    }

    /// @dev Any refund delay from 1 second to just under an hour is rejected.
    function testFuzz_ARefundDelayUnderAnHourIsRejected(uint48 refundDelaySecs) external {
        InitParams memory p = _defaultInitParams();
        p.refundDelaySecs = uint48(bound(refundDelaySecs, 1, 1 hours - 1));
        vm.expectRevert(Errors.InvalidRefundDelay.selector);
        _deployProxy(p);
    }

    /// @dev Any breaker window outside 60 seconds to a day is rejected.
    function testFuzz_ABreakerWindowOutsideItsRangeIsRejected(uint32 windowSecs) external {
        if (windowSecs >= 60 && windowSecs <= 86_400) windowSecs = windowSecs < 43_230 ? 59 : 86_401;
        InitParams memory p = _defaultInitParams();
        p.breakerWindowSecs = windowSecs;
        vm.expectRevert(Errors.InvalidBreakerParams.selector);
        _deployProxy(p);
    }
}
