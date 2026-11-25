// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ConfigParams} from "../types/ParamTypes.sol";
import {Side, Status, WithdrawPurpose} from "../types/StorageTypes.sol";

/// @title IManicFlashOptionEvents
/// @author Manic
/// @notice Every event the contract emits, declared once: the positions, the pool, the markets and settings, and the
///         payout circuit breaker. `ConfigUpdated` carries the whole `ConfigParams`, and the pool floor has an event
///         of its own, `PoolFloorUpdated`.
/// @dev The field order and types are the backend's ABI: changing either is an ABI change (docs/CONVENTIONS.md §6),
///      and test/unit/IManicFlashOptionAbi.t.sol pins every event's signature. `positionId` and `user` are indexed on
///      every position event. Prices are at the market's exponent, amounts in token base units, and times in
///      seconds. OpenZeppelin's bases add `Initialized`, `Upgraded`, `RoleGranted`, `RoleRevoked`, the
///      `DefaultAdmin*` events and `EIP712DomainChanged`. A reverted transaction emits nothing.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionEvents {
    // ---------------------------------------------------------------------------------------------------------------
    // Positions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A position was opened, with its terms as locked on-chain.
    /// @param positionId The position's id, chosen by the backend and signed by the user.
    /// @param user The position's owner.
    /// @param marketId The market's Pyth feed id.
    /// @param side Call (Higher) or Put (Lower).
    /// @param stake The margin, in base units.
    /// @param entryPrice The entry tick's price.
    /// @param priceExponent The market's price exponent (BTC: -8).
    /// @param liqPrice The liquidation line: touching it (equality counts) loses the whole stake.
    /// @param capPrice The cap line, rounded toward the entry: the payout (stake × cap) stops growing there, or one
    ///        price unit beyond it.
    /// @param thetaE7 The liquidation distance θ × 1e7.
    /// @param floorBps The least a right call pays, in bps of the stake.
    /// @param capBps The most the position pays, in bps of the stake.
    /// @param startTime The entry tick's publish time.
    /// @param endTime The expiry second the position settles at: startTime + duration.
    /// @param leverage The bet's leverage (1000 is 1000x), copied from its market at open.
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed user,
        bytes32 indexed marketId,
        Side side,
        uint64 stake,
        int64 entryPrice,
        int8 priceExponent,
        int64 liqPrice,
        int64 capPrice,
        uint32 thetaE7,
        uint16 floorBps,
        uint16 capBps,
        uint48 startTime,
        uint48 endTime,
        uint16 leverage
    );

    /// @notice A position touched its liquidation line: the user gets nothing back, and the stake stays in the pool as
    ///         free money, minus the loser fee.
    /// @param positionId The position's id.
    /// @param user The position's owner.
    /// @param side Call (Higher) or Put (Lower).
    /// @param stake The stake lost.
    /// @param liqPrice The position's liquidation line.
    /// @param price The tick that touched the line.
    /// @param publishTime The tick's publish time.
    /// @param endTime The position's expiry second.
    /// @param loserFee 3% of the stake to the fees; 0 while the pool's free money was below its floor.
    /// @param leverage The bet's leverage (1000 is 1000x), copied from its market at open.
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed user,
        Side side,
        uint64 stake,
        int64 liqPrice,
        int64 price,
        uint48 publishTime,
        uint48 endTime,
        uint64 loserFee,
        uint16 leverage
    );

    /// @notice A position was settled at its expiry price. With `owed > 0` it became an IOU at `queueSeq`; otherwise
    ///         it closed.
    /// @param positionId The position's id.
    /// @param user The position's owner.
    /// @param side Call (Higher) or Put (Lower).
    /// @param stake The position's stake.
    /// @param finalPrice The price at the expiry second.
    /// @param publishTime The final tick's publish time, equal to the expiry second.
    /// @param gBps The payout multiple at the final price, in bps.
    /// @param payout stake × gBps / 10_000: what the position earned before fees.
    /// @param paidNow What the user receives now: the stake part plus the profit the pool could pay, minus the winner
    ///        fee.
    /// @param owed The profit recorded as an IOU; 0 when paid in full.
    /// @param queueSeq The IOU's place in the repay queue; only meaningful when `owed > 0`.
    /// @param winnerFee 2% of the profit paid now.
    /// @param loserFee 3% of the loss; 0 for a winner, or while the pool's free money was below its floor.
    /// @param leverage The bet's leverage (1000 is 1000x), copied from its market at open.
    event PositionSettled(
        bytes32 indexed positionId,
        address indexed user,
        Side side,
        uint64 stake,
        int64 finalPrice,
        uint48 publishTime,
        uint16 gBps,
        uint64 payout,
        uint64 paidNow,
        uint64 owed,
        uint64 queueSeq,
        uint64 winnerFee,
        uint64 loserFee,
        uint16 leverage
    );

    /// @notice A position was sold early and closed.
    /// @param positionId The position's id.
    /// @param user The position's owner.
    /// @param side Call (Higher) or Put (Lower).
    /// @param stake The position's stake.
    /// @param price The sale's tick price.
    /// @param publishTime The sale's tick publish time.
    /// @param gNowBps The payout multiple at the sale's price, in bps.
    /// @param valuation What the sale is worth before the early-sell fee: sellAmount + sellFee.
    /// @param sellAmount The sale price; the user receives it minus `winnerFee`.
    /// @param sellFee The early-sell fee: valuation - sellAmount.
    /// @param winnerFee 2% of the profit (sellAmount - stake) on a profitable sale.
    /// @param loserFee 3% of the loss (stake - valuation) on a losing sale; 0 below the pool's floor.
    /// @param leverage The bet's leverage (1000 is 1000x), copied from its market at open.
    event PositionSold(
        bytes32 indexed positionId,
        address indexed user,
        Side side,
        uint64 stake,
        int64 price,
        uint48 publishTime,
        uint16 gNowBps,
        uint64 valuation,
        uint64 sellAmount,
        uint64 sellFee,
        uint64 winnerFee,
        uint64 loserFee,
        uint16 leverage
    );

    /// @notice An IOU was repaid, in full (`remainingOwed == 0`, it closes) or in part (it stays at the head of the
    ///         queue).
    /// @param positionId The IOU's position.
    /// @param user The position's owner.
    /// @param queueSeq The IOU's place in the repay queue.
    /// @param amount Taken off the IOU; the user receives it minus `winnerFee`.
    /// @param winnerFee 2% of `amount`.
    /// @param remainingOwed What is still owed.
    event OwedRepaid(
        bytes32 indexed positionId,
        address indexed user,
        uint64 queueSeq,
        uint64 amount,
        uint64 winnerFee,
        uint64 remainingOwed
    );

    /// @notice A position was skipped by a batch because it had already ended, for example sold in the same block.
    ///         A batch skips such ids instead of reverting.
    /// @param positionId The skipped position.
    /// @param status Its status when skipped: `Owed` or `Closed`.
    event PositionSkipped(bytes32 indexed positionId, Status status);

    /// @notice A position still open long after its expiry was refunded its stake, because the backend never ended it
    ///         (the safety refund).
    /// @param positionId The refunded position.
    /// @param user The position's owner, who receives the stake.
    /// @param stake The stake returned.
    event PositionRefunded(bytes32 indexed positionId, address indexed user, uint64 stake);

    // ---------------------------------------------------------------------------------------------------------------
    // The pool
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Money was added to the pool as free money.
    /// @param actor Who funded it.
    /// @param amount The amount added, in base units.
    event PoolFunded(address indexed actor, uint64 amount);

    /// @notice The admin took free money out of the pool.
    /// @param purpose Seed recovery (to the fee recipient) or rewards (to the rewards recipient).
    /// @param amount The amount withdrawn, in base units.
    /// @param destination The recipient it was sent to.
    event PoolWithdrawn(WithdrawPurpose purpose, uint64 amount, address indexed destination);

    /// @notice A payout couldn't be transferred (for example, the recipient is frozen), so it was credited to the
    ///         recipient's claimable balance instead.
    /// @param positionId The position the payout was for.
    /// @param to The recipient, who can claim it later.
    /// @param amount The amount credited.
    event PayoutDeferred(bytes32 indexed positionId, address indexed to, uint64 amount);

    /// @notice A claimable balance was paid out.
    /// @param account The account paid; a claim only ever pays the account itself.
    /// @param amount The amount paid.
    event Claimed(address indexed account, uint64 amount);

    /// @notice The accrued fees were sent to the fee recipient.
    /// @param to The fee recipient.
    /// @param amount The amount sent.
    event FeesSwept(address indexed to, uint64 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Markets and settings
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A market was created, switched off.
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage; with `marketId`, the market's key (ADR 0008).
    /// @param index The market's index in storage, which positions record.
    /// @param priceExponent The market's price exponent, fixed for its life.
    event MarketCreated(bytes32 indexed marketId, uint16 indexed leverage, uint16 index, int8 priceExponent);

    /// @notice A market's settings were replaced. Carries every setting as it is after the change, so a reader never
    ///         needs the earlier state.
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage.
    /// @param actor Who changed it.
    /// @param params The market's settings after the change.
    event ConfigUpdated(bytes32 indexed marketId, uint16 indexed leverage, address indexed actor, ConfigParams params);

    /// @notice A market was paused or unpaused.
    /// @param marketId The market's Pyth feed id.
    /// @param leverage The market's leverage.
    /// @param actor Who changed it.
    /// @param paused Whether the market is now paused.
    event PauseChanged(bytes32 indexed marketId, uint16 indexed leverage, address indexed actor, bool paused);

    /// @notice The whole contract was halted or resumed.
    /// @param actor Who changed it.
    /// @param halted Whether the contract is now halted.
    event HaltChanged(address indexed actor, bool halted);

    /// @notice The pool's floor changed.
    /// @param poolFloor The new floor, in base units.
    event PoolFloorUpdated(uint64 poolFloor);

    /// @notice The fee and rewards recipients changed.
    /// @param feeRecipient The new fee recipient.
    /// @param rewardsRecipient The new rewards recipient.
    event RecipientsUpdated(address indexed feeRecipient, address indexed rewardsRecipient);

    /// @notice The safety refund delay changed.
    /// @param refundDelaySecs The new delay after expiry, in seconds; 0 switches the refund off.
    event RefundDelayUpdated(uint48 refundDelaySecs);

    // ---------------------------------------------------------------------------------------------------------------
    // The payout circuit breaker
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The circuit breaker's limit or window changed.
    /// @param maxNetProfit The net profit allowed out per window, in base units; 0 switches the breaker off.
    /// @param windowSecs The window's length, in seconds.
    event CircuitBreakerUpdated(uint64 maxNetProfit, uint32 windowSecs);

    /// @notice The circuit breaker tripped: open and sell are blocked until the operator resets it.
    /// @param profitOut The profit paid to users in the window.
    /// @param lossIn The losers' losses kept by the pool in the window.
    /// @param windowStart When the window started.
    event CircuitBreakerTripped(uint64 profitOut, uint64 lossIn, uint48 windowStart);

    /// @notice The operator reset the circuit breaker, starting a fresh window.
    /// @param actor Who reset it.
    event CircuitBreakerReset(address indexed actor);
}
