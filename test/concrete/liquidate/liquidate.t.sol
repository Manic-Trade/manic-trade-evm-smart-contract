// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms} from "../../../src/types/OrderTypes.sol";
import {Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Liquidate_Concrete_Test
/// @notice Every branch of `liquidate`, from test/concrete/liquidate/liquidate.tree (docs/ARCHITECTURE.md §8.4):
///         alice's and bob's $10 BTC puts, opened at the same tick, liquidated at their line, into a pool with $1,500
///         of free money; eve's call on ETH is the position of another market.
/// @dev Each revert test breaks its own check and every later one (`_breakFrom`), so its own error also proves the
///      order: no later check can have run first. The positions are puts because a put's line is above the entry: a
///      price of zero, which breaks the price check, then also breaks the line check (a call's line is touched by
///      any price at or below it, zero included). Where a check has a boundary, the test also shows the other side
///      passes it: the next check's error appears instead. Success is checked by `_expectLiquidated`, which compares
///      every log, every field of the books, every slot and every balance with its own model.
contract Liquidate_Concrete_Test is Settlement_Base_Test {
    /// @dev A market that was never created.
    bytes32 internal constant NO_MARKET = keccak256("no such market");

    bytes32 internal constant A = keccak256("alice's put");
    bytes32 internal constant C = keccak256("bob's put");
    bytes32 internal constant B = keccak256("eve's call on ETH");
    bytes32 internal constant UNKNOWN = keccak256("never opened");

    /// @dev One call to `liquidate`.
    struct Attempt {
        bytes32 marketId;
        uint16 leverage;
        int64 price;
        uint48 publishTime;
        bytes32[] ids;
    }

    /// @dev Alice's and bob's puts share these: they were opened at the same tick.
    uint48 internal start;
    uint48 internal end;
    int64 internal line;
    int64 internal ethLine;

    function setUp() public override {
        super.setUp();
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.ETH, Defaults.LEVERAGE, _enabledConfig());
        OpenOrder memory o = _order(users.eve, B);
        o.marketId = Defaults.ETH;
        ethLine = _betWith(o, _terms()).liqPrice;

        Position memory a = _bet(users.alice, A, Side.Put);
        _bet(users.bob, C, Side.Put);
        start = a.startTime;
        end = _end(a);
        line = a.liqPrice;
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
            flashOption.liquidate(x.marketId, x.leverage, x.price, x.publishTime, x.ids);
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

    function test_RevertWhen_AnIdWasNeverOpened()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
    {
        // it should revert, naming the id
        _expectReverts(5, abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN));

        // The whole batch reverts: bob's put, which the tick liquidates, stays open.
        _expectLiquidateReverts(
            line, start, _ids(C, UNKNOWN), abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN)
        );
        assertEq(uint8(LayoutReader.position(address(flashOption), C).status), uint8(Status.Open), "bob's put is open");
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
        whenEveryIdWasOpened
    {
        // it should revert, naming the position
        _expectReverts(6, abi.encodeWithSelector(Errors.ConfigMismatch.selector, B));

        // Its own market liquidates it. Once ended, it still reverts on BTC instead of being skipped: the market is
        // checked before the status.
        vm.prank(users.settler);
        assertEq(
            flashOption.liquidate(Defaults.ETH, Defaults.LEVERAGE, ethLine, start, _ids(B)),
            1,
            "ETH liquidates its own position"
        );
        _expectLiquidateReverts(line, start, _ids(B), abi.encodeWithSelector(Errors.ConfigMismatch.selector, B));
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
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
    {
        _expectLiquidated(line, start, _ids(A));

        // it should skip it: alice's put ended before the batch, and bob's ends at its first occurrence
        // it should liquidate the others
        Ending[] memory endings = _expectLiquidated(line, start, _ids(A, C, C));
        assertTrue(endings[0].skipped, "alice's put is skipped");
        assertEq(uint8(endings[0].status), uint8(Status.Closed), "as closed");
        assertFalse(endings[1].skipped, "bob's put is liquidated");
        assertEq(endings[1].loserFee, 300_000, "3% of $10");
        assertTrue(endings[2].skipped, "and skipped when listed again");
    }

    modifier givenEveryPositionIsOpen() {
        _;
    }

    function test_RevertWhen_ThePriceIsNotPositive()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
    {
        // it should revert: zero, one below and the lowest price
        _expectReverts(7, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        Attempt memory x = _attempt();
        _breakFrom(x, 7);
        x.price = -1;
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        x.price = type(int64).min;
        _expectAttemptReverts(x, abi.encodeWithSelector(Errors.InvalidPrice.selector));
    }

    modifier whenThePriceIsPositive() {
        _;
    }

    function test_RevertWhen_TheTickIsOutsideAPositionsLife()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenThePriceIsPositive
    {
        // it should revert, naming the position: a second after the end
        bytes memory outside = abi.encodeWithSelector(Errors.InvalidLiquidationWindow.selector, A);
        bytes memory notReached = abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, A);
        _expectReverts(8, outside);

        // A second before the start is outside too; the start itself is inside, and the line check fails instead.
        _expectLiquidateReverts(line - 1, start - 1, _ids(A), outside);
        _expectLiquidateReverts(line - 1, start, _ids(A), notReached);

        // At the end: a second after it is outside, and the end itself is inside.
        vm.warp(end);
        _expectLiquidateReverts(line - 1, end + 1, _ids(A), outside);
        _expectLiquidateReverts(line - 1, end, _ids(A), notReached);
    }

    modifier whenTheTickIsInsideEveryPositionsLife() {
        _;
    }

    function test_RevertWhen_TheTickIsFromTheFuture()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenThePriceIsPositive
        whenTheTickIsInsideEveryPositionsLife
    {
        // it should revert: 30 seconds ahead of the chain's clock, inside the position's life
        _expectReverts(9, abi.encodeWithSelector(Errors.PriceFromFuture.selector));

        // The clock skew is the boundary: a tick 5 seconds ahead passes, 6 seconds ahead doesn't.
        uint48 skew = LayoutReader.market(address(flashOption), 0).clockSkewSecs;
        uint48 now_ = uint48(block.timestamp);
        _expectLiquidateReverts(
            line - 1, now_ + skew, _ids(A), abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, A)
        );
        _expectLiquidateReverts(
            line - 1, now_ + skew + 1, _ids(A), abi.encodeWithSelector(Errors.PriceFromFuture.selector)
        );
    }

    modifier whenTheTickIsNotFromTheFuture() {
        _;
    }

    function test_RevertWhen_ThePriceDoesNotTouchAPositionsLine()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenThePriceIsPositive
        whenTheTickIsInsideEveryPositionsLife
        whenTheTickIsNotFromTheFuture
    {
        // it should revert, naming the position: one unit inside the line
        _expectReverts(10, abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, A));

        // In a batch, the one position the tick doesn't reach reverts it all. Eve's wider put has its line further
        // out, so alice's line doesn't reach it, and alice's put, which the tick touches, stays open.
        bytes32 wide = keccak256("eve's wide put");
        OpenOrder memory o = _order(users.eve, wide);
        o.side = Side.Put;
        OpenTerms memory t = _terms();
        t.thetaE7 = LayoutReader.market(address(flashOption), 0).durations[0].thetaMaxE7;
        assertGt(_betWith(o, t).liqPrice, line, "the wider put's line is further out");
        _expectLiquidateReverts(
            line, start, _ids(A, wide), abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, wide)
        );
        assertEq(
            uint8(LayoutReader.position(address(flashOption), A).status), uint8(Status.Open), "alice's put is open"
        );
    }

    function test_WhenThePriceTouchesEveryPositionsLine()
        external
        whenTheCallerIsASettler
        givenTheContractIsNotHalted
        whenTheBatchHolds1To100Ids
        whenTheMarketExists
        whenEveryIdWasOpened
        whenEveryPositionBelongsToTheMarket
        givenEveryPositionIsOpen
        whenThePriceIsPositive
        whenTheTickIsInsideEveryPositionsLife
        whenTheTickIsNotFromTheFuture
    {
        // At the line itself (equality counts), 10 seconds in, sent 20 seconds later: an old tick is accepted.
        vm.warp(start + 30);
        Ending[] memory endings = _expectLiquidated(line, start + 10, _ids(A, C));

        // it should close each position
        // it should keep each stake as free money, less the loser fee
        // it should accrue the fees once
        // it should emit {PositionLiquidated} for each
        // it should return the number liquidated
        for (uint256 i; i < 2; ++i) {
            assertEq(uint8(endings[i].status), uint8(Status.Closed), "closed");
            assertEq(endings[i].loserFee, 300_000, "3% of the $10 stake: free money is above the floor");
        }
        assertEq(LayoutReader.pool(address(flashOption)).feesPending, 600_000, "both fees pending");
        assertEq(LayoutReader.pool(address(flashOption)).total, FREE + 3 * Defaults.STAKE - 600_000, "the stakes stay");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev A valid attempt: alice's put at its line, at the tick that opened it.
    function _attempt() private view returns (Attempt memory x) {
        x.marketId = Defaults.BTC;
        x.leverage = Defaults.LEVERAGE;
        x.price = line;
        x.publishTime = start;
        x.ids = _ids(A);
    }

    /// @dev Breaks check `from` (numbered in the order of `IManicFlashOptionSettlement.liquidate`'s requirements, the
    ///      role being 1) and every later one:
    ///      2 the halt; 3 the batch's size (101 ids); 4 the market; 5 an id never opened; 6 a position of another
    ///      market; 7 the price (zero); 8 the position's life (a second after the end); 9 the clock skew (30 seconds
    ///      ahead, inside the life); 10 the line (one unit inside it).
    function _breakFrom(Attempt memory x, uint256 from) private {
        if (from <= 2) {
            vm.prank(users.guardian);
            flashOption.setHalted(true);
        }
        if (from <= 3) x.ids = _unknownIds(101);
        else if (from <= 5) x.ids = _ids(UNKNOWN, B, A);
        else if (from <= 6) x.ids = _ids(B, A);
        if (from <= 4) x.marketId = NO_MARKET;
        if (from <= 7) x.price = 0;
        else if (from <= 10) x.price = line - 1;
        if (from <= 8) x.publishTime = end + 1;
        else if (from <= 9) x.publishTime = start + 30;
    }

    /// @dev Breaks check `from` and every later one, and expects `liquidate` to revert with `reason`.
    function _expectReverts(uint256 from, bytes memory reason) private {
        Attempt memory x = _attempt();
        _breakFrom(x, from);
        _expectAttemptReverts(x, reason);
    }

    function _expectAttemptReverts(Attempt memory x, bytes memory reason) private {
        vm.expectRevert(reason);
        vm.prank(users.settler);
        flashOption.liquidate(x.marketId, x.leverage, x.price, x.publishTime, x.ids);
    }

    /// @dev `n` ids that were never opened.
    function _unknownIds(uint256 n) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = keccak256(abi.encode("never opened", i));
        }
    }
}
