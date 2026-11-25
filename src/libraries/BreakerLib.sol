// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors} from "../interfaces/IManicFlashOptionErrors.sol";
import {Breaker} from "../types/StorageTypes.sol";

/// @title BreakerLib
/// @author Manic
/// @notice The payout circuit breaker's window and trip logic (docs/ARCHITECTURE.md §8.11), as internal functions on
///         the stored `Breaker`. It adds up, in fixed windows, the profit users take out of the pool and the losses
///         they leave in it, both before fees, and trips when the profit out is more than the losses in plus the
///         limit. A trip stops `open` and `sell` until the operator resets it (ADR 0003).
/// @dev `FlashOptionBase` counts each call through `count` and emits the trip; `AdminModule` resets through `reset`.
///      Both write only the breaker's first slot (§6.5b), so counting a call dirties one slot; the limit, alone in
///      the second slot, is only read, and only while the breaker hasn't tripped. Kept out of the modules
///      (ADR 0006), so its rules can be tested alone, without a proxy.
/// @custom:security-contact See SECURITY.md
library BreakerLib {
    /// @notice Counts one call's winnings and losses in the current window, and trips the breaker when the window's
    ///         net profit goes over its limit.
    /// @dev A count of nothing changes nothing. Otherwise:
    ///      - fixed windows: once `windowStart + windowSecs` has come, both counters restart at zero, and the window
    ///        starts at `currentTime`. Up to twice the limit can pass across a window's end, which §8.11 accepts;
    ///      - both counters grow by the amounts (`MathOverflow` if one doesn't fit 64 bits);
    ///      - a breaker with a limit that hasn't tripped trips when `profitOut > lossIn + maxNetProfit`, summed in 256
    ///        bits, so even the largest limit can't overflow the check.
    ///      The counters run while the breaker is off (a limit of 0) or tripped, so they always show the window's
    ///      flows.
    /// @param b The breaker.
    /// @param profit The profit the call paid to users, before fees.
    /// @param loss The users' losses the call kept in the pool, before fees.
    /// @param currentTime The chain's clock.
    /// @return tripped True if this count tripped the breaker: it hadn't tripped before, and has now.
    function count(Breaker storage b, uint64 profit, uint64 loss, uint48 currentTime) internal returns (bool tripped) {
        if (profit == 0 && loss == 0) return false;
        uint64 profitOut = b.profitOut;
        uint64 lossIn = b.lossIn;
        uint48 windowStart = b.windowStart;
        if (currentTime >= uint256(windowStart) + b.windowSecs) {
            profitOut = 0;
            lossIn = 0;
            windowStart = currentTime;
        }
        profitOut = _add(profitOut, profit);
        lossIn = _add(lossIn, loss);
        b.profitOut = profitOut;
        b.lossIn = lossIn;
        b.windowStart = windowStart;
        if (b.tripped) return false;
        uint64 limit = b.maxNetProfit;
        if (limit == 0 || profitOut <= uint256(lossIn) + limit) return false;
        b.tripped = true;
        return true;
    }

    /// @notice Clears a trip and starts a fresh window at `currentTime`, with both counters at zero.
    /// @dev The limit and the window's length stay.
    /// @param b The breaker.
    /// @param currentTime The chain's clock.
    function reset(Breaker storage b, uint48 currentTime) internal {
        b.profitOut = 0;
        b.lossIn = 0;
        b.windowStart = currentTime;
        b.tripped = false;
    }

    /// @notice `x + y`, reverting `MathOverflow` when the sum doesn't fit 64 bits.
    /// @param x The counter.
    /// @param y The amount to add.
    /// @return The sum.
    function _add(uint64 x, uint64 y) private pure returns (uint64) {
        uint256 sum = uint256(x) + y;
        if (sum > type(uint64).max) revert IManicFlashOptionErrors.MathOverflow();
        // casting to uint64 is safe because the sum was just checked to fit
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(sum);
    }
}
