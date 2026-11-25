// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Base_Test} from "../../Base.t.sol";
import {ManicFlashOptionHarness} from "../../harnesses/ManicFlashOptionHarness.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Claim_Concrete_Test
/// @notice Every branch of `claim`, from test/concrete/claim/claim.tree (docs/ARCHITECTURE.md §8.8): a payout that
///         waited because its recipient was frozen is paid once the recipient can receive again, to that recipient
///         only, whoever calls.
/// @dev The claimable balance is made the real way: a payout through `_pay` (on the harness) to a frozen recipient.
contract Claim_Concrete_Test is Base_Test {
    ManicFlashOptionHarness internal harness;
    uint64 internal constant FUNDS = 100e6;
    uint64 internal constant OWED = 40e6;
    bytes32 internal constant POSITION_ID = keccak256("a frozen winner's position");

    function setUp() public override {
        super.setUp();
        harness = _deployHarness(_defaultInitParams());
        _mintUsdg(address(harness), FUNDS);
    }

    function test_RevertWhen_TheAccountHasNothingToClaim() external {
        // it should revert
        vm.expectRevert(Errors.NothingToClaim.selector);
        harness.claim(users.bob);
    }

    modifier whenTheAccountHasAClaimableBalance() {
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        harness.exposed_pay(users.alice, OWED, POSITION_ID);
        assertEq(LayoutReader.claimable(address(harness), users.alice), OWED, "the payout waited");
        _;
    }

    function test_RevertWhen_TheTransferToTheAccountFails() external whenTheAccountHasAClaimableBalance {
        // it should revert, keeping the balance claimable: alice is still frozen
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        harness.claim(users.alice);
        assertEq(LayoutReader.claimable(address(harness), users.alice), OWED, "still claimable");
        assertEq(LayoutReader.pool(address(harness)).totalClaimable, OWED, "total claimable unchanged");
        assertEq(usdg.balanceOf(address(harness)), FUNDS, "nothing left the contract");
    }

    function test_WhenTheTransferSucceeds() external whenTheAccountHasAClaimableBalance {
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.alice);

        // it should emit {Claimed}
        vm.expectEmit(address(harness));
        emit Events.Claimed(users.alice, OWED);
        vm.prank(users.eve); // a stranger calls, but the money goes to alice
        harness.claim(users.alice);

        // it should pay the account, whoever calls
        assertEq(usdg.balanceOf(users.alice), OWED, "alice is paid");
        assertEq(usdg.balanceOf(users.eve), 0, "the caller gets nothing");
        assertEq(usdg.balanceOf(address(harness)), FUNDS - OWED, "from the contract");
        // it should clear the account's balance and lower the total claimable
        assertEq(LayoutReader.claimable(address(harness), users.alice), 0, "nothing left to claim");
        assertEq(LayoutReader.pool(address(harness)).totalClaimable, 0, "total claimable");
        _assertBooksBalanced(address(harness));
    }
}
