// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title IManicFlashOptionErrors
/// @author Manic
/// @notice Every custom error the contract can raise, declared once. The error names are part of the public
///         interface: the backend keys off them.
/// @dev The full list of docs/ARCHITECTURE.md §11.2, with final arguments: errors that can be raised for one position
///      inside a batch carry its `positionId`, so a reverted batch names the bet that broke it and the backend can
///      drop that id and resend. Errors that fail the same way for every id carry none. An error's name and argument
///      types are part of the ABI, and test/unit/IManicFlashOptionAbi.t.sol pins every selector.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionErrors {
    // ---------------------------------------------------------------------------------------------------------------
    // Switches and markets
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The contract is halted: only refunds, funding, withdrawals, claims, fee sweeps and admin work.
    error Halted();

    /// @notice No market has this id.
    error UnknownMarket();

    /// @notice The market is switched off, so nobody can open or sell.
    error LeverageDisabled();

    /// @notice The market is paused, so nobody can open or sell.
    error LeveragePaused();

    /// @notice The payout circuit breaker has tripped, so nobody can open or sell until the operator resets it.
    error BreakerTripped();

    // ---------------------------------------------------------------------------------------------------------------
    // Orders and signatures
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The signed order's deadline has passed.
    error OrderExpired();

    /// @notice The position id is zero or was used before. An id is single use, forever.
    error PositionIdUsed();

    /// @notice The signature is not the expected signer's: the order's user, or the position's user for a sale.
    error InvalidSignature();

    /// @notice The price tick was published before the user signed the order (before its `notBefore`).
    error PriceBeforeOrder();

    /// @notice A token pull moved a different amount than asked, for example because the token treated a reused or
    ///         cancelled authorisation as a silent no-op.
    /// @param expected The amount the contract asked for.
    /// @param received The amount its balance actually rose by.
    error TransferAmountMismatch(uint256 expected, uint256 received);

    // ---------------------------------------------------------------------------------------------------------------
    // Prices and parameters
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A price is zero or negative.
    error InvalidPrice();

    /// @notice A leverage parameter (the liquidation distance θ, the floor or the cap) is outside its allowed range.
    error InvalidLeverageParams();

    /// @notice A result does not fit its type, for example a payout above `type(uint64).max`.
    error MathOverflow();

    /// @notice An amount is zero where a positive amount is required.
    error InvalidAmount();

    // ---------------------------------------------------------------------------------------------------------------
    // Price times
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The price tick is older than the market's maximum age, or has no time at all.
    error PriceTooOld();

    /// @notice The price tick's time is ahead of the chain's clock by more than the allowed skew.
    error PriceFromFuture();

    /// @notice A liquidation's price tick is outside the position's life (before it opened or after it ended).
    /// @param positionId The position the tick can't liquidate.
    error InvalidLiquidationWindow(bytes32 positionId);

    /// @notice A liquidation's price does not touch the position's liquidation line.
    /// @param positionId The position that is not liquidated at this price.
    error LiquidationPriceNotReached(bytes32 positionId);

    /// @notice A settle's price tick is not at the position's expiry second.
    /// @param positionId The position whose expiry differs from the tick's time.
    error InvalidPriceTimestamp(bytes32 positionId);

    /// @notice The settle's price tick is ahead of the chain's clock, so the positions have not expired yet.
    error NotExpired();

    /// @notice The price touches the position's liquidation line, so it must be liquidated, not settled or sold.
    /// @param positionId The position to liquidate instead.
    error LiquidateInstead(bytes32 positionId);

    // ---------------------------------------------------------------------------------------------------------------
    // Positions and batches
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice No position has this id.
    /// @param positionId The unknown id.
    error UnknownPosition(bytes32 positionId);

    /// @notice The position belongs to a different market than the batch.
    /// @param positionId The position from the other market.
    error ConfigMismatch(bytes32 positionId);

    /// @notice The position is not open, so it can't be sold.
    error PositionNotOpen();

    /// @notice The batch has no ids.
    error EmptyBatch();

    /// @notice The batch has more ids than the maximum (100).
    error BatchSizeTooLarge();

    // ---------------------------------------------------------------------------------------------------------------
    // Opening
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice New positions are blocked: the total owed to winners exceeds the market's limit.
    error OpenBlockedTotalOwed();

    /// @notice New positions are blocked: the open positions' max profit would exceed the allowed share of free money.
    error OpenBlockedExposure();

    // ---------------------------------------------------------------------------------------------------------------
    // Selling
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The sale's price tick is outside the position's sell window.
    error SellWindowClosed();

    /// @notice The valuation is above what the position would pay at the current price.
    error ValuationAboveCurrentPayout();

    /// @notice The sale amount is above the valuation.
    error SellAmountExceedsValuation();

    /// @notice The early-sell fee (valuation - sale amount) is above the market's maximum.
    error SellFeeTooHigh();

    /// @notice The sale amount is below the user's signed minimum.
    error SellAmountBelowMin();

    /// @notice Winners are owed, so a sale would jump the repay queue.
    error QueueNotEmpty();

    /// @notice The pool can't pay this sale in full right now.
    error SellNotPayable();

    // ---------------------------------------------------------------------------------------------------------------
    // Repaying and refunding
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A repay call's `maxCount` is outside 1 to 50.
    error InvalidMaxCount();

    /// @notice The safety refund is switched off (its delay is 0).
    error RefundDisabled();

    /// @notice The position's expiry plus the refund delay has not passed yet.
    /// @param positionId The position that can't be refunded yet.
    error RefundTooEarly(bytes32 positionId);

    // ---------------------------------------------------------------------------------------------------------------
    // Payouts and claims
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Too little gas is left to try a payout transfer. Reverting stops a relayer from starving a payout on
    ///         purpose so that it lands in `claimable` instead of the user's wallet.
    error InsufficientGasForPayout();

    /// @notice The account has nothing to claim.
    error NothingToClaim();

    // ---------------------------------------------------------------------------------------------------------------
    // Withdrawing
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Not allowed while winners are owed.
    error OwedOutstanding();

    /// @notice The withdrawal would leave the pool's free money below its floor.
    error BelowPoolFloor();

    /// @notice The withdrawal would leave less than the floor plus every open position's max profit.
    error OpenExposureNotCovered();

    /// @notice Seed recovery would exceed 500 whole tokens in total.
    error SeedRecoveryExceeded();

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice An address that must be set is the zero address.
    error ZeroAddress();

    /// @notice The token's decimals are outside 6 to 9, so its amounts might not fit the contract's `uint64` books.
    /// @param decimals The token's decimals.
    error InvalidTokenDecimals(uint8 decimals);

    /// @notice The safety refund delay is neither 0 (off) nor at least 1 hour.
    error InvalidRefundDelay();

    /// @notice A market with this id already exists.
    error MarketExists();

    /// @notice Only the operator can unpause a market. The guardian can pause, but never resume.
    error OnlyOperatorCanUnpause();

    /// @notice Only the operator can resume a halted contract. The guardian can halt, but never resume.
    error OnlyOperatorCanUnhalt();

    /// @notice `revokeRelayer` was given a role other than `OPENER_ROLE` or `SETTLER_ROLE`. The guardian may only
    ///         revoke relayer keys; every other role is the admin's (timelocked).
    /// @param role The role that was given.
    error InvalidRelayerRole(bytes32 role);

    /// @notice The circuit breaker's window is outside 60 to 86,400 seconds.
    error InvalidBreakerParams();
}
