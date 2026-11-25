// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder} from "../../../src/types/OrderTypes.sol";
import {Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Settle_Concrete_Test
/// @notice Every branch of `settle`, from test/concrete/settle/settle.tree (docs/ARCHITECTURE.md §8.5): alice's $10
///         BTC call and bob's $10 BTC put, opened at the same tick and settled at its expiry second, at $8 above the
///         entry, into a pool with $1,500 of free money; eve's call on ETH is the position of another market. The
///         chain's clock is at the expiry second.
/// @dev Each revert test breaks its own check and every later one (`_breakFrom`), so its own error also proves the
///      order: no later check can have run first. Where a check has a boundary, the test also shows the other side
///      passes it: the next check's error appears instead. Success is checked by `_expectSettled`, which compares
///      every log, every field of the books, every slot and every balance with its own model; the tests also pin
///      hand-checkable amounts.
contract Settle_Concrete_Test is Settlement_Base_Test {
    /// @dev A market that was never created.
    bytes32 internal constant NO_MARKET = keccak256("no such market");

    bytes32 internal constant A = keccak256("alice's call");
    bytes32 internal constant C = keccak256("bob's put");
    bytes32 internal constant B = keccak256("eve's call on ETH");
    bytes32 internal constant UNKNOWN = keccak256("never opened");

    /// @dev One call to `settle`.
    struct Attempt {
        bytes32 marketId;
        uint16 leverage;
        int64 price;
        uint48 publishTime;
        bytes32[] ids;
    }

    /// @dev Alice's and bob's positions share these: they were opened at the same tick.
    uint48 internal start;
    uint48 internal end;
    /// @dev Alice's call's liquidation line.
    int64 internal line;
    uint48 internal skew;
    /// @dev $8 above the entry: alice's call wins at the 1.3x floor, bob's put loses $0.954.
    int64 internal winning;

    function setUp() public override {
        super.setUp();
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.ETH, Defaults.LEVERAGE, _enabledConfig());
        OpenOrder memory o = _order(users.eve, B);
        o.marketId = Defaults.ETH;
        _betWith(o, _terms());

        Position memory a = _bet(users.alice, A, Side.Call);
        _bet(users.bob, C, Side.Put);
        start = a.startTime;
        end = _end(a);
        line = a.liqPrice;
        skew = LayoutReader.market(address(flashOption), 0).clockSkewSecs;
        winning = Examples.priceAt(8);
        vm.warp(end);
    }

    function test_RevertWhen_TheCallerIsNotASettler() external {
        // it should revert: every user but the settler, with every check after the role broken
        Attempt memory x = _attempt();
        _breakFrom(x, 2);
        address[] memory callers = _everyoneBut(users.settler, users.settler);
        bytes32 settlerRole = flashOption.SETTLER_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], settlerRole
                )
            );
            vm.prank(callers[i]);
            flashOption.settle(x.marketId, x.leverage, x.price, x.publishTime, x.ids);
        }
    }

    modifier whenTheCallerIsASettler() {
        _;
    }

    function test_RevertGiven_TheContractIsHalted() external whenTheCallerIsASettler {
        // it should revert
        _expectReverts(2, abi.encodeWithSelector(Errors.Halted.selector));
    }

    modifier givenTheContractIsNotHalted() {
        _;
    }

    function test_RevertWhen_TheBatchIsEmptyOrHoldsMoreThan100Ids()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
    {
        // it should revert: 101 ids, and none
        _expectReverts(3, abi.encodeWithSelector(Errors.BatchSizeTooLarge.selector));
        Attempt memory x = _attempt();
        _breakFrom(x, 4);
        x.ids = new bytes32[](0);
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.EmptyBatch.selector));

        // 100 ids pass the size check: the next check, the market, fails instead.
        x.ids = _unknownIds(100);
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.UnknownMarket.selector));
    }

    modifier whenTheBatchHolds1To100Ids() {
        _;
    }

    function test_RevertWhen_TheMarketDoesNotExist()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
    {
        // it should revert: no market of that feed, and BTC at a leverage it has no market for
        _expectReverts(4, abi.encodeWithSelector(Errors.UnknownMarket.selector));
        Attempt memory x = _attempt();
        _breakFrom(x, 5);
        x.leverage = 500;
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.UnknownMarket.selector));
    }

    modifier whenTheMarketExists() {
        _;
    }

    function test_RevertWhen_ThePriceIsNotPositive()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
    {
        // it should revert: zero, one below and the lowest price
        _expectReverts(5, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        Attempt memory x = _attempt();
        _breakFrom(x, 5);
        x.price = -1;
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        x.price = type(int64).min;
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.InvalidPrice.selector));
    }

    modifier whenThePriceIsPositive() {
        _;
    }

    function test_RevertWhen_TheTickIsMoreThanTheClockSkewAhead()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
    {
        // it should revert: the second hasn't passed yet
        _expectReverts(6, abi.encodeWithSelector(Errors.NotExpired.selector));

        // The clock skew is the boundary: a tick 5 seconds ahead passes, and the next check fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 7);
        x.publishTime = uint48(block.timestamp) + skew;
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN));

        // So a position can be settled up to 5 seconds before the chain's clock reaches its expiry second.
        vm.warp(end - skew);
        _expectSettled(winning, end, _ids(A));
    }

    modifier whenTheTickIsAtMostTheClockSkewAhead() {
        _;
    }

    function test_RevertWhen_AnIdWasNeverOpened()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
    {
        // it should revert, naming the id
        _expectReverts(7, abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN));

        // The whole batch reverts: bob's put, which the tick settles, stays open and unpaid.
        _expectSettleReverts(
            winning, end, _ids(C, UNKNOWN), abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN)
        );
        assertEq(uint8(LayoutReader.position(address(flashOption), C).status), uint8(Status.Open), "bob's put is open");
        assertEq(usdg.balanceOf(users.bob), 0, "and bob is unpaid");
    }

    modifier whenEveryIdWasOpened() {
        _;
    }

    function test_RevertWhen_APositionBelongsToAnotherMarket()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
    {
        // it should revert, naming the position
        _expectReverts(8, abi.encodeWithSelector(Errors.ConfigMismatch.selector, B));

        // Its own market settles it. Once ended, it still reverts on BTC instead of being skipped: the market is
        // checked before the status.
        vm.prank(users.settler);
        assertEq(
            flashOption.settle(Defaults.ETH, Defaults.LEVERAGE, winning, end, _ids(B)),
            1,
            "ETH settles its own position"
        );
        _expectSettleReverts(winning, end, _ids(B), abi.encodeWithSelector(Errors.ConfigMismatch.selector, B));
    }

    modifier whenEveryPositionBelongsToTheMarket() {
        _;
    }

    function test_GivenAPositionHasAlreadyEnded()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
    {
        _expectSettled(winning, end, _ids(A));

        // it should skip it: alice's call ended before the batch, and bob's put ends at its first occurrence
        // it should settle the others
        Ending[] memory endings = _expectSettled(winning, end, _ids(A, C, C));
        assertTrue(endings[0].skipped, "alice's call is skipped");
        assertEq(uint8(endings[0].status), uint8(Status.Closed), "as closed");
        assertFalse(endings[1].skipped, "bob's put is settled");
        assertTrue(endings[2].skipped, "and skipped when listed again");
        assertEq(usdg.balanceOf(users.alice), 12_940_000, "alice is paid once");
        assertEq(usdg.balanceOf(users.bob), 9_046_000, "bob is paid once");
    }

    modifier givenEveryPositionIsOpen() {
        _;
    }

    function test_RevertWhen_TheTickIsNotAPositionsExpirySecond()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
    {
        // it should revert, naming the position: a second before its expiry
        bytes memory notItsSecond = abi.encodeWithSelector(Errors.InvalidPriceTimestamp.selector, A);
        _expectReverts(9, notItsSecond);

        // A second after it is not its second either (and is within the clock skew).
        _expectSettleReverts(line, end + 1, _ids(A), notItsSecond);

        // A batch of two expiry seconds: eve's bet, opened a second later, expires a second later.
        vm.warp(start + 1);
        bytes32 later = keccak256("eve's later call");
        Position memory e = _bet(users.eve, later, Side.Call);
        vm.warp(end);
        assertEq(_end(e), end + 1, "a second later");
        _expectSettleReverts(
            winning, end, _ids(A, later), abi.encodeWithSelector(Errors.InvalidPriceTimestamp.selector, later)
        );
    }

    modifier whenTheTickIsEveryPositionsExpirySecond() {
        _;
    }

    function test_RevertWhen_ThePriceTouchesAPositionsLine()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenTheTickIsEveryPositionsExpirySecond
    {
        // it should revert, naming the position: at the line, and one unit beyond it
        bytes memory liquidateInstead = abi.encodeWithSelector(Errors.LiquidateInstead.selector, A);
        _expectReverts(10, liquidateInstead);
        _expectSettleReverts(line - 1, end, _ids(A), liquidateInstead);

        // One unit inside the line settles: −3.0 bp at 1000x leaves 0.7x.
        Ending[] memory endings = _expectSettled(line + 1, end, _ids(A));
        assertEq(endings[0].s.g, 7000, "0.7x");
    }

    modifier whenThePriceTouchesNoLine() {
        _;
    }

    function test_RevertWhen_APayoutHasTooLittleGas()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenTheTickIsEveryPositionsExpirySecond
        whenThePriceTouchesNoLine
    {
        // it should revert: a settler that starves the call can't push alice's payout into claimable. Every gas limit
        // up to the least that settles reverts, some of them with `InsufficientGasForPayout`.
        bytes memory call_ =
            abi.encodeCall(flashOption.settle, (Defaults.BTC, Defaults.LEVERAGE, winning, end, _ids(A)));
        bytes32 starved = keccak256(abi.encodeWithSelector(Errors.InsufficientGasForPayout.selector));
        bool sawTheGuard;
        bool settled;
        for (uint256 gasLimit = 20_000; gasLimit < 400_000 && !settled; gasLimit += 1000) {
            vm.prank(users.settler);
            bytes memory reason;
            (settled, reason) = address(flashOption).call{gas: gasLimit}(call_);
            if (keccak256(reason) == starved) sawTheGuard = true;
        }
        assertTrue(sawTheGuard, "too little gas for the payout reverts InsufficientGasForPayout");
        assertTrue(settled, "and enough gas settles");

        // At the least gas that settles, alice is paid in full, and nothing waits in claimable.
        assertEq(usdg.balanceOf(users.alice), 12_940_000, "alice is paid");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 0, "nothing deferred");
        assertEq(LayoutReader.pool(address(flashOption)).totalClaimable, 0, "nothing deferred at all");
    }

    modifier whenEveryPayoutHasTheGasItNeeds() {
        _;
    }

    function test_GivenTheTokenRefusesAPayout()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenTheTickIsEveryPositionsExpirySecond
        whenThePriceTouchesNoLine
        whenEveryPayoutHasTheGasItNeeds
    {
        // Paxos freezes alice before her bet settles.
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);

        // it should keep the payout for the user to claim
        // it should settle the rest of the batch
        Ending[] memory endings = _expectSettled(winning, end, _ids(A, C));
        assertTrue(endings[0].deferred, "alice's payout waits");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 12_940_000, "in her claimable balance");
        assertEq(usdg.balanceOf(users.bob), 9_046_000, "bob is paid");

        // Once she is unfrozen, anyone can claim it for her, to her.
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.alice);
        vm.prank(users.eve);
        flashOption.claim(users.alice);
        assertEq(usdg.balanceOf(users.alice), 12_940_000, "alice has it");

        // While the token is paused, every payout of a batch waits, and the batch still settles.
        vm.warp(start);
        _bet(users.alice, "alice's second call", Side.Call);
        _bet(users.bob, "bob's second put", Side.Put);
        vm.warp(end);
        vm.prank(usdgAdmin);
        usdg.pause();
        endings = _expectSettled(winning, end, _ids("alice's second call", "bob's second put"));
        assertTrue(endings[0].deferred && endings[1].deferred, "both payouts wait");
        assertEq(LayoutReader.claimable(address(flashOption), users.bob), 9_046_000, "in bob's claimable balance");
    }

    function test_GivenThePoolCannotPayAProfitInFull()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenTheTickIsEveryPositionsExpirySecond
        whenThePriceTouchesNoLine
        whenEveryPayoutHasTheGasItNeeds
    {
        // A pool with $20 of free money and no exposure gate: alice's call at the 4x cap wins $30. (A new id: her
        // EIP-3009 nonce for A was used on the first pool, and USDG nonces are per token, not per payee.)
        _useSmallPool(20e6);
        bytes32 id = keccak256("alice's call on the small pool");
        Position memory p = _bet(users.alice, id, Side.Call);
        vm.warp(_end(p));

        // it should pay the profit free money allows
        // it should queue the rest as an IOU
        // it should keep the position as owed
        Ending[] memory endings = _expectSettled(Examples.priceAt(300), _end(p), _ids(id));
        assertEq(endings[0].s.paid, 20_000_000, "$20 of profit paid now");
        assertEq(endings[0].s.owed, 10_000_000, "$10 owed");
        assertEq(endings[0].s.toUser, 29_600_000, "her stake and $20, less 2%");
        assertEq(endings[0].queueSeq, 0, "first in the queue");
        assertEq(uint8(endings[0].status), uint8(Status.Owed), "owed");
        Position memory owed = LayoutReader.position(address(flashOption), id);
        assertEq(owed.stake, Defaults.STAKE, "slot 1 is kept");
        assertEq(owed.owed, 10_000_000, "slot 2 holds what is owed");

        // The boundary: free money one unit short of a +$8 winner's $3 profit leaves an IOU of one unit, not a
        // closed position (a new pool, with nobody owed yet).
        _useSmallPool(3_000_000 - 1);
        bytes32 short = keccak256("alice's call, one unit short");
        p = _bet(users.alice, short, Side.Call);
        vm.warp(_end(p));
        endings = _expectSettled(winning, _end(p), _ids(short));
        assertEq(endings[0].s.owed, 1, "one unit owed");
        assertEq(uint8(endings[0].status), uint8(Status.Owed), "still an IOU");
        assertEq(LayoutReader.pool(address(flashOption)).totalOwed, 1, "and counted");
    }

    function test_GivenThePoolCanPayEveryProfit()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenThePriceIsPositive
        whenTheTickIsAtMostTheClockSkewAhead
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenTheTickIsEveryPositionsExpirySecond
        whenThePriceTouchesNoLine
        whenEveryPayoutHasTheGasItNeeds
    {
        // Sent 20 seconds after the expiry second: an old tick is accepted.
        vm.warp(end + 20);
        Ending[] memory endings = _expectSettled(winning, end, _ids(A, C));

        // it should close each position
        // it should pay each user the payout, less the fees
        // it should accrue the fees once
        // it should emit {PositionSettled} for each
        // it should return the number settled
        assertEq(endings[0].s.g, 13_000, "alice's call: +$8 pays the 1.3x floor");
        assertEq(endings[0].s.toUser, 12_940_000, "$13, less 2% of the $3 profit");
        assertEq(endings[0].s.winnerFee, 60_000, "the winner fee");
        assertEq(endings[1].s.g, 9046, "bob's put: -$8 pays 0.9046x");
        assertEq(endings[1].s.toUser, 9_046_000, "$9.046");
        assertEq(endings[1].s.loserFee, 28_620, "3% of the $0.954 loss");
        assertEq(LayoutReader.pool(address(flashOption)).feesPending, 88_620, "both fees pending");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev A valid attempt: alice's call at its expiry second, $8 above the entry.
    function _attempt() private view returns (Attempt memory x) {
        x.marketId = Defaults.BTC;
        x.leverage = Defaults.LEVERAGE;
        x.price = winning;
        x.publishTime = end;
        x.ids = _ids(A);
    }

    /// @dev Breaks check `from` (numbered in the order of `IManicFlashOptionSettlement.settle`'s requirements, the role
    ///      being 1) and every later one:
    ///      2 the halt; 3 the batch's size (101 ids); 4 the market; 5 the price (zero); 6 the clock skew (6 seconds
    ///      ahead); 7 an id never opened; 8 a position of another market; 9 the expiry second (a second early);
    ///      10 the line (at it). A zero price also touches alice's line, so it breaks 10 too.
    function _breakFrom(Attempt memory x, uint256 from) private {
        if (from <= 2) {
            vm.prank(users.guardian);
            flashOption.setHalted(true);
        }
        if (from <= 3) x.ids = _unknownIds(101);
        else if (from <= 7) x.ids = _ids(UNKNOWN, B, A);
        else if (from <= 8) x.ids = _ids(B, A);
        if (from <= 4) x.marketId = NO_MARKET;
        if (from <= 5) x.price = 0;
        else if (from <= 10) x.price = line;
        if (from <= 6) x.publishTime = uint48(block.timestamp) + skew + 1;
        else if (from <= 9) x.publishTime = end - 1;
    }

    /// @dev Breaks check `from` and every later one, and expects `settle` to revert with `reason`.
    function _expectReverts(uint256 from, bytes memory reason) private {
        Attempt memory x = _attempt();
        _breakFrom(x, from);
        _expectAttemptReverts(x, reason);
    }

    function _expectAttemptReverts(Attempt memory x, bytes memory reason) private {
        vm.expectRevert(reason);
        vm.prank(users.settler);
        flashOption.settle(x.marketId, x.leverage, x.price, x.publishTime, x.ids);
    }

    /// @dev `n` ids that were never opened.
    function _unknownIds(uint256 n) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = keccak256(abi.encode("never opened", i));
        }
    }
}
