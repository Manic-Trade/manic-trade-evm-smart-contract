// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, PoolState, Position, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Sell_Scenario_Test
/// @notice Selling bets end to end, with every expected number to the base unit: sales at a profit, at a loss and in
///         the capped region with their fees, each bound of a sale at its edge, the sell window, stale and future
///         ticks, prices on the line, a disabled or paused market, who may send and sign a sale, the IOU queue, and a
///         pool that can't pay. The base bet is a $10 one-minute BTC long (θ 3 bp, floor 1.3x, cap 4x, at $83,884),
///         and a sale is `_expectSale(id, price, valuation, sellAmount, minAmount)` at the chain's clock.
/// @dev Every sale runs through `_expectSold`, which also checks the books, the slots, the logs and the balances
///      against its own model. The position's user signs the sale order, so another user's signature is
///      `InvalidSignature`, and only the opener role may send it.
contract Sell_Scenario_Test is Settlement_Base_Test {
    /// @dev $8 above the entry: the base long would pay its 1.3x floor, $13.
    int64 internal immutable UP = Examples.priceAt(8);

    /// @dev Sells a long at a profit: the sell fee and 2% of the profit go to the fee receiver.
    function test_ALongAtAProfit() external {
        _bet(users.alice, "long", Side.Call);
        // At +$8 the position would pay its 1.3x floor ($13); the backend values it at $12.50 and sells for $12.
        Ending memory e = _expectSale("long", UP, 12_500_000, 12_000_000, 11_640_000);
        assertEq(e.sale.gNow, 13_000, "g");
        assertEq(e.sale.toUser, 11_960_000, "to the user");
        assertEq(e.sale.sellFee, 500_000, "the sell fee");
        assertEq(e.sale.winnerFee, 40_000, "the winner fee");
        assertEq(e.sale.loserFee, 0, "no loser fee");
    }

    /// @dev Sells a short at a profit.
    function test_AShortAtAProfit() external {
        _bet(users.alice, "short", Side.Put);
        Ending memory e = _expectSale("short", Examples.priceAt(-8), 12_500_000, 12_000_000, 12_000_000);
        assertEq(e.sale.toUser, 11_960_000, "to the user");
    }

    /// @dev Sells at a loss with 3% of the loss to the fee receiver, and none one unit below the floor.
    function test_ALossAndNoLoserFeeBelowTheFloor() external {
        _bet(users.alice, "long", Side.Call);
        // At -$8 the position would pay $9.046; valued at $9, sold for $8.60.
        Ending memory e = _expectSale("long", Examples.priceAt(-8), 9_000_000, 8_600_000, 8_600_000);
        assertEq(e.sale.toUser, 8_600_000, "to the user");
        assertEq(e.sale.sellFee, 400_000, "the sell fee");
        assertEq(e.sale.loserFee, 30_000, "3% of the $1 loss");

        _bet(users.alice, "second long", Side.Call);
        uint64 free =
            LayoutReader.pool(address(flashOption)).total - LayoutReader.pool(address(flashOption)).lockedMargin;
        vm.prank(users.admin);
        flashOption.setPoolFloor(free + 1);
        Ending memory below = _expectSale("second long", Examples.priceAt(-8), 9_000_000, 8_600_000, 8_600_000);
        assertEq(below.sale.loserFee, 0, "no loser fee one unit below the floor");
    }

    /// @dev Sells in the capped region with no sell fee.
    function test_TheCappedRegionWithNoSellFee() external {
        _bet(users.alice, "long", Side.Call);
        Ending memory e = _expectSale("long", Examples.priceAt(300), 40_000_000, 40_000_000, 40_000_000);
        assertEq(e.sale.gNow, 40_000, "the 4x cap");
        assertEq(e.sale.toUser, 39_400_000, "to the user");
        assertEq(e.sale.sellFee, 0, "no sell fee");
        assertEq(e.sale.winnerFee, 600_000, "2% of the $30 profit");
    }

    /// @dev Accepts each bound at its edge and rejects one unit past it.
    function test_EachBoundAtItsEdge() external {
        _bet(users.alice, "a", Side.Call);
        _expectSaleReverts("a", UP, 13_000_001, 13_000_000, 13_000_000, Errors.ValuationAboveCurrentPayout.selector);
        _expectSale("a", UP, 13_000_000, 13_000_000, 13_000_000);

        // The fee cap is 6% (`maxSellFeeBps` 600): $0.75 on a $12.50 valuation.
        _bet(users.alice, "b", Side.Call);
        _expectSaleReverts("b", UP, 12_500_000, 11_749_999, 11_749_999, Errors.SellFeeTooHigh.selector);
        _expectSale("b", UP, 12_500_000, 11_750_000, 11_750_000);

        _bet(users.alice, "c", Side.Call);
        _expectSaleReverts("c", UP, 12_000_000, 12_000_001, 12_000_001, Errors.SellAmountExceedsValuation.selector);
        _expectSaleReverts("c", UP, 12_000_000, 12_000_000, 12_000_001, Errors.SellAmountBelowMin.selector);
        _expectSale("c", UP, 12_000_000, 12_000_000, 12_000_000);
    }

    /// @dev Closes the sell window before the minimum delay and in the last 2 seconds; the first and last seconds
    ///      sell. A 5-second rule in the last duration slot and a 1-second minimum delay make the window
    ///      [start + 1, end - 2) = [start + 1, start + 3).
    function test_TheSellWindowsEdges() external {
        ConfigParams memory c = _enabledConfig();
        c.durations[4] = DurationRule({durationSecs: 5, thetaMinE7: 1000, thetaMaxE7: 5000, enabled: true});
        c.sellMinDelaySecs = 1;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        Position memory a = _betLasting("a", 5);
        Position memory b = _betLasting("b", 5);
        uint48 start = a.startTime;

        vm.warp(start + 1);
        _expectFlatSaleReverts("a", start, Errors.SellWindowClosed.selector);
        _expectFlatSaleReverts("a", start + 3, Errors.SellWindowClosed.selector);
        _expectFlatSale("a", start + 1);
        vm.warp(start + 2);
        _expectFlatSale("b", b.startTime + 2);
    }

    /// @dev Rejects a stale tick and a future one.
    function test_AStaleTickAndAFutureOne() external {
        Position memory p = _bet(users.alice, "long", Side.Call);
        _expectFlatSaleReverts("long", uint48(block.timestamp) + 30, Errors.PriceFromFuture.selector);
        vm.warp(p.startTime + 6); // the open's own tick is now older than 5 seconds
        _expectFlatSaleReverts("long", p.startTime, Errors.PriceTooOld.selector);
        _expectFlatSale("long", uint48(block.timestamp));
    }

    /// @dev Rejects a price on or beyond the line, and a zero price.
    function test_APriceOnOrBeyondTheLineAndAZeroPrice() external {
        Position memory p = _bet(users.alice, "long", Side.Call);
        bytes4 liquidateInstead = Errors.LiquidateInstead.selector;
        _expectSaleReverts("long", p.liqPrice, 1_000_000, 1_000_000, 1_000_000, liquidateInstead);
        _expectSaleReverts("long", p.liqPrice - 1, 1_000_000, 1_000_000, 1_000_000, liquidateInstead);
        _expectSaleReverts("long", 0, 1_000_000, 1_000_000, 1_000_000, Errors.InvalidPrice.selector);
        Ending memory e = _expectSale("long", p.liqPrice + 1, 7_000_000, 7_000_000, 7_000_000);
        assertEq(e.sale.gNow, 7000, "one unit inside: 0.7x");
    }

    /// @dev Rejects a sale on a disabled or paused market.
    function test_ADisabledOrPausedMarket() external {
        _bet(users.alice, "long", Side.Call);
        ConfigParams memory c = _enabledConfig();
        c.enabled = false;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _expectFlatSaleReverts("long", uint48(block.timestamp), Errors.LeverageDisabled.selector);
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, _enabledConfig());
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        _expectFlatSaleReverts("long", uint48(block.timestamp), Errors.LeveragePaused.selector);
        vm.prank(users.operator);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        _expectFlatSale("long", uint48(block.timestamp));
    }

    /// @dev Rejects a sale sent by an account without the opener role, and a sale of alice's position signed by bob.
    function test_TheWrongRelayerAndAnotherUsersSignature() external {
        _bet(users.alice, "long", Side.Call);
        SellOrder memory s = _sellOrder("long", 10_000_000);
        SellTerms memory t = _sellTerms(Examples.P0, 10_000_000, 10_000_000);
        bytes memory signature = _signSell(aliceKey, s);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, users.settler, flashOption.OPENER_ROLE()
            )
        );
        vm.prank(users.settler);
        flashOption.sell(s, signature, t);
        bytes memory bobs = _signSell(bobKey, s);
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(users.opener);
        flashOption.sell(s, bobs, t);
        _expectSold(s, signature, t);
    }

    /// @dev Rejects a sale while anyone is owed, and an owed position can't be sold. The queue is made as in the settle
    ///      scenarios: two $10 longs at +$300 on a $20 pool.
    function test_AQueueStopsEverySaleAndAnOwedPositionCantBeSold() external {
        _useSmallPool(20e6);
        _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.alice, "b", Side.Call);
        vm.warp(_end(b));
        _expectSettled(Examples.priceAt(300), _end(b), _ids("a", "b"));
        assertGt(LayoutReader.pool(address(flashOption)).totalOwed, 0, "a queue");

        Position memory p = _bet(users.alice, "p", Side.Call);
        _expectSaleReverts("p", UP, 12_000_000, 12_000_000, 12_000_000, Errors.QueueNotEmpty.selector);

        // At expiry the winner's whole profit joins the queue, so the position becomes an IOU.
        vm.warp(_end(p));
        Ending[] memory endings = _expectSettled(UP, _end(p), _ids("p"));
        assertEq(endings[0].s.owed, 3_000_000, "$3 owed");
        _expectSaleReverts("p", UP, 12_000_000, 12_000_000, 12_000_000, Errors.PositionNotOpen.selector);
    }

    /// @dev Rejects a sale the pool can't pay in full; exactly at free money plus the stake it sells. A pool seeded
    ///      with $5 (its exposure gate off, so the $10 bet can open).
    function test_ASaleThePoolCantPayInFull() external {
        _useSmallPool(5e6);
        _bet(users.alice, "long", Side.Call);
        int64 capped = Examples.priceAt(300); // the position would pay $40, but the pool holds $5 + its $10
        _expectSaleReverts("long", capped, 15_000_001, 15_000_001, 15_000_001, Errors.SellNotPayable.selector);
        Ending memory e = _expectSale("long", capped, 15_000_000, 15_000_000, 15_000_000);
        assertEq(e.sale.toUser, 14_900_000, "$15 minus 2% of the $5 profit");
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.total, pool.lockedMargin, "the pool is empty");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Expects selling `id` now at `price` for these amounts, signed by alice, to revert with `selector`.
    function _expectSaleReverts(
        bytes32 id,
        int64 price,
        uint64 valuation,
        uint64 sellAmount,
        uint64 minAmount,
        bytes4 selector
    )
        private
    {
        bytes memory reason = selector == Errors.LiquidateInstead.selector
            ? abi.encodeWithSelector(selector, id)
            : abi.encodeWithSelector(selector);
        _expectSellReverts(_sellOrder(id, minAmount), _sellTerms(price, valuation, sellAmount), reason);
    }

    /// @dev A flat sale at the entry price for the stake, at a tick published at `publishTime`.
    function _expectFlatSale(bytes32 id, uint48 publishTime) private {
        SellOrder memory s = _sellOrder(id, 10_000_000);
        s.notBefore = publishTime;
        SellTerms memory t = _sellTerms(Examples.P0, 10_000_000, 10_000_000);
        t.publishTime = publishTime;
        _expectSold(s, _signSell(aliceKey, s), t);
    }

    /// @dev Expects that flat sale to revert with `selector`.
    function _expectFlatSaleReverts(bytes32 id, uint48 publishTime, bytes4 selector) private {
        SellOrder memory s = _sellOrder(id, 10_000_000);
        s.notBefore = publishTime;
        SellTerms memory t = _sellTerms(Examples.P0, 10_000_000, 10_000_000);
        t.publishTime = publishTime;
        _expectSellReverts(s, t, abi.encodeWithSelector(selector));
    }

    /// @dev Opens alice's base long lasting `durationSecs`.
    function _betLasting(bytes32 id, uint16 durationSecs) private returns (Position memory) {
        OpenOrder memory o = _order(users.alice, id);
        o.durationSecs = durationSecs;
        OpenTerms memory t = _terms();
        return _betWith(o, t);
    }
}
