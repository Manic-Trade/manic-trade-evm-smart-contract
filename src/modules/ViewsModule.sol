// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlashOptionBase} from "../base/FlashOptionBase.sol";
import {IManicFlashOptionViews} from "../interfaces/IManicFlashOptionViews.sol";
import {LeverageMath} from "../libraries/LeverageMath.sol";
import {OpenOrder, SellOrder} from "../types/OrderTypes.sol";
import {Breaker, Market, PoolState, Position, Status} from "../types/StorageTypes.sol";

/// @title ViewsModule
/// @author Manic
/// @notice The contract's read-only functions (docs/ARCHITECTURE.md §8.9): the getters and the EIP-712 hash helpers.
/// @dev Every getter that reads the `Layout` carries OpenZeppelin's `nonReentrantView`, so it reverts while a
///      state-changing function holds the reentrancy guard (§15 rule 12). The hash helpers read no books, so they need
///      no guard. `version` stays in `ManicFlashOption`, the entry contract, beside everything else an upgrade changes.
/// @custom:security-contact See SECURITY.md
abstract contract ViewsModule is IManicFlashOptionViews, FlashOptionBase {
    /// @inheritdoc IManicFlashOptionViews
    function getPosition(bytes32 positionId)
        external
        view
        override
        nonReentrantView
        returns (Position memory position, uint48 endTime, int64 capPrice)
    {
        Layout storage $ = _getFlashOptionStorage();
        position = $.positions[positionId];
        // can't overflow: a stored startTime is an entry tick's time, within the clock skew of a block's timestamp
        endTime = position.startTime + position.durationSecs;
        // Only an open position or an IOU still holds its terms, its leverage among them; a closed one has cleared
        // them.
        if (position.status == Status.Open || position.status == Status.Owed) {
            capPrice = LeverageMath.capLine(position.entryPrice, position.side, position.leverage, position.capBps);
        }
    }

    /// @inheritdoc IManicFlashOptionViews
    function getMarket(
        bytes32 marketId,
        uint16 leverage
    )
        external
        view
        override
        nonReentrantView
        returns (Market memory)
    {
        (Market storage m,) = _market(marketId, leverage);
        return m;
    }

    /// @inheritdoc IManicFlashOptionViews
    function marketIdAt(uint16 index)
        external
        view
        override
        nonReentrantView
        returns (bytes32 marketId, uint16 leverage)
    {
        Layout storage $ = _getFlashOptionStorage();
        if (index >= $.marketCount) revert UnknownMarket();
        Market storage m = $.markets[index];
        return (m.marketId, m.leverage);
    }

    /// @inheritdoc IManicFlashOptionViews
    function marketCount() external view override nonReentrantView returns (uint16) {
        return _getFlashOptionStorage().marketCount;
    }

    /// @inheritdoc IManicFlashOptionViews
    function getPool() external view override nonReentrantView returns (PoolState memory) {
        return _getFlashOptionStorage().pool;
    }

    /// @inheritdoc IManicFlashOptionViews
    function freeMoney() external view override nonReentrantView returns (uint64) {
        PoolState storage pool = _getFlashOptionStorage().pool;
        // can't underflow: the total always includes the stakes it holds (§12, invariant 4)
        return pool.total - pool.lockedMargin;
    }

    /// @inheritdoc IManicFlashOptionViews
    function claimableOf(address account) external view override nonReentrantView returns (uint64) {
        return _getFlashOptionStorage().claimable[account];
    }

    /// @inheritdoc IManicFlashOptionViews
    function queueHead()
        external
        view
        override
        nonReentrantView
        returns (uint64 queueSeq, bytes32 positionId, uint64 owed)
    {
        Layout storage $ = _getFlashOptionStorage();
        queueSeq = $.pool.nextRepaySeq;
        if (queueSeq == $.pool.nextQueueSeq) return (queueSeq, bytes32(0), 0);
        positionId = $.iouQueue[queueSeq];
        owed = $.positions[positionId].owed;
    }

    /// @inheritdoc IManicFlashOptionViews
    function getBreaker() external view override nonReentrantView returns (Breaker memory) {
        return _getFlashOptionStorage().breaker;
    }

    /// @inheritdoc IManicFlashOptionViews
    function token() external view override nonReentrantView returns (IERC20) {
        return _getFlashOptionStorage().token;
    }

    /// @inheritdoc IManicFlashOptionViews
    function halted() external view override nonReentrantView returns (bool) {
        return _getFlashOptionStorage().halted;
    }

    /// @inheritdoc IManicFlashOptionViews
    function refundDelaySecs() external view override nonReentrantView returns (uint48) {
        return _getFlashOptionStorage().refundDelaySecs;
    }

    /// @inheritdoc IManicFlashOptionViews
    function recipients()
        external
        view
        override
        nonReentrantView
        returns (address feeRecipient, address rewardsRecipient)
    {
        Layout storage $ = _getFlashOptionStorage();
        return ($.feeRecipient, $.rewardsRecipient);
    }

    /// @inheritdoc IManicFlashOptionViews
    function hashOpenOrder(OpenOrder calldata o) external view override returns (bytes32) {
        return _openOrderDigest(o);
    }

    /// @inheritdoc IManicFlashOptionViews
    function hashSellOrder(SellOrder calldata s) external view override returns (bytes32) {
        return _sellOrderDigest(s);
    }
}
