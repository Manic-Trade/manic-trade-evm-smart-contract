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

/// @title Refund_Fuzz_Test
/// @notice The safety refund (docs/ARCHITECTURE.md §8.6) on random books: any mix of open and ended bets, of any
///         users, stakes, sides and lengths, on markets of any leverages (a refund names no market, so one batch may
///         hold bets of several), refunded in any order and with repeats, under any delay, at any time
///         around their refunds' first seconds, a bettor often frozen. When every open bet in the batch is due, the
///         batch matches the checkers' model in every field. Otherwise it reverts: `RefundDisabled` with the delay at
///         0, or `RefundTooEarly` naming the first open bet in the batch that isn't due yet. Either way, free money
///         never moves, and the contract still holds exactly its books.
/// @dev 1 to 8 bets, opened 0 to 20 seconds apart, each with a random duration rule (60 to 300 seconds), stake, side,
///      θ, floor and cap inside the rules of its market: BTC at a leverage of its own (`_leverageFor`), with the
///      launch config fitted to it (`LeverageConfigs.launchAt`). About a third are settled flat at their expiry
///      first, each in a batch of its own market, so they have ended; a flat settle pays back the stake whatever the
///      floor and cap. The delay is 0 one time in eight, otherwise 1 hour to 7 days. Inputs are bounded with `bound`,
///      never `vm.assume`. CI runs 10,000 cases.
contract Refund_Fuzz_Test is Settlement_Base_Test {
    function testFuzz_RefundMatchesTheModel(
        uint256 salt,
        uint8 count,
        uint48 delay,
        uint256 when,
        uint8 frozen,
        uint8 batchSize
    )
        external
    {
        (bytes32[] memory ids, uint48 firstEnd, uint48 lastEnd) = _openBets(salt, bound(count, 1, 8));
        // Once the bets are open (USDG refuses a frozen bettor's stake), a bettor is frozen three times in four.
        if (frozen % 4 < 3) {
            vm.prank(usdgAdmin);
            usdg.freeze(_bettor(frozen));
        }
        vm.warp(lastEnd);
        _settleAThird(ids);

        delay = delay % 8 == 0 ? 0 : uint48(bound(delay, 1 hours, 7 days));
        vm.prank(users.admin);
        flashOption.setRefundDelay(delay);
        // From a minute before the first refund second to a minute after the last; with the refund off, any day.
        vm.warp(
            delay == 0
                ? bound(when, lastEnd, uint256(lastEnd) + 7 days)
                : bound(when, uint256(firstEnd) + delay - 60, uint256(lastEnd) + delay + 60)
        );

        bytes32[] memory batch = new bytes32[](bound(batchSize, 1, 12));
        for (uint256 i; i < batch.length; ++i) {
            batch[i] = ids[uint256(keccak256(abi.encode(salt, "batch", i))) % ids.length];
        }
        PoolState memory before = LayoutReader.pool(address(flashOption));
        bytes memory refusal = _expectedRefusal(batch, delay);
        if (refusal.length > 0) _expectRefundReverts(batch, refusal);
        else _expectRefunded(batch, users.eve);

        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.total - pool.lockedMargin, before.total - before.lockedMargin, "free money never moves");
        assertEq(
            usdg.balanceOf(address(flashOption)),
            uint256(pool.total) + pool.feesPending + pool.totalClaimable,
            "the contract holds exactly its books"
        );
    }

    /// @dev Opens `count` bets, each 0 to 20 seconds after the last, and returns their ids and their first and last
    ///      expiry.
    function _openBets(
        uint256 salt,
        uint256 count
    )
        private
        returns (bytes32[] memory ids, uint48 firstEnd, uint48 lastEnd)
    {
        ids = new bytes32[](count);
        firstEnd = type(uint48).max;
        for (uint256 i; i < count; ++i) {
            ids[i] = keccak256(abi.encode(salt, i));
            uint256 x = uint256(keccak256(abi.encode(ids[i])));
            vm.warp(block.timestamp + x % 21);
            uint48 end = _end(_openRandom(_bettor(x >> 8), ids[i], x));
            if (end < firstEnd) firstEnd = end;
            if (end > lastEnd) lastEnd = end;
        }
    }

    /// @dev Settles about a third of `ids` flat, each at its own expiry second, checked by `_expectSettled`.
    function _settleAThird(bytes32[] memory ids) private {
        for (uint256 i; i < ids.length; ++i) {
            if (uint256(keccak256(abi.encode(ids[i], "settled"))) % 3 > 0) continue;
            Position memory p = LayoutReader.position(address(flashOption), ids[i]);
            batchLeverage = p.leverage;
            _expectSettled(Defaults.ENTRY_PRICE, _end(p), _ids(ids[i]));
        }
    }

    /// @dev Opens a bet for `user` on BTC's market at a leverage `x` picks (switched on with the launch config fitted
    ///      to it, and created if it is new), with a random duration rule, stake, side, θ, floor and cap inside its
    ///      rules, from `x`.
    function _openRandom(address user, bytes32 id, uint256 x) private returns (Position memory) {
        uint16 marketLeverage = _leverageFor(x >> 128);
        ConfigParams memory c = LeverageConfigs.launchAt(marketLeverage);
        c.maxExposureBps = 10_000;
        _useBtcAt(marketLeverage, c);
        DurationRule memory rule = c.durations[(x >> 96) % 5];
        OpenOrder memory o = _order(user, id);
        o.leverage = marketLeverage;
        o.stake = uint64(bound(uint64(x), c.minStake, c.maxStake));
        o.durationSecs = rule.durationSecs;
        o.side = (x >> 104) % 2 == 0 ? Side.Call : Side.Put;
        OpenTerms memory t = _terms();
        t.thetaE7 = uint32(bound(uint32(x >> 112), rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(bound(uint16(x >> 64), c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(uint16(x >> 80), t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
        return _betWith(o, t);
    }

    /// @dev What `refundExpired(batch)` must revert with now, or nothing: `RefundDisabled` with the delay at 0,
    ///      otherwise `RefundTooEarly` naming the first open bet in the batch whose refund second hasn't come. A
    ///      repeat of a bet that is due is skipped, so only the first listing of each bet can refuse.
    function _expectedRefusal(bytes32[] memory batch, uint48 delay) private view returns (bytes memory) {
        if (delay == 0) return abi.encodeWithSelector(Errors.RefundDisabled.selector);
        for (uint256 i; i < batch.length; ++i) {
            Position memory p = LayoutReader.position(address(flashOption), batch[i]);
            if (p.status == Status.Open && block.timestamp < uint256(_end(p)) + delay) {
                return abi.encodeWithSelector(Errors.RefundTooEarly.selector, batch[i]);
            }
        }
        return "";
    }

    /// @dev Alice, bob or eve, from `x`.
    function _bettor(uint256 x) private view returns (address) {
        uint256 who = x % 3;
        return who == 0 ? users.alice : who == 1 ? users.bob : users.eve;
    }
}
