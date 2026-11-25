// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {PoolState, Position, Side, Status} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Repay_Scenario_Test
/// @notice Repaying the IOU queue end to end, with every expected number to the base unit: a part repayment from the
///         free money there is, none without free money, and a loss and top-ups that repay the queue in order until
///         it is empty. `setUp` settles bets on a pool seeded with $20, as the settle and sale scenarios do, which
///         leaves four IOUs of $10, $30, $3 and $3, and $1.908 of free money.
/// @dev The later tests start with the first one's repayment (`_repayPartOfTheHead`). Every call runs through
///      `_expectRepaid`, which walks the queue from its head with its own model and checks every log, pool field,
///      slot, queue entry and balance. Eve, who holds no role, calls `repay`: anyone may. `repay` takes only a count,
///      and the contract walks the queue from its head itself.
contract Repay_Scenario_Test is Settlement_Base_Test {
    /// @dev An open position whose stake repay must never touch.
    bytes32 internal constant X = "x";

    function setUp() public override {
        super.setUp();
        _useSmallPool(20e6);
        // In one batch, the first winner is partly paid ($10 owed) and the second fully queued ($30 owed).
        _bet(users.alice, "a", Side.Call);
        _settleAtExpiry(_bet(users.alice, "b", Side.Call), 300, _ids("a", "b"));
        // A loser below the floor pays no fee ($0.954 freed), and a later winner is fully queued ($3 owed).
        _settleAtExpiry(_bet(users.alice, "c", Side.Call), -8, _ids("c"));
        _settleAtExpiry(_bet(users.alice, "d", Side.Call), 8, _ids("d"));
        // A loser ($0.954 more freed): the settle scenario's last bet, which the gate on total owed lets in at its
        // limit.
        _settleAtExpiry(_bet(users.alice, "e", Side.Call), -8, _ids("e"));
        // A winner fully queued at expiry ($3 owed): the sale scenario's bet whose sale the queue refused.
        _settleAtExpiry(_bet(users.alice, "p", Side.Call), 8, _ids("p"));

        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.nextQueueSeq - pool.nextRepaySeq, 4, "the set-up leaves four IOUs");
        assertEq(pool.nextRepaySeq, 0, "nothing repaid yet");
        assertEq(pool.totalOwed, 46_000_000, "$10 + $30 + $3 + $3 owed");
        assertEq(pool.total - pool.lockedMargin, 1_908_000, "two losses' $0.954 each of free money");
    }

    /// @dev Anyone repays part of the queue head from the free money there is; an open stake stays untouched.
    function test_AnyoneRepaysPartOfTheHeadAndAnOpenStakeStaysUntouched() external {
        _repayPartOfTheHead();
    }

    /// @dev With no free money, a repay pays nothing and leaves the head as it is.
    function test_WithNoFreeMoneyNothingIsPaid() external {
        _repayPartOfTheHead();
        (Ending[] memory endings, uint256 repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 0, "no repayment");
        assertEq(endings.length, 0, "and no event");
    }

    /// @dev A loss and a top-up repay the queue in order, stopping at the first IOU they can't cover; a further top-up
    ///      empties the queue.
    function test_ALossAndATopUpRepayTheQueueInOrder() external {
        Position memory x = _repayPartOfTheHead();

        // x settles one unit inside its line: it pays back 70% of the stake, and the other 30% becomes free money.
        vm.warp(_end(x));
        _expectSettled(x.liqPrice + 1, _end(x), _ids(X));
        _fund(users.bob, 37e6);
        (Ending[] memory endings, uint256 repaid) = _expectRepaid(3, users.eve);
        assertEq(repaid, 3, "three repayments");
        assertEq(endings[0].repayment.amount, 8_092_000, "the rest of a, in full");
        assertEq(endings[1].repayment.amount, 30_000_000, "b, in full");
        assertEq(endings[2].repayment.amount, 1_908_000, "what is left, to d");
        assertEq(endings[2].repayment.remaining, 1_092_000, "d is paid in part and becomes the head");
        assertEq(LayoutReader.pool(address(flashOption)).nextRepaySeq, 2, "the head is d");

        // A further top-up empties the queue.
        _fund(users.bob, 5e6);
        (endings, repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 2, "d and p");
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.nextRepaySeq, pool.nextQueueSeq, "the queue is empty");
        assertEq(pool.totalOwed, 0, "nobody is owed");
        assertEq(uint8(LayoutReader.position(address(flashOption), "p").status), uint8(Status.Closed), "p closed");
    }

    /// @dev The first test's steps: x opens, and a stranger repays the head from all the free money there is.
    /// @return x The open position.
    function _repayPartOfTheHead() private returns (Position memory x) {
        x = _bet(users.alice, X, Side.Call);
        (Ending[] memory endings, uint256 repaid) = _expectRepaid(50, users.eve);
        assertEq(repaid, 1, "one repayment");
        assertEq(endings[0].repayment.amount, 1_908_000, "all of the free money, none of the open stake");
        assertEq(endings[0].repayment.winnerFee, 38_160, "2% of it");
        assertEq(endings[0].repayment.toUser, 1_869_840, "to the owner");
        assertEq(endings[0].repayment.remaining, 8_092_000, "the head is still owed");
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.total, pool.lockedMargin, "no free money left");
        assertEq(pool.lockedMargin, x.stake, "x's stake is held, untouched");
    }

    /// @dev Settles `ids` at the expiry second of `p` (which they share), `dollars` from the entry.
    function _settleAtExpiry(Position memory p, int64 dollars, bytes32[] memory ids) private {
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(dollars), _end(p), ids);
    }
}
