// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title IManicFlashOptionSettlement
/// @author Manic
/// @notice How positions end at a price, how a position the backend never ended is refunded, and how the winners the
///         pool couldn't pay are paid later. The settler relayer liquidates positions when a tick touches their line
///         and settles them at their expiry second, in batches of up to 100 positions of one market (one feed at one
///         leverage) at one price tick (docs/ARCHITECTURE.md §8.4, §8.5). Anyone refunds the stake of a position
///         still open long after its expiry (the safety refund, §8.6), and anyone repays the IOU queue from the
///         pool's free money (§8.7). Implemented by `SettlementModule`.
/// @dev The settler is trusted for the price only: each position's own times and line are
///      checked against the tick. `liquidate`, `settle` and `repay` work while a market is paused or switched off,
///      and while the circuit breaker is tripped; only the halt stops them (§8.10), so a bet can always end once the
///      operator releases the halt. No brake stops `refundExpired`, which only ever returns a user's own stake.
///
///      A batch skips any position that has already ended, with {PositionSkipped}: sold, liquidated, settled or
///      refunded earlier, or listed twice in the same batch. An id that was never opened, or a position of another
///      market, still reverts the whole batch, with the id in the error, so the backend can drop it and resend.
///
///      Free money is measured position by position, in batch order: an earlier position's released stake or loss
///      counts for the next one's loser fee and payout. Fees accrue in the pool's pending fees
///      once per batch; anyone sweeps them to the fee recipient later (`sweepFees`). `liquidate`, `settle` and
///      `repay` also count their users' winnings and losses in the payout circuit breaker once per call (§8.11);
///      a refund counts nothing.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionSettlement {
    /// @notice Liquidates every position in `ids` whose liquidation line the tick touches: the user gets nothing back,
    ///         and the stake stays in the pool as free money, less the 3% loser fee while free money is at or above
    ///         the floor.
    /// @dev For each position, in order: free money is measured with its stake still held, the stake and its max
    ///      profit are released, the loser fee leaves the pool's total, and the position closes (slot 0 stays as the
    ///      tombstone, slot 1 is cleared). Emits {PositionLiquidated} per position ended and {PositionSkipped} per
    ///      position that had already ended. After the loop, the batch's fees are added to the pending fees and to
    ///      `feesPaid`, and its liquidated stakes are counted as losses in the payout circuit breaker (§8.11). No
    ///      tokens move. Old ticks are accepted, so the backend can catch up after an outage.
    ///
    /// Requirements (in check order):
    /// - The caller holds `SETTLER_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The contract is not halted (`Halted`).
    /// - `ids` has 1 to 100 ids (`EmptyBatch` / `BatchSizeTooLarge`).
    /// - The market exists at this feed and leverage (`UnknownMarket`).
    /// - For each id, in order: it was opened (`UnknownPosition(id)`) on this market, so at this leverage
    ///   (`ConfigMismatch(id)`); if it is still open, then the price is positive (`InvalidPrice`), the tick is inside
    ///   the position's life, both ends included (`InvalidLiquidationWindow(id)`), and at most the market's clock skew
    ///   ahead of the chain's clock (`PriceFromFuture`), and the price touches the line, equality included
    ///   (`LiquidationPriceNotReached(id)`).
    /// - The pool's books stay within their types (`MathOverflow`).
    ///
    /// @param marketId The market's Pyth feed id; every position in `ids` must belong to it.
    /// @param leverage The market's leverage; every position in `ids` must have been opened at it.
    /// @param price The tick's price, at the market's exponent.
    /// @param publishTime The tick's publish time.
    /// @param ids The positions to liquidate.
    /// @return processed The number of positions liquidated; skipped ids are not counted.
    function liquidate(
        bytes32 marketId,
        uint16 leverage,
        int64 price,
        uint48 publishTime,
        bytes32[] calldata ids
    )
        external
        returns (uint256 processed);

    /// @notice Settles every position in `ids` that expires at the tick's second, at the tick's price: each pays
    ///         `stake × g`, with the floor and the cap applied, less the 2% winner fee on the profit paid now, or the
    ///         3% loser fee on a loss while free money is at or above the floor. Profit the pool can't pay now becomes
    ///         an IOU at the back of the repay queue.
    /// @dev For each position, in order: g and the payout at the tick's price, at the market's leverage; the split with
    ///      free money measured
    ///      with its stake still held (while anyone is owed, a new winner's whole profit is queued, so nobody jumps
    ///      the queue); the stake and its max profit released; what leaves the pool (the user's part and both fees)
    ///      leaves its total. With nothing owed, the position closes (slot 0 stays as the tombstone, slot 1 is
    ///      cleared). With profit owed, it becomes an IOU: the next queue number, the total owed, the IOU count and
    ///      slot 2 are written, and slot 1 is kept. Then {PositionSettled} is emitted, and the user's part is paid
    ///      through `_pay`: if the token refuses the transfer (a frozen user, a paused token), it waits in the user's
    ///      claimable balance ({PayoutDeferred}), and the rest of the batch goes on. Emits {PositionSkipped} per
    ///      position that had already ended. After the loop, the batch's fees are added to the pending fees and to
    ///      `feesPaid`, and its profit paid now and its losses are counted in the payout circuit breaker, which may
    ///      trip ({CircuitBreakerTripped}, after the batch's other events; §8.11). Old ticks are accepted, so the
    ///      backend can catch up after an outage.
    ///
    /// Requirements (in check order):
    /// - The caller holds `SETTLER_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The contract is not halted (`Halted`).
    /// - `ids` has 1 to 100 ids (`EmptyBatch` / `BatchSizeTooLarge`).
    /// - The market exists at this feed and leverage (`UnknownMarket`).
    /// - The price is positive (`InvalidPrice`).
    /// - The tick is at most the market's clock skew ahead of the chain's clock, so the second has passed
    ///   (`NotExpired`).
    /// - For each id, in order: it was opened (`UnknownPosition(id)`) on this market, so at this leverage
    ///   (`ConfigMismatch(id)`); if it is still open, then it expires at exactly the tick's second
    ///   (`InvalidPriceTimestamp(id)`), and the price doesn't touch its line (`LiquidateInstead(id)`: such a position
    ///   is liquidated at the same tick).
    /// - The pool's books stay within their types (`MathOverflow`).
    /// - Each payout has at least 60,000 gas, and doesn't run out of gas (`InsufficientGasForPayout`).
    ///
    /// @param marketId The market's Pyth feed id; every position in `ids` must belong to it.
    /// @param leverage The market's leverage; every position in `ids` must have been opened at it.
    /// @param price The price at the close of the expiry second, at the market's exponent.
    /// @param publishTime The tick's publish time: the positions' expiry second.
    /// @param ids The positions to settle.
    /// @return processed The number of positions settled, IOUs included; skipped ids are not counted.
    function settle(
        bytes32 marketId,
        uint16 leverage,
        int64 price,
        uint48 publishTime,
        bytes32[] calldata ids
    )
        external
        returns (uint256 processed);

    /// @notice Returns the stake of every position in `ids` that is still open once the refund delay has passed since
    ///         its expiry: the safety refund, for a bet the backend never ended. Anyone may call it, and no brake
    ///         stops it.
    /// @dev For each position, in order: its stake and max profit are released, the stake leaves the pool's total, and
    ///      the position closes (slot 0 stays as the tombstone, slot 1 is cleared). Then {PositionRefunded} is
    ///      emitted, and the whole stake is paid back through `_pay`: no fee is taken, and if the token refuses the
    ///      transfer (a frozen user, a paused token), it waits in the user's claimable balance ({PayoutDeferred}),
    ///      and the rest of the batch goes on. Free money doesn't change: the stake was held for the position and
    ///      leaves with it, so the payout circuit breaker counts nothing. Emits {PositionSkipped} per position that
    ///      had already ended.
    ///
    ///      The delay is read when the refund runs, so a change by `setRefundDelay` applies to positions already
    ///      open. Once the delay has passed, `settle` and `liquidate` can still end a position too; whichever lands
    ///      first ends it, and the other skips it. The backend settles within seconds of expiry, so this only
    ///      matters after an outage of at least the delay (24 hours by default).
    ///
    /// Requirements (in check order):
    /// - The refund is switched on: its delay is not 0 (`RefundDisabled`).
    /// - `ids` has 1 to 100 ids (`EmptyBatch` / `BatchSizeTooLarge`).
    /// - For each id, in order: it was opened (`UnknownPosition(id)`), on any market; if it is still open, then at
    ///   least the refund delay has passed since its expiry, `block.timestamp ≥ endTime + refundDelaySecs`
    ///   (`RefundTooEarly(id)`).
    /// - The pool's books stay within their types (`MathOverflow`).
    /// - Each payout has at least 60,000 gas, and doesn't run out of gas (`InsufficientGasForPayout`).
    ///
    /// @param ids The positions to refund. They may belong to different markets.
    /// @return processed The number of positions refunded; skipped ids are not counted.
    function refundExpired(bytes32[] calldata ids) external returns (uint256 processed);

    /// @notice Repays the IOU queue out of the pool's free money, strictly in queue order, from the head. Anyone may
    ///         call it: the backend after each settle batch, or an owner waiting to be paid.
    /// @dev Each repayment pays the head as much as free money allows, less the 2% winner fee (`repaySplit`): the
    ///      amount leaves the pool's total and its total owed, and the IOU's `owed` drops by it. Only free money
    ///      repays, so the stakes of open bets are never touched.
    ///
    ///      A head paid in full leaves the queue: the owed count drops, the head moves on to the next IOU, its queue
    ///      entry is deleted, and the position closes (slot 0 stays as the tombstone; slots 1 and 2 are cleared). The
    ///      first IOU that free money covers only in part keeps the rest owed and stays at the head, and the call
    ///      stops there. The call also stops when free money runs out, when the queue is empty, and after `maxCount`
    ///      repayments, so with an empty queue or no free money it changes nothing.
    ///
    ///      Emits {OwedRepaid} per repayment, then pays the owner through `_pay`: if the token refuses the transfer
    ///      (a frozen owner, a paused token), it waits in the owner's claimable balance ({PayoutDeferred}), and the
    ///      rest of the queue is still paid. After the loop, the winner fees are added to the pending fees and to
    ///      `feesPaid`, and the amounts repaid are counted as profit in the payout circuit breaker, which may trip
    ///      ({CircuitBreakerTripped}; §8.11).
    ///
    /// Requirements (in check order):
    /// - The contract is not halted (`Halted`).
    /// - `maxCount` is 1 to 50 (`InvalidMaxCount`).
    /// - The pool's books stay within their types (`MathOverflow`).
    /// - Each payout has at least 60,000 gas, and doesn't run out of gas (`InsufficientGasForPayout`).
    ///
    /// @param maxCount The most IOUs to repay in this call.
    /// @return repaid The number of IOUs repaid: each was paid in full, except perhaps the last, which may have been
    ///         paid in part and is then the new head.
    function repay(uint256 maxCount) external returns (uint256 repaid);
}
