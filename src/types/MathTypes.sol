// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

// The results of LeverageMath's money splits. They are computed and used within one call and never stored, so
// they may still change before mainnet (unlike StorageTypes.sol).

/// @notice How an expiry payout splits, fees included.
/// @dev The user receives `own + paid - winnerFee`, and `own + paid + loserFee` leaves the pool's books
///      (`LeverageMath.toUser` and `LeverageMath.outOfPool`).
struct SettleSplit {
    // Paid back out of the position's own held stake: min(payout, stake).
    uint64 own;
    // Profit paid now out of the pool's free money, before the winner fee.
    uint64 paid;
    // Profit the pool could not pay now, recorded as an IOU in the repay queue.
    uint64 owed;
    // 2% of `paid`, to the fee recipient.
    uint64 winnerFee;
    // 3% of the loss (stake - payout), to the fee recipient; 0 while the pool is below its floor.
    uint64 loserFee;
}

/// @notice How an early sale splits, fees included.
/// @dev The fee recipient receives `sellFee + winnerFee + loserFee` (`LeverageMath.fees`), and that plus `toUser`
///      leaves the pool's books (`LeverageMath.outOfPool`).
struct SellSplit {
    // What the user receives: sellAmount - winnerFee.
    uint64 toUser;
    // The early-sell fee: valuation - sellAmount.
    uint64 sellFee;
    // 2% of the profit (sellAmount - stake) on a profitable sale.
    uint64 winnerFee;
    // 3% of the loss (stake - valuation) on a losing sale; 0 while the pool is below its floor.
    uint64 loserFee;
}

/// @notice How one repayment of an IOU splits.
struct RepaySplit {
    // Taken off the IOU and out of the pool: min(owed, free).
    uint64 amount;
    // 2% of `amount`, to the fee recipient.
    uint64 winnerFee;
    // What the owner receives: amount - winnerFee.
    uint64 toUser;
    // What stays owed: owed - amount.
    uint64 remaining;
}
