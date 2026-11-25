// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {PoolState, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Repay_Concrete_Test
/// @notice Every branch of `repay`, from test/concrete/repay/repay.tree (docs/ARCHITECTURE.md §8.7): on a pool seeded
///         with $20 and no exposure gate, alice's and bob's $10 calls settle at the 4x cap. Alice's $30 profit is
///         paid $20 now and owed $10 (the head, place 0); bob's is owed in full, $30 (place 1). Free money is then
///         zero. Eve, who holds no role, calls `repay`: anyone may.
/// @dev The two checks are tested in order: a halted contract is refused even with `maxCount` broken too. Success is
///      checked by `_expectRepaid`, which walks the queue from its head with its own model and compares every log,
///      every pool field, every slot of every IOU it reaches, the queue and every balance.
contract Repay_Concrete_Test is Settlement_Base_Test {
    bytes32 internal constant A = keccak256("alice's call");
    bytes32 internal constant B = keccak256("bob's call");

    function setUp() public override {
        super.setUp();
        _useSmallPool(20e6);
        _bet(users.alice, A, Side.Call);
        Position memory b = _bet(users.bob, B, Side.Call);
        vm.warp(_end(b));
        _expectSettled(Examples.priceAt(300), _end(b), _ids(A, B));
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.totalOwed, 40_000_000, "$10 + $30 owed");
        assertEq(pool.total, pool.lockedMargin, "no free money");
    }

    function test_RevertGiven_TheContractIsHalted() external {
        // it should revert, before the count is checked
        vm.prank(users.guardian);
        flashOption.setHalted(true);
        vm.expectRevert(Errors.Halted.selector);
        vm.prank(users.eve);
        flashOption.repay(0);
    }

    modifier givenTheContractIsNotHalted() {
        _;
    }

    function test_RevertWhen_MaxCountIsZeroOrAbove50() external givenTheContractIsNotHalted {
        // it should revert: 0, 51 and the largest count
        uint256[3] memory refused = [uint256(0), 51, type(uint256).max];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(Errors.InvalidMaxCount.selector);
            vm.prank(users.eve);
            flashOption.repay(refused[i]);
        }

        // 1 and 50 are accepted (with no free money, they repay nothing).
        (, uint256 repaid) = _expectRepaid(1, users.eve);
        assertEq(repaid, 0, "1 is accepted");
        (, repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 0, "50 is accepted");
    }

    modifier whenMaxCountIs1To50() {
        _;
    }

    function test_GivenTheQueueIsEmpty() external givenTheContractIsNotHalted whenMaxCountIs1To50 {
        // it should change nothing: a new pool with free money and nobody owed
        _useSmallPool(100e6);
        (, uint256 repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 0, "nothing repaid");
    }

    modifier givenSomeoneIsOwed() {
        _;
    }

    function test_GivenThereIsNoFreeMoney()
        external
        givenTheContractIsNotHalted
        whenMaxCountIs1To50
        givenSomeoneIsOwed
    {
        // it should change nothing
        (, uint256 repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 0, "nothing repaid");
        assertEq(LayoutReader.pool(address(flashOption)).nextRepaySeq, 0, "alice's IOU is still the head");
    }

    modifier givenThereIsFreeMoney() {
        _;
    }

    function test_RevertWhen_APayoutHasTooLittleGas()
        external
        givenTheContractIsNotHalted
        whenMaxCountIs1To50
        givenSomeoneIsOwed
        givenThereIsFreeMoney
    {
        // it should revert: a caller that starves the call can't push alice's repayment into claimable. Every gas
        // limit up to the least that repays reverts, some of them with `InsufficientGasForPayout`.
        _fund(users.bob, 100e6);
        bytes memory call_ = abi.encodeCall(flashOption.repay, (1));
        bytes32 starved = keccak256(abi.encodeWithSelector(Errors.InsufficientGasForPayout.selector));
        bool sawTheGuard;
        bool repaid;
        for (uint256 gasLimit = 20_000; gasLimit < 400_000 && !repaid; gasLimit += 1000) {
            vm.prank(users.eve);
            bytes memory reason;
            (repaid, reason) = address(flashOption).call{gas: gasLimit}(call_);
            if (keccak256(reason) == starved) sawTheGuard = true;
        }
        assertTrue(sawTheGuard, "too little gas for the payout reverts InsufficientGasForPayout");
        assertTrue(repaid, "and enough gas repays");

        // At the least gas that repays, alice is paid in full, and nothing waits in claimable.
        assertEq(usdg.balanceOf(users.alice), 29_600_000 + 9_800_000, "her settle payout, then $10 less 2%");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 0, "nothing deferred");
    }

    modifier whenEveryPayoutHasTheGasItNeeds() {
        _;
    }

    function test_GivenTheTokenRefusesAPayout()
        external
        givenTheContractIsNotHalted
        whenMaxCountIs1To50
        givenSomeoneIsOwed
        givenThereIsFreeMoney
        whenEveryPayoutHasTheGasItNeeds
    {
        // Paxos freezes alice, whose IOU is the head.
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        _fund(users.bob, 100e6);

        // it should keep it for the owner to claim
        // it should go on down the queue
        (Ending[] memory endings, uint256 repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 2, "both repaid");
        assertTrue(endings[0].deferred, "alice's repayment waits");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 9_800_000, "in her claimable balance");
        assertFalse(endings[1].deferred, "bob is paid");
        assertEq(LayoutReader.pool(address(flashOption)).totalOwed, 0, "nobody is owed");
    }

    function test_GivenFreeMoneyCoversOnlyPartOfTheHead()
        external
        givenTheContractIsNotHalted
        whenMaxCountIs1To50
        givenSomeoneIsOwed
        givenThereIsFreeMoney
        whenEveryPayoutHasTheGasItNeeds
    {
        _fund(users.bob, 4e6);

        // it should pay the head all the free money, less the winner fee
        // it should keep the rest owed at the head
        // it should stop there
        (Ending[] memory endings, uint256 repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 1, "one repayment");
        assertEq(endings[0].repayment.amount, 4_000_000, "all the free money");
        assertEq(endings[0].repayment.winnerFee, 80_000, "2% of it");
        assertEq(endings[0].repayment.toUser, 3_920_000, "to alice");
        assertEq(endings[0].repayment.remaining, 6_000_000, "$6 still owed");
        assertEq(uint8(endings[0].status), uint8(Status.Owed), "still an IOU");
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.nextRepaySeq, 0, "still the head");
        assertEq(LayoutReader.position(address(flashOption), B).owed, 30_000_000, "bob waits behind her");
    }

    function test_GivenFreeMoneyCoversTheHead()
        external
        givenTheContractIsNotHalted
        whenMaxCountIs1To50
        givenSomeoneIsOwed
        givenThereIsFreeMoney
        whenEveryPayoutHasTheGasItNeeds
    {
        _fund(users.bob, 100e6);

        // it should close the head and move on to the next IOU
        // it should repay in queue order, at most maxCount
        (Ending[] memory endings, uint256 repaid) = _expectRepaid(1, users.eve);
        assertEq(repaid, 1, "one, as asked");
        assertEq(endings[0].repayment.amount, 10_000_000, "alice's $10");
        assertEq(endings[0].repayment.toUser, 9_800_000, "less 2%");
        assertEq(uint8(endings[0].status), uint8(Status.Closed), "closed");
        assertEq(LayoutReader.pool(address(flashOption)).nextRepaySeq, 1, "bob's IOU is the head");

        // it should accrue the winner fees once
        // it should emit {OwedRepaid} for each repayment
        // it should return the number repaid
        (endings, repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 1, "bob's, and the queue is empty");
        assertEq(endings[0].repayment.toUser, 29_400_000, "$30 less 2%");
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.nextRepaySeq, pool.nextQueueSeq, "the queue is empty");
        assertEq(pool.totalOwed, 0, "nobody is owed");
        assertEq(pool.owedPositions, 0, "no IOUs");
        assertEq(pool.feesPending, 400_000 + 200_000 + 600_000, "the settle's winner fee, then 2% of each repayment");
    }
}
