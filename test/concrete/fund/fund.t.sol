// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {InitParams} from "../../../src/types/ParamTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockFeeOnTransferToken} from "../../mocks/MockFeeOnTransferToken.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Fund_Concrete_Test
/// @notice Every branch of `fund`, from test/concrete/fund/fund.tree (docs/ARCHITECTURE.md §8.8). Anyone may fund the
///         pool, and the pool counts only what actually arrives.
contract Fund_Concrete_Test is Base_Test {
    function test_RevertWhen_TheAmountIsZero() external {
        // it should revert
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(users.alice);
        flashOption.fund(0);
    }

    modifier whenTheAmountIsNotZero() {
        _;
    }

    function test_RevertWhen_ThePoolTotalWouldPass64Bits() external whenTheAmountIsNotZero {
        // it should revert, before pulling anything: alice holds no tokens and approved nothing, so a pull first
        // would fail with the token's own error instead
        _writeLayout(address(flashOption), 3, 0, 64, type(uint64).max);
        vm.expectRevert(Errors.MathOverflow.selector);
        vm.prank(users.alice);
        flashOption.fund(1);
    }

    modifier whenThePoolTotalFits64Bits() {
        _;
    }

    function test_RevertWhen_TheTokenMovesADifferentAmountThanAsked()
        external
        whenTheAmountIsNotZero
        whenThePoolTotalFits64Bits
    {
        // it should revert: this token burns 1 unit of every transfer, so 99 of the 100 arrive
        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken();
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(feeToken));
        ManicFlashOption proxy = ManicFlashOption(_deployProxy(p));
        feeToken.mint(users.alice, 100);
        vm.startPrank(users.alice);
        feeToken.approve(address(proxy), 100);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferAmountMismatch.selector, 100, 99));
        proxy.fund(100);
        vm.stopPrank();
    }

    function test_WhenTheTokenMovesExactlyTheAmount() external whenTheAmountIsNotZero whenThePoolTotalFits64Bits {
        uint256[3] memory restBefore = [
            LayoutReader.word(address(flashOption), 4),
            LayoutReader.word(address(flashOption), 5),
            LayoutReader.word(address(flashOption), 6)
        ];
        uint64 aliceAmount = 1000e6;
        uint64 bobAmount = 500e6;
        _mintUsdg(users.alice, aliceAmount);
        vm.prank(users.alice);
        usdg.approve(address(flashOption), aliceAmount);

        // it should emit {PoolFunded}
        vm.expectEmit(address(flashOption));
        emit Events.PoolFunded(users.alice, aliceAmount);
        vm.prank(users.alice);
        flashOption.fund(aliceAmount);

        // it should take the tokens from the funder, whoever it is
        assertEq(usdg.balanceOf(users.alice), 0, "alice paid");
        assertEq(usdg.balanceOf(address(flashOption)), aliceAmount, "the pool holds them");
        // it should add them to the pool total as free money
        assertEq(LayoutReader.pool(address(flashOption)).total, aliceAmount, "total");
        assertEq(LayoutReader.pool(address(flashOption)).lockedMargin, 0, "free money, not held for a bet");

        // A second funder, also without any role.
        _fund(users.bob, bobAmount);
        assertEq(LayoutReader.pool(address(flashOption)).total, aliceAmount + bobAmount, "both funds counted");
        assertEq(LayoutReader.word(address(flashOption), 3), aliceAmount + bobAmount, "slot 3 holds only the total");
        assertEq(LayoutReader.word(address(flashOption), 4), restBefore[0], "slot 4 unchanged");
        assertEq(LayoutReader.word(address(flashOption), 5), restBefore[1], "slot 5 unchanged");
        assertEq(LayoutReader.word(address(flashOption), 6), restBefore[2], "slot 6 unchanged");
        _assertBooksBalanced(address(flashOption));
    }
}
