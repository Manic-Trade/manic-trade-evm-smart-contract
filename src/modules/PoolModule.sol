// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FlashOptionBase} from "../base/FlashOptionBase.sol";
import {IManicFlashOptionPool} from "../interfaces/IManicFlashOptionPool.sol";
import {LeverageMath} from "../libraries/LeverageMath.sol";
import {PoolState, WithdrawPurpose} from "../types/StorageTypes.sol";

/// @title PoolModule
/// @author Manic
/// @notice The pool's money in and out: funding, the admin's withdrawals, claims of payouts that waited, and fee sweeps
///         (docs/ARCHITECTURE.md §8.1, §8.8).
/// @dev These are the only places tokens enter or leave outside a bet. `withdraw`, `claim` and `sweepFees` follow
///      checks, then effects, then the transfer, with the event before the transfer; a failed transfer reverts all of
///      it, so nothing is lost. `fund` pulls first, because it must measure what actually arrived. Every function is
///      `nonReentrant`, and none checks the halt or a pause (§8.10).
/// @custom:security-contact See SECURITY.md
abstract contract PoolModule is IManicFlashOptionPool, FlashOptionBase {
    using SafeERC20 for IERC20;

    /// @inheritdoc IManicFlashOptionPool
    function fund(uint64 amount) external override nonReentrant {
        if (amount == 0) revert InvalidAmount();
        Layout storage $ = _getFlashOptionStorage();
        uint64 newTotal = _add64($.pool.total, amount);

        // Measure what arrives: a token that takes a fee, or silently moves nothing, is refused.
        IERC20 token = $.token;
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(_msgSender(), address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch(amount, received);

        $.pool.total = newTotal;
        emit PoolFunded(_msgSender(), amount);
    }

    /// @inheritdoc IManicFlashOptionPool
    function withdraw(
        WithdrawPurpose purpose,
        uint64 amount
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Layout storage $ = _getFlashOptionStorage();
        PoolState storage pool = $.pool;
        LeverageMath.checkWithdraw({
            purpose: purpose,
            amount: amount,
            free: pool.total - pool.lockedMargin,
            totalOwed: pool.totalOwed,
            poolFloor: pool.poolFloor,
            openMaxProfit: pool.openMaxProfit,
            seedRecovered: pool.seedRecovered,
            decimals: $.tokenDecimals
        });

        pool.total -= amount; // can't underflow: checkWithdraw kept free money above amount + floor
        address destination;
        if (purpose == WithdrawPurpose.SeedRecovery) {
            pool.seedRecovered = _add64(pool.seedRecovered, amount);
            destination = $.feeRecipient;
        } else {
            pool.rewardsWithdrawn = _add64(pool.rewardsWithdrawn, amount);
            destination = $.rewardsRecipient;
        }
        emit PoolWithdrawn(purpose, amount, destination);
        $.token.safeTransfer(destination, amount);
    }

    /// @inheritdoc IManicFlashOptionPool
    function claim(address account) external override nonReentrant {
        Layout storage $ = _getFlashOptionStorage();
        uint64 amount = $.claimable[account];
        if (amount == 0) revert NothingToClaim();
        $.claimable[account] = 0;
        $.pool.totalClaimable -= amount; // can't underflow: totalClaimable is the sum of every claimable balance
        emit Claimed(account, amount);
        $.token.safeTransfer(account, amount);
    }

    /// @inheritdoc IManicFlashOptionPool
    function sweepFees() external override nonReentrant {
        Layout storage $ = _getFlashOptionStorage();
        uint64 amount = $.pool.feesPending;
        if (amount == 0) revert InvalidAmount();
        $.pool.feesPending = 0;
        address to = $.feeRecipient;
        emit FeesSwept(to, amount);
        $.token.safeTransfer(to, amount);
    }
}
