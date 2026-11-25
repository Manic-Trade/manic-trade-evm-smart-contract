// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../src/interfaces/IManicFlashOptionEvents.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Market, Position, Side} from "../../src/types/StorageTypes.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {FlashOption_Scenario_Shared_Test} from "./FlashOptionShared.sol";

/// @title FlashOption_Scenario_Test
/// @notice Markets at several leverages, end to end, with every expected number to the base unit: BTC at 500x and
///         100x beside 1000x on one pool; the checks that depend on the leverage, at create and update; a 500x and a
///         100x bet's lines, sales and settlements; each bet keeping its leverage.
/// @dev Every ending runs through the settlement checkers, whose model values a bet at its own leverage and checks the
///      books, the slots, the logs and the balances. The tests rely on these rules:
///      - a market is a feed at one leverage (ADR 0008), and every market shares the contract's one pool;
///      - a sale names no market, so the bet's own applies (ARCHITECTURE §8.3): no sale goes through another
///        leverage's market;
///      - `getPosition` and the position events carry each bet's leverage;
///      - a bet ends when the clock is moved to its expiry, not by waiting.
contract FlashOption_Scenario_Test is FlashOption_Scenario_Shared_Test {
    /// @dev The 1000x market and the pool as they were before `setUp` created the 500x and 100x markets, ABI-encoded
    ///      (the legacy pipeline can't copy a `Market` into storage).
    bytes internal x1000Before;
    bytes internal poolBefore;

    function setUp() public override {
        super.setUp();
        x1000Before = abi.encode(flashOption.getMarket(Defaults.BTC, L1000));
        poolBefore = abi.encode(flashOption.getPool());
        // Every test runs with BTC at 500x and 100x: they are made here, with both events and every field checked,
        // and the first test checks the result.
        _createMarket(L500, _options(L500));
        _createMarket(L100, _options(L100));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The markets
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Creates BTC at 500x and 100x next to 1000x: each market under its own key, all on one pool.
    function test_CreatesBtc500xAnd100xNextTo1000x() external view {
        assertEq(flashOption.marketCount(), 3, "BTC at 1000x, 500x and 100x");
        uint16[3] memory leverages = [L1000, L500, L100];
        for (uint16 i; i < 3; ++i) {
            (bytes32 feed, uint16 marketLeverage) = flashOption.marketIdAt(i);
            assertEq(feed, Defaults.BTC, "BTC");
            assertEq(marketLeverage, leverages[i], "at its leverage");
            assertEq(
                LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.BTC, leverages[i]), i + 1, "its own key"
            );
            assertEq(flashOption.getMarket(Defaults.BTC, leverages[i]).leverage, leverages[i], "its stored leverage");
        }
        // One contract, one pool: creating markets didn't touch it, and the 1000x market is as it was.
        assertEq(abi.encode(flashOption.getPool()), poolBefore, "the pool");
        assertEq(abi.encode(flashOption.getMarket(Defaults.BTC, L1000)), x1000Before, "the 1000x market");
    }

    /// @dev Rejects a leverage outside 1x to 10,000x, a line at 1/leverage and a cap a short can't reach.
    function test_RejectsALeverageOutsideTheRangeALineAtOneOverLeverageAndACapAShortCantReach() external {
        // The launch config with the open gate at 100% (`Defaults.marketConfig`): `validate` refuses the gate off
        // (ADR 0009), and each config must be wrong only in the bound under test.
        ConfigParams memory launch = Defaults.marketConfig();
        // A 250x line at 1/250: θ = 40 bp, and 40 bp × 250 = 100%.
        ConfigParams memory line250 = Defaults.marketConfig();
        line250.durations[0].thetaMaxE7 = 40_000;
        // A 3x cap at 2x: a short's price falls at most 100%, which pays at most 1x + 2 × 100% = 3x, and the cap must
        // stay below that.
        ConfigParams memory cap2 = Defaults.marketConfig();
        cap2.capMaxBps = 30_000;
        _expectCreateRejected(0, launch);
        _expectCreateRejected(10_001, launch);
        _expectCreateRejected(250, line250);
        _expectCreateRejected(2, cap2);

        // One unit inside each limit, the same configs are valid (created switched off).
        line250.durations[0].thetaMaxE7 = 39_999;
        cap2.capMaxBps = 29_999;
        vm.startPrank(users.admin);
        flashOption.createMarket(Defaults.BTC, 250, Defaults.PRICE_EXPONENT, line250);
        flashOption.createMarket(Defaults.BTC, 2, Defaults.PRICE_EXPONENT, cap2);
        vm.stopPrank();
        assertEq(flashOption.getMarket(Defaults.BTC, 250).durations[0].thetaMaxE7, 39_999, "250x: a 39.999 bp line");
        assertEq(flashOption.getMarket(Defaults.BTC, 2).capMaxBps, 29_999, "2x: a 2.9999x cap");
        assertFalse(flashOption.getMarket(Defaults.BTC, 250).enabled, "created switched off");
    }

    /// @dev A market cannot be created twice for the same leverage.
    function test_CannotBeCreatedTwiceForTheSameLeverage() external {
        Market memory before500 = flashOption.getMarket(Defaults.BTC, L500);
        vm.expectRevert(Errors.MarketExists.selector);
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, L500, Defaults.PRICE_EXPONENT, _options(L500));
        assertEq(abi.encode(flashOption.getMarket(Defaults.BTC, L500)), abi.encode(before500), "the 500x market");
        assertEq(flashOption.marketCount(), 3, "still three markets");
    }

    /// @dev Checks each update against the market's own leverage, which never changes.
    function test_ChecksEachUpdateAgainstTheMarketsOwnLeverage() external {
        // The widest line each leverage allows: the largest θ with θ × L < 1e7.
        uint16[3] memory leverages = [L1000, L500, L100];
        uint32[3] memory widest = [uint32(9999), 19_999, 99_999];
        for (uint256 i; i < 3; ++i) {
            assertEq(_widestLine(leverages[i]), widest[i], "the widest line");
            ConfigParams memory c = _configOf(leverages[i]);
            c.durations[0].thetaMaxE7 = widest[i] + 1;
            _expectUpdateRejected(leverages[i], c);
            c.durations[0].thetaMaxE7 = widest[i];
            _setConfig(leverages[i], c);
            _setConfig(leverages[i], _configOf(leverages[i]));
        }
        // The widest 500x tier line (11.76 bp) fits 500x but not 1000x.
        ConfigParams memory x1000 = _configOf(L1000);
        x1000.durations[0].thetaMaxE7 = 11_760;
        _expectUpdateRejected(L1000, x1000);
        // A short must still reach the highest cap after an update: at 2x, under 3x.
        ConfigParams memory cap2 = Defaults.marketConfig();
        cap2.capMaxBps = 29_999;
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, 2, Defaults.PRICE_EXPONENT, cap2);
        cap2.capMaxBps = 30_000;
        _expectUpdateRejected(2, cap2);
        // The settings carry no leverage, so no update can change it: each market keeps its own.
        for (uint256 i; i < 3; ++i) {
            assertEq(flashOption.getMarket(Defaults.BTC, leverages[i]).leverage, leverages[i], "its leverage");
        }
    }

    /// @dev Update and pause change one leverage only. A sale names no market, so the 1000x bet sells through its own.
    function test_UpdateAndPauseChangeOneLeverageOnly() external {
        Market memory x1000 = flashOption.getMarket(Defaults.BTC, L1000);
        Market memory x100 = flashOption.getMarket(Defaults.BTC, L100);

        // A new maximum stake at 500x leaves the others as they were.
        ConfigParams memory c = _configOf(L500);
        c.maxStake = 40e6;
        _setConfig(L500, c);
        _assertUnchanged(x1000, x100);
        _setConfig(L500, _configOf(L500));

        // Paused at 500x: its opens stop, 1000x keeps opening.
        vm.expectEmit(address(flashOption));
        emit Events.PauseChanged(Defaults.BTC, L500, users.guardian, true);
        vm.prank(users.guardian);
        flashOption.setPaused(Defaults.BTC, L500, true);
        _assertUnchanged(x1000, x100);
        Bet memory at500 = _baseBet(users.alice, "alice at 500x", L500, Side.Call);
        (at500.floorBps, at500.capBps) = (12_000, 25_000);
        _expectOpenRejected(at500, Errors.LeveragePaused.selector);
        Bet memory at1000 = _baseBet(users.alice, "alice at 1000x", L1000, Side.Call);
        _open(at1000);
        vm.expectEmit(address(flashOption));
        emit Events.PauseChanged(Defaults.BTC, L500, users.operator, false);
        vm.prank(users.operator);
        flashOption.setPaused(Defaults.BTC, L500, false);
        _assertUnchanged(x1000, x100);

        // The 1000x bet sells through its own market: flat, valued at its $10 stake, sold for $9.50.
        Ending memory e = _expectSale(at1000.id, P0, 10e6, 9_500_000, 9_500_000);
        assertEq(e.sale.gNow, 10_000, "flat: 1x");
        assertEq(e.sale.toUser, 9_500_000, "$9.50 to the user");
        assertEq(e.sale.sellFee, 500_000, "the sell fee");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // A 500x and a 100x bet
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A 500x bet: the lines at 500x, and the sale bounded and paid at 500x.
    function test_A500xBetTheLinesAndTheSaleAt500x() external {
        // The widest 500x tier line and the tier's highest cap.
        Bet memory b = _baseBet(users.alice, "alice at 500x", L500, Side.Call);
        (b.thetaE7, b.floorBps, b.capBps) = (11_760, 12_500, 25_000);
        OpenedData memory d = _open(b);
        assertEq(d.liqPrice, 8_378_535_241_600, "liq: 11.76 bp below entry");
        assertEq(d.capPrice, 8_413_565_200_000, "cap: 2.5x is a 0.3% move at 500x");

        // At +8 bp a 500x bet pays 1.4x (5% of the stake per bp). 1000x would pay 1.8x, so a valuation above 1.4x
        // would pass only at 1000x.
        _expectSellReverts(
            _sellOrder(b.id, 14_000_001),
            _sellTerms(_up(8), 14_000_001, 14_000_001),
            abi.encodeWithSelector(Errors.ValuationAboveCurrentPayout.selector)
        );
        Ending memory e = _expectSale(b.id, _up(8), 14e6, 13_500_000, 13_500_000);
        assertEq(e.sale.gNow, 14_000, "1.4x");
        // The profit is $3.50; the trader gets $13.50 minus the 2% winner fee.
        assertEq(e.sale.toUser, 13_430_000, "to the user");
        assertEq(e.sale.sellFee, 500_000, "the sell fee");
        assertEq(e.sale.winnerFee, 70_000, "2% of the $3.50 profit");
    }

    /// @dev A 500x bet settles at 500x; another leverage's market can neither liquidate nor settle it.
    function test_A500xBetSettlesAt500xAndOnlyInItsOwnMarketsBatches() external {
        Bet memory b = _baseBet(users.alice, "alice at 500x", L500, Side.Call);
        (b.durationSecs, b.thetaE7, b.floorBps, b.capBps) = (5, 3000, 10_250, 15_000);
        OpenedData memory d = _open(b);
        bytes memory mismatch = abi.encodeWithSelector(Errors.ConfigMismatch.selector, b.id);

        // A tick on its line, in the 1000x market's batch.
        _expectLiquidateReverts(d.liqPrice, uint48(block.timestamp), _ids(b.id), mismatch);

        // At expiry, +6 bp pays 1.3x at 500x (1.6x at 1000x).
        vm.warp(d.endTime);
        _expectSettleReverts(_up(6), d.endTime, _ids(b.id), mismatch);
        batchLeverage = L500;
        Ending[] memory endings = _expectSettled(_up(6), d.endTime, _ids(b.id));
        assertEq(endings[0].s.g, 13_000, "1.3x");
        assertEq(endings[0].s.payout, 13e6, "$13");
    }

    /// @dev A 100x bet: the lines, the sale and the settlement at 100x.
    function test_A100xBetTheLinesTheSaleAndTheSettlementAt100x() external {
        // The widest 100x tier line (5 minutes) and the tier's highest cap.
        Bet memory b = _baseBet(users.alice, "alice at 100x", L100, Side.Call);
        (b.durationSecs, b.thetaE7, b.floorBps, b.capBps) = (300, 17_640, 10_500, 20_000);
        OpenedData memory d = _open(b);
        assertEq(d.liqPrice, 8_373_602_862_400, "liq: 17.64 bp below entry");
        assertEq(d.capPrice, 8_472_284_000_000, "cap: 2x is a 1% move at 100x");

        // At +8 bp a 100x bet pays 1.08x (1% per bp), above its 1.05x floor.
        _expectSellReverts(
            _sellOrder(b.id, 10_800_001),
            _sellTerms(_up(8), 10_800_001, 10_800_001),
            abi.encodeWithSelector(Errors.ValuationAboveCurrentPayout.selector)
        );
        assertEq(_expectSale(b.id, _up(8), 10_800_000, 10_700_000, 10_700_000).sale.gNow, 10_800, "1.08x");

        // A 5-second short: at -6 bp it pays 1.06x at 100x.
        Bet memory q = _baseBet(users.alice, "alice's 100x short", L100, Side.Put);
        (q.durationSecs, q.thetaE7, q.floorBps, q.capBps) = (5, 3000, 10_050, 15_000);
        OpenedData memory s = _open(q);
        assertGt(s.liqPrice, P0, "a short's line above the entry");
        assertLt(s.capPrice, P0, "its cap line below");
        vm.warp(s.endTime);
        batchLeverage = L500;
        _expectSettleReverts(
            _down(6), s.endTime, _ids(q.id), abi.encodeWithSelector(Errors.ConfigMismatch.selector, q.id)
        );
        batchLeverage = L100;
        Ending[] memory endings = _expectSettled(_down(6), s.endTime, _ids(q.id));
        assertEq(endings[0].s.g, 10_600, "1.06x");
        assertEq(endings[0].s.payout, 10_600_000, "$10.60");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Each bet records its leverage
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Each bet records its leverage, which `PositionOpened` and `getPosition` return, and each leverage
    ///      liquidates in its own batch.
    function test_EachBetRecordsItsLeverageAndEachLeverageLiquidatesInItsOwnBatch() external {
        // The same θ at the three leverages, each with a floor and cap inside its market's ranges. θ is a price
        // distance, so the three liquidation lines are one price. The cap line moves (cap - 1x) / leverage: a 4x cap
        // at 1000x and a 2.5x cap at 500x are both 0.3% above entry, a 2x cap at 100x is 1% above.
        Bet[3] memory bets = [
            _baseBet(users.alice, "alice at 1000x", L1000, Side.Call),
            _baseBet(users.alice, "alice at 500x", L500, Side.Call),
            _baseBet(users.alice, "alice at 100x", L100, Side.Call)
        ];
        (bets[1].floorBps, bets[1].capBps) = (12_000, 25_000);
        (bets[2].floorBps, bets[2].capBps) = (10_500, 20_000);
        int64[3] memory capLines = [int64(8_413_565_200_000), 8_413_565_200_000, 8_472_284_000_000];
        int64 line;
        for (uint256 i; i < 3; ++i) {
            OpenedData memory d = _open(bets[i]);
            assertEq(d.leverage, bets[i].leverage, "PositionOpened carries its leverage");
            (Position memory p,,) = flashOption.getPosition(bets[i].id);
            assertEq(p.leverage, bets[i].leverage, "getPosition returns it");
            if (i == 0) line = d.liqPrice;
            assertEq(d.liqPrice, line, "one liquidation line");
            assertEq(d.capPrice, capLines[i], "cap lines: +0.3%, +0.3%, +1%");
        }

        // One tick touches all three lines, but a batch holds one market, so it can't mix leverages.
        uint48 now48 = uint48(block.timestamp);
        _expectLiquidateReverts(
            line,
            now48,
            _ids(bets[0].id, bets[1].id),
            abi.encodeWithSelector(Errors.ConfigMismatch.selector, bets[1].id)
        );
        // One batch per market; each PositionLiquidated carries its bet's leverage (the checkers' logs).
        for (uint256 i; i < 3; ++i) {
            batchLeverage = bets[i].leverage;
            _expectLiquidated(line, now48, _ids(bets[i].id));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The settings `setUp` gave BTC at `marketLeverage`, switched on.
    function _configOf(uint16 marketLeverage) private pure returns (ConfigParams memory c) {
        c = marketLeverage == L1000 ? Defaults.marketConfig() : _options(marketLeverage);
        c.enabled = true;
    }

    /// @dev Expects the admin's creation of BTC at `marketLeverage` with `p` to revert `InvalidLeverageParams`, leaving
    ///      no market. A gate-off `p` is sent with the gate at 100%, so the refusal comes from the bound under test and
    ///      not from the bounded open gate (ADR 0009).
    function _expectCreateRejected(uint16 marketLeverage, ConfigParams memory p) private {
        uint16 count = flashOption.marketCount();
        uint32 exposure = p.maxExposureBps;
        if (exposure == 0) p.maxExposureBps = 10_000;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, marketLeverage, Defaults.PRICE_EXPONENT, p);
        p.maxExposureBps = exposure;
        assertEq(LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.BTC, marketLeverage), 0, "no market");
        assertEq(flashOption.marketCount(), count, "none created");
    }

    /// @dev Expects the operator's update of BTC at `marketLeverage` to `p` to revert `InvalidLeverageParams`, leaving
    ///      the market as it was. A gate-off `p` is sent with the gate at 100%, so the refusal comes from the bound
    ///      under test and not from the bounded open gate (ADR 0009).
    function _expectUpdateRejected(uint16 marketLeverage, ConfigParams memory p) private {
        Market memory before = flashOption.getMarket(Defaults.BTC, marketLeverage);
        uint32 exposure = p.maxExposureBps;
        if (exposure == 0) p.maxExposureBps = 10_000;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, marketLeverage, p);
        p.maxExposureBps = exposure;
        assertEq(abi.encode(flashOption.getMarket(Defaults.BTC, marketLeverage)), abi.encode(before), "unchanged");
    }

    /// @dev The 1000x and 100x markets are as they were.
    function _assertUnchanged(Market memory x1000, Market memory x100) private view {
        assertEq(abi.encode(flashOption.getMarket(Defaults.BTC, L1000)), abi.encode(x1000), "the 1000x market");
        assertEq(abi.encode(flashOption.getMarket(Defaults.BTC, L100)), abi.encode(x100), "the 100x market");
    }
}
