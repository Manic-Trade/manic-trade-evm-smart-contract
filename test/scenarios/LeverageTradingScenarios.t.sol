// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../src/interfaces/IManicFlashOptionEvents.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, PoolState, Position, Side} from "../../src/types/StorageTypes.sol";
import {Defaults} from "../utils/Defaults.sol";
import {FlashOption_Scenario_Shared_Test} from "./FlashOptionShared.sol";

/// @title LeverageTrading_Scenario_Test
/// @notice Trading at the 500x and 100x tiers, end to end, with the tier settings and the tier example bet: opens at
///         every bound, the widest line each leverage allows, liquidations, settlements and sales with their fees,
///         bets of three leverages expiring in one second, the exposure gate reading the shared pool, and IOUs of
///         three leverages in one queue, repaid in order, with every expected number to the base unit.
/// @dev Every ending runs through the settlement checkers. Each test starts from a fresh deployment, and the last,
///      `test_WithTheQueueEmptyTheBetsOfAllThreeLeveragesSellAgain`, ends with no bet open and nobody owed in the
///      pool. Besides the shared set-up (FlashOptionShared.sol):
///      - bets end when the clock is moved to their expiry, not by waiting, so the settlements use the tier example
///        bet's one minute, except where only a 5-second rule allows the line (the widest line) or the flow needs one
///        (the empty pool's queue);
///      - bets that must expire in the same second open in one block;
///      - the IOU scenarios run on a second, empty pool: a second deployment, on the same feed (`_useEmptyPool`);
///      - a sale names no market: the bet's own applies.
contract LeverageTrading_Scenario_Test is FlashOption_Scenario_Shared_Test {
    /// @dev A sale and what it must pay: the price `move` bp from entry in the bet's favour.
    struct SaleCase {
        Side side;
        int64 move;
        uint16 g;
        uint64 valuation;
        uint64 sellAmount;
        uint64 toUser;
        uint64 sellFee;
        uint64 winnerFee;
        uint64 loserFee;
    }

    function setUp() public override {
        super.setUp();
        // BTC at 500x and 100x with the tier settings: every test starts from the markets the first test sets and
        // checks.
        _createMarket(L500, _tierConfig(L500));
        _createMarket(L100, _tierConfig(L100));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The tier settings on the BTC markets
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Puts the tier lines for every duration on the BTC 500x and 100x markets, each under 1/leverage.
    function test_PutsTheTierLinesOnThe500xAnd100xMarkets() external {
        uint16[2] memory options = [L500, L100];
        for (uint256 i; i < 2; ++i) {
            // Checked field by field, with the event, which carries the leverage.
            ConfigParams memory c = _tierConfig(options[i]);
            _setConfig(options[i], c);
            for (uint256 j; j < 5; ++j) {
                assertLt(uint256(c.durations[j].thetaMaxE7) * options[i], 1e7, "each line is under 1/leverage");
            }
        }
    }

    /// @dev Anyone may fund: $2,000 more in the pool leaves free money well above the floor, so profits are paid at
    ///      once and loser fees are taken.
    function test_TopsThePoolUpBy2000() external {
        PoolState memory before = flashOption.getPool();
        _mintUsdg(users.eve, 2000e6);
        vm.startPrank(users.eve);
        usdg.approve(address(flashOption), 2000e6);
        vm.expectEmit(address(flashOption));
        emit Events.PoolFunded(users.eve, 2000e6);
        flashOption.fund(2000e6);
        vm.stopPrank();
        PoolState memory pool = flashOption.getPool();
        assertEq(pool.total, before.total + 2000e6, "the pool's total");
        assertGe(pool.total - pool.lockedMargin, pool.poolFloor + 1000e6, "free money well above the floor");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Opens
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Opens the tier example bet long and short at 500x and 100x, with the lines at the bet's leverage.
    function test_OpensTheTierExampleBetLongAndShortWithTheLinesAtItsLeverage() external {
        // θ is a price distance: 5.25 bp and 6.60 bp from entry. The cap line sits (cap - 1x) / leverage from entry:
        // 2.5x at 500x is 0.3%, 2x at 100x is 1%.
        OpenedData memory long500 = _open(_example(users.alice, "500x long", L500, Side.Call));
        OpenedData memory short500 = _open(_example(users.alice, "500x short", L500, Side.Put));
        OpenedData memory long100 = _open(_example(users.alice, "100x long", L100, Side.Call));
        OpenedData memory short100 = _open(_example(users.alice, "100x short", L100, Side.Put));
        assertEq(long500.liqPrice, 8_383_996_090_000, "500x long: the line");
        assertEq(long500.capPrice, 8_413_565_200_000, "500x long: the cap line");
        assertEq(short500.liqPrice, 8_392_803_910_000, "500x short: the line");
        assertEq(short500.capPrice, 8_363_234_800_000, "500x short: the cap line");
        assertEq(long100.liqPrice, 8_382_863_656_000, "100x long: the line");
        assertEq(long100.capPrice, 8_472_284_000_000, "100x long: the cap line");
        assertEq(short100.liqPrice, 8_393_936_344_000, "100x short: the line");
        assertEq(short100.capPrice, 8_304_516_000_000, "100x short: the cap line");
    }

    /// @dev Opens every duration at its lowest and highest line, rejects one unit past either, and liquidates each
    ///      leverage's bets in one batch.
    function test_OpensEveryDurationAtItsLowestAndHighestLine() external {
        uint16[2] memory options = [L500, L100];
        for (uint256 i; i < 2; ++i) {
            uint16 x = options[i];
            ConfigParams memory c = _tierConfig(x);
            bytes32[] memory ids = new bytes32[](10);
            // The longest duration first, so all ten bets are still running at the tick below.
            for (uint256 j; j < 5; ++j) {
                DurationRule memory rule = c.durations[4 - j];
                Bet memory b = _example(users.alice, "", x, Side.Call);
                b.durationSecs = rule.durationSecs;
                b.id = keccak256(abi.encode(x, rule.durationSecs, "one unit past"));
                b.thetaE7 = rule.thetaMinE7 - 1;
                _expectOpenRejected(b, Errors.InvalidLeverageParams.selector);
                b.thetaE7 = rule.thetaMaxE7 + 1;
                _expectOpenRejected(b, Errors.InvalidLeverageParams.selector);
                (b.id, b.thetaE7) = (keccak256(abi.encode(x, rule.durationSecs, "lowest")), rule.thetaMinE7);
                _open(b);
                ids[2 * j] = b.id;
                (b.id, b.thetaE7) = (keccak256(abi.encode(x, rule.durationSecs, "highest")), rule.thetaMaxE7);
                _open(b);
                ids[2 * j + 1] = b.id;
            }
            // A tick 20 bp down is beyond all ten lines (the widest is 17.64 bp), so one batch at this leverage
            // liquidates them all, each paying the 3% loser fee.
            batchLeverage = x;
            Ending[] memory endings = _expectLiquidated(_down(20), uint48(block.timestamp), ids);
            for (uint256 k; k < 10; ++k) {
                assertEq(endings[k].loserFee, 300_000, "3% of each $10 stake");
            }
        }
    }

    /// @dev Opens stake, floor and cap at each of their bounds, and rejects one unit past any.
    function test_OpensStakeFloorAndCapAtEachOfTheirBounds() external {
        uint16[2] memory options = [L500, L100];
        for (uint256 i; i < 2; ++i) {
            uint16 x = options[i];
            ConfigParams memory c = _tierConfig(x);
            Bet memory low = _example(users.alice, string.concat(vm.toString(x), "x low"), x, Side.Call);
            (low.stake, low.floorBps, low.capBps) = (c.minStake, c.floorMinBps, c.capMinBps);
            Bet memory high = _example(users.alice, string.concat(vm.toString(x), "x high"), x, Side.Call);
            (high.stake, high.floorBps, high.capBps) = (c.maxStake, c.floorMaxBps, c.capMaxBps);

            low.stake = c.minStake - 1;
            _expectOpenRejected(low, Errors.InvalidAmount.selector);
            (low.stake, high.stake) = (c.minStake, c.maxStake + 1);
            _expectOpenRejected(high, Errors.InvalidAmount.selector);
            (high.stake, low.floorBps) = (c.maxStake, c.floorMinBps - 1);
            _expectOpenRejected(low, Errors.InvalidLeverageParams.selector);
            (low.floorBps, high.floorBps) = (c.floorMinBps, c.floorMaxBps + 1);
            _expectOpenRejected(high, Errors.InvalidLeverageParams.selector);
            (high.floorBps, low.capBps) = (c.floorMaxBps, c.capMinBps - 1);
            _expectOpenRejected(low, Errors.InvalidLeverageParams.selector);
            (low.capBps, high.capBps) = (c.capMinBps, c.capMaxBps + 1);
            _expectOpenRejected(high, Errors.InvalidLeverageParams.selector);
            high.capBps = c.capMaxBps;

            OpenedData memory d = _open(low);
            _open(high);
            // The same line for both: one tick on it liquidates them together.
            batchLeverage = x;
            Ending[] memory endings = _expectLiquidated(d.liqPrice, uint48(block.timestamp), _ids(low.id, high.id));
            assertEq(endings[0].loserFee, 30_000, "3% of the $1 stake");
            assertEq(endings[1].loserFee, 1_500_000, "3% of the $50 stake");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The line limit at its edge
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Turns the 4-minute line into a 5-second one up to the widest line, and gives 1000x a 5-second rule.
    function test_TurnsTheFourMinuteLineIntoAFiveSecondOneUpToTheWidestLine() external {
        assertEq(_widestLine(L500), 19_999, "19.999 bp at 500x");
        assertEq(_widestLine(L100), 99_999, "99.999 bp at 100x");
        _useFiveSecondRules();
    }

    /// @dev At the widest line each leverage allows, a bet opens, pays 0 one unit inside its line, and is liquidated
    ///      on it.
    function test_AtTheWidestLineABetOpensPaysZeroOneUnitInsideItsLineAndIsLiquidatedOnIt() external {
        _useFiveSecondRules();
        // The payout reaches 0 at 1/leverage (20 bp at 500x, 100 bp at 100x), just past the widest line. One unit
        // inside the line g rounds down to 0: the whole stake is lost, as on the line.
        uint16[2] memory options = [L500, L100];
        int64[2] memory longLines = [int64(8_371_624_038_840), 8_304_516_838_840];
        for (uint256 i; i < 2; ++i) {
            uint16 x = options[i];
            Bet memory longBet = _example(users.alice, string.concat(vm.toString(x), "x widest long"), x, Side.Call);
            (longBet.durationSecs, longBet.thetaE7) = (5, _widestLine(x));
            Bet memory shortBet = _example(users.alice, string.concat(vm.toString(x), "x widest short"), x, Side.Put);
            (shortBet.durationSecs, shortBet.thetaE7) = (5, _widestLine(x));
            OpenedData memory longOpen = _open(longBet);
            OpenedData memory shortOpen = _open(shortBet);
            assertEq(longOpen.liqPrice, longLines[i], "the long's line");
            assertGt(longOpen.liqPrice, P0 - P0 / int64(uint64(x)), "the line comes before the payout reaches 0");

            vm.warp(longOpen.endTime);
            batchLeverage = x;
            Ending[] memory endings = _expectSettled(longOpen.liqPrice + 1, longOpen.endTime, _ids(longBet.id));
            assertEq(endings[0].s.g, 0, "one unit inside the line, the bet is worth 0");
            assertEq(endings[0].s.payout + endings[0].s.toUser, 0, "nothing to the user");
            assertEq(endings[0].s.loserFee, 300_000, "3% of the stake to the fees");

            _expectLiquidateReverts(
                shortOpen.liqPrice - 1,
                shortOpen.startTime,
                _ids(shortBet.id),
                abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, shortBet.id)
            );
            _expectLiquidated(shortOpen.liqPrice, shortOpen.startTime, _ids(shortBet.id));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidations
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Liquidates the tier example bets on their lines, not one unit inside them, with the 3% loser fee.
    function test_LiquidatesTheTierExampleBetsOnTheirLinesNotOneUnitInside() external {
        uint16[2] memory options = [L500, L100];
        for (uint256 i; i < 2; ++i) {
            uint16 x = options[i];
            Bet memory longBet = _example(users.alice, string.concat(vm.toString(x), "x long"), x, Side.Call);
            Bet memory shortBet = _example(users.alice, string.concat(vm.toString(x), "x short"), x, Side.Put);
            OpenedData memory longOpen = _open(longBet);
            OpenedData memory shortOpen = _open(shortBet);
            // Later, an old tick inside each bet's life is accepted, so the backend can replay one.
            vm.warp(block.timestamp + 10);
            batchLeverage = x;
            _expectLiquidateReverts(
                longOpen.liqPrice + 1,
                longOpen.startTime,
                _ids(longBet.id),
                abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, longBet.id)
            );
            _expectLiquidateReverts(
                shortOpen.liqPrice - 1,
                shortOpen.startTime,
                _ids(shortBet.id),
                abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, shortBet.id)
            );
            Ending[] memory e = _expectLiquidated(longOpen.liqPrice, longOpen.startTime, _ids(longBet.id));
            assertEq(e[0].loserFee, 300_000, "3% of the long's $10 stake");
            e = _expectLiquidated(shortOpen.liqPrice, shortOpen.startTime, _ids(shortBet.id));
            assertEq(e[0].loserFee, 300_000, "3% of the short's $10 stake");
        }
    }

    /// @dev Rejects a liquidation batch that mixes leverages, through either market and wherever the other bet sits.
    function test_RejectsALiquidationBatchThatMixesLeverages() external {
        Bet memory a = _example(users.alice, "500x a", L500, Side.Call);
        Bet memory b = _example(users.alice, "500x b", L500, Side.Call);
        Bet memory c = _example(users.alice, "100x c", L100, Side.Call);
        c.thetaE7 = 5250; // the 500x bets' line, inside the 100x range
        int64 line = _open(a).liqPrice;
        _open(b);
        assertEq(_open(c).liqPrice, line, "one line for all three");
        uint48 now48 = uint48(block.timestamp);
        batchLeverage = L500;
        _expectLiquidateReverts(
            line, now48, _ids(a.id, b.id, c.id), abi.encodeWithSelector(Errors.ConfigMismatch.selector, c.id)
        );
        _expectLiquidateReverts(
            line, now48, _ids(c.id, a.id), abi.encodeWithSelector(Errors.ConfigMismatch.selector, c.id)
        );
        batchLeverage = L100;
        _expectLiquidateReverts(
            line, now48, _ids(c.id, a.id), abi.encodeWithSelector(Errors.ConfigMismatch.selector, a.id)
        );
        batchLeverage = L500;
        _expectLiquidated(line, now48, _ids(a.id, b.id));
        batchLeverage = L100;
        _expectLiquidated(line, now48, _ids(c.id));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Settlements
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Pays winners at the floor, mid-range and the cap, long and short, minus the 2% winner fee. g moves 5% of
    ///      the stake per bp at 500x and 1% at 100x.
    function test_PaysWinnersAtTheFloorMidRangeAndTheCap() external {
        // 500x: +2 bp would be 1.1x, under the 1.15x floor; +40 bp is past the cap line (+30 bp), 2.5x.
        _expectWinners(
            L500, [int64(2), 10, 40], [uint16(11_500), 15_000, 25_000], [uint64(11_470_000), 14_900_000, 24_700_000]
        );
        // 100x: +2 bp would be 1.02x, under the 1.03x floor; +150 bp is past the cap line (+100 bp), 2x.
        _expectWinners(
            L100, [int64(2), 50, 150], [uint16(10_300), 15_000, 20_000], [uint64(10_294_000), 14_900_000, 19_800_000]
        );
    }

    /// @dev Returns the stake at a flat expiry; losers pay 3% of the loss; one unit inside the line settles, the line
    ///      is `LiquidateInstead`. At -2 bp, and one unit inside the line (5.25 bp at 500x, 6.60 bp at 100x).
    function test_FlatExpiryLosersAndOneUnitInsideTheLine() external {
        _expectFlatLosersAndInside(L500, 9000, 9_000_000, 30_000, 7375);
        _expectFlatLosersAndInside(L100, 9800, 9_800_000, 6000, 9340);
    }

    /// @dev Settles bets of three leverages that expire in the same second in one batch per market; a mixed batch is
    ///      rejected. The four bets open in one block, so they share the expiry second.
    function test_SettlesBetsOfThreeLeveragesExpiringInTheSameSecond() external {
        Bet memory x1000 = _baseBet(users.alice, "1000x", L1000, Side.Call);
        Bet memory x500 = _example(users.alice, "500x", L500, Side.Call);
        Bet memory x500b = _example(users.bob, "500x, another user", L500, Side.Call);
        Bet memory x100 = _example(users.alice, "100x", L100, Side.Call);
        uint48 end = _open(x1000).endTime;
        assertEq(_open(x500).endTime, end, "one expiry second");
        assertEq(_open(x500b).endTime, end, "one expiry second");
        assertEq(_open(x100).endTime, end, "one expiry second");
        vm.warp(end);
        int64 tick = _up(6);
        batchLeverage = L500;
        _expectSettleReverts(
            tick, end, _ids(x500.id, x500b.id, x100.id), abi.encodeWithSelector(Errors.ConfigMismatch.selector, x100.id)
        );
        batchLeverage = L1000;
        _expectSettleReverts(
            tick, end, _ids(x1000.id, x500.id), abi.encodeWithSelector(Errors.ConfigMismatch.selector, x500.id)
        );

        // One batch per market at the one price. +6 bp pays 1.6x at 1000x, 1.3x at 500x (both users) and 1.06x at
        // 100x.
        assertEq(_expectSettled(tick, end, _ids(x1000.id))[0].s.g, 16_000, "1000x: 1.6x");
        batchLeverage = L500;
        Ending[] memory e = _expectSettled(tick, end, _ids(x500.id, x500b.id));
        assertEq(e[0].s.g, 13_000, "500x: 1.3x");
        assertEq(e[1].s.g, 13_000, "500x, another user: 1.3x");
        batchLeverage = L100;
        assertEq(_expectSettled(tick, end, _ids(x100.id))[0].s.g, 10_600, "100x: 1.06x");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Sales
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Sells long and short at a profit, at a loss and in the capped region, with the fees at each leverage.
    function test_SellsLongAndShortAtAProfitAtALossAndCapped() external {
        // 500x: 2% of the $2.50 profit; 3% of the $1 loss; capped at 2.5x, with no sell fee.
        _expectSaleCase(L500, SaleCase(Side.Call, 6, 13_000, 13e6, 12.5e6, 12_450_000, 500_000, 50_000, 0));
        _expectSaleCase(L500, SaleCase(Side.Put, 6, 13_000, 13e6, 12.5e6, 12_450_000, 500_000, 50_000, 0));
        _expectSaleCase(L500, SaleCase(Side.Call, -2, 9000, 9e6, 8.6e6, 8_600_000, 400_000, 0, 30_000));
        _expectSaleCase(L500, SaleCase(Side.Call, 40, 25_000, 25e6, 25e6, 24_700_000, 0, 300_000, 0));
        // 100x: 3% of the $0.20 loss; capped at 2x.
        _expectSaleCase(L100, SaleCase(Side.Call, 20, 12_000, 12e6, 11.5e6, 11_470_000, 500_000, 30_000, 0));
        _expectSaleCase(L100, SaleCase(Side.Put, 20, 12_000, 12e6, 11.5e6, 11_470_000, 500_000, 30_000, 0));
        _expectSaleCase(L100, SaleCase(Side.Call, -2, 9800, 9.8e6, 9.4e6, 9_400_000, 400_000, 0, 6000));
        _expectSaleCase(L100, SaleCase(Side.Put, 150, 20_000, 20e6, 20e6, 19_800_000, 0, 200_000, 0));
    }

    /// @dev Bounds a sale's valuation by the payout at the bet's own leverage: at the payout it sells, one unit above
    ///      it doesn't. +4 bp in the bet's favour: 1.2x at 500x, 1.04x at 100x.
    function test_BoundsASalesValuationByThePayoutAtTheBetsOwnLeverage() external {
        _expectPayoutBound(L500, 12e6, 12_000);
        _expectPayoutBound(L100, 10_400_000, 10_400);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // One pool for every leverage: the exposure gate
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A market's exposure gate counts every leverage's bets in the shared pool, and stops only its own opens.
    function test_AMarketsExposureGateCountsEveryLeveragesBets() external {
        // A 1000x and a 100x bet take up exposure in the pool: stake × (cap - 1x), $30 and $10.
        Bet memory x1000 = _baseBet(users.alice, "1000x", L1000, Side.Call);
        Bet memory x100 = _example(users.alice, "100x", L100, Side.Call);
        _open(x1000);
        _open(x100);
        Bet memory bet = _example(users.alice, "500x", L500, Side.Call); // $15 of exposure
        (uint32 limit, uint32 alone) = _limitFor(bet);
        assertLt(alone, limit - 1, "on its own the 500x bet would fit: the other leverages' bets block it");
        ConfigParams memory c = _tierConfig(L500);
        c.maxExposureBps = limit - 1;
        _setConfig(L500, c);
        _expectOpenRejected(bet, Errors.OpenBlockedExposure.selector);

        // The 100x market has no gate, so its opens go on.
        Bet memory x100b = _example(users.alice, "100x, the second", L100, Side.Call);
        _open(x100b);
        // At its limit, counting the new bet too, the 500x bet opens.
        (limit,) = _limitFor(bet);
        c.maxExposureBps = limit;
        _setConfig(L500, c);
        _open(bet);
        _setConfig(L500, _tierConfig(L500));

        // Clean-up: one tick 10 bp down is beyond all four lines; one batch per market.
        uint48 now48 = uint48(block.timestamp);
        _expectLiquidated(_down(10), now48, _ids(x1000.id));
        batchLeverage = L100;
        _expectLiquidated(_down(10), now48, _ids(x100.id, x100b.id));
        batchLeverage = L500;
        _expectLiquidated(_down(10), now48, _ids(bet.id));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // One pool for every leverage: IOUs and repayment, on a second, empty pool
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Creates 500x and 100x markets with the tier settings next to 1000x, on a second, empty pool.
    ///      `_useEmptyPool` creates each market and checks its events and every field.
    function test_CreatesThe500xAnd100xMarketsOfAnEmptyPool() external {
        _useEmptyPool();
        assertEq(flashOption.marketCount(), 3, "1000x, 500x and 100x");
        PoolState memory pool = flashOption.getPool();
        assertEq(
            uint256(pool.total) + pool.lockedMargin + pool.totalOwed + pool.openPositions + pool.owedPositions,
            0,
            "the pool is empty"
        );
    }

    /// @dev Winners the empty pool can't pay join one queue in settle order, whatever their leverage, each keeping it.
    function test_WinnersTheEmptyPoolCantPayJoinOneQueueInSettleOrder() external {
        _useEmptyPool();
        _queueThreeIous();
    }

    /// @dev While anyone is owed, no leverage can sell, and each market's owed gate stops only its own opens.
    function test_WhileAnyoneIsOwedNoLeverageCanSellAndEachOwedGateStopsOnlyItsOwnOpens() external {
        _useEmptyPool();
        _queueThreeIous();
        bytes32[3] memory waiting = _openWaitingBets();
        for (uint256 i; i < 3; ++i) {
            _expectSellReverts(
                _sellOrder(waiting[i], 9_500_000),
                _sellTerms(P0, 10e6, 9_500_000),
                abi.encodeWithSelector(Errors.QueueNotEmpty.selector)
            );
        }

        // 500x's gate one unit under what is owed: only its opens stop.
        uint64 totalOwed = flashOption.getPool().totalOwed;
        assertEq(totalOwed, 16e6, "$5 + $1 + $10");
        ConfigParams memory c = _tierConfigWithFiveSeconds(L500);
        c.maxTotalOwed = totalOwed - 1;
        _setConfig(L500, c);
        Bet memory y500 = _example(users.alice, "y at 500x", L500, Side.Call);
        Bet memory y100 = _example(users.alice, "y at 100x", L100, Side.Call);
        (y500.durationSecs, y100.durationSecs) = (5, 5);
        _expectOpenRejected(y500, Errors.OpenBlockedTotalOwed.selector);
        uint48 end = _open(y100).endTime;
        // At the limit it opens.
        c.maxTotalOwed = totalOwed;
        _setConfig(L500, c);
        _open(y500);
        c.maxTotalOwed = type(uint64).max;
        _setConfig(L500, c);

        // Both settle flat: the stake back, nothing queued.
        vm.warp(end);
        batchLeverage = L100;
        assertEq(_expectSettled(P0, end, _ids(y100.id))[0].s.owed, 0, "100x: nothing owed");
        batchLeverage = L500;
        assertEq(_expectSettled(P0, end, _ids(y500.id))[0].s.owed, 0, "500x: nothing owed");
    }

    /// @dev Repays the queue in order across leverages: a part-paid IOU keeps its leverage, and the queue ends empty.
    function test_RepaysTheQueueInOrderAcrossLeverages() external {
        _useEmptyPool();
        bytes32[3] memory ious = _queueThreeIous();
        // The queue, head first, is the settle order: the 500x, 100x and 1000x IOUs.
        bytes32[] memory queue = _queueFromHead(3);
        uint16[3] memory leverages = [L500, L100, L1000];
        for (uint256 i; i < 3; ++i) {
            assertEq(queue[i], ious[i], "in settle order");
            (Position memory p,,) = flashOption.getPosition(queue[i]);
            assertEq(p.leverage, leverages[i], "each with its leverage");
        }

        // Enough for the 500x IOU ($5) and half of the 100x one.
        _fund(users.eve, 5_500_000);
        (Ending[] memory first,) = _expectRepaid(3, users.eve);
        assertEq(first.length, 2, "the 1000x IOU waits");
        assertEq(first[0].repayment.amount, 5e6, "the 500x IOU in full");
        assertEq(first[0].repayment.remaining, 0, "nothing left of it");
        assertEq(first[1].repayment.amount, 500_000, "half of the 100x IOU");
        assertEq(first[1].repayment.remaining, 500_000, "half still owed");
        (Position memory part,,) = flashOption.getPosition(ious[1]);
        assertEq(part.leverage, L100, "a part-paid IOU keeps its leverage");

        // The rest: the 100x IOU's last $0.50 and the 1000x IOU.
        _fund(users.eve, 10_500_000);
        (Ending[] memory rest,) = _expectRepaid(3, users.eve);
        assertEq(rest.length, 2, "both");
        assertEq(rest[0].repayment.remaining + rest[1].repayment.remaining, 0, "both paid in full");
        PoolState memory pool = flashOption.getPool();
        assertEq(pool.totalOwed, 0, "nobody is owed");
        assertEq(pool.owedPositions, 0, "no IOU");
        assertEq(pool.nextRepaySeq, pool.nextQueueSeq, "the queue is empty");
    }

    /// @dev With the queue empty, the bets of all three leverages sell again, and the pool ends with no bet open and
    ///      nobody owed.
    function test_WithTheQueueEmptyTheBetsOfAllThreeLeveragesSellAgain() external {
        _useEmptyPool();
        _queueThreeIous();
        bytes32[3] memory waiting = _openWaitingBets();
        _fund(users.eve, 16e6);
        _expectRepaid(3, users.eve);
        // Flat: valued at the stake and sold for $9.50; the pool pays it out of the stake it holds.
        for (uint256 i; i < 3; ++i) {
            Ending memory e = _expectSale(waiting[i], P0, 10e6, 9_500_000, 9_500_000);
            assertEq(e.sale.gNow, 10_000, "1x");
            assertEq(e.sale.toUser, 9_500_000, "$9.50 to the user");
            assertEq(e.sale.sellFee, 500_000, "the sell fee");
            assertEq(e.sale.winnerFee + e.sale.loserFee, 0, "no winner or loser fee");
        }
        PoolState memory pool = flashOption.getPool();
        assertEq(pool.lockedMargin, 0, "no stake held");
        assertEq(pool.totalOwed, 0, "nobody owed");
        assertEq(pool.openPositions, 0, "no bet open");
        assertEq(pool.owedPositions, 0, "no IOU");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev BTC at 500x and 100x get a 5-second rule up to their widest line in the 4-minute slot, and the 1000x test
    ///      market one (θ 0.1 to 0.5 bp) in its 5-minute slot, each update checked in full.
    function _useFiveSecondRules() private {
        _setConfig(L500, _tierConfigWithFiveSeconds(L500));
        _setConfig(L100, _tierConfigWithFiveSeconds(L100));
        ConfigParams memory x1000 = Defaults.marketConfig();
        x1000.durations[4] = _rule(5, 1000, 5000);
        _setConfig(L1000, x1000);
    }

    /// @dev Settles one example bet per case and side at `x`, at `moves[i]` bp in its favour, expecting `g[i]` and
    ///      `paid[i]` to the user.
    function _expectWinners(uint16 x, int64[3] memory moves, uint16[3] memory g, uint64[3] memory paid) private {
        batchLeverage = x;
        for (uint256 i; i < 3; ++i) {
            for (uint256 side; side < 2; ++side) {
                string memory name = string.concat(vm.toString(x), "x winner ", vm.toString(i * 2 + side));
                Bet memory b = _example(users.alice, name, x, Side(side));
                uint48 end = _open(b).endTime;
                vm.warp(end);
                Ending[] memory e = _expectSettled(_favour(Side(side), moves[i]), end, _ids(b.id));
                assertEq(e[0].s.g, g[i], "g");
                assertEq(e[0].s.toUser, paid[i], "paid");
            }
        }
    }

    /// @dev At `x`: a flat expiry returns the stake with no fee; a loser at -2 bp, long and short, pays `gLoss` and
    ///      `paidLoss` with `feeLoss`; one unit inside the line settles at `gInside`, the line and beyond are
    ///      `LiquidateInstead`.
    function _expectFlatLosersAndInside(
        uint16 x,
        uint16 gLoss,
        uint64 paidLoss,
        uint64 feeLoss,
        uint16 gInside
    )
        private
    {
        batchLeverage = x;
        string memory prefix = string.concat(vm.toString(x), "x ");
        Bet memory flat = _example(users.alice, string.concat(prefix, "flat"), x, Side.Call);
        uint48 end = _open(flat).endTime;
        vm.warp(end);
        Ending[] memory e = _expectSettled(P0, end, _ids(flat.id));
        assertEq(e[0].s.toUser, 10e6, "the stake back");
        assertEq(e[0].s.winnerFee + e[0].s.loserFee, 0, "no fee");

        for (uint256 side; side < 2; ++side) {
            Bet memory loser = _example(users.alice, string.concat(prefix, "loser ", vm.toString(side)), x, Side(side));
            end = _open(loser).endTime;
            vm.warp(end);
            e = _expectSettled(_favour(Side(side), -2), end, _ids(loser.id));
            assertEq(e[0].s.g, gLoss, "g at -2 bp");
            assertEq(e[0].s.toUser, paidLoss, "paid");
            assertEq(e[0].s.loserFee, feeLoss, "3% of the loss");
        }

        for (uint256 side; side < 2; ++side) {
            Bet memory b = _example(users.alice, string.concat(prefix, "inside ", vm.toString(side)), x, Side(side));
            OpenedData memory d = _open(b);
            vm.warp(d.endTime);
            bool isCall = Side(side) == Side.Call;
            bytes memory instead = abi.encodeWithSelector(Errors.LiquidateInstead.selector, b.id);
            _expectSettleReverts(d.liqPrice, d.endTime, _ids(b.id), instead);
            _expectSettleReverts(isCall ? d.liqPrice - 1 : d.liqPrice + 1, d.endTime, _ids(b.id), instead);
            e = _expectSettled(isCall ? d.liqPrice + 1 : d.liqPrice - 1, d.endTime, _ids(b.id));
            assertEq(e[0].s.g, gInside, "g one unit inside the line");
        }
    }

    /// @dev Opens an example bet at `x` on `c.side` and sells it at once at `c.move` bp in its favour, checking the
    ///      sale against `c`. The user's minimum is the sale price.
    function _expectSaleCase(uint16 x, SaleCase memory c) private {
        string memory name =
            string.concat(vm.toString(x), "x sale ", vm.toString(c.move), " ", vm.toString(uint8(c.side)));
        Bet memory b = _example(users.alice, name, x, c.side);
        _open(b);
        Ending memory e = _expectSale(b.id, _favour(c.side, c.move), c.valuation, c.sellAmount, c.sellAmount);
        assertEq(e.sale.gNow, c.g, "g");
        assertEq(e.sale.toUser, c.toUser, "to the user");
        assertEq(e.sale.sellFee, c.sellFee, "the sell fee");
        assertEq(e.sale.winnerFee, c.winnerFee, "the winner fee");
        assertEq(e.sale.loserFee, c.loserFee, "the loser fee");
    }

    /// @dev At `x`, long and short at +4 bp: a valuation one unit above `payout` is refused, and at `payout` the bet
    ///      sells, at g = `g`.
    function _expectPayoutBound(uint16 x, uint64 payout, uint16 g) private {
        for (uint256 side; side < 2; ++side) {
            Bet memory b =
                _example(users.alice, string.concat(vm.toString(x), "x bound ", vm.toString(side)), x, Side(side));
            _open(b);
            int64 price = _favour(Side(side), 4);
            _expectSellReverts(
                _sellOrder(b.id, payout),
                _sellTerms(price, payout + 1, payout),
                abi.encodeWithSelector(Errors.ValuationAboveCurrentPayout.selector)
            );
            assertEq(_expectSale(b.id, price, payout, payout, payout).sale.gNow, g, "g at the bet's own leverage");
        }
    }

    /// @dev The smallest exposure limit, in bps of free money, under which `b` opens now:
    ///      ⌈exposure × 10,000 / free⌉, with the pool's open bets counted (`limit`) and on its own (`alone`).
    function _limitFor(Bet memory b) private view returns (uint32 limit, uint32 alone) {
        PoolState memory pool = flashOption.getPool();
        uint256 free = pool.total - pool.lockedMargin;
        uint256 mine = uint256(b.stake) * (b.capBps - 10_000) / 10_000;
        limit = uint32(((pool.openMaxProfit + mine) * 10_000 + free - 1) / free);
        alone = uint32((mine * 10_000 + free - 1) / free);
    }

    /// @dev On the empty pool, settles a 500x, a 100x and a 1000x 5-second winner at +10 bp (1.5x, 1.1x and 2x), in
    ///      that order: with no free money each gets its stake back and is owed its whole profit, $5, $1 and $10,
    ///      queued in settle order and keeping its leverage. Returns their ids.
    function _queueThreeIous() private returns (bytes32[3] memory ids) {
        Bet[3] memory bets = [
            _example(users.alice, "iou at 500x", L500, Side.Call),
            _example(users.alice, "iou at 100x", L100, Side.Call),
            _baseBet(users.alice, "iou at 1000x", L1000, Side.Call)
        ];
        uint64[3] memory owed = [uint64(5e6), 1e6, 10e6];
        uint64 firstSeq = flashOption.getPool().nextQueueSeq;
        uint48 end;
        for (uint256 i; i < 3; ++i) {
            bets[i].durationSecs = 5;
            end = _open(bets[i]).endTime;
            ids[i] = bets[i].id;
        }
        vm.warp(end);
        for (uint256 i; i < 3; ++i) {
            batchLeverage = bets[i].leverage;
            Ending[] memory e = _expectSettled(_up(10), end, _ids(ids[i]));
            assertEq(e[0].s.paid, 0, "no profit paid now");
            assertEq(e[0].s.toUser, 10e6, "the stake back, nothing more");
            assertEq(e[0].s.owed, owed[i], "the whole profit owed");
            assertEq(e[0].queueSeq, firstSeq + i, "queued in settle order");
            (Position memory p,,) = flashOption.getPosition(ids[i]);
            assertEq(p.leverage, bets[i].leverage, "the IOU keeps its leverage");
        }
    }

    /// @dev Opens 3-minute bets at 1000x, 500x and 100x (θ 5 bp fits each one's 3-minute range), so they can still be
    ///      sold once the queue is empty. Returns their ids.
    function _openWaitingBets() private returns (bytes32[3] memory ids) {
        Bet[3] memory bets = [
            _baseBet(users.alice, "waiting at 1000x", L1000, Side.Call),
            _example(users.alice, "waiting at 500x", L500, Side.Call),
            _example(users.alice, "waiting at 100x", L100, Side.Call)
        ];
        for (uint256 i; i < 3; ++i) {
            (bets[i].durationSecs, bets[i].thetaE7) = (180, 5000);
            _open(bets[i]);
            ids[i] = bets[i].id;
        }
    }
}
