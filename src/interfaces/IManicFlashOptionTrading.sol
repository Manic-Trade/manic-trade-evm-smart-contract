// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../types/OrderTypes.sol";

/// @title IManicFlashOptionTrading
/// @author Manic
/// @notice Opening positions and selling them early: what the opener relayer calls with a user's signed order and the
///         price tick it saw (docs/ARCHITECTURE.md §8.2, §8.3). Implemented by `TradingModule`.
/// @dev The relayer is trusted for the price only: everything else it supplies is checked
///      against the user's signature or the market's bounds.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionTrading {
    /// @notice Opens a position: the user's signed order, at the price the relayer saw.
    /// @dev Records the position (stake held, lines locked), adds the stake to the pool's total and its held margin and
    ///      the position's max profit to the open max profit, emits {PositionOpened}, and only then pulls the stake
    ///      with the user's EIP-3009 authorisation, `a`, whose nonce is the position id. A failed pull reverts all of
    ///      it. The position's clock starts at the entry tick, not when the transaction lands.
    ///
    /// Requirements (in check order):
    /// - The caller holds `OPENER_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The contract is not halted (`Halted`).
    /// - The order has not expired: `block.timestamp` ≤ `o.deadline` (`OrderExpired`).
    /// - The market of the order's feed at the order's leverage exists (`UnknownMarket`), is enabled
    ///   (`LeverageDisabled`) and is not paused (`LeveragePaused`), and the circuit breaker has not tripped
    ///   (`BreakerTripped`).
    /// - `o.positionId` is not zero and was never used (`PositionIdUsed`).
    /// - `signature` is `o.user`'s signature of the order (`InvalidSignature`).
    /// - The terms fit the market: the stake (`InvalidAmount`); an enabled duration, θ inside its rule, the floor, and
    ///   a cap of at least the floor (`InvalidLeverageParams`).
    /// - The entry tick is at most the market's maximum age old (`PriceTooOld`) and at most its clock skew ahead
    ///   (`PriceFromFuture`).
    /// - The entry tick is at or after `o.notBefore`, so the user signed before the price was known
    ///   (`PriceBeforeOrder`).
    /// - The entry price is positive and the lines fit (`InvalidPrice` / `InvalidLeverageParams`).
    /// - The open gate lets the bet in (`OpenBlockedTotalOwed` / `OpenBlockedExposure`).
    /// - The pool's books stay within their types (`MathOverflow`).
    /// - The token moves exactly `o.stake` from `o.user` (the token's own error, or `TransferAmountMismatch`). USDG
    ///   names its own bad-signature error `InvalidSignature` too; this function checks the order's signature first.
    ///
    /// @param o The order, signed by the user before the price was known.
    /// @param signature `o.user`'s signature of `o` (EIP-712), 65 bytes from an EOA.
    /// @param t The terms the relayer adds at the tick: the entry price and time, θ, the floor and the cap.
    /// @param a The user's EIP-3009 authorisation for exactly `o.stake`, with `o.positionId` as its nonce.
    function open(OpenOrder calldata o, bytes calldata signature, OpenTerms calldata t, StakeAuth calldata a) external;

    /// @notice Sells a position before its expiry: the user's signed order, at the price and the amounts the relayer
    ///         quotes.
    /// @dev The relayer quotes the valuation (what the position is worth at the tick) and the sale amount (the
    ///      valuation less the early-sell fee); the contract bounds both with its own maths, and the user's
    ///      `minAmount` bounds the sale amount from below. A sale is never partly paid: it goes through only while
    ///      nobody is owed and the pool can pay the whole valuation now, so it can never jump the repay queue.
    ///
    ///      The position closes: its stake and max profit are released, the valuation and the loser fee leave the
    ///      pool's total, and the early-sell, winner and loser fees go into the pending fees. Then {PositionSold} is
    ///      emitted, the sale amount against the stake is counted in the payout circuit breaker as a profit or a
    ///      loss, which may trip it ({CircuitBreakerTripped}; §8.11), and the user is paid the sale amount less the
    ///      winner fee through `_pay`: if the token refuses the transfer (a frozen user, a paused token), it waits in
    ///      the user's claimable balance ({PayoutDeferred}). A sale closes its position, so its order can never be
    ///      used again.
    ///
    /// Requirements (in check order):
    /// - The caller holds `OPENER_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - The contract is not halted (`Halted`).
    /// - The order has not expired: `block.timestamp` ≤ `s.deadline` (`OrderExpired`).
    /// - The position exists (`UnknownPosition(id)`). Its market is enabled (`LeverageDisabled`) and not paused
    ///   (`LeveragePaused`), and the circuit breaker has not tripped (`BreakerTripped`).
    /// - The position is open (`PositionNotOpen`).
    /// - `signature` is the position's user's signature of the order (`InvalidSignature`).
    /// - The tick is inside the sell window: at least the market's minimum delay after the start, and more than its
    ///   cutoff before the end; and the sale lands before the end, `block.timestamp < endTime` (`SellWindowClosed`
    ///   for either).
    /// - The tick is at most the market's maximum age old (`PriceTooOld`) and at most its clock skew ahead
    ///   (`PriceFromFuture`).
    /// - The tick is at or after `s.notBefore`, so the user signed before the price was known (`PriceBeforeOrder`).
    /// - The price is positive (`InvalidPrice`) and doesn't touch the position's line (`LiquidateInstead(id)`).
    /// - The valuation is at most what the position pays at this price (`ValuationAboveCurrentPayout`); the sale
    ///   amount at most the valuation (`SellAmountExceedsValuation`); the early-sell fee at most the market's cap
    ///   (`SellFeeTooHigh`); the sale amount at least `s.minAmount` (`SellAmountBelowMin`); nobody is owed
    ///   (`QueueNotEmpty`); and the valuation within free money plus the position's own stake (`SellNotPayable`).
    /// - The pool's books stay within their types (`MathOverflow`).
    /// - The payout has at least 60,000 gas, and doesn't run out of gas (`InsufficientGasForPayout`).
    ///
    /// @param s The order, signed by the position's user before the price was known.
    /// @param signature The position's user's signature of `s` (EIP-712), 65 bytes from an EOA.
    /// @param t The terms the relayer adds at the tick: the price and its time, the valuation and the sale amount.
    function sell(SellOrder calldata s, bytes calldata signature, SellTerms calldata t) external;
}
