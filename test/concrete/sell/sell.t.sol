// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {SellOrder, SellTerms} from "../../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../../src/types/ParamTypes.sol";
import {Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Sell_Concrete_Test
/// @notice Every branch of `sell`, from test/concrete/sell/sell.tree (docs/ARCHITECTURE.md §8.3): alice sells her $10
///         BTC call 20 seconds after it opened, at $8 above the entry, where it would pay its 1.3x floor ($13). The
///         relayer values it at $12.50 and sells it for $12, and she signed for at least $11.64. The pool has $1,500
///         of free money; bob's call, liquidated at the start, is the position that has already ended.
/// @dev Each revert test breaks its own check and every later one (`_breakFrom`), so its own error also proves the
///      order: no later check can have run first. Where a check has a boundary, the test also shows the other side
///      passes it: the next check's error appears instead. Two later checks can't both be broken: a sale amount above
///      the valuation leaves no fee to be too high, so that pair is shown one at a time. The pool's owed total and
///      free money are written straight into storage for the last two checks. Success is checked by `_expectSold`,
///      which compares every log, every field of the books, every slot and every balance with its own model.
contract Sell_Concrete_Test is Settlement_Base_Test {
    bytes32 internal constant A = keccak256("alice's call");
    bytes32 internal constant B = keccak256("bob's call, liquidated");
    bytes32 internal constant UNKNOWN = keccak256("never opened");

    /// @dev The sale's numbers: the position would pay $13 at +$8.
    uint64 internal constant PAYOUT = 13_000_000;
    uint64 internal constant VALUATION = 12_500_000;
    uint64 internal constant SELL_AMOUNT = 12_000_000;
    uint64 internal constant MIN_AMOUNT = 11_640_000;
    /// @dev The largest early-sell fee on the $12.50 valuation: 6% (`maxSellFeeBps` 600) is $0.75.
    uint64 internal constant MAX_FEE = 750_000;

    /// @dev One call to `sell`.
    struct Attempt {
        SellOrder s;
        bytes signature;
        SellTerms t;
    }

    /// @dev Alice's call: when it started and ends, and its line. The clock is 20 seconds after the start.
    uint48 internal start;
    uint48 internal end;
    int64 internal line;
    /// @dev $8 above the entry.
    int64 internal winning;

    function setUp() public override {
        super.setUp();
        Position memory a = _bet(users.alice, A, Side.Call);
        Position memory b = _bet(users.bob, B, Side.Call);
        _liquidate(b.liqPrice, b.startTime, _ids(B));
        start = a.startTime;
        end = _end(a);
        line = a.liqPrice;
        winning = Examples.priceAt(8);
        vm.warp(start + 20);
    }

    function test_RevertWhen_TheCallerIsNotAnOpener() external {
        // it should revert: every user but the opener, with every check after the role broken
        Attempt memory x = _attempt();
        _breakFrom(x, 2);
        address[] memory callers = _everyoneBut(users.opener, users.opener);
        bytes32 openerRole = flashOption.OPENER_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], openerRole)
            );
            vm.prank(callers[i]);
            flashOption.sell(x.s, x.signature, x.t);
        }
    }

    modifier whenTheCallerIsAnOpener() {
        _;
    }

    function test_RevertGiven_TheContractIsHalted() external whenTheCallerIsAnOpener {
        // it should revert
        _expectReverts(2, abi.encodeWithSelector(Errors.Halted.selector));
    }

    modifier givenTheContractIsNotHalted() {
        _;
    }

    function test_RevertWhen_TheOrderHasExpired() external whenTheCallerIsAnOpener givenTheContractIsNotHalted {
        // it should revert: one second past the deadline
        _expectReverts(3, abi.encodeWithSelector(Errors.OrderExpired.selector));

        // At the deadline itself the order is still good: the next check, the position, fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 4);
        x.s.deadline = uint48(block.timestamp);
        _expectAttemptReverts(x, 4, abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN));
    }

    modifier whenTheOrderHasNotExpired() {
        _;
    }

    function test_RevertWhen_ThePositionDoesNotExist()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
    {
        // it should revert, naming the id
        _expectReverts(4, abi.encodeWithSelector(Errors.UnknownPosition.selector, UNKNOWN));
    }

    modifier whenThePositionExists() {
        _;
    }

    function test_RevertGiven_ItsMarketIsDisabled()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
    {
        // it should revert
        _expectReverts(5, abi.encodeWithSelector(Errors.LeverageDisabled.selector));
    }

    modifier givenItsMarketIsEnabled() {
        _;
    }

    function test_RevertGiven_ItsMarketIsPaused()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
    {
        // it should revert
        _expectReverts(6, abi.encodeWithSelector(Errors.LeveragePaused.selector));
    }

    modifier givenItsMarketIsNotPaused() {
        _;
    }

    function test_RevertGiven_TheBreakerHasTripped()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
    {
        // it should revert
        _expectReverts(7, abi.encodeWithSelector(Errors.BreakerTripped.selector));
    }

    modifier givenTheBreakerHasNotTripped() {
        _;
    }

    function test_RevertGiven_ThePositionIsNotOpen()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
    {
        // it should revert: bob's call was liquidated
        _expectReverts(8, abi.encodeWithSelector(Errors.PositionNotOpen.selector));

        // A sale closes its position, so the same signed order can't sell it twice (security checklist SIG-3).
        Attempt memory x = _attempt();
        _expectSold(x.s, x.signature, x.t);
        vm.expectRevert(Errors.PositionNotOpen.selector);
        vm.prank(users.opener);
        flashOption.sell(x.s, x.signature, x.t);
    }

    modifier givenThePositionIsOpen() {
        _;
    }

    function test_RevertWhen_TheSignatureIsNotThePositionsUsers()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
    {
        // it should revert: eve's signature, and bob's, of alice's order
        _expectReverts(9, abi.encodeWithSelector(Errors.InvalidSignature.selector));
        Attempt memory x = _attempt();
        _breakFrom(x, 10);
        x.signature = _signSell(bobKey, x.s);
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(users.opener);
        flashOption.sell(x.s, x.signature, x.t);
    }

    modifier whenTheSignatureIsThePositionsUsers() {
        _;
    }

    function test_RevertWhen_TheTickIsOutsideTheSellWindow()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
    {
        // it should revert: at the cutoff, 2 seconds before the end
        bytes memory closed = abi.encodeWithSelector(Errors.SellWindowClosed.selector);
        bytes memory beforeTheOrder = abi.encodeWithSelector(Errors.PriceBeforeOrder.selector);
        _expectReverts(10, closed);

        // The last second before the cutoff still sells (the order's notBefore check fails instead); the cutoff
        // itself doesn't.
        uint48 cutoff = LayoutReader.market(address(flashOption), 0).sellCutoffSecs;
        vm.warp(end - cutoff - 1);
        _expectTickAt(uint48(block.timestamp), beforeTheOrder);
        vm.warp(end - cutoff);
        _expectTickAt(uint48(block.timestamp), closed);

        // With a 1-second minimum delay, the start is too early and the second after it sells.
        ConfigParams memory c = _enabledConfig();
        c.sellMinDelaySecs = 1;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        vm.warp(start + 1);
        _expectTickAt(start, closed);
        _expectTickAt(start + 1, beforeTheOrder);
    }

    modifier whenTheTickIsInsideTheSellWindow() {
        _;
    }

    function test_RevertWhen_TheSaleLandsAtOrAfterTheEndOfTheBet()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
    {
        // A second before the end, alice's sale on a tick 3 seconds before the end sells: the tick is inside the
        // window, and 2 seconds old.
        uint256 clean = vm.snapshotState();
        vm.warp(end - 3);
        SellOrder memory s = _sellOrder(A, MIN_AMOUNT);
        bytes memory signature = _signSell(aliceKey, s);
        SellTerms memory t = _sellTerms(winning, VALUATION, SELL_AMOUNT); // the tick, published now
        vm.warp(end - 1);
        _expectSold(s, signature, t);
        vm.revertToState(clean);

        // it should revert: the same tick in a sale landing at the end, and at the end + 2, when the tick is 5 seconds
        // old, its maximum age
        bytes memory closed = abi.encodeWithSelector(Errors.SellWindowClosed.selector);
        vm.warp(end);
        _expectTickAt(end - 3, closed);
        vm.warp(end + 2);
        _expectTickAt(end - 3, closed);
    }

    modifier whenTheSaleLandsBeforeTheEndOfTheBet() {
        _;
    }

    function test_RevertWhen_TheTickIsTooOldOrFromTheFuture()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
    {
        // it should revert: 6 seconds old
        bytes memory tooOld = abi.encodeWithSelector(Errors.PriceTooOld.selector);
        bytes memory beforeTheOrder = abi.encodeWithSelector(Errors.PriceBeforeOrder.selector);
        _expectReverts(11, tooOld);

        // The maximum age (5 seconds) passes. With the skew at 2 seconds, so it can't be mistaken for the age, a tick
        // 2 seconds ahead passes and 3 seconds ahead is from the future.
        uint48 now_ = uint48(block.timestamp);
        _expectTickAt(now_ - 5, beforeTheOrder);
        ConfigParams memory c = _enabledConfig();
        c.clockSkewSecs = 2;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _expectTickAt(now_ + 2, beforeTheOrder);
        _expectTickAt(now_ + 3, abi.encodeWithSelector(Errors.PriceFromFuture.selector));
    }

    modifier whenTheTickIsFresh() {
        _;
    }

    function test_RevertWhen_TheTickIsBeforeTheOrder()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
    {
        // it should revert: a second before alice signed
        _expectReverts(12, abi.encodeWithSelector(Errors.PriceBeforeOrder.selector));

        // A tick at the second she signed passes: the next check, the price, fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 13);
        x.s.notBefore = x.t.publishTime;
        _expectAttemptReverts(x, 13, abi.encodeWithSelector(Errors.InvalidPrice.selector));
    }

    modifier whenTheTickIsAtOrAfterTheOrder() {
        _;
    }

    function test_RevertWhen_ThePriceIsNotPositive()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
    {
        // it should revert: zero, one below and the lowest price
        _expectReverts(13, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        Attempt memory x = _attempt();
        _breakFrom(x, 13);
        x.t.price = -1;
        _expectAttemptReverts(x, 13, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        x.t.price = type(int64).min;
        _expectAttemptReverts(x, 13, abi.encodeWithSelector(Errors.InvalidPrice.selector));
    }

    modifier whenThePriceIsPositive() {
        _;
    }

    function test_RevertWhen_ThePriceTouchesTheLine()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
    {
        // it should revert, naming the position: at the line, and one unit beyond it
        bytes memory liquidateInstead = abi.encodeWithSelector(Errors.LiquidateInstead.selector, A);
        _expectReverts(14, liquidateInstead);
        Attempt memory x = _attempt();
        _breakFrom(x, 15);
        x.t.price = line - 1;
        _expectAttemptReverts(x, 15, liquidateInstead);

        // One unit inside the line passes (it would pay 0.7x): the valuation check fails instead.
        x.t.price = line + 1;
        _expectAttemptReverts(x, 15, abi.encodeWithSelector(Errors.ValuationAboveCurrentPayout.selector));
    }

    modifier whenThePriceDoesNotTouchTheLine() {
        _;
    }

    function test_RevertWhen_TheValuationIsAboveTheCurrentPayout()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
    {
        // it should revert: one unit above the $13 the position would pay
        _expectReverts(15, abi.encodeWithSelector(Errors.ValuationAboveCurrentPayout.selector));

        // Exactly $13 passes: the sale amount, above it, fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 15);
        x.t.valuation = PAYOUT;
        _expectAttemptReverts(x, 15, abi.encodeWithSelector(Errors.SellAmountExceedsValuation.selector));
    }

    modifier whenTheValuationIsAtMostTheCurrentPayout() {
        _;
    }

    function test_RevertWhen_TheSaleAmountExceedsTheValuation()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
    {
        // it should revert: one unit above the valuation
        _expectReverts(16, abi.encodeWithSelector(Errors.SellAmountExceedsValuation.selector));

        // A sale amount equal to the valuation (no fee) passes: the minimum, above it, fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 16);
        x.t.sellAmount = x.t.valuation;
        _expectAttemptReverts(x, 16, abi.encodeWithSelector(Errors.SellAmountBelowMin.selector));
    }

    modifier whenTheSaleAmountIsAtMostTheValuation() {
        _;
    }

    function test_RevertWhen_TheSellFeeIsAboveItsCap()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
    {
        // it should revert: a fee one unit above 6% of the valuation
        _expectReverts(17, abi.encodeWithSelector(Errors.SellFeeTooHigh.selector));

        // A fee of exactly 6% ($0.75) passes: the minimum, above the sale amount, fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 17);
        x.t.sellAmount = VALUATION - MAX_FEE;
        x.s.minAmount = x.t.sellAmount + 1;
        _expectAttemptReverts(x, 17, abi.encodeWithSelector(Errors.SellAmountBelowMin.selector));
    }

    modifier whenTheSellFeeIsAtMostItsCap() {
        _;
    }

    function test_RevertWhen_TheSaleAmountIsBelowTheMinimum()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
        whenTheSellFeeIsAtMostItsCap
    {
        // it should revert: one unit below the minimum alice signed for
        _expectReverts(18, abi.encodeWithSelector(Errors.SellAmountBelowMin.selector));

        // A sale amount at the minimum passes: the queue check fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 19);
        x.s.minAmount = x.t.sellAmount;
        _expectAttemptReverts(x, 19, abi.encodeWithSelector(Errors.QueueNotEmpty.selector));
    }

    modifier whenTheSaleAmountIsAtLeastTheMinimum() {
        _;
    }

    function test_RevertGiven_AnyoneIsOwed()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
        whenTheSellFeeIsAtMostItsCap
        whenTheSaleAmountIsAtLeastTheMinimum
    {
        // it should revert: one unit owed to anyone stops every sale
        _expectReverts(19, abi.encodeWithSelector(Errors.QueueNotEmpty.selector));

        // With nobody owed, the next check, the pool's free money, fails instead.
        Attempt memory x = _attempt();
        _breakFrom(x, 20);
        _writeLayout(address(flashOption), 3, 192, 64, 0); // pool.totalOwed
        _expectAttemptReverts(x, 20, abi.encodeWithSelector(Errors.SellNotPayable.selector));
    }

    modifier givenNobodyIsOwed() {
        _;
    }

    function test_RevertWhen_ThePoolCannotPayTheValuation()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
        whenTheSellFeeIsAtMostItsCap
        whenTheSaleAmountIsAtLeastTheMinimum
        givenNobodyIsOwed
    {
        // it should revert: no free money, so only the stake itself is there to pay the $12.50
        _expectReverts(20, abi.encodeWithSelector(Errors.SellNotPayable.selector));

        // Free money of exactly the valuation less the stake ($2.50) pays it: the sale goes through and empties it.
        PoolStateLite memory books = _books();
        _writeLayout(address(flashOption), 3, 0, 64, books.lockedMargin + VALUATION - Defaults.STAKE); // pool.total
        Attempt memory x = _attempt();
        _expectSold(x.s, x.signature, x.t);
        books = _books();
        assertEq(books.total, books.lockedMargin, "no free money left");
    }

    modifier whenThePoolCanPayTheValuation() {
        _;
    }

    function test_RevertWhen_ThePayoutHasTooLittleGas()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
        whenTheSellFeeIsAtMostItsCap
        whenTheSaleAmountIsAtLeastTheMinimum
        givenNobodyIsOwed
        whenThePoolCanPayTheValuation
    {
        // it should revert: an opener that starves the call can't push alice's proceeds into claimable. Every gas limit
        // up to the least that sells reverts, some of them with `InsufficientGasForPayout`.
        Attempt memory x = _attempt();
        bytes memory call_ = abi.encodeCall(flashOption.sell, (x.s, x.signature, x.t));
        bytes32 starved = keccak256(abi.encodeWithSelector(Errors.InsufficientGasForPayout.selector));
        bool sawTheGuard;
        bool sold;
        for (uint256 gasLimit = 20_000; gasLimit < 400_000 && !sold; gasLimit += 1000) {
            vm.prank(users.opener);
            bytes memory reason;
            (sold, reason) = address(flashOption).call{gas: gasLimit}(call_);
            if (keccak256(reason) == starved) sawTheGuard = true;
        }
        assertTrue(sawTheGuard, "too little gas for the payout reverts InsufficientGasForPayout");
        assertTrue(sold, "and enough gas sells");

        // At the least gas that sells, alice is paid in full, and nothing waits in claimable.
        assertEq(usdg.balanceOf(users.alice), 11_960_000, "alice is paid");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 0, "nothing deferred");
    }

    modifier whenThePayoutHasTheGasItNeeds() {
        _;
    }

    function test_GivenTheTokenRefusesThePayout()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
        whenTheSellFeeIsAtMostItsCap
        whenTheSaleAmountIsAtLeastTheMinimum
        givenNobodyIsOwed
        whenThePoolCanPayTheValuation
        whenThePayoutHasTheGasItNeeds
    {
        // Paxos freezes alice before her sale.
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);

        // it should keep it for the user to claim
        // it should still close the position
        Attempt memory x = _attempt();
        Ending memory e = _expectSold(x.s, x.signature, x.t);
        assertTrue(e.deferred, "her proceeds wait");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 11_960_000, "in her claimable balance");
        assertEq(uint8(LayoutReader.position(address(flashOption), A).status), uint8(Status.Closed), "closed");
    }

    function test_GivenTheTokenPays()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenThePositionExists
        givenItsMarketIsEnabled
        givenItsMarketIsNotPaused
        givenTheBreakerHasNotTripped
        givenThePositionIsOpen
        whenTheSignatureIsThePositionsUsers
        whenTheTickIsInsideTheSellWindow
        whenTheSaleLandsBeforeTheEndOfTheBet
        whenTheTickIsFresh
        whenTheTickIsAtOrAfterTheOrder
        whenThePriceIsPositive
        whenThePriceDoesNotTouchTheLine
        whenTheValuationIsAtMostTheCurrentPayout
        whenTheSaleAmountIsAtMostTheValuation
        whenTheSellFeeIsAtMostItsCap
        whenTheSaleAmountIsAtLeastTheMinimum
        givenNobodyIsOwed
        whenThePoolCanPayTheValuation
        whenThePayoutHasTheGasItNeeds
    {
        Attempt memory x = _attempt();
        Ending memory e = _expectSold(x.s, x.signature, x.t);

        // it should close the position
        // it should move the sale through the books
        // it should accrue the fees
        // it should emit {PositionSold}
        // it should pay the user the sale amount, less the winner fee
        assertEq(e.sale.gNow, 13_000, "at +$8 it would pay the 1.3x floor");
        assertEq(e.sale.toUser, 11_960_000, "$12, less 2% of the $2 profit");
        assertEq(e.sale.sellFee, 500_000, "the early-sell fee: the valuation less the sale amount");
        assertEq(e.sale.winnerFee, 40_000, "the winner fee");
        assertEq(e.sale.loserFee, 0, "no loser fee on a profit");
        assertEq(uint8(e.status), uint8(Status.Closed), "closed");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The parts of the pool's books the last two checks write.
    struct PoolStateLite {
        uint64 total;
        uint64 lockedMargin;
    }

    /// @dev A valid attempt: alice's sale now, at +$8, for the sale's numbers above, signed by her.
    function _attempt() private view returns (Attempt memory x) {
        x.s = _sellOrder(A, MIN_AMOUNT);
        x.t = _sellTerms(winning, VALUATION, SELL_AMOUNT);
        x.signature = _signSell(aliceKey, x.s);
    }

    /// @dev Breaks check `from` (numbered in the order of `IManicFlashOptionTrading.sell`'s requirements, the role
    /// being 1) and every later one:
    ///      2 the halt; 3 the deadline (a second ago); 4 the position (never opened); 5 the market (switched off);
    ///      6 the pause; 7 the breaker; 8 an open position (bob's, liquidated); 9 the signature (eve's);
    ///      10 the sell window (the cutoff, which is also 38 seconds ahead); 11 the tick's age (6 seconds);
    ///      12 notBefore (a second after the tick); 13 the price (zero, which also touches the line); 14 the line;
    ///      15 the valuation (a unit above the payout); 16 the sale amount (a unit above the valuation); 17 the fee (a
    ///      unit above the cap); 18 the minimum (a unit above the sale amount); 19 the queue (one unit owed); 20 free
    ///      money (none). Then the order is signed: by eve while check 9 must fail, by alice otherwise.
    function _breakFrom(Attempt memory x, uint256 from) private {
        if (from <= 2) {
            vm.prank(users.guardian);
            flashOption.setHalted(true);
        }
        if (from <= 3) x.s.deadline = uint48(block.timestamp) - 1;
        if (from <= 4) x.s.positionId = UNKNOWN;
        else if (from <= 8) x.s.positionId = B;
        if (from <= 5) {
            ConfigParams memory c = _enabledConfig();
            c.enabled = false;
            vm.prank(users.operator);
            flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        }
        if (from <= 6) {
            vm.prank(users.guardian);
            flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        }
        if (from <= 7) _writeLayout(address(flashOption), 7, 176, 8, 1); // breaker.tripped
        if (from <= 10) x.t.publishTime = end - LayoutReader.market(address(flashOption), 0).sellCutoffSecs;
        else if (from <= 11) x.t.publishTime = uint48(block.timestamp) - 6;
        if (from <= 12) x.s.notBefore = x.t.publishTime + 1;
        if (from <= 13) x.t.price = 0;
        else if (from <= 14) x.t.price = line;
        if (from <= 15) x.t.valuation = PAYOUT + 1;
        if (from <= 16) x.t.sellAmount = x.t.valuation + 1;
        else if (from <= 17) x.t.sellAmount = VALUATION - MAX_FEE - 1;
        if (from <= 18) x.s.minAmount = x.t.sellAmount + 1;
        if (from <= 19) _writeLayout(address(flashOption), 3, 192, 64, 1); // pool.totalOwed
        if (from <= 20) _writeLayout(address(flashOption), 3, 0, 64, _books().lockedMargin); // pool.total: no free
        // money
        x.signature = _signSell(from <= 9 ? eveKey : aliceKey, x.s);
    }

    /// @dev Breaks check `from` and every later one, expects `sell` to revert with `reason`, then puts every broken
    ///      check back: storage written with `vm.store` stays written after a reverted call, and the test may go on
    ///      to sell.
    function _expectReverts(uint256 from, bytes memory reason) private {
        uint256 clean = vm.snapshotState();
        Attempt memory x = _attempt();
        _breakFrom(x, from);
        _expectAttemptReverts(x, from, reason);
        vm.revertToState(clean);
    }

    /// @dev Signs `x` as `_breakFrom(x, from)` would, then expects `sell` to revert with `reason`.
    function _expectAttemptReverts(Attempt memory x, uint256 from, bytes memory reason) private {
        x.signature = _signSell(from <= 9 ? eveKey : aliceKey, x.s);
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.sell(x.s, x.signature, x.t);
    }

    /// @dev Expects a sale at a tick published at `publishTime` to give `expected`, with every check after the tick's
    ///      time broken (the order is signed for a second after the tick).
    function _expectTickAt(uint48 publishTime, bytes memory expected) private {
        Attempt memory x = _attempt();
        _breakFrom(x, 12);
        x.t.publishTime = publishTime;
        x.s.notBefore = publishTime + 1;
        _expectAttemptReverts(x, 12, expected);
    }

    /// @dev The pool's total and held margin, from storage.
    function _books() private view returns (PoolStateLite memory b) {
        b.total = LayoutReader.pool(address(flashOption)).total;
        b.lockedMargin = LayoutReader.pool(address(flashOption)).lockedMargin;
    }
}
