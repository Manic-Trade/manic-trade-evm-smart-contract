// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {FlashOptionBase} from "../base/FlashOptionBase.sol";
import {IManicFlashOptionSettlement} from "../interfaces/IManicFlashOptionSettlement.sol";
import {LeverageMath} from "../libraries/LeverageMath.sol";
import {RepaySplit, SettleSplit} from "../types/MathTypes.sol";
import {Market, PoolState, Position, Side, Status} from "../types/StorageTypes.sol";

/// @title SettlementModule
/// @author Manic
/// @notice How positions end at a price, how a position the backend never ended is refunded, and how the winners the
///         pool couldn't pay are paid later: `liquidate` when a tick touches their line, and `settle` at their expiry
///         second, each in batches the settler relayer sends (docs/ARCHITECTURE.md §8.4, §8.5); `refundExpired`,
///         which anyone calls to return the stake of a position still open long after its expiry (§8.6); and
///         `repay`, which anyone calls to pay the IOU queue from free money (§8.7).
/// @dev `liquidate` and `settle` run the batch checks (`_checkBatch`), then walk the ids in order. Each id is looked
///      up and checked against the batch's market (`_batchPosition`); an ended one is skipped. Each open one is ended
///      by `_liquidateOne` or `_settleOne`, which do the books for that position, so free money is measured in batch
///      order. The batch's fees are accrued once, after the loop, and its winnings and losses are
///      counted in the payout circuit breaker once (`_countForBreaker`, §8.11). Settle pays each user from inside the
///      loop through `_pay`, which never reverts on a refused transfer, so one frozen winner can't block a batch.
///      `refundExpired` takes ids of any market (`_knownPosition`), and `_refundOne` returns each open one's stake
///      the same way. `repay` walks the queue itself from its head, one IOU at a time (`_repayHead`), and stops at
///      the first it can only pay in part, and counts what it repaid in the breaker. A refund counts nothing. The
///      private functions are listed in solhint's order: state-changing, then view, then pure.
/// @custom:security-contact See SECURITY.md
abstract contract SettlementModule is IManicFlashOptionSettlement, FlashOptionBase {
    /// @dev One batch's tick, its market, and its running totals, kept in memory so the loops fit the legacy
    ///      pipeline's stack.
    struct Batch {
        uint16 index; // the market's index, which every position in the batch must record
        uint8 clockSkewSecs; // how far ahead of the chain's clock the tick may be
        int64 price; // the tick's price
        uint48 publishTime; // the tick's publish time
        uint64 fees; // the fees taken so far, accrued once after the loop
        uint64 profit; // the profit paid to users so far, before fees, counted in the breaker after the loop
        uint64 loss; // the users' losses kept so far, before fees, counted in the breaker after the loop
        uint256 processed; // the positions ended so far
    }

    /// @dev The fields of {PositionSettled}, in its order. The event is emitted from this struct because, emitted
    ///      inline, its 14 fields don't fit the legacy pipeline's stack (docs/CONVENTIONS.md §7).
    struct Settled {
        bytes32 positionId;
        address user;
        Side side;
        uint64 stake;
        int64 finalPrice;
        uint48 publishTime;
        uint16 gBps;
        uint64 payout;
        uint64 paidNow;
        uint64 owed;
        uint64 queueSeq;
        uint64 winnerFee;
        uint64 loserFee;
        uint16 leverage;
    }

    /// @notice The most ids one batch may hold. It bounds a batch's gas, measured with a different user per position:
    ///         about 5.6 million for 100 settles and 2.1 million for 100 liquidations, well inside a block.
    uint256 private constant _MAX_BATCH = 100;

    /// @notice The most IOUs one `repay` call may repay. The contract walks the queue itself, and this bounds a
    ///         call's gas.
    uint256 private constant _MAX_REPAY = 50;

    /// @inheritdoc IManicFlashOptionSettlement
    function liquidate(
        bytes32 marketId,
        uint16 leverage,
        int64 price,
        uint48 publishTime,
        bytes32[] calldata ids
    )
        external
        override
        nonReentrant
        onlyRole(SETTLER_ROLE)
        returns (uint256 processed)
    {
        Batch memory b = _checkBatch({
            marketId: marketId, leverage: leverage, price: price, publishTime: publishTime, count: ids.length
        });
        for (uint256 i; i < ids.length; ++i) {
            Position storage p = _batchPosition(ids[i], b.index);
            if (p.status != Status.Open) {
                emit PositionSkipped(ids[i], p.status);
                continue;
            }
            _liquidateOne(b, ids[i], p);
        }
        _accrueFees(b.fees);
        _countForBreaker(b.profit, b.loss);
        processed = b.processed;
    }

    /// @inheritdoc IManicFlashOptionSettlement
    function settle(
        bytes32 marketId,
        uint16 leverage,
        int64 price,
        uint48 publishTime,
        bytes32[] calldata ids
    )
        external
        override
        nonReentrant
        onlyRole(SETTLER_ROLE)
        returns (uint256 processed)
    {
        Batch memory b = _checkBatch({
            marketId: marketId, leverage: leverage, price: price, publishTime: publishTime, count: ids.length
        });
        // One tick for the whole batch: the close of one expiry second, which must have passed, give or take the
        // clock skew (`publishTime <= block.timestamp + clockSkewSecs`). Old ticks are accepted, so the backend can
        // settle after an outage.
        if (price <= 0) revert InvalidPrice();
        if (publishTime > block.timestamp + b.clockSkewSecs) revert NotExpired();
        for (uint256 i; i < ids.length; ++i) {
            Position storage p = _batchPosition(ids[i], b.index);
            if (p.status != Status.Open) {
                emit PositionSkipped(ids[i], p.status);
                continue;
            }
            _settleOne(b, ids[i], p);
        }
        _accrueFees(b.fees);
        _countForBreaker(b.profit, b.loss);
        processed = b.processed;
    }

    /// @inheritdoc IManicFlashOptionSettlement
    function refundExpired(bytes32[] calldata ids) external override nonReentrant returns (uint256 processed) {
        uint48 delay = _getFlashOptionStorage().refundDelaySecs;
        if (delay == 0) revert RefundDisabled();
        _checkBatchSize(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            Position storage p = _knownPosition(ids[i]);
            if (p.status != Status.Open) {
                emit PositionSkipped(ids[i], p.status);
                continue;
            }
            _refundOne(ids[i], p, delay);
            ++processed;
        }
    }

    /// @inheritdoc IManicFlashOptionSettlement
    function repay(uint256 maxCount) external override nonReentrant returns (uint256 repaid) {
        Layout storage $ = _getFlashOptionStorage();
        if ($.halted) revert Halted();
        if (maxCount == 0 || maxCount > _MAX_REPAY) revert InvalidMaxCount();
        PoolState storage pool = $.pool;
        uint64 fees = 0;
        uint64 profit = 0;
        while (repaid < maxCount && pool.nextRepaySeq < pool.nextQueueSeq) {
            RepaySplit memory split = _repayHead(pool);
            // No free money left: the rest of the queue waits for more losers' money.
            if (split.amount == 0) break;
            fees = _add64(fees, split.winnerFee);
            profit = _add64(profit, split.amount);
            ++repaid;
            // The first IOU free money covers only in part stays at the head: stop there.
            if (split.remaining > 0) break;
        }
        _accrueFees(fees);
        // A repayment is profit paid out late, so the breaker counts it now, before fees.
        _countForBreaker(profit, 0);
    }

    /// @notice Liquidates one open position at the batch's tick, and counts it and its fee in the batch.
    /// @dev The loser fee is measured against free money with the stake still held, so it is computed before the
    ///      margin is released. Emits {PositionLiquidated} after the position closes, from the stake and the line
    ///      read before slot 1 was cleared.
    /// @param b The batch.
    /// @param id The position's id.
    /// @param p The position's storage.
    function _liquidateOne(Batch memory b, bytes32 id, Position storage p) private {
        // can't overflow: startTime is an entry tick's time, within the clock skew of a past block's timestamp
        uint48 endTime = p.startTime + p.durationSecs;
        LeverageMath.checkLiquidation({
            positionId: id,
            startTime: p.startTime,
            endTime: endTime,
            liqPrice: p.liqPrice,
            side: p.side,
            price: b.price,
            publishTime: b.publishTime,
            currentTime: block.timestamp,
            clockSkewSecs: b.clockSkewSecs
        });

        uint64 stake = p.stake;
        int64 liqPrice = p.liqPrice;
        uint16 leverage = p.leverage;
        PoolState storage pool = _getFlashOptionStorage().pool;
        uint64 fee = LeverageMath.loserFee(stake, pool.total - pool.lockedMargin, pool.poolFloor);
        _releaseMargin(pool, stake, p.capBps);
        // can't underflow: the released stake is at least the fee, and it stays in the total
        pool.total -= fee;
        _closePosition(p);
        b.fees = _add64(b.fees, fee);
        b.loss = _add64(b.loss, stake); // the whole stake is lost
        ++b.processed;

        emit PositionLiquidated({
            positionId: id,
            user: p.user,
            side: p.side,
            stake: stake,
            liqPrice: liqPrice,
            price: b.price,
            publishTime: b.publishTime,
            endTime: endTime,
            loserFee: fee,
            leverage: leverage
        });
    }

    /// @notice Settles one open position at the batch's tick, pays its user, and counts it and its fees in the
    ///         batch.
    /// @dev The event's fields are gathered in one memory struct, so the function fits the legacy pipeline's stack.
    ///      Emits {PositionSettled} once the books are done and before the payout, whose transfer is the only external
    ///      call (checks, effects, then the interaction).
    /// @param b The batch.
    /// @param id The position's id.
    /// @param p The position's storage.
    function _settleOne(Batch memory b, bytes32 id, Position storage p) private {
        // It expires at exactly this tick's second. A tick on the line ends it as a liquidation instead.
        // can't overflow: startTime is an entry tick's time, within the clock skew of a past block's timestamp
        if (p.startTime + p.durationSecs != b.publishTime) revert InvalidPriceTimestamp(id);
        if (LeverageMath.touched(b.price, p.liqPrice, p.side)) revert LiquidateInstead(id);

        // A memory struct starts zeroed; every field is written below (audit/static-analysis.md).
        // slither-disable-next-line uninitialized-local
        Settled memory e;
        e.positionId = id;
        e.user = p.user;
        e.side = p.side;
        e.stake = p.stake;
        e.leverage = p.leverage;
        e.finalPrice = b.price;
        e.publishTime = b.publishTime;
        e.gBps = LeverageMath.gBps({
            entry: p.entryPrice,
            price: b.price,
            side: e.side,
            leverage: p.leverage, // the bet's own, copied from its market at open
            floorBps: p.floorBps,
            capBps: p.capBps
        });
        e.payout = LeverageMath.payout(e.stake, e.gBps);

        // Free money is measured before this position's stake is released, in batch order.
        PoolState storage pool = _getFlashOptionStorage().pool;
        SettleSplit memory split = LeverageMath.settleSplit({
            payoutAmount: e.payout,
            stake: e.stake,
            freeBefore: pool.total - pool.lockedMargin,
            totalOwed: pool.totalOwed,
            poolFloor: pool.poolFloor
        });
        _releaseMargin(pool, e.stake, p.capBps);
        // can't underflow: the user's own part is at most the stake, the profit paid at most the free money before,
        // and the loser fee at most the rest of the stake, all inside the total
        pool.total -= LeverageMath.outOfPool(split);
        e.paidNow = LeverageMath.toUser(split);
        pool.transferred = _add64(pool.transferred, e.paidNow);
        e.owed = split.owed;
        e.winnerFee = split.winnerFee;
        e.loserFee = split.loserFee;
        if (split.owed > 0) e.queueSeq = _queueIou(pool, p, id, split.owed);
        else _closePosition(p);
        b.fees = _add64(b.fees, _add64(split.winnerFee, split.loserFee));
        // The breaker counts the profit paid now and the loss, before fees. Profit owed counts when it is repaid.
        // can't underflow: the user's own part is at most the stake
        b.profit = _add64(b.profit, split.paid);
        b.loss = _add64(b.loss, e.stake - split.own);
        ++b.processed;

        _emitSettled(e);
        _pay(e.user, e.paidNow, id);
    }

    /// @notice Returns one open position's whole stake to its user, once the refund delay has passed since its
    ///         expiry: the safety refund (docs/ARCHITECTURE.md §8.6).
    /// @dev The expiry plus the delay is summed in 256 bits, so no delay can overflow it: one too long to reach just
    ///      means "not yet". The stake and the max profit are released and the stake leaves the total, so free money
    ///      doesn't change; no fee is taken. Emits {PositionRefunded} once the books are written and before the
    ///      payout, the only external call, as settle does.
    /// @param id The position's id.
    /// @param p The position's storage.
    /// @param delay The refund delay, in seconds; not 0.
    function _refundOne(bytes32 id, Position storage p, uint48 delay) private {
        if (block.timestamp < uint256(p.startTime) + p.durationSecs + delay) revert RefundTooEarly(id);
        address user = p.user;
        uint64 stake = p.stake;
        PoolState storage pool = _getFlashOptionStorage().pool;
        _releaseMargin(pool, stake, p.capBps);
        // can't underflow: an open position's stake is held in the total
        pool.total -= stake;
        pool.transferred = _add64(pool.transferred, stake);
        _closePosition(p);

        emit PositionRefunded(id, user, stake);
        _pay(user, stake, id);
    }

    /// @notice Repays the head of the IOU queue as much as free money allows.
    /// @dev Nothing is written when there is no free money: the caller stops. Paid in full, the IOU leaves the queue
    ///      (its entry deleted, the head moved on) and the position closes with slots 1 and 2 cleared; paid in part,
    ///      it keeps the rest owed at the head. Emits {OwedRepaid} once the books are written and before the payout,
    ///      the only external call.
    /// @param pool The pool's books.
    /// @return split What the head was repaid: nothing (`amount` 0) when there is no free money.
    function _repayHead(PoolState storage pool) private returns (RepaySplit memory split) {
        Layout storage $ = _getFlashOptionStorage();
        uint64 queueSeq = pool.nextRepaySeq;
        bytes32 id = $.iouQueue[queueSeq];
        Position storage p = $.positions[id];
        // Only free money repays the queue; the stakes of open bets are never touched.
        split = LeverageMath.repaySplit(p.owed, pool.total - pool.lockedMargin);
        if (split.amount == 0) return split;

        // can't underflow: the amount is at most the free money, which is part of the total, and at most this IOU's
        // owed, which is part of the total owed
        pool.total -= split.amount;
        pool.totalOwed -= split.amount;
        pool.transferred = _add64(pool.transferred, split.toUser);
        p.owed = split.remaining;
        if (split.remaining == 0) {
            // can't underflow or overflow: this IOU is counted, and its place is below the next queue number
            pool.owedPositions -= 1;
            pool.nextRepaySeq = queueSeq + 1;
            delete $.iouQueue[queueSeq];
            p.queueSeq = 0;
            _closePosition(p);
        }

        emit OwedRepaid({
            positionId: id,
            user: p.user,
            queueSeq: queueSeq,
            amount: split.amount,
            winnerFee: split.winnerFee,
            remainingOwed: split.remaining
        });
        _pay(p.user, split.toUser, id);
    }

    /// @notice Turns a settled position whose profit the pool can't pay now into an IOU at the back of the repay
    ///         queue.
    /// @dev The position keeps slot 1 and gets slot 2: what it is owed and its place in the queue. Each counter is
    ///      checked (`MathOverflow`).
    /// @param pool The pool's books.
    /// @param p The position's storage.
    /// @param id The position's id, which joins the queue.
    /// @param owed The profit owed.
    /// @return queueSeq The IOU's place in the queue.
    function _queueIou(
        PoolState storage pool,
        Position storage p,
        bytes32 id,
        uint64 owed
    )
        private
        returns (uint64 queueSeq)
    {
        queueSeq = pool.nextQueueSeq;
        pool.nextQueueSeq = _add64(queueSeq, 1);
        pool.totalOwed = _add64(pool.totalOwed, owed);
        uint32 owedPositions = pool.owedPositions;
        if (owedPositions == type(uint32).max) revert MathOverflow();
        pool.owedPositions = owedPositions + 1;
        _getFlashOptionStorage().iouQueue[queueSeq] = id;
        p.status = Status.Owed;
        p.owed = owed;
        p.queueSeq = queueSeq;
    }

    /// @notice Emits {PositionSettled} from its fields.
    /// @param e The event's fields.
    function _emitSettled(Settled memory e) private {
        emit PositionSettled({
            positionId: e.positionId,
            user: e.user,
            side: e.side,
            stake: e.stake,
            finalPrice: e.finalPrice,
            publishTime: e.publishTime,
            gBps: e.gBps,
            payout: e.payout,
            paidNow: e.paidNow,
            owed: e.owed,
            queueSeq: e.queueSeq,
            winnerFee: e.winnerFee,
            loserFee: e.loserFee,
            leverage: e.leverage
        });
    }

    /// @notice The checks every batch of `liquidate` and `settle` runs first: the halt, the batch's size and the
    ///         market (docs/ARCHITECTURE.md §8.4, §8.5). Then the batch, with nothing ended yet.
    /// @param marketId The batch's market's feed.
    /// @param leverage The batch's market's leverage: a batch holds one market, so one leverage.
    /// @param price The tick's price.
    /// @param publishTime The tick's publish time.
    /// @param count The number of ids in the batch.
    /// @return b The batch.
    function _checkBatch(
        bytes32 marketId,
        uint16 leverage,
        int64 price,
        uint48 publishTime,
        uint256 count
    )
        private
        view
        returns (Batch memory b)
    {
        if (_getFlashOptionStorage().halted) revert Halted();
        _checkBatchSize(count);
        (Market storage m, uint16 index) = _market(marketId, leverage);
        b.index = index;
        b.clockSkewSecs = m.clockSkewSecs;
        b.price = price;
        b.publishTime = publishTime;
    }

    /// @notice Looks up one id of a batch: it must have been opened, on the batch's market.
    /// @dev Reverts `UnknownPosition(id)` for an id never opened, and `ConfigMismatch(id)` for a position of another
    ///      market, so a bad id names itself and the backend can resend without it.
    /// @param id The position's id.
    /// @param index The batch's market index.
    /// @return p The position's storage.
    function _batchPosition(bytes32 id, uint16 index) private view returns (Position storage p) {
        p = _knownPosition(id);
        if (p.marketIdx != index) revert ConfigMismatch(id);
    }

    /// @notice Looks up a position that must have been opened, on any market.
    /// @dev Reverts `UnknownPosition(id)` for an id never opened. Every opened id keeps its record, ended or not.
    /// @param id The position's id.
    /// @return p The position's storage.
    function _knownPosition(bytes32 id) private view returns (Position storage p) {
        p = _getFlashOptionStorage().positions[id];
        if (p.status == Status.None) revert UnknownPosition(id);
    }

    /// @notice A batch holds 1 to 100 ids (`EmptyBatch` / `BatchSizeTooLarge`).
    /// @param count The number of ids in the batch.
    function _checkBatchSize(uint256 count) private pure {
        if (count == 0) revert EmptyBatch();
        if (count > _MAX_BATCH) revert BatchSizeTooLarge();
    }
}
