// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {DurationRule, PoolState, Position, Side, Status} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title Settlement_Fuzz_Test
/// @notice `liquidate` and `settle`, for random bets and random prices, on a market at any leverage
///         (docs/ARCHITECTURE.md §8.4, §8.5):
///         - DOS-1: a stored open position always ends at its expiry second, at any positive price: exactly one of
///           `settle` and `liquidate` takes it, and the other refuses it with its own error;
///         - a random batch, split at one tick into the positions it liquidates and those it settles, matches the
///           checkers' model in every field, whatever the free money, the floor and the queue, with any one user
///           possibly frozen; and afterwards the contract holds exactly its books, every bet having ended;
///         - a batch holds one market's bets: one that also holds a bet of another market, open or already ended,
///           before or after its own, is refused (`ConfigMismatch` naming that bet). Its own bet then ends in a batch
///           of its own market.
/// @dev The terms are bounded with `bound` inside the market's rules, never `vm.assume`, as in Open_Fuzz_Test. Each
///      case's market is BTC at the case's leverage (`_leverageFor`), with the launch config fitted to it
///      (`LeverageConfigs.launchAt`), and a batch's tick is within 4 / L of the entry (`_priceNear`), which spans
///      every line and every cap. The checkers (`_expectLiquidated`, `_expectSettled`) compare the contract with an
///      independent model, which values each bet at its own leverage, so this is also a differential test of
///      `LeverageMath`'s ending maths against `Calculations`. CI runs 10,000 cases per property.
contract Settlement_Fuzz_Test is Settlement_Base_Test {
    /// @dev The random terms of one bet, and the seed of its market's leverage.
    struct Terms {
        uint64 stake;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
        bool isPut;
        int64 entryPrice;
        uint16 leverageSeed;
    }

    function testFuzz_AStoredOpenPositionAlwaysEnds(uint8 ruleIndex, Terms memory r, int64 price) external {
        DurationRule memory rule = _useMarketFor(r.leverageSeed, 10_000).durations[ruleIndex % 5];
        Position memory p = _openRandom(users.alice, "the bet", rule, r);
        uint48 end = _end(p);
        vm.warp(end);
        price = int64(bound(price, 1, type(int64).max));

        bool touched = p.side == Side.Call ? price <= p.liqPrice : price >= p.liqPrice;
        if (touched) {
            _expectSettleReverts(
                price,
                end,
                _ids("the bet"),
                abi.encodeWithSelector(Errors.LiquidateInstead.selector, bytes32("the bet"))
            );
            _expectLiquidated(price, end, _ids("the bet"));
        } else {
            _expectLiquidateReverts(
                price,
                end,
                _ids("the bet"),
                abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, bytes32("the bet"))
            );
            _expectSettled(price, end, _ids("the bet"));
        }
        assertEq(LayoutReader.pool(address(flashOption)).openPositions, 0, "it ended");
    }

    function testFuzz_ARandomBatchMatchesTheModel(
        uint64 free,
        uint64 poolFloor,
        uint8 count,
        uint8 ruleIndex,
        uint256 seed,
        int64 price,
        uint8 frozen
    )
        external
    {
        // A pool of any size, with the exposure gate off so winners can be owed, and any floor.
        _useSmallPool(uint64(bound(free, 1, 3000e6)));
        vm.prank(users.admin);
        flashOption.setPoolFloor(uint64(bound(poolFloor, Defaults.POOL_FLOOR, 5000e6)));

        // 1 to 8 bets of one duration on BTC at any leverage (gate off), from alice, bob and eve, opened at one tick.
        DurationRule memory rule = _useMarketFor(seed, 0).durations[ruleIndex % 5];
        count = uint8(bound(count, 1, 8));
        bytes32[] memory ids = new bytes32[](count);
        Position memory p;
        for (uint256 i; i < count; ++i) {
            ids[i] = keccak256(abi.encode(seed, i));
            p = _openRandom(_bettor(uint256(ids[i])), ids[i], rule, _randomTerms(ids[i]));
        }
        uint48 end = _end(p);
        vm.warp(end);

        // Any one of them may be frozen by the time the batch runs.
        if (frozen % 4 < 3) {
            vm.prank(usdgAdmin);
            usdg.freeze(_bettor(frozen));
        }

        // A tick within 4 / L of the entry (0.4% at 1000x), which spans every line and every cap: it liquidates the
        // bets whose line it touches and settles the rest.
        price = _priceNear(p.entryPrice, batchLeverage, price);
        (bytes32[] memory touched, bytes32[] memory untouched) = _split(ids, price);
        if (touched.length > 0) _expectLiquidated(price, end, touched);
        if (untouched.length > 0) _expectSettled(price, end, untouched);

        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.openPositions, 0, "every bet ended");
        assertEq(pool.lockedMargin, 0, "no stake held");
        assertEq(pool.openMaxProfit, 0, "no exposure left");
        assertEq(
            usdg.balanceOf(address(flashOption)),
            uint256(pool.total) + pool.feesPending + pool.totalClaimable,
            "the contract holds exactly its books"
        );
    }

    function testFuzz_ABatchHoldingAnotherMarketsBetIsRefused(uint256 seed, uint8 how) external {
        // BTC at two leverages, each with a one-minute bet opened now: theirs, and ours, on the batch's market.
        uint16 ourLeverage = _leverageFor(seed);
        uint16 theirLeverage = _leverageFor(uint256(keccak256(abi.encode(seed, "theirs"))));
        if (theirLeverage == ourLeverage) theirLeverage = ourLeverage == 10_000 ? 1 : ourLeverage + 1;
        DurationRule memory rule = _useMarketAt(theirLeverage, 10_000).durations[0];
        Position memory theirs = _openRandom(users.bob, "theirs", rule, _randomTerms("theirs"));
        rule = _useMarketAt(ourLeverage, 10_000).durations[0];
        Position memory ours = _openRandom(users.alice, "ours", rule, _randomTerms("ours"));

        // Theirs is still open, or has ended in a batch of its own market: liquidated on its line, or settled.
        uint48 end = _end(ours);
        batchLeverage = theirLeverage;
        if (how % 3 == 1) _liquidate(theirs.liqPrice, uint48(block.timestamp), _ids("theirs"));
        vm.warp(end);
        if (how % 3 == 2) _settle(theirs.entryPrice, end, _ids("theirs"));
        batchLeverage = ourLeverage;

        // A batch of our market that holds theirs, before or after ours, is refused, whether it settles or liquidates,
        // and ours then ends in a batch of its own market.
        bytes32[] memory ids = (how / 3) % 2 == 0 ? _ids("ours", "theirs") : _ids("theirs", "ours");
        bytes memory refusal = abi.encodeWithSelector(Errors.ConfigMismatch.selector, bytes32("theirs"));
        if ((how / 6) % 2 == 0) {
            _expectSettleReverts(ours.entryPrice, end, ids, refusal);
            _assertStillOpen("ours");
            _expectSettled(ours.entryPrice, end, _ids("ours"));
        } else {
            _expectLiquidateReverts(ours.liqPrice, end, ids, refusal);
            _assertStillOpen("ours");
            _expectLiquidated(ours.liqPrice, end, _ids("ours"));
        }
    }

    /// @dev Switches on BTC's market at the leverage `leverageSeed` picks (`_leverageFor`): see `_useMarketAt`.
    function _useMarketFor(uint256 leverageSeed, uint16 exposureBps) private returns (ConfigParams memory) {
        return _useMarketAt(_leverageFor(leverageSeed), exposureBps);
    }

    /// @dev Switches on BTC's market at `marketLeverage`, with the launch config fitted to it and the open gate at
    ///      `exposureBps`, and points the batch helpers and `_openRandom` at it. An `exposureBps` of 0 switches the
    ///      gate off, which `validate` refuses (ADR 0009): the market is set at 100%, then switched off in storage.
    /// @return c Its settings.
    function _useMarketAt(uint16 marketLeverage, uint16 exposureBps) private returns (ConfigParams memory c) {
        batchLeverage = marketLeverage;
        c = LeverageConfigs.launchAt(marketLeverage);
        if (exposureBps > 0) c.maxExposureBps = exposureBps;
        _useBtcAt(marketLeverage, c);
        if (exposureBps == 0) {
            _switchOffOpenGate(address(flashOption), Defaults.BTC, marketLeverage);
            c.maxExposureBps = 0;
        }
    }

    /// @dev The position `id` is still open.
    function _assertStillOpen(bytes32 id) private view {
        assertEq(uint8(LayoutReader.position(address(flashOption), id).status), uint8(Status.Open), "still open");
    }

    /// @dev Opens a bet for `user` with random terms bounded inside the rules of the market the batch helpers point at
    ///      (`batchLeverage`), for `rule`'s duration.
    function _openRandom(
        address user,
        bytes32 id,
        DurationRule memory rule,
        Terms memory r
    )
        private
        returns (Position memory)
    {
        ConfigParams memory c = LeverageConfigs.launchAt(batchLeverage);
        OpenOrder memory o = _order(user, id);
        o.leverage = batchLeverage;
        o.stake = uint64(bound(r.stake, c.minStake, c.maxStake));
        o.durationSecs = rule.durationSecs;
        o.side = r.isPut ? Side.Put : Side.Call;
        OpenTerms memory t = _terms();
        t.thetaE7 = uint32(bound(r.thetaE7, rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(bound(r.floorBps, c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(r.capBps, t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
        t.entryPrice = int64(bound(r.entryPrice, 1, type(int64).max / 2));
        return _betWith(o, t);
    }

    /// @dev Random terms from `id`, with the batch's entry price fixed at the base price so one tick reaches them all.
    function _randomTerms(bytes32 id) private pure returns (Terms memory r) {
        uint256 x = uint256(keccak256(abi.encode(id)));
        r.stake = uint64(x);
        r.thetaE7 = uint32(x >> 64);
        r.floorBps = uint16(x >> 96);
        r.capBps = uint16(x >> 112);
        r.isPut = (x >> 128) & 1 == 1;
        r.entryPrice = Defaults.ENTRY_PRICE;
    }

    /// @dev Alice, bob or eve, from `x`.
    function _bettor(uint256 x) private view returns (address) {
        uint256 who = x % 3;
        return who == 0 ? users.alice : who == 1 ? users.bob : users.eve;
    }

    /// @dev Splits `ids` into the positions whose line `price` touches and the rest, keeping their order.
    function _split(
        bytes32[] memory ids,
        int64 price
    )
        private
        view
        returns (bytes32[] memory touched, bytes32[] memory untouched)
    {
        touched = new bytes32[](ids.length);
        untouched = new bytes32[](ids.length);
        uint256 t;
        uint256 u;
        for (uint256 i; i < ids.length; ++i) {
            Position memory p = LayoutReader.position(address(flashOption), ids[i]);
            if (p.side == Side.Call ? price <= p.liqPrice : price >= p.liqPrice) touched[t++] = ids[i];
            else untouched[u++] = ids[i];
        }
        assembly ("memory-safe") {
            mstore(touched, t) // shrink the arrays to the ids kept
            mstore(untouched, u)
        }
    }
}
