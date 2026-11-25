// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {VmSafe} from "forge-std/Vm.sol";

import {IManicFlashOptionEvents as Events} from "../src/interfaces/IManicFlashOptionEvents.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms} from "../src/types/OrderTypes.sol";
import {Breaker, PoolState, Position, Side, Status} from "../src/types/StorageTypes.sol";
import {Base_Test} from "./Base.t.sol";
import {Calculations, Repayment, Sale, Settlement} from "./utils/Calculations.sol";
import {Defaults} from "./utils/Defaults.sol";
import {LayoutReader} from "./utils/LayoutReader.sol";
import {OrderSigner} from "./utils/OrderSigner.sol";

/// @title Settlement_Base_Test
/// @notice The shared set-up of the tests of every ending: `liquidate` and `settle` (docs/ARCHITECTURE.md §8.4,
///         §8.5), `sell` (§8.3), `repay` (§8.7) and the safety refund, `refundExpired` (§8.6).
///         A pool with $1,500 of free money, helpers that open the positions to end and sign the sale orders, and
///         five checkers that run an ending and then check everything it changed.
/// @dev The checkers (`_expectLiquidated`, `_expectSettled`, `_expectSold`, `_expectRefunded`, `_expectRepaid`) first
///      walk the ending with their own model of the books, built from `Calculations` and never from `LeverageMath`:
///      free money is measured per position, in batch order, and a repeated id sees its first occurrence's ending;
///      `repay` is walked down the queue from its head. Then they run it with the logs recorded and check:
///      - every log, from the contract and from the token, in order and field by field, and that there are no
///        others;
///      - the number of positions a batch ended;
///      - all 15 fields of the pool's books, and the payout circuit breaker's 6 (ADR 0003): each call adds its users'
///        winnings and losses before fees, once, and its trip, if any, logs {CircuitBreakerTripped} after the
///        endings (a sale's before its payout);
///      - each id's three raw slots: slot 0 kept with its new status, slot 1 cleared (closed) or kept (owed), slot 2
///        written only for an IOU, and cleared when a repayment closes it; an id the batch only skipped is unchanged;
///      - the repay queue's new entries;
///      - every paid user's token and claimable balances, and the contract's balance;
///      - the books invariant.
///      A payout counts as refused, and so waits in `claimable`, while the token is paused or either side is frozen,
///      which is when `MockUSDG` refuses a transfer.
abstract contract Settlement_Base_Test is Base_Test {
    /// @dev The free money in the pool at the start: enough for the exposure gate to let in 50 bets of $10 at 4x.
    uint64 internal constant FREE = 1500e6;

    /// @dev What one id of a batch did, as the checker expected it and the contract matched.
    struct Ending {
        Settlement s; // a settle's split (for a repayment, `s.owed` is what stays owed); zero for the other endings
        Sale sale; // a sale's split; zero for the other endings
        Repayment repayment; // a repayment's split; zero for the other endings
        Status status; // its status after the batch
        uint64 loserFee; // a liquidation's loser fee; zero for a settle
        uint64 queueSeq; // an IOU's place in the queue
        bool skipped; // the position had already ended, so the batch skipped it
        bool deferred; // the payout was refused, so it waits in claimable
    }

    /// @dev A user the batch pays, with what they held before and what they should gain.
    struct Payee {
        address user;
        uint64 claimableBefore;
        uint64 claim; // kept for them in claimable
        uint256 balanceBefore;
        uint256 gain; // pushed to their wallet
    }

    /// @dev The checker's model of one batch.
    struct Model {
        PoolState pool; // the books, as the batch should leave them
        Breaker breaker; // the payout circuit breaker, as the call should leave it
        VmSafe.Log[] logs; // the logs the batch should emit, in order
        uint256 logCount;
        Payee[] payees;
        uint256 payeeCount;
        uint64 fees; // the batch's fees, accrued after the loop
        uint64 profit; // the profit the call pays users, before fees, for the breaker
        uint64 loss; // the users' losses the call keeps, before fees, for the breaker
        uint256 processed; // the positions the batch should end
        uint256 balanceBefore; // the contract's token balance
    }

    /// @dev The fields of {PositionOpened} that are not indexed, in its order, to decode its data.
    struct OpenedData {
        Side side;
        uint64 stake;
        int64 entryPrice;
        int8 priceExponent;
        int64 liqPrice;
        int64 capPrice;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
        uint48 startTime;
        uint48 endTime;
        uint16 leverage;
    }

    /// @dev The fields of {PositionSold} that are not indexed, in its order. Every one is a static type, so
    ///      `abi.encode` of this struct is exactly the log's data.
    struct SoldData {
        Side side;
        uint64 stake;
        int64 price;
        uint48 publishTime;
        uint16 gNowBps;
        uint64 valuation;
        uint64 sellAmount;
        uint64 sellFee;
        uint64 winnerFee;
        uint64 loserFee;
        uint16 leverage;
    }

    /// @dev The fields of {PositionSettled} that are not indexed, in its order. Every one is a static type, so
    ///      `abi.encode` of this struct is exactly the log's data.
    struct SettledData {
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

    uint256 internal aliceKey;
    uint256 internal bobKey;
    uint256 internal eveKey;

    /// @dev The market the batch helpers and the checkers run on: BTC at 1000x, unless a test picks another of a feed's
    ///      markets. A batch holds one market, one feed at one leverage (ADR 0008).
    bytes32 internal batchFeed = Defaults.BTC;
    uint16 internal batchLeverage = Defaults.LEVERAGE;

    function setUp() public virtual override {
        super.setUp();
        aliceKey = _keyOf("alice");
        bobKey = _keyOf("bob");
        eveKey = _keyOf("eve");
        _fund(users.bob, FREE);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Opening the positions to end
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Opens `user`'s base bet on `side` (a $10 BTC position for 60 seconds, floor 1.3x, cap 4x, θ 3 bp, at the
    ///      example price of $83,884, starting now) and returns it as stored.
    function _bet(address user, bytes32 id, Side side) internal returns (Position memory) {
        OpenOrder memory o = _order(user, id);
        o.side = side;
        return _betWith(o, _terms());
    }

    /// @dev Opens the order `o` with the terms `t`, signed by its user, and returns the position as stored. The bet
    ///      must keep its market's leverage, which its order names: the checkers' model values it at that copy.
    function _betWith(OpenOrder memory o, OpenTerms memory t) internal returns (Position memory p) {
        _open(_keyFor(o.user), o, t);
        p = LayoutReader.position(address(flashOption), o.positionId);
        assertEq(p.leverage, o.leverage, "the bet keeps its market's leverage");
    }

    /// @dev Opens the order `o` with the terms `t`, like `_betWith`, and returns what its {PositionOpened} reported.
    function _betRecorded(OpenOrder memory o, OpenTerms memory t) internal returns (OpenedData memory) {
        vm.recordLogs();
        _betWith(o, t);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(flashOption) && logs[i].topics[0] == Events.PositionOpened.selector) {
                return abi.decode(logs[i].data, (OpenedData));
            }
        }
        revert("no PositionOpened");
    }

    /// @dev The signing key of alice, bob or eve.
    function _keyFor(address user) internal view returns (uint256) {
        if (user == users.alice) return aliceKey;
        if (user == users.bob) return bobKey;
        assertEq(user, users.eve, "only alice, bob and eve bet");
        return eveKey;
    }

    /// @dev A position's expiry second.
    function _end(Position memory p) internal pure returns (uint48) {
        return p.startTime + p.durationSecs;
    }

    function _ids(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _ids(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _ids(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Calling the batches
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The settler liquidates `ids` on the batch market (BTC at 1000x unless a test picks another) at this tick.
    function _liquidate(int64 price, uint48 publishTime, bytes32[] memory ids) internal returns (uint256) {
        vm.prank(users.settler);
        return flashOption.liquidate(batchFeed, batchLeverage, price, publishTime, ids);
    }

    /// @dev The settler settles `ids` on the batch market (BTC at 1000x unless a test picks another) at this tick.
    function _settle(int64 price, uint48 publishTime, bytes32[] memory ids) internal returns (uint256) {
        vm.prank(users.settler);
        return flashOption.settle(batchFeed, batchLeverage, price, publishTime, ids);
    }

    /// @dev Expects the settler's liquidation of `ids` at this tick to revert with `reason`.
    function _expectLiquidateReverts(
        int64 price,
        uint48 publishTime,
        bytes32[] memory ids,
        bytes memory reason
    )
        internal
    {
        vm.expectRevert(reason);
        _liquidate(price, publishTime, ids);
    }

    /// @dev Expects the settler's settle of `ids` at this tick to revert with `reason`.
    function _expectSettleReverts(int64 price, uint48 publishTime, bytes32[] memory ids, bytes memory reason) internal {
        vm.expectRevert(reason);
        _settle(price, publishTime, ids);
    }

    /// @dev Expects eve's refund of `ids` to revert with `reason`. Eve holds no role: anyone may refund.
    function _expectRefundReverts(bytes32[] memory ids, bytes memory reason) internal {
        vm.expectRevert(reason);
        vm.prank(users.eve);
        flashOption.refundExpired(ids);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Selling
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev An order to sell `id` for at least `minAmount`, signed now and valid for `Defaults.ORDER_LIFETIME`.
    function _sellOrder(bytes32 id, uint64 minAmount) internal view returns (SellOrder memory) {
        return SellOrder({
            positionId: id,
            minAmount: minAmount,
            notBefore: uint48(block.timestamp),
            deadline: uint48(block.timestamp) + Defaults.ORDER_LIFETIME
        });
    }

    /// @dev The relayer's terms for a sale at `price`, at a tick published now.
    function _sellTerms(int64 price, uint64 valuation, uint64 sellAmount) internal view returns (SellTerms memory) {
        return
            SellTerms({
                price: price, publishTime: uint48(block.timestamp), valuation: valuation, sellAmount: sellAmount
            });
    }

    /// @dev `key`'s signature of `s`, under `leverage`'s domain.
    function _signSell(uint256 key, SellOrder memory s) internal view returns (bytes memory) {
        return OrderSigner.sign(key, flashOption.hashSellOrder(s));
    }

    /// @dev Expects the opener's sale of `s` with `t`, signed by the position's user, to revert with `reason`.
    function _expectSellReverts(SellOrder memory s, SellTerms memory t, bytes memory reason) internal {
        bytes memory signature = _signSell(_keyFor(LayoutReader.position(address(flashOption), s.positionId).user), s);
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
    }

    /// @dev Sells `id` now at `price` for these amounts, signed by its user, and checks everything the sale changed.
    function _expectSale(
        bytes32 id,
        int64 price,
        uint64 valuation,
        uint64 sellAmount,
        uint64 minAmount
    )
        internal
        returns (Ending memory)
    {
        SellOrder memory s = _sellOrder(id, minAmount);
        bytes memory signature = _signSell(_keyFor(LayoutReader.position(address(flashOption), id).user), s);
        return _expectSold(s, signature, _sellTerms(price, valuation, sellAmount));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The checkers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Liquidates `ids` at this tick and checks everything the batch changed (see the contract's notes).
    /// @return endings What each id did.
    function _expectLiquidated(
        int64 price,
        uint48 publishTime,
        bytes32[] memory ids
    )
        internal
        returns (Ending[] memory endings)
    {
        (Model memory m, uint256[3][] memory before) = _startModel(ids);
        endings = new Ending[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (_skips(m, ids, i, endings)) continue;
            endings[i] = _modelLiquidation(m, ids[i], price, publishTime);
        }
        _accrueModelFees(m);
        _countModelBreaker(m);
        vm.recordLogs();
        uint256 processed = _liquidate(price, publishTime, ids);
        _checkBatch(m, processed, ids, before, endings);
    }

    /// @dev Settles `ids` at this tick and checks everything the batch changed (see the contract's notes).
    /// @return endings What each id did.
    function _expectSettled(
        int64 price,
        uint48 publishTime,
        bytes32[] memory ids
    )
        internal
        returns (Ending[] memory endings)
    {
        (Model memory m, uint256[3][] memory before) = _startModel(ids);
        endings = new Ending[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (_skips(m, ids, i, endings)) continue;
            endings[i] = _modelSettlement(m, ids[i], price, publishTime);
        }
        _accrueModelFees(m);
        _countModelBreaker(m);
        vm.recordLogs();
        uint256 processed = _settle(price, publishTime, ids);
        _checkBatch(m, processed, ids, before, endings);
    }

    /// @dev The opener sells `s` with `t` and `signature`, and checks everything the sale changed (see the contract's
    ///      notes).
    /// @return e What the sale did.
    function _expectSold(
        SellOrder memory s,
        bytes memory signature,
        SellTerms memory t
    )
        internal
        returns (Ending memory e)
    {
        bytes32[] memory ids = _ids(s.positionId);
        (Model memory m, uint256[3][] memory before) = _startModel(ids);
        Ending[] memory endings = new Ending[](1);
        endings[0] = _modelSale(m, s.positionId, t);
        _accrueModelFees(m);
        vm.recordLogs();
        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
        _checkEnding(m, ids, before, endings);
        e = endings[0];
    }

    /// @dev `caller` refunds `ids`, and checks everything the batch changed (see the contract's notes). Every open id
    ///      must be refundable now: a refund that is too early reverts the whole batch, which this checker doesn't
    ///      model.
    /// @return endings What each id did.
    function _expectRefunded(bytes32[] memory ids, address caller) internal returns (Ending[] memory endings) {
        (Model memory m, uint256[3][] memory before) = _startModel(ids);
        endings = new Ending[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (_skips(m, ids, i, endings)) continue;
            endings[i] = _modelRefund(m, ids[i]);
        }
        vm.recordLogs();
        vm.prank(caller);
        uint256 processed = flashOption.refundExpired(ids);
        _checkBatch(m, processed, ids, before, endings);
    }

    /// @dev `caller` repays the queue with `maxCount`, and checks everything the call changed (see the contract's
    ///      notes). The ids are the IOUs it should reach, head first.
    /// @return endings What each repayment did.
    /// @return repaid The number the call returned, which the model matched.
    function _expectRepaid(uint256 maxCount, address caller)
        internal
        returns (Ending[] memory endings, uint256 repaid)
    {
        bytes32[] memory ids = _queueFromHead(maxCount);
        (Model memory m, uint256[3][] memory before) = _startModel(ids);
        endings = new Ending[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            endings[i] = _modelRepayment(m, ids[i]);
            if (endings[i].repayment.amount == 0) {
                // No free money left: this IOU and the rest are untouched.
                assembly ("memory-safe") {
                    mstore(ids, i) // shrink to the IOUs repaid
                    mstore(endings, i)
                }
                break;
            }
            if (endings[i].repayment.remaining > 0) {
                assembly ("memory-safe") {
                    mstore(ids, add(i, 1)) // the part-paid IOU is the last
                    mstore(endings, add(i, 1))
                }
                break;
            }
        }
        _accrueModelFees(m);
        _countModelBreaker(m);
        vm.recordLogs();
        vm.prank(caller);
        repaid = flashOption.repay(maxCount);
        _checkBatch(m, repaid, ids, before, endings);
    }

    /// @dev The ids of the IOUs from the head of the queue: at most `maxCount`, and at most as many as are queued.
    function _queueFromHead(uint256 maxCount) internal view returns (bytes32[] memory ids) {
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        uint256 queued = pool.nextQueueSeq - pool.nextRepaySeq;
        ids = new bytes32[](queued < maxCount ? queued : maxCount);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = LayoutReader.iouQueue(address(flashOption), pool.nextRepaySeq + uint64(i));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The model
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The model of a batch of `ids` before it runs: the books as they are, and each id's three raw slots.
    function _startModel(bytes32[] memory ids) private view returns (Model memory m, uint256[3][] memory before) {
        m.pool = LayoutReader.pool(address(flashOption));
        m.breaker = LayoutReader.breaker(address(flashOption));
        m.logs = new VmSafe.Log[](2 * ids.length + 1); // each id's ending and payout, then a trip of the breaker
        m.payees = new Payee[](ids.length);
        m.balanceBefore = usdg.balanceOf(address(flashOption));
        before = new uint256[3][](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 slot; slot < 3; ++slot) {
                before[i][slot] = LayoutReader.positionWord(address(flashOption), ids[i], slot);
            }
        }
    }

    /// @dev True, after adding its {PositionSkipped} to the model, if the batch must skip `ids[i]`: it had ended
    ///      before the batch, or an earlier occurrence in this batch ended it.
    function _skips(
        Model memory m,
        bytes32[] memory ids,
        uint256 i,
        Ending[] memory endings
    )
        private
        view
        returns (bool)
    {
        Status status = LayoutReader.position(address(flashOption), ids[i]).status;
        for (uint256 j; j < i; ++j) {
            if (ids[j] == ids[i] && !endings[j].skipped) status = endings[j].status;
        }
        if (status == Status.Open) return false;
        endings[i].skipped = true;
        endings[i].status = status;
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = Events.PositionSkipped.selector;
        topics[1] = ids[i];
        _addLog(m, address(flashOption), topics, abi.encode(status));
        return true;
    }

    /// @dev The model of liquidating the open position `id` at this tick.
    function _modelLiquidation(
        Model memory m,
        bytes32 id,
        int64 price,
        uint48 publishTime
    )
        private
        view
        returns (Ending memory e)
    {
        Position memory p = LayoutReader.position(address(flashOption), id);
        e.loserFee = Calculations.liquidationFee(p.stake, m.pool.total - m.pool.lockedMargin, m.pool.poolFloor);
        _releaseModelMargin(m, p);
        m.pool.total -= e.loserFee;
        m.fees += e.loserFee;
        m.loss += p.stake;
        m.processed += 1;
        e.status = Status.Closed;

        bytes32[] memory topics = new bytes32[](3);
        topics[0] = Events.PositionLiquidated.selector;
        topics[1] = id;
        topics[2] = bytes32(uint256(uint160(p.user)));
        _addLog(
            m,
            address(flashOption),
            topics,
            abi.encode(p.side, p.stake, p.liqPrice, price, publishTime, _end(p), e.loserFee, p.leverage)
        );
    }

    /// @dev The leverage the contract values `p` at: its own, copied from its market at open (ADR 0008).
    function _leverageOf(Position memory p) internal pure returns (uint16) {
        return p.leverage;
    }

    /// @dev The model of settling the open position `id` at this tick, and of paying its user.
    function _modelSettlement(
        Model memory m,
        bytes32 id,
        int64 price,
        uint48 publishTime
    )
        private
        view
        returns (Ending memory e)
    {
        Position memory p = LayoutReader.position(address(flashOption), id);
        uint16 g = Calculations.gBps(p.entryPrice, price, p.side, _leverageOf(p), p.floorBps, p.capBps);
        e.s = Calculations.settle({
            stake: p.stake,
            g: g,
            free: m.pool.total - m.pool.lockedMargin,
            totalOwed: m.pool.totalOwed,
            poolFloor: m.pool.poolFloor
        });
        _releaseModelMargin(m, p);
        m.pool.total -= e.s.outOfPool;
        m.pool.transferred += e.s.toUser;
        m.fees += e.s.winnerFee + e.s.loserFee;
        m.profit += e.s.paid;
        if (e.s.payout < p.stake) m.loss += p.stake - e.s.payout;
        m.processed += 1;
        e.status = Status.Closed;
        if (e.s.owed > 0) {
            e.status = Status.Owed;
            e.queueSeq = m.pool.nextQueueSeq++;
            m.pool.totalOwed += e.s.owed;
            m.pool.owedPositions += 1;
        }
        e.deferred = _refused(p.user);
        _addSettledLog(m, id, p, e, price, publishTime);
        _modelPayout(m, id, p.user, e.s.toUser, e.deferred);
    }

    /// @dev The model of selling the open position `id` with the terms `t`, and of paying its user.
    function _modelSale(Model memory m, bytes32 id, SellTerms memory t) private view returns (Ending memory e) {
        Position memory p = LayoutReader.position(address(flashOption), id);
        e.sale = Calculations.sell({
            stake: p.stake,
            valuation: t.valuation,
            sellAmount: t.sellAmount,
            free: m.pool.total - m.pool.lockedMargin,
            poolFloor: m.pool.poolFloor
        });
        e.sale.gNow = Calculations.gBps(p.entryPrice, t.price, p.side, _leverageOf(p), p.floorBps, p.capBps);
        _releaseModelMargin(m, p);
        m.pool.total -= e.sale.outOfPool;
        m.pool.transferred += e.sale.toUser;
        m.fees += e.sale.sellFee + e.sale.winnerFee + e.sale.loserFee;
        m.processed += 1;
        e.status = Status.Closed;
        e.deferred = _refused(p.user);
        _addSoldLog(m, id, p, e.sale, t);
        // The sale is counted in the breaker before its payout.
        if (t.sellAmount > p.stake) m.profit += t.sellAmount - p.stake;
        else m.loss += p.stake - t.sellAmount;
        _countModelBreaker(m);
        _modelPayout(m, id, p.user, e.sale.toUser, e.deferred);
    }

    /// @dev The model of refunding the open position `id`: its stake and max profit released, its whole stake back to
    ///      its user with no fee, so free money doesn't change.
    function _modelRefund(Model memory m, bytes32 id) private view returns (Ending memory e) {
        Position memory p = LayoutReader.position(address(flashOption), id);
        _releaseModelMargin(m, p);
        m.pool.total -= p.stake;
        m.pool.transferred += p.stake;
        m.processed += 1;
        e.status = Status.Closed;
        e.deferred = _refused(p.user);
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = Events.PositionRefunded.selector;
        topics[1] = id;
        topics[2] = bytes32(uint256(uint160(p.user)));
        _addLog(m, address(flashOption), topics, abi.encode(p.stake));
        _modelPayout(m, id, p.user, p.stake, e.deferred);
    }

    /// @dev The model of repaying the IOU `id` at the head of the queue from free money, and of paying its owner. A
    ///      repayment of nothing (no free money) changes nothing and logs nothing.
    function _modelRepayment(Model memory m, bytes32 id) private view returns (Ending memory e) {
        Position memory p = LayoutReader.position(address(flashOption), id);
        e.repayment = Calculations.repay(p.owed, m.pool.total - m.pool.lockedMargin);
        if (e.repayment.amount == 0) return e;
        e.queueSeq = p.queueSeq;
        e.s.owed = e.repayment.remaining;
        e.status = Status.Owed;
        m.pool.total -= e.repayment.amount;
        m.pool.totalOwed -= e.repayment.amount;
        m.pool.transferred += e.repayment.toUser;
        m.fees += e.repayment.winnerFee;
        m.profit += e.repayment.amount;
        m.processed += 1;
        if (e.repayment.remaining == 0) {
            e.status = Status.Closed;
            m.pool.owedPositions -= 1;
            m.pool.nextRepaySeq += 1;
        }
        e.deferred = _refused(p.user);
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = Events.OwedRepaid.selector;
        topics[1] = id;
        topics[2] = bytes32(uint256(uint160(p.user)));
        _addLog(
            m,
            address(flashOption),
            topics,
            abi.encode(p.queueSeq, e.repayment.amount, e.repayment.winnerFee, e.repayment.remaining)
        );
        _modelPayout(m, id, p.user, e.repayment.toUser, e.deferred);
    }

    /// @dev Whether `MockUSDG` refuses a payout to `user` now: the token is paused, or either side is frozen.
    function _refused(address user) private view returns (bool) {
        return usdg.paused() || usdg.isFrozen(user) || usdg.isFrozen(address(flashOption));
    }

    /// @dev The model of releasing an ending position's stake, max profit and count.
    function _releaseModelMargin(Model memory m, Position memory p) private pure {
        m.pool.lockedMargin -= p.stake;
        m.pool.openMaxProfit -= Calculations.maxProfit(p.stake, p.capBps);
        m.pool.openPositions -= 1;
    }

    /// @dev The model of paying an ended position's user `amount`: the token's {Transfer}, or {PayoutDeferred} and a
    ///      claim when the token refuses it.
    function _modelPayout(Model memory m, bytes32 id, address user, uint64 amount, bool deferred) private view {
        if (amount == 0) return;
        Payee memory payee = _payee(m, user);
        bytes32[] memory topics = new bytes32[](3);
        if (deferred) {
            topics[0] = Events.PayoutDeferred.selector;
            topics[1] = id;
            topics[2] = bytes32(uint256(uint160(user)));
            _addLog(m, address(flashOption), topics, abi.encode(amount));
            payee.claim += amount;
            m.pool.totalClaimable += amount;
        } else {
            topics[0] = keccak256("Transfer(address,address,uint256)");
            topics[1] = bytes32(uint256(uint160(address(flashOption))));
            topics[2] = bytes32(uint256(uint160(user)));
            _addLog(m, address(usdg), topics, abi.encode(uint256(amount)));
            payee.gain += amount;
        }
    }

    /// @dev Adds the expected {PositionSettled} for `p` to the model.
    function _addSettledLog(
        Model memory m,
        bytes32 id,
        Position memory p,
        Ending memory e,
        int64 price,
        uint48 publishTime
    )
        private
        view
    {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = Events.PositionSettled.selector;
        topics[1] = id;
        topics[2] = bytes32(uint256(uint160(p.user)));
        SettledData memory d = SettledData({
            side: p.side,
            stake: p.stake,
            finalPrice: price,
            publishTime: publishTime,
            gBps: e.s.g,
            payout: e.s.payout,
            paidNow: e.s.toUser,
            owed: e.s.owed,
            queueSeq: e.queueSeq,
            winnerFee: e.s.winnerFee,
            loserFee: e.s.loserFee,
            leverage: p.leverage
        });
        _addLog(m, address(flashOption), topics, abi.encode(d));
    }

    /// @dev Adds the expected {PositionSold} for `p` to the model.
    function _addSoldLog(
        Model memory m,
        bytes32 id,
        Position memory p,
        Sale memory r,
        SellTerms memory t
    )
        private
        view
    {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = Events.PositionSold.selector;
        topics[1] = id;
        topics[2] = bytes32(uint256(uint160(p.user)));
        SoldData memory d = SoldData({
            side: p.side,
            stake: p.stake,
            price: t.price,
            publishTime: t.publishTime,
            gNowBps: r.gNow,
            valuation: t.valuation,
            sellAmount: t.sellAmount,
            sellFee: r.sellFee,
            winnerFee: r.winnerFee,
            loserFee: r.loserFee,
            leverage: p.leverage
        });
        _addLog(m, address(flashOption), topics, abi.encode(d));
    }

    /// @dev The model of one call's count in the payout circuit breaker (ARCHITECTURE §8.11), from the call's summed
    ///      winnings and losses. Nothing happens when both are zero. Otherwise a window that has run its length
    ///      restarts at zero from now, both counters grow, and a breaker with a limit that hasn't tripped trips,
    /// logging {CircuitBreakerTripped}, when the profit out is more than the losses kept plus the limit.
    function _countModelBreaker(Model memory m) private view {
        if (m.profit == 0 && m.loss == 0) return;
        Breaker memory b = m.breaker;
        if (block.timestamp >= uint256(b.windowStart) + b.windowSecs) {
            b.profitOut = 0;
            b.lossIn = 0;
            b.windowStart = uint48(block.timestamp);
        }
        b.profitOut += m.profit;
        b.lossIn += m.loss;
        m.profit = 0;
        m.loss = 0;
        if (b.tripped || b.maxNetProfit == 0 || uint256(b.profitOut) <= uint256(b.lossIn) + b.maxNetProfit) return;
        b.tripped = true;
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = Events.CircuitBreakerTripped.selector;
        _addLog(m, address(flashOption), topics, abi.encode(b.profitOut, b.lossIn, b.windowStart));
    }

    /// @dev The ending's fees join the pending fees and `feesPaid` once, after the loop.
    function _accrueModelFees(Model memory m) private pure {
        m.pool.feesPending += m.fees;
        m.pool.feesPaid += m.fees;
    }

    /// @dev `user`'s entry among the batch's payees, added with their balances on first use.
    function _payee(Model memory m, address user) private view returns (Payee memory) {
        for (uint256 i; i < m.payeeCount; ++i) {
            if (m.payees[i].user == user) return m.payees[i];
        }
        m.payees[m.payeeCount] = Payee({
            user: user,
            balanceBefore: usdg.balanceOf(user),
            claimableBefore: LayoutReader.claimable(address(flashOption), user),
            gain: 0,
            claim: 0
        });
        return m.payees[m.payeeCount++];
    }

    function _addLog(Model memory m, address emitter, bytes32[] memory topics, bytes memory data) private pure {
        m.logs[m.logCount++] = VmSafe.Log({topics: topics, data: data, emitter: emitter});
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Checking the batch against the model
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Checks the batch that just ran against the model: the number it ended, then everything else.
    function _checkBatch(
        Model memory m,
        uint256 processed,
        bytes32[] memory ids,
        uint256[3][] memory before,
        Ending[] memory endings
    )
        private
        view
    {
        assertEq(processed, m.processed, "positions ended");
        _checkEnding(m, ids, before, endings);
    }

    /// @dev Checks the ending that just ran against the model: the logs, the books, the slots and the balances.
    function _checkEnding(
        Model memory m,
        bytes32[] memory ids,
        uint256[3][] memory before,
        Ending[] memory endings
    )
        private
        view
    {
        _checkLogs(m);
        _assertPool(LayoutReader.pool(address(flashOption)), m.pool);
        _assertBreaker(LayoutReader.breaker(address(flashOption)), m.breaker);
        for (uint256 i; i < ids.length; ++i) {
            _checkSlots(ids, i, before[i], endings);
        }
        uint256 paid;
        for (uint256 i; i < m.payeeCount; ++i) {
            Payee memory payee = m.payees[i];
            assertEq(usdg.balanceOf(payee.user), payee.balanceBefore + payee.gain, "a payee's balance");
            assertEq(
                LayoutReader.claimable(address(flashOption), payee.user),
                payee.claimableBefore + payee.claim,
                "a payee's claimable balance"
            );
            paid += payee.gain;
        }
        assertEq(usdg.balanceOf(address(flashOption)), m.balanceBefore - paid, "the contract's balance");
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev The recorded logs are exactly the model's, in order and field by field.
    function _checkLogs(Model memory m) private view {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, m.logCount, "the number of logs");
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, m.logs[i].emitter, "a log's emitter");
            assertEq(logs[i].topics, m.logs[i].topics, "a log's topics");
            assertEq(logs[i].data, m.logs[i].data, "a log's data");
        }
    }

    /// @dev The three raw slots of `ids[i]`: as the first occurrence that ended it left them, or unchanged if the
    ///      batch only skipped it. An IOU is also checked in the repay queue.
    function _checkSlots(
        bytes32[] memory ids,
        uint256 i,
        uint256[3] memory before,
        Ending[] memory endings
    )
        private
        view
    {
        // A copy, value by value: assigning a memory array copies only the reference.
        uint256[3] memory expected = [before[0], before[1], before[2]];
        Status was = Status(uint8(before[0] >> 184));
        for (uint256 j; j < ids.length; ++j) {
            if (ids[j] != ids[i] || endings[j].skipped) continue;
            uint256 statusMask = uint256(0xff) << 184;
            expected[0] = (before[0] & ~statusMask) | (uint256(endings[j].status) << 184);
            if (endings[j].status == Status.Closed) expected[1] = 0;
            if (was == Status.Owed && endings[j].status == Status.Closed) {
                // A repayment closed this IOU: slot 2 is cleared, and it has left the queue.
                expected[2] = 0;
                assertEq(LayoutReader.iouQueue(address(flashOption), uint64(before[2] >> 64)), 0, "out of the queue");
            }
            if (endings[j].status == Status.Owed) {
                expected[2] = uint256(endings[j].s.owed) | (uint256(endings[j].queueSeq) << 64);
                assertEq(LayoutReader.iouQueue(address(flashOption), endings[j].queueSeq), ids[i], "in the IOU queue");
            }
        }
        for (uint256 slot; slot < 3; ++slot) {
            assertEq(LayoutReader.positionWord(address(flashOption), ids[i], slot), expected[slot], "a position slot");
        }
    }

    /// @dev Every field of the payout circuit breaker.
    function _assertBreaker(Breaker memory a, Breaker memory e) internal pure {
        assertEq(a.profitOut, e.profitOut, "breaker profitOut");
        assertEq(a.lossIn, e.lossIn, "breaker lossIn");
        assertEq(a.windowStart, e.windowStart, "breaker windowStart");
        assertEq(a.tripped, e.tripped, "breaker tripped");
        assertEq(a.windowSecs, e.windowSecs, "breaker windowSecs");
        assertEq(a.maxNetProfit, e.maxNetProfit, "breaker maxNetProfit");
    }

    /// @dev Every field of the pool's books.
    function _assertPool(PoolState memory a, PoolState memory e) internal pure {
        assertEq(a.total, e.total, "total");
        assertEq(a.lockedMargin, e.lockedMargin, "lockedMargin");
        assertEq(a.openMaxProfit, e.openMaxProfit, "openMaxProfit");
        assertEq(a.totalOwed, e.totalOwed, "totalOwed");
        assertEq(a.poolFloor, e.poolFloor, "poolFloor");
        assertEq(a.nextQueueSeq, e.nextQueueSeq, "nextQueueSeq");
        assertEq(a.nextRepaySeq, e.nextRepaySeq, "nextRepaySeq");
        assertEq(a.openPositions, e.openPositions, "openPositions");
        assertEq(a.owedPositions, e.owedPositions, "owedPositions");
        assertEq(a.feesPending, e.feesPending, "feesPending");
        assertEq(a.totalClaimable, e.totalClaimable, "totalClaimable");
        assertEq(a.transferred, e.transferred, "transferred");
        assertEq(a.feesPaid, e.feesPaid, "feesPaid");
        assertEq(a.seedRecovered, e.seedRecovered, "seedRecovered");
        assertEq(a.rewardsWithdrawn, e.rewardsWithdrawn, "rewardsWithdrawn");
    }
}
