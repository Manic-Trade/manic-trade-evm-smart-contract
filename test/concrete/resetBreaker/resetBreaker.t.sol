// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Breaker, Position, Side} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title ResetBreaker_Concrete_Test
/// @notice Every branch of `resetBreaker`, from test/concrete/resetBreaker/resetBreaker.tree (docs/ARCHITECTURE.md
///         §8.1, §8.11).
/// @dev The breaker is tripped for real first: a $10 limit, then two winners settled together at the 4x cap, $30
///      profit each. Ten minutes later, inside the same window, the operator resets it.
contract ResetBreaker_Concrete_Test is Settlement_Base_Test {
    function setUp() public override {
        super.setUp();
        vm.prank(users.admin);
        flashOption.setBreaker(10e6, Defaults.BREAKER_WINDOW);
        Position memory p = _bet(users.alice, "a", Side.Call);
        _bet(users.bob, "b", Side.Call);
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(300), _end(p), _ids("a", "b"));
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "tripped");
        vm.warp(block.timestamp + 10 minutes);
    }

    function test_RevertWhen_TheCallerIsNotTheOperator() external {
        // it should revert: every user but the operator, the admin and the guardian included
        address[] memory callers = _everyoneBut(users.operator, users.operator);
        bytes32 operatorRole = flashOption.OPERATOR_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], operatorRole
                )
            );
            vm.prank(callers[i]);
            flashOption.resetBreaker();
        }
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "still tripped");
    }

    function test_WhenTheCallerIsTheOperator() external {
        // it should emit {CircuitBreakerReset}
        vm.expectEmit(address(flashOption));
        emit Events.CircuitBreakerReset(users.operator);
        vm.prank(users.operator);
        flashOption.resetBreaker();

        Breaker memory b = LayoutReader.breaker(address(flashOption));
        // it should clear a trip
        assertFalse(b.tripped, "cleared");
        // it should zero both counters and start the window now
        assertEq(b.profitOut, 0, "no profit out");
        assertEq(b.lossIn, 0, "no losses in");
        assertEq(b.windowStart, block.timestamp, "the window starts now");
        // it should leave the limit and the window's length alone
        assertEq(b.maxNetProfit, 10e6, "the limit");
        assertEq(b.windowSecs, Defaults.BREAKER_WINDOW, "the window's length");

        // it should let open and sell work again: eve's bet opens, then sells flat
        _bet(users.eve, "after the reset", Side.Call);
        _expectSale("after the reset", Defaults.ENTRY_PRICE, Defaults.STAKE, Defaults.STAKE, Defaults.STAKE);

        // A reset with nothing tripped is allowed too, and emits again.
        vm.expectEmit(address(flashOption));
        emit Events.CircuitBreakerReset(users.operator);
        vm.prank(users.operator);
        flashOption.resetBreaker();
    }
}
