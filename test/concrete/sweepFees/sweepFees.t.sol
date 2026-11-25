// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SweepFees_Concrete_Test
/// @notice Every branch of `sweepFees`, from test/concrete/sweepFees/sweepFees.tree (docs/ARCHITECTURE.md §8.8):
///         anyone can send the accrued fees to the fee recipient, and a blocked recipient only delays the sweep.
/// @dev Pending fees are written straight into storage (settle and sell accrue them later), backed by minted tokens.
contract SweepFees_Concrete_Test is Base_Test {
    uint64 internal constant FEES = 50e6;

    function test_RevertWhen_NoFeesArePending() external {
        // it should revert
        vm.expectRevert(Errors.InvalidAmount.selector);
        flashOption.sweepFees();
    }

    modifier whenFeesArePending() {
        _mintUsdg(address(flashOption), FEES);
        _writeLayout(address(flashOption), 5, 0, 64, FEES); // pool.feesPending
        _;
    }

    function test_RevertWhen_TheTransferToTheFeeRecipientFails() external whenFeesArePending {
        // it should revert, and the fees stay pending: the fee recipient is frozen
        vm.prank(usdgAdmin);
        usdg.freeze(users.feeRecipient);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        flashOption.sweepFees();
        assertEq(LayoutReader.pool(address(flashOption)).feesPending, FEES, "fees still pending");
        assertEq(usdg.balanceOf(address(flashOption)), FEES, "nothing left the contract");
    }

    function test_WhenTheTransferSucceeds() external whenFeesArePending {
        uint256 slot5 = LayoutReader.word(address(flashOption), 5);

        // it should emit {FeesSwept}
        vm.expectEmit(address(flashOption));
        emit Events.FeesSwept(users.feeRecipient, FEES);
        vm.prank(users.eve); // anyone may sweep; the fees still go to the fee recipient
        flashOption.sweepFees();

        // it should send every pending fee to the fee recipient, whoever calls
        assertEq(usdg.balanceOf(users.feeRecipient), FEES, "the fee recipient has them");
        assertEq(usdg.balanceOf(users.eve), 0, "the caller gets nothing");
        assertEq(usdg.balanceOf(address(flashOption)), 0, "the contract sent them all");
        // it should clear the pending fees, and nothing else in their slot
        assertEq(LayoutReader.pool(address(flashOption)).feesPending, 0, "no fees pending");
        assertEq(LayoutReader.word(address(flashOption), 5), slot5 & ~uint256(type(uint64).max), "rest of slot 5");
        _assertBooksBalanced(address(flashOption));
    }
}
