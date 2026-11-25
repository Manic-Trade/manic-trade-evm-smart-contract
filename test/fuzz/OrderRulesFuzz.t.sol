// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../../src/types/OrderTypes.sol";
import {Position, Side, Status} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title OrderRules_Fuzz_Test
/// @notice The rules a signed order lives by, for random times, users and endings (docs/ARCHITECTURE.md §7, §8.2 and
///         §8.3; security checklist SIG-3 and MEV-2). An order can't be used late, early or twice:
///         - late: after its `deadline`, `open` and `sell` refuse it (`OrderExpired`). At the deadline itself it still
///           goes through;
///         - early: a tick published before the order's `notBefore` is refused (`PriceBeforeOrder`), and one
///           published at `notBefore` itself goes through. This is what holds "commit first, price after" on chain;
///         - twice: a position id, once used, never opens another bet, whoever signs it, on whichever market and at
///           whichever leverage, and however the first one ended: still open, liquidated, settled, sold, refunded, or
///           owed as an IOU (`PositionIdUsed`). And a position that has ended can never be sold (`PositionNotOpen`).
/// @dev The late and early properties also run their boundary case, which must succeed: a check that refused too much
///      fails here as surely as one that refused too little. The concrete tests (test/concrete/open/,
///      test/concrete/sell/) show each rule once; these show it for any gap, age, lifetime, user and ending. The bets
///      are the base terms (Defaults: a $10 BTC call for 60 seconds), whose sell window ends 2 seconds before the
///      expiry. Inputs are bounded with `bound`, never `vm.assume`. CI runs 10,000 cases per property.
contract OrderRules_Fuzz_Test is Settlement_Base_Test {
    /// @notice 2026-11-13, midnight UTC: a realistic clock, so a tick can be published seconds before "now".
    uint256 internal constant START = 1_794_528_000;

    /// @notice The launch market's oldest tick, in seconds (`entryMaxAgeSecs`).
    uint256 internal constant MAX_AGE = 5;

    /// @notice How a test bet ends before its id is used again.
    uint8 internal constant STILL_OPEN = 0;
    uint8 internal constant LIQUIDATED = 1;
    uint8 internal constant SETTLED = 2;
    uint8 internal constant SOLD = 3;
    uint8 internal constant REFUNDED = 4;
    uint8 internal constant OWED = 5;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
    }

    /// @dev An open order a second or more past its deadline is refused, however long it lived and however late it
    ///      is. At the deadline itself it opens.
    function testFuzz_AnOpenOrderPastItsDeadlineIsRefused(uint256 lifetime, uint256 late) external {
        OpenOrder memory o = _order(users.alice, "the bet");
        o.deadline = uint48(block.timestamp + bound(lifetime, 0, 1 hours));

        vm.warp(o.deadline + bound(late, 1, 30 days));
        _expectOpenReverts(o, _terms(), Errors.OrderExpired.selector);

        vm.warp(o.deadline);
        _assertStatus(_betWith(o, _terms()), Status.Open);
    }

    /// @dev An open priced at a tick published before the order's `notBefore` is refused, by any gap and with the tick
    ///      at any age the market accepts. A tick published at `notBefore` itself opens.
    function testFuzz_AnOpenTickBeforeTheOrderIsRefused(uint256 gap, uint256 age) external {
        OpenOrder memory o = _order(users.alice, "the bet");
        OpenTerms memory t = _terms();
        t.entryPublishTime = uint48(block.timestamp - bound(age, 0, MAX_AGE));
        o.notBefore = t.entryPublishTime + uint48(bound(gap, 1, 1 days));
        _expectOpenReverts(o, t, Errors.PriceBeforeOrder.selector);

        vm.warp(o.notBefore);
        t.entryPublishTime = o.notBefore;
        o.deadline = o.notBefore + Defaults.ORDER_LIFETIME;
        _assertStatus(_betWith(o, t), Status.Open);
    }

    /// @dev Once a position id is used, no order with it opens again: not alice's, not anyone else's, on either side,
    ///      for any stake and on BTC's market at any leverage (`_leverageFor`; the first bet's is 1000x), whether the
    ///      first bet is still open, was liquidated, settled, sold or refunded, or is owed as an IOU. The id is checked
    ///      before the terms, so the base terms do on every market.
    function testFuzz_AUsedPositionIdNeverOpensAgain(uint8 ending, uint8 reuser, uint256 seed) external {
        bytes32 id = keccak256(abi.encode("the bet", seed));
        _betEndedBy(ending % 6, id);
        uint16 marketLeverage = _leverageFor(seed >> 16);
        _useBtcAt(marketLeverage, LeverageConfigs.launchAt(marketLeverage));

        address who = reuser % 3 == 0 ? users.alice : (reuser % 3 == 1 ? users.bob : users.eve);
        OpenOrder memory o = _order(who, id);
        o.leverage = marketLeverage;
        o.side = seed % 2 == 0 ? Side.Call : Side.Put;
        o.stake = uint64(bound(seed >> 8, 1e6, 50e6)); // anything the market accepts: $1 to $50
        _expectOpenReverts(o, _terms(), Errors.PositionIdUsed.selector);
    }

    /// @dev A sale order a second or more past its deadline is refused, however long it lived and however late it is.
    ///      At the deadline itself it sells, as long as that is still inside the sell window.
    function testFuzz_ASaleOrderPastItsDeadlineIsRefused(uint256 lifetime, uint256 late) external {
        Position memory p = _bet(users.alice, "the bet", Side.Call);
        SellOrder memory s = _sellOrder("the bet", 0);
        s.deadline = uint48(block.timestamp + bound(lifetime, 0, 50)); // the window closes 58 seconds in

        vm.warp(s.deadline + bound(late, 1, 30 days));
        _expectSellReverts(s, _flatSale(p), abi.encodeWithSelector(Errors.OrderExpired.selector));

        vm.warp(s.deadline);
        bytes memory signature = _signSell(aliceKey, s); // before the prank: signing calls the contract
        vm.prank(users.opener);
        flashOption.sell(s, signature, _flatSale(p));
        _assertStatus(LayoutReader.position(address(flashOption), "the bet"), Status.Closed);
    }

    /// @dev A sale priced at a tick published before the order's `notBefore` is refused, by any gap, anywhere in the
    ///      sell window and at any age the market accepts. A tick published at `notBefore` itself sells.
    function testFuzz_ASaleTickBeforeTheOrderIsRefused(uint256 into, uint256 gap, uint256 age) external {
        Position memory p = _bet(users.alice, "the bet", Side.Call);
        uint48 publishTime = p.startTime + uint48(bound(into, 0, 40));
        age = bound(age, 0, MAX_AGE);
        SellOrder memory s = _sellOrder("the bet", 0);
        s.notBefore = publishTime + uint48(bound(gap, 1, 10)); // at most 50 seconds in
        s.deadline = s.notBefore + Defaults.ORDER_LIFETIME;

        vm.warp(publishTime + age);
        SellTerms memory t = _flatSale(p);
        t.publishTime = publishTime;
        _expectSellReverts(s, t, abi.encodeWithSelector(Errors.PriceBeforeOrder.selector));

        vm.warp(s.notBefore + age); // at most 55 seconds in: before the bet ends
        t.publishTime = s.notBefore;
        bytes memory signature = _signSell(aliceKey, s); // before the prank: signing calls the contract
        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
        _assertStatus(LayoutReader.position(address(flashOption), "the bet"), Status.Closed);
    }

    /// @dev A position that has ended (liquidated, settled, sold, refunded, or owed as an IOU) can never be sold, by a
    ///      new order with any minimum: the sale is refused before its signature is even checked.
    function testFuzz_AnEndedPositionIsNeverSold(uint8 ending, uint64 minAmount, uint256 seed) external {
        bytes32 id = keccak256(abi.encode("the bet", seed));
        Position memory p = _betEndedBy(LIQUIDATED + ending % 5, id);
        _expectSellReverts(
            _sellOrder(id, minAmount), _flatSale(p), abi.encodeWithSelector(Errors.PositionNotOpen.selector)
        );
    }

    /// @dev Opens alice's base call with `id` and ends it as `how` says, checking it reached that state. An IOU needs a
    ///      pool too small to pay: `_useSmallPool` leaves $1 of free money, and a settle past the cap line owes $29 of
    ///      the $30 profit.
    function _betEndedBy(uint8 how, bytes32 id) private returns (Position memory p) {
        if (how == OWED) _useSmallPool(1e6);
        p = _bet(users.alice, id, Side.Call);
        Status expected = Status.Closed;
        if (how == STILL_OPEN) {
            expected = Status.Open;
        } else if (how == LIQUIDATED) {
            _liquidate(p.liqPrice, uint48(block.timestamp), _ids(id)); // touching the line; equality counts
        } else if (how == SETTLED) {
            vm.warp(_end(p));
            _settle(p.entryPrice, _end(p), _ids(id));
        } else if (how == SOLD) {
            SellOrder memory s = _sellOrder(id, 0);
            bytes memory signature = _signSell(aliceKey, s); // before the prank: signing calls the contract
            vm.prank(users.opener);
            flashOption.sell(s, signature, _flatSale(p));
        } else if (how == REFUNDED) {
            vm.warp(_end(p) + Defaults.REFUND_DELAY);
            flashOption.refundExpired(_ids(id));
        } else {
            vm.warp(_end(p));
            _settle(p.entryPrice + p.entryPrice / 100, _end(p), _ids(id)); // 1% up: past the 4x cap line (0.3%)
            expected = Status.Owed;
        }
        _assertStatus(LayoutReader.position(address(flashOption), id), expected);
    }

    /// @dev A sale at the position's entry price, at a tick published now: valued at its stake (g = 1x), sold for it.
    function _flatSale(Position memory p) private view returns (SellTerms memory) {
        return _sellTerms(p.entryPrice, p.stake, p.stake);
    }

    /// @dev Expects the opener's open of `o` with `t`, signed by its user and paid by a fresh stake authorisation, to
    ///      revert with `selector`.
    function _expectOpenReverts(OpenOrder memory o, OpenTerms memory t, bytes4 selector) private {
        _mintUsdg(o.user, o.stake);
        bytes memory signature = _signOrder(flashOption, _keyFor(o.user), o);
        StakeAuth memory a = _stakeAuth(flashOption, _keyFor(o.user), o);
        vm.expectRevert(selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
    }

    /// @dev `p`'s status is `expected`.
    function _assertStatus(Position memory p, Status expected) private pure {
        assertEq(uint8(p.status), uint8(expected), "the position's status");
    }
}
