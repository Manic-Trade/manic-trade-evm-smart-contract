// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionSettlement} from "../../../src/interfaces/IManicFlashOptionSettlement.sol";
import {PoolState, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {BaseHandler, HandlerSetup} from "./BaseHandler.sol";

/// @title SettlementHandler
/// @notice Every way a bet ends besides a sale: the settler's liquidations and settles, in batches at one price tick;
///         anyone's safety refund once the delay has passed; and anyone's repayment of the IOU queue
///         (docs/ARCHITECTURE.md §8.4 to §8.7).
/// @dev Each batch holds exactly what the contract must end at its tick, all on one market: the market of a bet it
///      picks. `liquidate` takes that market's bets the price touches, at a tick inside each one's life; `settle`
///      takes that market's bets expiring at one second that the price doesn't touch. One batch in three also carries
///      a bet of the same market that has already ended, which the contract must skip. `mixedBatch` sends a batch
///      holding a bet of another market, which must be refused. The handler predicts the halt, which stops all but
///      the refund (§8.10) and the switched-off refund, and checks how many bets each batch ended. A refund, which
///      names no market, may take bets of every market at once. A refund or a repayment comes from any known
///      account, the stranger included: the money check around every call proves only the bets' users are paid.
contract SettlementHandler is BaseHandler {
    /// @dev Which open bets a scan keeps.
    enum Filter {
        Open, // every open bet
        Touched, // the price touches its line
        Due, // it has expired, within the clock skew, and the price doesn't touch its line
        Refundable // the refund delay has passed since its expiry
    }

    /// @dev The most bets one batch ends here. The contract takes 100; a run rarely has more than 20 to end at once.
    uint256 internal constant MAX_BATCH = 20;

    /// @dev Any market, for `_withEnded` and `_anEnded`: a refund names no market, so an ended bet of any may ride
    ///      along.
    uint16 internal constant ANY_MARKET = type(uint16).max;

    constructor(HandlerSetup memory s) BaseHandler(s) {}

    /// @notice The settler liquidates the bets of one market the current price touches, at one tick: the expiry second
    ///         of a touched bet that has already ended, or now. Every touched bet of that market whose life holds that
    ///         tick is in the batch.
    /// @param seed Picks the bet whose market and life set the batch's market and tick, and whether an ended bet rides
    ///        along.
    function liquidate(uint256 seed) external instrumented("liquidate") {
        int64 price = store.price();
        (bytes32[] memory touched, uint256 n) = _scan(Filter.Touched, price, 0);
        if (n == 0) {
            _skip();
            return;
        }
        Position memory first = LayoutReader.position(address(flashOption), touched[seed % n]);
        uint256 firstEnd = uint256(first.startTime) + first.durationSecs;
        uint48 tick = uint48(block.timestamp < firstEnd ? block.timestamp : firstEnd);
        (bytes32[] memory ids, uint256 ending) = _touchedBatch(touched, n, first.marketIdx, tick, seed);
        _sendBatch(false, _marketOf(first).leverage, price, tick, ids, ending);
    }

    /// @notice The settler settles the bets of one market that expired at one second, at the current price: every bet
    ///         of that market with that expiry the price doesn't touch. Those it touches are left to `liquidate`, as
    ///         the backend does, and those of the other markets to their own batches.
    /// @param seed Picks the bet whose market and expiry second set the batch's, and whether an ended bet rides along.
    function settle(uint256 seed) external instrumented("settle") {
        int64 price = store.price();
        (bytes32[] memory due, uint256 n) = _scan(Filter.Due, price, 0);
        if (n == 0) {
            _skip();
            return;
        }
        Position memory first = LayoutReader.position(address(flashOption), due[seed % n]);
        uint48 end = uint48(uint256(first.startTime) + first.durationSecs);
        (bytes32[] memory ids, uint256 ending) = _dueBatch(due, n, first.marketIdx, end, seed);
        _sendBatch(true, _marketOf(first).leverage, price, end, ids, ending);
    }

    /// @notice The settler sends a batch of one market that holds a bet of another: refused, naming that bet
    ///         (`ConfigMismatch`), whatever its status, or with `Halted` while the halt is on. The batch liquidates or
    ///         settles at the current price and now, on one of the two other markets. Half the time it starts with a
    ///         bet of its own market that has already ended, if there is one, which the contract skips before it
    ///         reaches the other's.
    /// @param seed Picks the other market's bet, the batch's market, whether its own ended bet comes first, and whether
    ///        it liquidates or settles.
    function mixedBatch(uint256 seed) external instrumented("mixedBatch") {
        uint256 total = store.betCount();
        if (total == 0) {
            _skip();
            return;
        }
        bytes32 theirs = store.idAt(seed % total);
        uint16 theirLeverage = store.bet(theirs).leverage;
        uint16 ourLeverage = _pickLeverage(_pick(seed, 1, 0, 2));
        if (ourLeverage == theirLeverage) ourLeverage = _pickLeverage(_pick(seed, 1, 0, 2) + 1);
        bytes32[] memory ids = new bytes32[](2);
        uint256 count;
        bytes32 ended = _pick(seed, 3, 0, 1) == 0 ? _anEnded(seed, _marketIndexOf(ourLeverage)) : bytes32(0);
        if (ended != bytes32(0)) ids[count++] = ended;
        ids[count++] = theirs;
        _shrink(ids, count);

        bytes memory data = _pick(seed, 2, 0, 1) == 0
            ? abi.encodeCall(
                IManicFlashOptionSettlement.liquidate,
                (Defaults.BTC, ourLeverage, store.price(), uint48(block.timestamp), ids)
            )
            : abi.encodeCall(
                IManicFlashOptionSettlement.settle,
                (Defaults.BTC, ourLeverage, store.price(), uint48(block.timestamp), ids)
            );
        bytes memory expected = LayoutReader.halted(address(flashOption))
            ? abi.encodeWithSelector(Errors.Halted.selector)
            : abi.encodeWithSelector(Errors.ConfigMismatch.selector, theirs);
        (bool ok, bytes memory reason) = _attempt("mixedBatch", users.settler, data);
        _checkRefusal(13, "mixedBatch", ok, reason, expected);
        _refuse();
    }

    /// @notice Anyone refunds every open bet whose refund delay has passed since its expiry. No brake stops it. With
    ///         the refund switched off, any refund is refused.
    /// @param seed Picks the caller, and whether an ended bet rides along.
    function refund(uint256 seed) external instrumented("refund") {
        address caller = _anyone(seed);
        uint48 delay = LayoutReader.refundDelaySecs(address(flashOption));
        if (delay == 0) {
            (bytes32[] memory open, uint256 m) = _scan(Filter.Open, 0, 0);
            if (m == 0) {
                _skip();
                return;
            }
            bytes32[] memory one = new bytes32[](1);
            one[0] = open[seed % m];
            (bool ok, bytes memory reason) =
                _attempt("refund", caller, abi.encodeCall(IManicFlashOptionSettlement.refundExpired, (one)));
            _checkRefusal(13, "refund", ok, reason, abi.encodeWithSelector(Errors.RefundDisabled.selector));
            _refuse();
            return;
        }
        (bytes32[] memory due, uint256 n) = _scan(Filter.Refundable, 0, delay);
        if (n == 0) {
            _skip();
            return;
        }
        uint256 count = n < MAX_BATCH ? n : MAX_BATCH;
        bytes32[] memory ids = new bytes32[](count + 1);
        for (uint256 i; i < count; ++i) {
            ids[i] = due[i];
        }
        _shrink(ids, _withEnded(ids, count, seed, ANY_MARKET));
        vm.prank(caller);
        uint256 processed = flashOption.refundExpired(ids);
        if (processed != count) store.recordBreach(13, "refund: refunded a different number of bets than it held");
        _done();
    }

    /// @notice Anyone repays the IOU queue, up to `maxCount` IOUs, from the pool's free money.
    /// @param seed Picks the caller and the most IOUs to repay, 1 to 50.
    function repay(uint256 seed) external instrumented("repay") {
        PoolState memory pool = _pool();
        if (pool.nextRepaySeq == pool.nextQueueSeq) {
            _skip();
            return;
        }
        address caller = _anyone(seed);
        uint256 maxCount = _pick(seed, 1, 1, 50);
        if (LayoutReader.halted(address(flashOption))) {
            (bool ok, bytes memory reason) =
                _attempt("repay", caller, abi.encodeCall(IManicFlashOptionSettlement.repay, (maxCount)));
            _checkRefusal(13, "repay", ok, reason, abi.encodeWithSelector(Errors.Halted.selector));
            _refuse();
            return;
        }
        vm.prank(caller);
        uint256 repaid = flashOption.repay(maxCount);
        // With no free money there is nothing to repay with, and the call changes nothing.
        if (repaid == 0) _skip();
        else _done();
    }

    /// @notice Winds the pool down at the end of a run (`afterInvariant` calls it; it is never a fuzz target). Every
    ///         brake that stops an ending or a payment is released: the halt, the token's pause and every freeze.
    ///         Every open bet ends at its expiry second: settled, or liquidated if the price touches its line. The
    ///         funder tops up what the IOU queue needs and the queue is repaid in full. Every waiting payout is
    ///         claimed and the fees are swept. The money, status and breaker checks run around all of it.
    function windDown() external instrumented("windDown") {
        _releaseBrakes();
        _endEveryBet();
        _repayEveryIou();
        for (uint256 k; k < known.length; ++k) {
            if (LayoutReader.claimable(address(flashOption), known[k]) > 0) flashOption.claim(known[k]);
        }
        if (_pool().feesPending > 0) flashOption.sweepFees();
        _done();
    }

    /// @dev Releases what stops an ending or a payment. A paused or switched-off market, and a tripped breaker, stop
    ///      only opens and sales, so they stay.
    function _releaseBrakes() private {
        if (LayoutReader.halted(address(flashOption))) {
            vm.prank(users.operator);
            flashOption.setHalted(false);
        }
        vm.startPrank(usdgAdmin);
        if (usdg.paused()) usdg.unpause();
        for (uint256 k; k < known.length; ++k) {
            if (usdg.isFrozen(known[k])) usdg.unfreeze(known[k]);
        }
        vm.stopPrank();
    }

    /// @dev Moves the clock past every open bet's expiry, then ends each one at its expiry second, at the current
    ///      price, in a batch of its own market: settled, or liquidated if the price touches its line.
    function _endEveryBet() private {
        (bytes32[] memory open, uint256 n) = _scan(Filter.Open, 0, 0);
        uint256 latest = block.timestamp;
        for (uint256 i; i < n; ++i) {
            uint256 end = _endOf(open[i]);
            if (end > latest) latest = end;
        }
        vm.warp(latest);
        int64 price = store.price();
        for (uint256 i; i < n; ++i) {
            Position memory p = LayoutReader.position(address(flashOption), open[i]);
            uint16 marketLeverage = _marketOf(p).leverage;
            bytes32[] memory one = new bytes32[](1);
            one[0] = open[i];
            bool touched = p.side == Side.Call ? price <= p.liqPrice : price >= p.liqPrice;
            vm.prank(users.settler);
            if (touched) flashOption.liquidate(Defaults.BTC, marketLeverage, price, uint48(_endOf(open[i])), one);
            else flashOption.settle(Defaults.BTC, marketLeverage, price, uint48(_endOf(open[i])), one);
        }
    }

    /// @dev Tops up free money to what the IOU queue is owed, then repays it, 50 IOUs a call, until it is empty.
    function _repayEveryIou() private {
        PoolState memory pool = _pool();
        if (pool.totalOwed == 0) return;
        uint256 free = pool.total - pool.lockedMargin;
        if (free < pool.totalOwed) {
            // casting to uint64 is safe: the top-up is less than the total owed, a uint64
            uint64 topUp = uint64(pool.totalOwed - free);
            _mint(funder, topUp);
            vm.startPrank(funder);
            usdg.approve(address(flashOption), topUp);
            flashOption.fund(topUp);
            vm.stopPrank();
        }
        while (_pool().nextRepaySeq < _pool().nextQueueSeq) {
            flashOption.repay(50);
        }
    }

    /// @dev The open bets of every market `filter` keeps, at `price` for the line, and `param` as the refund delay
    ///      (`Refundable`). `Due` takes each bet's own market's clock skew.
    function _scan(Filter filter, int64 price, uint256 param) private view returns (bytes32[] memory ids, uint256 n) {
        uint256 total = store.betCount();
        ids = new bytes32[](total);
        for (uint256 i; i < total; ++i) {
            bytes32 id = store.idAt(i);
            Position memory p = LayoutReader.position(address(flashOption), id);
            if (p.status != Status.Open) continue;
            uint256 end = uint256(p.startTime) + p.durationSecs;
            bool touched = p.side == Side.Call ? price <= p.liqPrice : price >= p.liqPrice;
            if (filter == Filter.Touched && !touched) continue;
            if (filter == Filter.Due && (touched || end > block.timestamp + _marketOf(p).clockSkewSecs)) continue;
            if (filter == Filter.Refundable && block.timestamp < end + param) continue;
            ids[n++] = id;
        }
    }

    /// @dev The batch `liquidate` sends at `tick`: every bet of `touched` (its first `n`) on the market at index
    ///      `marketIdx` whose life holds the tick, at most `MAX_BATCH`, and one time in three an ended bet of that
    ///      market (`_withEnded`). Returns it, and how many of its bets must end: all but the ended one.
    function _touchedBatch(
        bytes32[] memory touched,
        uint256 n,
        uint16 marketIdx,
        uint48 tick,
        uint256 seed
    )
        private
        view
        returns (bytes32[] memory ids, uint256 ending)
    {
        ids = new bytes32[](n + 1);
        for (uint256 i; i < n && ending < MAX_BATCH; ++i) {
            Position memory p = LayoutReader.position(address(flashOption), touched[i]);
            bool lives = p.startTime <= tick && tick <= uint256(p.startTime) + p.durationSecs;
            if (p.marketIdx == marketIdx && lives) ids[ending++] = touched[i];
        }
        _shrink(ids, _withEnded(ids, ending, seed, marketIdx));
    }

    /// @dev The batch `settle` sends: every bet of `due` (its first `n`) on the market at index `marketIdx` that
    ///      expires at `end`, at most `MAX_BATCH`, and one time in three an ended bet of that market (`_withEnded`).
    ///      Returns it, and how many of its bets must end: all but the ended one.
    function _dueBatch(
        bytes32[] memory due,
        uint256 n,
        uint16 marketIdx,
        uint256 end,
        uint256 seed
    )
        private
        view
        returns (bytes32[] memory ids, uint256 ending)
    {
        ids = new bytes32[](n + 1);
        for (uint256 i; i < n && ending < MAX_BATCH; ++i) {
            Position memory p = LayoutReader.position(address(flashOption), due[i]);
            if (p.marketIdx == marketIdx && uint256(p.startTime) + p.durationSecs == end) ids[ending++] = due[i];
        }
        _shrink(ids, _withEnded(ids, ending, seed, marketIdx));
    }

    /// @dev The settler sends the batch `ids` of BTC's market at `marketLeverage`, at this tick: a settle, or a
    ///      liquidation. While the halt is on it must be refused (`Halted`); otherwise it must end exactly `ending`
    ///      bets.
    function _sendBatch(
        bool isSettle,
        uint16 marketLeverage,
        int64 price,
        uint48 tick,
        bytes32[] memory ids,
        uint256 ending
    )
        private
    {
        string memory action = isSettle ? "settle" : "liquidate";
        if (LayoutReader.halted(address(flashOption))) {
            bytes memory data = isSettle
                ? abi.encodeCall(IManicFlashOptionSettlement.settle, (Defaults.BTC, marketLeverage, price, tick, ids))
                : abi.encodeCall(
                    IManicFlashOptionSettlement.liquidate, (Defaults.BTC, marketLeverage, price, tick, ids)
                );
            (bool ok, bytes memory reason) = _attempt(action, users.settler, data);
            _checkRefusal(13, action, ok, reason, abi.encodeWithSelector(Errors.Halted.selector));
            _refuse();
            return;
        }
        vm.prank(users.settler);
        uint256 processed = isSettle
            ? flashOption.settle(Defaults.BTC, marketLeverage, price, tick, ids)
            : flashOption.liquidate(Defaults.BTC, marketLeverage, price, tick, ids);
        if (processed != ending) {
            store.recordBreach(13, string.concat(action, ": ended a different number of bets than it held"));
        }
        _done();
    }

    /// @dev One batch in three also carries a bet that has already ended (closed or owed), which the contract must
    ///      skip: one of the batch's market (index `marketIdx`), or of any market for a refund, which names none
    ///      (`ANY_MARKET`). One of another market would make the contract refuse a liquidation or a settle whole
    ///      (`mixedBatch`). It goes in the spare place at `ids[count]`. Returns the batch's new size.
    function _withEnded(
        bytes32[] memory ids,
        uint256 count,
        uint256 seed,
        uint16 marketIdx
    )
        private
        view
        returns (uint256)
    {
        if (_pick(seed, 6, 0, 2) != 0) return count;
        bytes32 id = _anEnded(seed, marketIdx);
        if (id == bytes32(0)) return count;
        ids[count] = id;
        return count + 1;
    }

    /// @dev A bet that has already ended (closed or owed), of the market at index `marketIdx` or of any market
    ///      (`ANY_MARKET`), found from a place `seed` picks; zero if there is none.
    function _anEnded(uint256 seed, uint16 marketIdx) private view returns (bytes32) {
        uint256 total = store.betCount();
        if (total == 0) return bytes32(0);
        uint256 first = _pick(seed, 7, 0, total - 1);
        for (uint256 j; j < total; ++j) {
            bytes32 id = store.idAt((first + j) % total);
            Position memory p = LayoutReader.position(address(flashOption), id);
            if (p.status == Status.Open || (marketIdx != ANY_MARKET && p.marketIdx != marketIdx)) continue;
            return id;
        }
        return bytes32(0);
    }

    /// @dev The index of BTC's market at `marketLeverage`.
    function _marketIndexOf(uint16 marketLeverage) private view returns (uint16) {
        return LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.BTC, marketLeverage) - 1;
    }

    /// @dev A bet's expiry second.
    function _endOf(bytes32 id) private view returns (uint256) {
        Position memory p = LayoutReader.position(address(flashOption), id);
        return uint256(p.startTime) + p.durationSecs;
    }

    /// @dev Shortens `ids` to its first `count` entries.
    function _shrink(bytes32[] memory ids, uint256 count) private pure {
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }
}
