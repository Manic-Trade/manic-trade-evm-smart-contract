// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../../src/types/ParamTypes.sol";
import {Market, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {LeverageConfigs} from "../../utils/LeverageConfigs.sol";

/// @title Leverages_Concrete_Test
/// @notice One feed at three leverages on one pool (ADR 0008): BTC at 1000x, the test market, and at 500x and 100x
///         with the tier settings (`LeverageConfigs.planned`). Each leverage is a market of its own, with its own
///         settings, checks and pause, and a bet opens, settles, sells and is liquidated at its market's leverage.
///         Each bet keeps its own copy of that leverage.
/// @dev Every ending runs through the settlement checkers, whose model values a bet at its own leverage with
///      `Calculations` (never `LeverageMath`), and checks the books, the logs and the slots. The expected lines are
///      written here from their formulas. Prices move in whole bps of the entry ($83,884.00, so 1 bp is $8.3884).
contract Leverages_Concrete_Test is Settlement_Base_Test {
    uint16 internal constant L500 = 500;
    uint16 internal constant L100 = 100;
    /// @dev 1 bp of the entry price, exactly.
    int64 internal constant BP = Examples.BP;

    function setUp() public override {
        super.setUp();
        vm.startPrank(users.admin);
        flashOption.createMarket(Defaults.BTC, L500, Defaults.PRICE_EXPONENT, _config500x(false));
        flashOption.createMarket(Defaults.BTC, L100, Defaults.PRICE_EXPONENT, _config100x(false));
        vm.stopPrank();
        vm.startPrank(users.operator);
        flashOption.setConfig(Defaults.BTC, L500, _config500x(true));
        flashOption.setConfig(Defaults.BTC, L100, _config100x(true));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Three markets of one feed
    // ---------------------------------------------------------------------------------------------------------------

    function test_EachLeverageIsAMarketOfItsOwn() external {
        assertEq(flashOption.marketCount(), 3, "BTC at 1000x, 500x and 100x");
        (bytes32 feed, uint16 marketLeverage) = flashOption.marketIdAt(1);
        assertEq(feed, Defaults.BTC, "index 1: BTC");
        assertEq(marketLeverage, L500, "at 500x");
        (feed, marketLeverage) = flashOption.marketIdAt(2);
        assertEq(feed, Defaults.BTC, "index 2: BTC");
        assertEq(marketLeverage, L100, "at 100x");

        // Each has its own settings: the tier floors and caps, beside the test market's.
        Market memory m500 = flashOption.getMarket(Defaults.BTC, L500);
        Market memory m100 = flashOption.getMarket(Defaults.BTC, L100);
        Market memory m1000 = flashOption.getMarket(Defaults.BTC, Defaults.LEVERAGE);
        assertEq(m500.leverage, L500, "500x");
        assertEq(m500.floorMinBps, 10_250, "500x: a 1.025x floor");
        assertEq(m500.capMaxBps, 25_000, "500x: up to a 2.5x cap");
        assertEq(m100.leverage, L100, "100x");
        assertEq(m100.floorMinBps, 10_050, "100x: a 1.005x floor");
        assertEq(m100.capMaxBps, 20_000, "100x: up to a 2x cap");
        assertEq(m1000.leverage, Defaults.LEVERAGE, "1000x");
        assertEq(m1000.capMaxBps, 40_000, "1000x: up to a 4x cap");

        // A change to one leaves the others as they were.
        ConfigParams memory c = _config500x(true);
        c.maxStake = 20e6;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, L500, c);
        assertEq(flashOption.getMarket(Defaults.BTC, L500).maxStake, 20e6, "500x: a new maximum stake");
        assertEq(abi.encode(flashOption.getMarket(Defaults.BTC, L100)), abi.encode(m100), "100x unchanged");
        assertEq(
            abi.encode(flashOption.getMarket(Defaults.BTC, Defaults.LEVERAGE)), abi.encode(m1000), "1000x unchanged"
        );
    }

    function test_PausingOneLeverageLeavesTheOthersOpen() external {
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, L500, true);
        assertTrue(flashOption.getMarket(Defaults.BTC, L500).paused, "500x paused");
        assertFalse(flashOption.getMarket(Defaults.BTC, L100).paused, "100x open");
        assertFalse(flashOption.getMarket(Defaults.BTC, Defaults.LEVERAGE).paused, "1000x open");

        _expectOpenReverts(
            _orderAt(users.alice, "alice at 500x", L500, Side.Call), _terms500(), Errors.LeveragePaused.selector
        );
        _bet(users.alice, keccak256("alice at 1000x"), Side.Call);
        _betWith(_orderAt(users.bob, "bob at 100x", L100, Side.Put), _terms100());
        assertEq(flashOption.getPool().openPositions, 2, "the 1000x and 100x bets opened");
    }

    function test_RevertWhen_AnOrderNamesALeverageWithNoMarket() external {
        // BTC has markets at 1000x, 500x and 100x, and none at 2000x.
        _expectOpenReverts(
            _orderAt(users.alice, "alice at 2000x", 2000, Side.Call), _terms(), Errors.UnknownMarket.selector
        );
    }

    function test_EachMarketChecksItsSettingsAtItsLeverage() external {
        // The 100x tier's lines (up to 17.64 bp) and the 500x tier's (up to 11.76 bp) are too wide for 1000x, where a
        // line must stay under 10 bp; at their own leverage they pass.
        vm.startPrank(users.admin);
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, _config100x(false));
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, _config500x(false));
        flashOption.createMarket(Defaults.ETH, L100, Defaults.PRICE_EXPONENT, _config100x(false));
        flashOption.createMarket(Defaults.ETH, L500, Defaults.PRICE_EXPONENT, _config500x(false));
        vm.stopPrank();

        // New settings are checked at the market's own leverage: BTC at 1000x refuses the 500x settings, while BTC at
        // 500x takes a line of 19.999 bp, its widest, and refuses 20 bp.
        vm.startPrank(users.operator);
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, _config500x(true));
        ConfigParams memory c = _config500x(true);
        c.durations[4].thetaMaxE7 = 19_999;
        flashOption.setConfig(Defaults.BTC, L500, c);
        c.durations[4].thetaMaxE7 = 20_000;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, L500, c);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // A bet at its market's leverage
    // ---------------------------------------------------------------------------------------------------------------

    function test_A500xBetOpensWithTheLinesOf500x() external {
        OpenOrder memory o = _orderAt(users.alice, "alice at 500x", L500, Side.Call);
        OpenedData memory d = _betRecorded(o, _terms500());
        int256 entry = Defaults.ENTRY_PRICE;
        // The line is θ away whatever the leverage: 5 bp below.
        assertEq(d.liqPrice, entry - (entry * 5000) / 1e7, "the line: 5 bp below the entry");
        // The cap line is where g reaches the 2.5x cap at 500x: (2.5 - 1) / 500 = 0.3% above, $84,135.652, the same
        // price as 1000x's 4x cap line.
        assertEq(d.capPrice, entry + (entry * 15_000) / (int256(uint256(L500)) * 10_000), "the cap line: 0.3% above");
        assertEq(d.capPrice, 8_413_565_200_000, "$84,135.652");

        Position memory p = LayoutReader.position(address(flashOption), o.positionId);
        assertEq(p.marketIdx, 1, "on the 500x market");
        (,, int64 capPrice) = flashOption.getPosition(o.positionId);
        assertEq(capPrice, d.capPrice, "getPosition's cap line is at the market's leverage too");
    }

    function test_A500xAndA100xBetSettleAtTheirLeverage() external {
        bytes32 a = keccak256("alice at 500x");
        bytes32 b = keccak256("bob at 100x");
        Position memory p = _betWith(_orderAt(users.alice, "alice at 500x", L500, Side.Call), _terms500());
        _betWith(_orderAt(users.bob, "bob at 100x", L100, Side.Put), _terms100());
        vm.warp(_end(p));
        int64 up4 = Defaults.ENTRY_PRICE + 4 * BP;

        // +4 bp at 500x: the call pays 1 + 500 × 0.04% = 1.2x.
        batchLeverage = L500;
        Ending[] memory endings = _expectSettled(up4, _end(p), _ids(a));
        assertEq(endings[0].s.g, 12_000, "500x: +4 bp pays 1.2x");

        // The same tick at 100x: the put has lost 100 × 0.04% = 4%, so it pays 0.96x.
        batchLeverage = L100;
        endings = _expectSettled(up4, _end(p), _ids(b));
        assertEq(endings[0].s.g, 9600, "100x: 4 bp against pays 0.96x");
    }

    function test_A500xBetSellsAtItsLeverage() external {
        bytes32 id = keccak256("alice at 500x");
        _betWith(_orderAt(users.alice, "alice at 500x", L500, Side.Call), _terms500());
        vm.warp(block.timestamp + 10);
        // +6 bp at 500x: g = 1 + 500 × 0.06% = 1.3x, so the bet is worth $13. Alice sells for $12.87, a 1% fee.
        Ending memory e = _expectSale(id, Defaults.ENTRY_PRICE + 6 * BP, 13e6, 12_870_000, 12e6);
        assertEq(e.sale.gNow, 13_000, "valued at 500x");
    }

    function test_A100xBetSellsAtItsLeverage() external {
        bytes32 id = keccak256("bob at 100x");
        _betWith(_orderAt(users.bob, "bob at 100x", L100, Side.Call), _terms100());
        vm.warp(block.timestamp + 10);
        // +20 bp at 100x: g = 1 + 100 × 0.2% = 1.2x, so the bet is worth $12. Bob sells for $11.94, a 0.5% fee.
        Ending memory e = _expectSale(id, Defaults.ENTRY_PRICE + 20 * BP, 12e6, 11_940_000, 11e6);
        assertEq(e.sale.gNow, 12_000, "valued at 100x");
    }

    function test_A500xBetIsLiquidatedAtItsLine() external {
        bytes32 id = keccak256("alice at 500x");
        Position memory p = _betWith(_orderAt(users.alice, "alice at 500x", L500, Side.Call), _terms500());
        vm.warp(block.timestamp + 5);
        batchLeverage = L500;
        _expectLiquidated(p.liqPrice, p.startTime + 5, _ids(id));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // A batch holds one market, so one leverage
    // ---------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_ABatchMixesLeverages() external {
        bytes32 at1000 = keccak256("alice at 1000x");
        bytes32 at500 = keccak256("bob at 500x");
        Position memory p = _bet(users.alice, at1000, Side.Call);
        _betWith(_orderAt(users.bob, "bob at 500x", L500, Side.Call), _terms500());
        vm.warp(_end(p));

        // The 500x market's batch can't hold the 1000x bet, and the 1000x market's can't hold the 500x one.
        batchLeverage = L500;
        _expectSettleReverts(
            Defaults.ENTRY_PRICE,
            _end(p),
            _ids(at500, at1000),
            abi.encodeWithSelector(Errors.ConfigMismatch.selector, at1000)
        );
        batchLeverage = Defaults.LEVERAGE;
        _expectSettleReverts(
            Defaults.ENTRY_PRICE,
            _end(p),
            _ids(at1000, at500),
            abi.encodeWithSelector(Errors.ConfigMismatch.selector, at500)
        );
        _expectLiquidateReverts(
            p.liqPrice, p.startTime, _ids(at500, at1000), abi.encodeWithSelector(Errors.ConfigMismatch.selector, at500)
        );

        // Each settles in its own market's batch.
        _expectSettled(Defaults.ENTRY_PRICE, _end(p), _ids(at1000));
        batchLeverage = L500;
        _expectSettled(Defaults.ENTRY_PRICE, _end(p), _ids(at500));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Each bet keeps its leverage
    // ---------------------------------------------------------------------------------------------------------------

    function test_EachBetRecordsItsMarketsLeverage() external {
        OpenOrder[3] memory orders = [
            _orderAt(users.alice, "alice at 1000x", Defaults.LEVERAGE, Side.Call),
            _orderAt(users.bob, "bob at 500x", L500, Side.Put),
            _orderAt(users.eve, "eve at 100x", L100, Side.Call)
        ];
        OpenTerms[3] memory terms = [_terms(), _terms500(), _terms100()];
        for (uint256 i; i < 3; ++i) {
            OpenedData memory d = _betRecorded(orders[i], terms[i]);
            assertEq(d.leverage, orders[i].leverage, "PositionOpened reports its market's leverage");
            (Position memory p,,) = flashOption.getPosition(orders[i].positionId);
            assertEq(p.leverage, orders[i].leverage, "getPosition returns it");
            assertEq(p.marketIdx, i, "the bet's market");
        }
    }

    function test_AnIouKeepsItsLeverageUntilRepaid() external {
        // A pool with $5 of free money and BTC at 500x, with no exposure gate.
        _useSmallPool(5e6);
        ConfigParams memory c = _config500x(false);
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, L500, Defaults.PRICE_EXPONENT, c);
        c.enabled = true;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, L500, c);
        _switchOffOpenGate(address(flashOption), Defaults.BTC, L500);

        bytes32 id = keccak256("alice at 500x");
        OpenedData memory d = _betRecorded(_orderAt(users.alice, "alice at 500x", L500, Side.Call), _terms500());
        vm.warp(d.endTime);
        // +20 bp at 500x: g = 1 + 500 × 0.2% = 2x, a $10 profit. The pool pays the $5 it has and owes the rest.
        batchLeverage = L500;
        Ending[] memory endings = _expectSettled(Defaults.ENTRY_PRICE + 20 * BP, d.endTime, _ids(id));
        assertEq(endings[0].s.g, 20_000, "2x at 500x");
        assertEq(endings[0].s.owed, 5e6, "$5 owed");

        // An IOU keeps its terms, its leverage among them, so its cap line is still 500x's.
        (Position memory p,, int64 capPrice) = flashOption.getPosition(id);
        assertEq(uint8(p.status), uint8(Status.Owed), "owed");
        assertEq(p.leverage, L500, "it keeps its leverage");
        assertEq(capPrice, d.capPrice, "and its cap line, $84,135.652");

        // Repaid in full, it closes, and its leverage is cleared with its other terms.
        _fund(users.bob, 100e6);
        _expectRepaid(1, users.eve);
        (p,, capPrice) = flashOption.getPosition(id);
        assertEq(uint8(p.status), uint8(Status.Closed), "closed");
        assertEq(p.leverage, 0, "its leverage is cleared");
        assertEq(capPrice, 0, "so it has no cap line");
    }

    function test_EachEndingUsesTheBetsOwnLeverage() external {
        // No function changes a market's leverage, so a bet's copy and its market's always agree. Writing 1000 over
        // the 500x market's stored leverage (white-box) tells them apart: its bets must still end at 500x.
        bytes32 a = keccak256("alice at 500x");
        bytes32 b = keccak256("bob at 500x");
        bytes32 c = keccak256("eve at 500x");
        Position memory p = _betWith(_orderAt(users.alice, "alice at 500x", L500, Side.Call), _terms500());
        _betWith(_orderAt(users.bob, "bob at 500x", L500, Side.Call), _terms500());
        _betWith(_orderAt(users.eve, "eve at 500x", L500, Side.Call), _terms500());
        (,, int64 capPrice) = flashOption.getPosition(a);
        _overwriteMarketLeverage(1, Defaults.LEVERAGE);

        // getPosition: the bet's own leverage, and its cap line at it.
        (Position memory stored,, int64 capNow) = flashOption.getPosition(a);
        assertEq(stored.leverage, L500, "the bet's own leverage");
        assertEq(capNow, capPrice, "500x's cap line, $84,135.652");

        // Liquidated: PositionLiquidated reports 500x, as the checkers' model expects.
        vm.warp(block.timestamp + 5);
        batchLeverage = L500;
        _expectLiquidated(p.liqPrice, p.startTime + 5, _ids(c));

        // Sold at +6 bp: still 1.3x, $13 (1000x would value it at 1.6x).
        vm.warp(block.timestamp + 5);
        Ending memory e = _expectSale(b, Defaults.ENTRY_PRICE + 6 * BP, 13e6, 12_870_000, 12e6);
        assertEq(e.sale.gNow, 13_000, "sold at 500x");

        // Settled at +4 bp: still 1.2x (1000x would pay 1.4x).
        vm.warp(_end(p));
        Ending[] memory endings = _expectSettled(Defaults.ENTRY_PRICE + 4 * BP, _end(p), _ids(a));
        assertEq(endings[0].s.g, 12_000, "settled at 500x");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `user`'s base order (a $10 BTC bet for 60 seconds), at `orderLeverage` on `side`, with the id `name` hashes
    ///      to.
    function _orderAt(
        address user,
        string memory name,
        uint16 orderLeverage,
        Side side
    )
        private
        view
        returns (OpenOrder memory o)
    {
        o = _order(user, keccak256(bytes(name)));
        o.leverage = orderLeverage;
        o.side = side;
    }

    /// @dev Terms inside the 500x market's one-minute rule: a line of 5 bp, the 1.025x floor and the 2.5x cap.
    function _terms500() private view returns (OpenTerms memory t) {
        t = _terms();
        (t.thetaE7, t.floorBps, t.capBps) = (5000, 10_250, 25_000);
    }

    /// @dev Terms at the 100x market's widest one-minute line: 9 bp, the 1.005x floor and the 2x cap.
    function _terms100() private view returns (OpenTerms memory t) {
        t = _terms();
        (t.thetaE7, t.floorBps, t.capBps) = (9000, 10_050, 20_000);
    }

    /// @dev White-box: writes `value` over the leverage stored in market `index` (its slot 2, bytes 16 and 17),
    ///      which no function can change, and keeps the rest of the slot.
    function _overwriteMarketLeverage(uint16 index, uint16 value) private {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(index), LayoutReader.ROOT + 9))) + 2);
        uint256 word = uint256(vm.load(address(flashOption), slot));
        uint256 mask = uint256(type(uint16).max) << 128;
        vm.store(address(flashOption), slot, bytes32((word & ~mask) | (uint256(value) << 128)));
        assertEq(LayoutReader.market(address(flashOption), index).leverage, value, "the market's stored leverage");
        assertEq(LayoutReader.marketWord(address(flashOption), index, 2) & ~mask, word & ~mask, "the rest of the slot");
    }

    /// @dev Opens `o` with `t` as the opener, expecting the revert `reason`.
    function _expectOpenReverts(OpenOrder memory o, OpenTerms memory t, bytes4 reason) private {
        uint256 key = _keyFor(o.user);
        _mintUsdg(o.user, o.stake);
        bytes memory signature = _signOrder(flashOption, key, o);
        StakeAuth memory a = _stakeAuth(flashOption, key, o);
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
    }

    /// @dev The 500x tier settings (`LeverageConfigs.planned`): floors 1.025x to 1.25x, caps 1.5x to 2.5x, the line
    ///      range for each duration (each minimum 15% below the tier's lowest line), and the open gate at 100%.
    function _config500x(bool enabled) private pure returns (ConfigParams memory c) {
        c = LeverageConfigs.planned(L500);
        c.enabled = enabled;
    }

    /// @dev The 100x tier settings (`LeverageConfigs.planned`): floors 1.005x to 1.05x, caps 1.5x to 2x, the line
    ///      range for each duration, and the open gate at 100%.
    function _config100x(bool enabled) private pure returns (ConfigParams memory c) {
        c = LeverageConfigs.planned(L100);
        c.enabled = enabled;
    }
}
