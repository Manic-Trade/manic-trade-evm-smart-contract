// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Position, Side, Status} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Settle_Scenario_Test
/// @notice Settling bets end to end, with every expected number to the base unit: winners at the floor, mid-range and
///         the cap, a flat expiry, losers and the loser fee below the floor, one unit inside the line, several users
///         in one batch, a late settle, the batch size limit, and the IOU queue on a pool of its own seeded with $20.
///         The base bet is a $10 BTC long (θ 3 bp, floor 1.3x, cap 4x, at $83,884).
/// @dev Every settle runs through `_expectSettled`, which also checks the books, the slots, the queue, the logs and
///      the balances against its own model. Each bet lasts the base 60 seconds, and the clock is moved to its expiry
///      instead of waiting. A batch holds at most 100 ids, and skips an owed position.
contract Settle_Scenario_Test is Settlement_Base_Test {
    /// @dev Pays a long winner at the floor, mid-range and the cap, minus the 2% winner fee.
    function test_ALongWinnerAtTheFloorMidRangeAndTheCap() external {
        _expectWinner(Side.Call, 8, 13_000, 12_940_000, 60_000); // +$8: the 1.3x floor
        _expectWinner(Side.Call, 84, 20_013, 19_812_740, 200_260); // +$84: $20.013, mid-range
        _expectWinner(Side.Call, 300, 40_000, 39_400_000, 600_000); // beyond the cap price: 4x
    }

    /// @dev Pays a short winner at the floor, mid-range and the cap.
    function test_AShortWinnerAtTheFloorMidRangeAndTheCap() external {
        _expectWinner(Side.Put, -8, 13_000, 12_940_000, 60_000);
        _expectWinner(Side.Put, -84, 20_013, 19_812_740, 200_260);
        _expectWinner(Side.Put, -300, 40_000, 39_400_000, 600_000);
    }

    /// @dev Returns exactly the stake at a flat expiry, with no fee.
    function test_AFlatExpiryReturnsExactlyTheStake() external {
        Position memory p = _bet(users.alice, "flat", Side.Call);
        vm.warp(_end(p));
        Ending[] memory endings = _expectSettled(Examples.P0, _end(p), _ids("flat"));
        assertEq(endings[0].s.toUser, 10_000_000, "the stake back");
        assertEq(endings[0].s.winnerFee + endings[0].s.loserFee, 0, "no fee");
    }

    /// @dev Pays a long and a short loser their payout, minus 3% of the loss to the fee receiver.
    function test_ALongAndAShortLoser() external {
        Position memory long = _bet(users.alice, "long", Side.Call);
        vm.warp(_end(long));
        Ending[] memory lost = _expectSettled(Examples.priceAt(-8), _end(long), _ids("long"));
        assertEq(lost[0].s.toUser, 9_046_000, "-$8 pays $9.046");
        assertEq(lost[0].s.loserFee, 28_620, "3% of the $0.954 loss");

        Position memory short = _bet(users.alice, "short", Side.Put);
        vm.warp(_end(short));
        Ending[] memory shortLost = _expectSettled(Examples.priceAt(8), _end(short), _ids("short"));
        assertEq(shortLost[0].s.loserFee, 28_620, "the same loss on the other side");
    }

    /// @dev Takes no loser fee while free money is one unit below the floor.
    function test_NoLoserFeeOneUnitBelowTheFloor() external {
        Position memory p = _bet(users.alice, "long", Side.Call);
        uint64 free =
            LayoutReader.pool(address(flashOption)).total - LayoutReader.pool(address(flashOption)).lockedMargin;
        vm.prank(users.admin);
        flashOption.setPoolFloor(free + 1);
        vm.warp(_end(p));
        Ending[] memory endings = _expectSettled(Examples.priceAt(-8), _end(p), _ids("long"));
        assertEq(endings[0].s.loserFee, 0, "no loser fee");
    }

    /// @dev Settles one unit inside the line; on the line or beyond it is `LiquidateInstead`.
    function test_OneUnitInsideTheLineSettles() external {
        Position memory long = _bet(users.alice, "long", Side.Call);
        Position memory short = _bet(users.bob, "short", Side.Put);
        vm.warp(_end(long));
        _expectLiquidateInstead(long.liqPrice, _end(long), "long");
        _expectLiquidateInstead(long.liqPrice - 1, _end(long), "long");
        Ending[] memory endings = _expectSettled(long.liqPrice + 1, _end(long), _ids("long"));
        assertEq(endings[0].s.g, 7000, "-3.0 bp at 1000x leaves 0.7x");

        _expectLiquidateInstead(short.liqPrice, _end(short), "short");
        _expectLiquidateInstead(short.liqPrice + 1, _end(short), "short");
        _expectSettled(short.liqPrice - 1, _end(short), _ids("short"));
    }

    /// @dev Pays several users in one batch, each their own payout.
    function test_SeveralUsersInOneBatch() external {
        _bet(users.alice, "a long at the 1.3x floor", Side.Call);
        _bet(users.bob, "a losing short", Side.Put);
        OpenOrder memory o = _order(users.eve, "a long at the 1.1x floor");
        OpenTerms memory t = _terms();
        t.floorBps = 11_000;
        t.capBps = 15_000;
        Position memory p = _betWith(o, t);
        vm.warp(_end(p));

        Ending[] memory endings = _expectSettled(
            Examples.priceAt(8), _end(p), _ids("a long at the 1.3x floor", "a losing short", "a long at the 1.1x floor")
        );
        assertEq(endings[0].s.toUser, 12_940_000, "a long at the 1.3x floor");
        assertEq(endings[1].s.toUser, 9_046_000, "a losing short");
        assertEq(endings[2].s.toUser, 10_980_000, "a long at the 1.1x floor");
    }

    /// @dev Settles long after the expiry second: an old tick is accepted.
    function test_LongAfterTheExpirySecond() external {
        Position memory p = _bet(users.alice, "late", Side.Call);
        _expectSettleReverts(
            Examples.priceAt(8), _end(p), _ids("late"), abi.encodeWithSelector(Errors.NotExpired.selector)
        );
        vm.warp(_end(p) + 10);
        _expectSettled(Examples.priceAt(8), _end(p), _ids("late"));
    }

    /// @dev Settles 100 positions in one batch, then the 101st alone, but not 101 at once: a batch holds at most 100.
    function test_OneHundredPositionsInOneBatchThenTheHundredAndFirstAlone() external {
        _fund(users.bob, 1600e6); // the exposure gate needs $30 of free money per bet
        bytes32[] memory all = new bytes32[](101);
        Position memory p;
        for (uint256 i; i < 101; ++i) {
            all[i] = keccak256(abi.encode("bet", i));
            p = _bet(users.alice, all[i], i % 2 == 0 ? Side.Call : Side.Put);
        }
        vm.warp(_end(p));
        int64 price = Examples.priceAt(8);
        _expectSettleReverts(price, _end(p), all, abi.encodeWithSelector(Errors.BatchSizeTooLarge.selector));

        bytes32[] memory hundred = new bytes32[](100);
        for (uint256 i; i < 100; ++i) {
            hundred[i] = all[i];
        }
        _expectSettled(price, _end(p), hundred);
        _expectSettled(price, _end(p), _ids(all[100]));
        // 51 calls at $12.94 and 50 puts at $9.046.
        assertEq(usdg.balanceOf(users.alice), 51 * 12_940_000 + 50 * 9_046_000, "every payout");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The IOU queue, on a pool of its own seeded with $20
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Four steps that build on each other: winners the pool can't pay are owed in order, a later winner queues
    ///      behind them, settling or liquidating an owed position skips it, and the gate on total owed stops opens
    ///      while more than its limit is owed.
    function test_TheIouQueue() external {
        _useSmallPool(20e6);

        // In one batch, the first winner is partly paid and the second is fully queued.
        _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.alice, "b", Side.Call);
        vm.warp(_end(b));
        Ending[] memory endings = _expectSettled(Examples.priceAt(300), _end(b), _ids("a", "b"));
        // a: $30 profit, $20 free → $20 paid now (minus 2%), $10 owed, first in the queue.
        _assertIou(endings[0], 20_000_000, 10_000_000, 29_600_000, 0);
        // b: nothing left and someone is queued → its whole $30 profit is owed; its stake comes back.
        _assertIou(endings[1], 0, 30_000_000, 10_000_000, 1);

        // A loser below the floor pays no fee, and a later winner is fully queued although free money exists.
        Position memory c = _bet(users.alice, "c", Side.Call);
        vm.warp(_end(c));
        Ending[] memory lost = _expectSettled(Examples.priceAt(-8), _end(c), _ids("c"));
        assertEq(lost[0].s.loserFee, 0, "free money is below the $500 floor");
        assertGt(
            LayoutReader.pool(address(flashOption)).total - LayoutReader.pool(address(flashOption)).lockedMargin,
            0,
            "the loss is free money now"
        );
        Position memory d = _bet(users.alice, "d", Side.Call);
        vm.warp(_end(d));
        Ending[] memory won = _expectSettled(Examples.priceAt(8), _end(d), _ids("d"));
        _assertIou(won[0], 0, 3_000_000, 10_000_000, 2); // FIFO: nobody jumps the queue

        // Settling or liquidating an owed position skips it.
        Position memory a = LayoutReader.position(address(flashOption), "a");
        Ending[] memory skipped = _expectSettled(Examples.P0, _end(a), _ids("a"));
        assertTrue(skipped[0].skipped, "settle skips the owed position");
        assertEq(uint8(skipped[0].status), uint8(Status.Owed), "as owed");
        skipped = _expectLiquidated(a.liqPrice, _end(a), _ids("a"));
        assertTrue(skipped[0].skipped, "liquidate skips it too");

        // The open gate blocks while total owed exceeds the market's `maxTotalOwed`, and lets the bet in at the limit.
        _expectTheGateOnTotalOwed();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The last IOU step: with $43 owed, a gate one unit below it blocks a new bet, and a gate at it lets the same
    ///      order in, which then settles.
    function _expectTheGateOnTotalOwed() private {
        assertEq(LayoutReader.pool(address(flashOption)).totalOwed, 43_000_000, "$10 + $30 + $3 owed");
        _setMaxTotalOwed(43_000_000 - 1);
        OpenOrder memory o = _order(users.alice, "e");
        _mintUsdg(users.alice, o.stake);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory auth = _stakeAuth(flashOption, aliceKey, o);
        OpenTerms memory t = _terms();
        vm.expectRevert(Errors.OpenBlockedTotalOwed.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, auth);
        _setMaxTotalOwed(43_000_000);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, auth);
        vm.warp(block.timestamp + o.durationSecs);
        _expectSettled(Examples.priceAt(-8), t.entryPublishTime + o.durationSecs, _ids("e"));
    }

    /// @dev Opens the base bet on `side`, settles it `dollars` from the entry at its expiry second, and checks `g`,
    ///      what the user is paid and the winner fee.
    function _expectWinner(Side side, int64 dollars, uint16 g, uint64 toUser, uint64 winnerFee) private {
        bytes32 id = keccak256(abi.encode(side, dollars));
        Position memory p = _bet(users.alice, id, side);
        vm.warp(_end(p));
        Ending[] memory endings = _expectSettled(Examples.priceAt(dollars), _end(p), _ids(id));
        assertEq(endings[0].s.g, g, "g");
        assertEq(endings[0].s.toUser, toUser, "paid");
        assertEq(endings[0].s.winnerFee, winnerFee, "winner fee");
    }

    /// @dev Expects settling `id` at this tick to revert `LiquidateInstead(id)`.
    function _expectLiquidateInstead(int64 price, uint48 publishTime, bytes32 id) private {
        bytes memory reason = abi.encodeWithSelector(Errors.LiquidateInstead.selector, id);
        _expectSettleReverts(price, publishTime, _ids(id), reason);
    }

    /// @dev An IOU settled as expected: the profit paid now, what is owed, what the user got, the queue place.
    function _assertIou(Ending memory e, uint64 paid, uint64 owed, uint64 toUser, uint64 queueSeq) private pure {
        assertEq(e.s.paid, paid, "paid now");
        assertEq(e.s.owed, owed, "owed");
        assertEq(e.s.toUser, toUser, "to the user");
        assertEq(e.queueSeq, queueSeq, "queue place");
    }

    /// @dev The operator sets BTC's open gate on total owed, keeping the small pool's other settings: the exposure gate
    ///      off, written back into storage (`_switchOffOpenGate`), since `validate` refuses it (ADR 0009).
    function _setMaxTotalOwed(uint64 maxTotalOwed) private {
        ConfigParams memory c = Defaults.marketConfig();
        c.enabled = true;
        c.maxTotalOwed = maxTotalOwed;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _switchOffOpenGate(address(flashOption), Defaults.BTC, Defaults.LEVERAGE);
    }
}
