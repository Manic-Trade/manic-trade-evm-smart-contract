// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {Breaker, Position, Side} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Breaker_Concrete_Test
/// @notice The payout circuit breaker (ADR 0003, docs/ARCHITECTURE.md §8.11), across the functions that count in it:
///         what each ending counts, the fixed window, the trip and what it stops, the limit switched off, the one slot
///         a call writes, and the attack it is for. The breaker starts with the test default: a $1,000 limit per
///         1-hour window.
/// @dev Every ending runs through the checkers of `Settlement_Base_Test`, whose own model counts the breaker and
///      compares its 6 fields and its trip event after every call. The tests here add the numbers. The base bet is a
///      $10 BTC long for a minute, θ 3 bp, floor 1.3x, cap 4x, at $83,884: at +$300 it pays its 4x cap, $30 of profit;
///      at -$8 it pays $9.046, a $0.954 loss.
contract Breaker_Concrete_Test is Settlement_Base_Test {
    /// @dev The breaker's two slots in `Layout` (docs/storage-layout.md).
    bytes32 internal constant SLOT_0 = bytes32(LayoutReader.ROOT + 7);
    bytes32 internal constant SLOT_1 = bytes32(LayoutReader.ROOT + 8);

    function test_EachEndingCountsItsWinningsAndLosses() external {
        Position memory p = _bet(users.alice, "winner", Side.Call);
        _bet(users.bob, "loser", Side.Call);
        _bet(users.eve, "liquidated", Side.Call);
        _bet(users.alice, "refunded", Side.Call);
        _bet(users.bob, "sold at a profit", Side.Call);
        _bet(users.eve, "sold at a loss", Side.Call);

        // A sale counts its sale amount against the stake: $12 is $2 of profit, $8.60 a $1.40 loss.
        _expectSale("sold at a profit", Examples.priceAt(8), 12_500_000, 12_000_000, 11_640_000);
        _assertCounted(2_000_000, 0);
        _expectSale("sold at a loss", Examples.priceAt(-8), 9_000_000, 8_600_000, 8_600_000);
        _assertCounted(2_000_000, 1_400_000);
        // A liquidation counts the whole stake as a loss.
        _expectLiquidated(p.liqPrice, p.startTime, _ids("liquidated"));
        _assertCounted(2_000_000, 11_400_000);
        // A settle counts the profit paid now, and the loss: $30 at the cap, then $10 less $9.046.
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(300), _end(p), _ids("winner"));
        _assertCounted(32_000_000, 11_400_000);
        _expectSettled(Examples.priceAt(-8), _end(p), _ids("loser"));
        _assertCounted(32_000_000, 12_354_000);
        // A refund counts nothing.
        vm.warp(_end(p) + Defaults.REFUND_DELAY);
        _expectRefunded(_ids("refunded"), users.eve);
        _assertCounted(32_000_000, 12_354_000);
    }

    /// @dev On a pool seeded with $20 (no exposure gate), two winners at the 4x cap: the first is paid the $20 now
    ///      and owed $10, the second is owed its whole $30.
    function test_AnIouCountsWhenItIsRepaidNotWhenItIsOwed() external {
        _useSmallPool(20e6);
        _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.bob, "b", Side.Call);
        vm.warp(_end(b));
        _expectSettled(Examples.priceAt(300), _end(b), _ids("a", "b"));
        _assertCounted(20_000_000, 0); // only what was paid now
        _fund(users.bob, 100e6);
        _expectRepaid(50, users.eve);
        _assertCounted(60_000_000, 0); // the $10 and the $30, repaid
    }

    /// @dev The stored window starts at 0, so on a real chain, whose clock is far past it, the first count starts a
    ///      window at its own second. The test chain's clock starts near 0, so the first count here is a window later.
    function test_TheWindowRestartsAtItsEndAndNotASecondBefore() external {
        uint48 start = _settleAWinnerAt(uint48(block.timestamp) + Defaults.BREAKER_WINDOW + Defaults.DURATION, "a");
        assertEq(LayoutReader.breaker(address(flashOption)).windowStart, start, "the window starts at the first count");

        // A second before the window's end, a winner adds to it.
        _settleAWinnerAt(start + Defaults.BREAKER_WINDOW - 1, "b");
        Breaker memory w = LayoutReader.breaker(address(flashOption));
        assertEq(w.windowStart, start, "the same window");
        assertEq(w.profitOut, 60e6, "$30 + $30");

        // At its end, the next winner starts a new one, from its own second.
        _settleAWinnerAt(start + Defaults.BREAKER_WINDOW, "c");
        w = LayoutReader.breaker(address(flashOption));
        assertEq(w.windowStart, start + Defaults.BREAKER_WINDOW, "a new window, from now");
        assertEq(w.profitOut, 30e6, "the counters restarted");
    }

    function test_ItTripsOneUnitOverTheLimitAndNotAtIt() external {
        uint256 before = vm.snapshotState();
        _setBreaker(30e6, Defaults.BREAKER_WINDOW); // exactly one winner's profit
        _settleAWinnerAt(uint48(block.timestamp) + Defaults.DURATION, "a");
        assertFalse(LayoutReader.breaker(address(flashOption)).tripped, "at the limit, it holds");

        vm.revertToState(before);
        _setBreaker(30e6 - 1, Defaults.BREAKER_WINDOW);
        _settleAWinnerAt(uint48(block.timestamp) + Defaults.DURATION, "a");
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "one unit over, it trips");
    }

    /// @dev A $1 limit, then a winner trips it. Open and sell stop; liquidate, settle, refund and claim go on, and a
    ///      second winner over the limit adds to the counters without a second trip. The operator's reset lets the
    ///      next bet open.
    function test_ATripStopsOnlyOpenAndSell() external {
        _setBreaker(1e6, Defaults.BREAKER_WINDOW);
        Position memory p = _bet(users.alice, "winner", Side.Call);
        _bet(users.bob, "second winner", Side.Call);
        _bet(users.eve, "liquidated", Side.Call);
        _bet(users.alice, "refunded", Side.Call);
        _bet(users.bob, "kept", Side.Call);
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice); // so her payout waits in claimable
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(300), _end(p), _ids("winner"));
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "tripped");

        _expectOpenStopped();
        _expectSellReverts(_sellOrder("kept", 0), _sellTerms(Defaults.ENTRY_PRICE, 0, 0), _reason());
        _expectLiquidated(p.liqPrice, p.startTime, _ids("liquidated"));
        _expectSettled(Examples.priceAt(300), _end(p), _ids("second winner")); // no second trip: the model checks
        vm.warp(_end(p) + Defaults.REFUND_DELAY);
        _expectRefunded(_ids("refunded"), users.eve);
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.alice);
        vm.prank(users.eve);
        flashOption.claim(users.alice);
        assertEq(LayoutReader.breaker(address(flashOption)).profitOut, 60e6, "both winners, counted while tripped");

        vm.prank(users.operator);
        flashOption.resetBreaker();
        _bet(users.eve, "after the reset", Side.Call);
    }

    /// @dev A $1 limit, and a sale with $2 of profit: the sale trips it. The checker expects the logs in the contract's
    ///      order: {PositionSold}, then {CircuitBreakerTripped}, then the payout's transfer.
    function test_ASaleThatTripsItAnnouncesTheTripBeforeItsPayout() external {
        _setBreaker(1e6, Defaults.BREAKER_WINDOW);
        _bet(users.bob, "sold at a profit", Side.Call);
        _expectSale("sold at a profit", Examples.priceAt(8), 12_500_000, 12_000_000, 11_640_000);
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "the sale tripped it");
    }

    function test_WithTheLimitAtZeroItNeverTrips() external {
        _setBreaker(0, Defaults.BREAKER_WINDOW);
        _settleWinners(10, "off"); // $300 of profit
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        assertFalse(b.tripped, "never trips");
        assertEq(b.profitOut, 300e6, "but still counts");
    }

    /// @dev `vm.accesses` lists every storage write. A call writes the breaker's first slot as often for ten endings
    ///      as for one, and never its second, which only `setBreaker` writes.
    function test_ACallWritesOnlyTheBreakersFirstSlotOncePerCall() external {
        uint256 one = _breakerWrites(1, "one");
        uint256 ten = _breakerWrites(10, "ten");
        assertGt(one, 0, "a counted call writes the first slot");
        assertEq(ten, one, "as often for ten endings as for one");
    }

    /// @dev The attack the breaker is for (Ostium, Arbitrum, Jul 2026): stolen opener and settler keys open bets at a
    ///      fake entry and settle them at the real price, at the cap, in a loop, for wallets the attacker controls.
    ///      Each round here opens five $50 longs $300 below the real price and settles them at it, taking $150 of
    ///      profit each, $750 a round, from a pool with $10,000 of free money. With the breaker off the third round
    ///      opens as easily as the first. With the $1,000 limit, the second round's settle trips it ($1,500 out), and
    ///      the third round's first open reverts.
    function test_TheOstiumLoopIsStoppedByTheFirstCallOverTheLimit() external {
        _fund(users.bob, 8500e6);
        uint256 before = vm.snapshotState();
        _setBreaker(0, Defaults.BREAKER_WINDOW);
        for (uint256 round; round < 3; ++round) {
            _ostiumRound(round);
        }
        assertEq(flashOption.freeMoney(), 10_000e6 - 2250e6, "without the breaker, every round pays");

        vm.revertToState(before);
        _ostiumRound(0);
        _ostiumRound(1);
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "tripped by the second round's settle");
        OpenOrder memory o = _order(users.eve, "the third round");
        o.stake = 50e6;
        _mintUsdg(users.eve, o.stake);
        bytes memory signature = _signOrder(flashOption, eveKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, eveKey, o);
        vm.expectRevert(Errors.BreakerTripped.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);
        assertEq(flashOption.freeMoney(), 10_000e6 - 1500e6, "the attack took two rounds");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The breaker's counters are these.
    function _assertCounted(uint64 profitOut, uint64 lossIn) private view {
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        assertEq(b.profitOut, profitOut, "profit out");
        assertEq(b.lossIn, lossIn, "losses in");
    }

    /// @dev Opens a base long for eve that expires at `end`, and settles it there at the 4x cap ($30 of profit).
    /// @return end The second it was settled at.
    function _settleAWinnerAt(uint48 end, bytes32 id) private returns (uint48) {
        vm.warp(end - Defaults.DURATION);
        _bet(users.eve, id, Side.Call);
        vm.warp(end);
        _expectSettled(Examples.priceAt(300), end, _ids(id));
        return end;
    }

    /// @dev Opens `n` base longs for eve now, and settles them together at the 4x cap at their expiry.
    function _settleWinners(uint256 n, string memory tag) private {
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = keccak256(abi.encode(tag, i));
            _bet(users.eve, ids[i], Side.Call);
        }
        uint48 end = uint48(block.timestamp) + Defaults.DURATION;
        vm.warp(end);
        _expectSettled(Examples.priceAt(300), end, ids);
    }

    /// @dev How many times settling `n` winners together writes the breaker's first slot. Its second is never written.
    function _breakerWrites(uint256 n, string memory tag) private returns (uint256 writes) {
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = keccak256(abi.encode(tag, i));
            _bet(users.eve, ids[i], Side.Call);
        }
        uint48 end = uint48(block.timestamp) + Defaults.DURATION;
        vm.warp(end);
        vm.record();
        _settle(Examples.priceAt(300), end, ids);
        (, bytes32[] memory written) = vm.accesses(address(flashOption));
        for (uint256 i; i < written.length; ++i) {
            if (written[i] == SLOT_0) ++writes;
            assertTrue(written[i] != SLOT_1, "the limit's slot is never written");
        }
    }

    /// @dev One round of the attack: five $50 longs for eve at the entry the relayer claims, settled at the cap.
    function _ostiumRound(uint256 round) private {
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            OpenOrder memory o = _order(users.eve, keccak256(abi.encode("ostium", round, i)));
            o.stake = 50e6;
            _betWith(o, _terms());
            ids[i] = o.positionId;
        }
        uint48 end = uint48(block.timestamp) + Defaults.DURATION;
        vm.warp(end);
        _expectSettled(Examples.priceAt(300), end, ids);
    }

    /// @dev Expects a new base bet of eve's to be refused with `BreakerTripped`.
    function _expectOpenStopped() private {
        OpenOrder memory o = _order(users.eve, "stopped");
        _mintUsdg(users.eve, o.stake);
        bytes memory signature = _signOrder(flashOption, eveKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, eveKey, o);
        vm.expectRevert(Errors.BreakerTripped.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);
    }

    /// @dev `BreakerTripped`, as `vm.expectRevert` takes it.
    function _reason() private pure returns (bytes memory) {
        return abi.encodeWithSelector(Errors.BreakerTripped.selector);
    }

    /// @dev The admin sets the breaker's limit and window.
    function _setBreaker(uint64 maxNetProfit, uint32 windowSecs) private {
        vm.prank(users.admin);
        flashOption.setBreaker(maxNetProfit, windowSecs);
    }
}
