// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Breaker, Position, Side} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetBreaker_Concrete_Test
/// @notice Every branch of `setBreaker`, from test/concrete/setBreaker/setBreaker.tree (docs/ARCHITECTURE.md §8.1,
///         §8.11).
/// @dev The limit and the window share `_setBreaker` with `initialize`, whose tests cover the same window bounds at
///      deployment. To show what `setBreaker` leaves alone, the breaker is first tripped for real: a $10 limit, then
///      two winners settled together at the 4x cap, $30 profit each.
contract SetBreaker_Concrete_Test is Settlement_Base_Test {
    function test_RevertWhen_TheCallerIsNotTheAdmin() external {
        // it should revert: every user but the admin, with a window that is out of bounds as well
        address[] memory callers = _everyoneBut(users.admin, users.admin);
        bytes32 adminRole = flashOption.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], adminRole)
            );
            vm.prank(callers[i]);
            flashOption.setBreaker(0, 0);
        }
    }

    modifier whenTheCallerIsTheAdmin() {
        _;
    }

    function test_RevertWhen_TheWindowIsUnder60SecondsOrOver1Day() external whenTheCallerIsTheAdmin {
        // it should revert: no window, 59 seconds, a day and a second, and the largest window
        uint32[4] memory refused = [uint32(0), 59, 1 days + 1, type(uint32).max];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(Errors.InvalidBreakerParams.selector);
            _setBreaker(Defaults.BREAKER_MAX_NET_PROFIT, refused[i]);
        }
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        assertEq(b.windowSecs, Defaults.BREAKER_WINDOW, "the window is unchanged");
        assertEq(b.maxNetProfit, Defaults.BREAKER_MAX_NET_PROFIT, "and so is the limit");
    }

    function test_WhenTheWindowIs60SecondsTo1Day() external whenTheCallerIsTheAdmin {
        Breaker memory tripped = _tripForReal();
        // Off with the shortest window, the smallest limit with the longest, and the largest limit with an hour.
        uint64[3] memory limits = [uint64(0), 1, type(uint64).max];
        uint32[3] memory windows = [uint32(60), 1 days, 1 hours];
        for (uint256 i; i < limits.length; ++i) {
            // it should emit {CircuitBreakerUpdated}
            vm.expectEmit(address(flashOption));
            emit Events.CircuitBreakerUpdated(limits[i], windows[i]);
            _setBreaker(limits[i], windows[i]);

            // it should store the limit and the window
            Breaker memory b = LayoutReader.breaker(address(flashOption));
            assertEq(b.maxNetProfit, limits[i], "the limit");
            assertEq(b.windowSecs, windows[i], "the window");
            // it should leave the counters, the window start and a trip alone
            assertEq(b.profitOut, tripped.profitOut, "profit out");
            assertEq(b.lossIn, tripped.lossIn, "losses in");
            assertEq(b.windowStart, tripped.windowStart, "the window start");
            assertTrue(b.tripped, "still tripped: switching the breaker off doesn't clear a trip");
            assertEq(abi.encode(flashOption.getBreaker()), abi.encode(b), "read back");
        }
    }

    /// @dev Sets the limit to $10, then settles two winners together at the 4x cap: $60 of profit trips it.
    function _tripForReal() private returns (Breaker memory b) {
        _setBreaker(10e6, Defaults.BREAKER_WINDOW);
        Position memory p = _bet(users.alice, "a", Side.Call);
        _bet(users.bob, "b", Side.Call);
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(300), _end(p), _ids("a", "b"));
        b = LayoutReader.breaker(address(flashOption));
        assertTrue(b.tripped, "tripped");
        assertEq(b.profitOut, 60e6, "$30 each");
    }

    /// @dev The admin sets the breaker's limit and window.
    function _setBreaker(uint64 maxNetProfit, uint32 windowSecs) private {
        vm.prank(users.admin);
        flashOption.setBreaker(maxNetProfit, windowSecs);
    }
}
