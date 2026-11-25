// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {WithdrawPurpose} from "../types/StorageTypes.sol";

/// @title IManicFlashOptionPool
/// @author Manic
/// @notice The pool's money in and out: funding, the admin's withdrawals, claims of payouts that waited, and fee sweeps
///         (docs/ARCHITECTURE.md §8.1, §8.8). Implemented by `PoolModule`.
/// @dev Every function here works while the contract is halted or a market is paused (§8.10). The books these change
///      are in `PoolState`: `total` is held stakes plus free money, and `feesPending` and `totalClaimable` are kept
///      apart from it, so the contract's balance always covers `total + feesPending + totalClaimable` (§9).
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionPool {
    /// @notice Adds money to the pool as free money: the launch seed, or a top-up later. Anyone may fund it.
    /// @dev Pulls `amount` from the caller with `transferFrom`, so the caller must have approved it first, then checks
    ///      the contract's balance rose by exactly `amount`. Emits {PoolFunded}.
    ///
    /// Requirements (in check order):
    /// - `amount` is not zero (`InvalidAmount`).
    /// - The pool's total stays within 64 bits (`MathOverflow`).
    /// - The pull succeeds (the token's own error otherwise).
    /// - The balance rises by exactly `amount` (`TransferAmountMismatch`): a token that takes a fee, or moves nothing,
    ///   is refused.
    ///
    /// @param amount The amount to add, in base units of the token.
    function fund(uint64 amount) external;

    /// @notice Takes free money out of the pool: the launch seed back (to the fee recipient), or money for rewards (to
    ///         the rewards recipient).
    /// @dev Never touches the stakes of open bets, and keeps every open bet's max profit covered above the floor.
    ///      Emits {PoolWithdrawn}, then sends the amount; a failed transfer reverts everything.
    ///
    /// Requirements (in check order, `LeverageMath.checkWithdraw` after the role):
    /// - The caller holds `DEFAULT_ADMIN_ROLE` (`AccessControlUnauthorizedAccount`).
    /// - `amount` is not zero (`InvalidAmount`).
    /// - Nobody is owed (`OwedOutstanding`).
    /// - Free money stays at or above the floor (`BelowPoolFloor`).
    /// - What stays above the floor still covers every open bet's max profit (`OpenExposureNotCovered`).
    /// - Seed recovery stays within 500 whole tokens in total (`SeedRecoveryExceeded`).
    ///
    /// @param purpose Seed recovery or rewards; it decides the recipient and the counter.
    /// @param amount The amount to withdraw, in base units.
    function withdraw(WithdrawPurpose purpose, uint64 amount) external;

    /// @notice Pays an account the payouts that waited for it because their transfer failed (for example while it was
    ///         frozen). Anyone may call it, but the money only ever goes to `account`.
    /// @dev Emits {Claimed}, then sends the balance. If the transfer fails, everything reverts and the balance stays
    ///      claimable.
    ///
    /// Requirements (in check order):
    /// - `account` has a claimable balance (`NothingToClaim`).
    /// - The transfer to `account` succeeds (the token's own error otherwise).
    ///
    /// @param account The account to pay.
    function claim(address account) external;

    /// @notice Sends every accrued fee to the fee recipient. Anyone may call it. Fees accrue apart from the pool, so a
    ///         blocked fee recipient never stops a bet from ending.
    /// @dev Emits {FeesSwept}, then sends the fees. If the transfer fails, everything reverts and the fees stay
    ///      pending; the admin can change the recipient.
    ///
    /// Requirements (in check order):
    /// - Some fees are pending (`InvalidAmount`).
    /// - The transfer to the fee recipient succeeds (the token's own error otherwise).
    function sweepFees() external;
}
