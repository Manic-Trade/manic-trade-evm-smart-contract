// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlashOptionBase} from "../base/FlashOptionBase.sol";
import {IManicFlashOptionTrading} from "../interfaces/IManicFlashOptionTrading.sol";
import {IUSDG} from "../interfaces/external/IUSDG.sol";
import {ConfigLib} from "../libraries/ConfigLib.sol";
import {LeverageMath} from "../libraries/LeverageMath.sol";
import {SellSplit} from "../types/MathTypes.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../types/OrderTypes.sol";
import {Market, PoolState, Position, Side, Status} from "../types/StorageTypes.sol";

/// @title TradingModule
/// @author Manic
/// @notice Opening positions and selling them early: what the opener relayer calls with a user's signed order and the
///         price tick it saw (docs/ARCHITECTURE.md §8.2, §8.3).
/// @dev `open` runs its checks in the order its interface lists, then writes the position and the books, emits
///      {PositionOpened}, and only then pulls the stake. A failed pull reverts all of it. `sell` runs its checks the
///      same way, then closes the position through the books helpers every ending shares, emits {PositionSold},
///      counts the sale's profit or loss in the payout circuit breaker (`_countForBreaker`, §8.11), and only then
///      pays the user through `_pay`, which never reverts on a refused transfer. The
///      checks are split into private functions only to keep each within the legacy pipeline's stack. The private
///      functions are listed in solhint's order, state-changing before view; `open` runs `_checkOrder`,
///      `_checkTerms`, `_recordOpen`, `_emitOpened` and `_pullStake`, and `sell` runs `_checkSale`, `_priceSale`,
///      `_recordSale` and `_emitSold`.
/// @custom:security-contact See SECURITY.md
abstract contract TradingModule is IManicFlashOptionTrading, FlashOptionBase {
    /// @dev The fields of {PositionOpened}, in its order. The event is emitted from this struct because, emitted
    ///      inline, its 15 fields don't fit the legacy pipeline's stack (docs/CONVENTIONS.md §7).
    struct Opened {
        bytes32 positionId;
        address user;
        bytes32 marketId;
        Side side;
        uint64 stake;
        int64 entryPrice;
        int8 priceExponent;
        int64 liqPrice;
        int64 capPrice;
        uint32 thetaE7;
        uint16 floorBps;
        uint16 capBps;
        uint48 startTime;
        uint48 endTime;
        uint16 leverage;
    }

    /// @dev The fields of {PositionSold}, in its order. The event is emitted from this struct because, emitted inline,
    ///      its 13 fields don't fit the legacy pipeline's stack (docs/CONVENTIONS.md §7).
    struct Sold {
        bytes32 positionId;
        address user;
        Side side;
        uint64 stake;
        int64 price;
        uint48 publishTime;
        uint16 gNowBps;
        uint64 valuation;
        uint64 sellAmount;
        uint64 sellFee;
        uint64 winnerFee;
        uint64 loserFee;
        uint16 leverage;
    }

    /// @inheritdoc IManicFlashOptionTrading
    function open(
        OpenOrder calldata o,
        bytes calldata signature,
        OpenTerms calldata t,
        StakeAuth calldata a
    )
        external
        override
        nonReentrant
        onlyRole(OPENER_ROLE)
    {
        (Market storage m, uint16 index) = _checkOrder(o, signature);
        (Opened memory e, uint64 maxProfit) = _checkTerms(m, o, t);
        _recordOpen({o: o, t: t, index: index, leverage: e.leverage, liqPrice: e.liqPrice, maxProfit: maxProfit});
        _emitOpened(e);
        _pullStake(o, a);
    }

    /// @inheritdoc IManicFlashOptionTrading
    function sell(
        SellOrder calldata s,
        bytes calldata signature,
        SellTerms calldata t
    )
        external
        override
        nonReentrant
        onlyRole(OPENER_ROLE)
    {
        (Position storage p, Market storage m) = _checkSale(s, signature, t);
        (Sold memory e, SellSplit memory split) = _priceSale(p, m, s, t);
        _recordSale(p, split);
        _emitSold(e);
        // The breaker counts the sale's profit or loss before fees: the sale amount against the stake.
        if (e.sellAmount > e.stake) _countForBreaker(e.sellAmount - e.stake, 0);
        else _countForBreaker(0, e.stake - e.sellAmount);
        _pay(e.user, split.toUser, s.positionId);
    }

    /// @notice Writes the new position and holds its stake and max profit in the pool's books.
    /// @dev The position takes slots 0 and 1. Slot 2 is written only if the position later becomes an IOU. The stake
    ///      counts in the total and in the held margin, so free money is unchanged and no one else's payout can use it.
    ///      Each counter is checked (`MathOverflow`).
    /// @param o The order.
    /// @param t The relayer's terms.
    /// @param index The market's index.
    /// @param leverage The market's leverage, which the bet keeps.
    /// @param liqPrice The liquidation line.
    /// @param maxProfit The position's max profit.
    function _recordOpen(
        OpenOrder calldata o,
        OpenTerms calldata t,
        uint16 index,
        uint16 leverage,
        int64 liqPrice,
        uint64 maxProfit
    )
        private
    {
        Layout storage $ = _getFlashOptionStorage();
        Position storage p = $.positions[o.positionId];
        p.user = o.user;
        p.marketIdx = index;
        p.side = o.side;
        p.status = Status.Open;
        p.startTime = t.entryPublishTime;
        p.durationSecs = o.durationSecs;
        p.stake = o.stake;
        p.entryPrice = t.entryPrice;
        p.liqPrice = liqPrice;
        p.floorBps = t.floorBps;
        p.capBps = t.capBps;
        p.leverage = leverage;

        PoolState storage pool = $.pool;
        pool.total = _add64(pool.total, o.stake);
        pool.lockedMargin = _add64(pool.lockedMargin, o.stake);
        pool.openMaxProfit = _add64(pool.openMaxProfit, maxProfit);
        uint32 openPositions = pool.openPositions;
        if (openPositions == type(uint32).max) revert MathOverflow();
        pool.openPositions = openPositions + 1;
    }

    /// @notice Emits {PositionOpened} from its fields.
    /// @param e The event's fields.
    function _emitOpened(Opened memory e) private {
        emit PositionOpened({
            positionId: e.positionId,
            user: e.user,
            marketId: e.marketId,
            side: e.side,
            stake: e.stake,
            entryPrice: e.entryPrice,
            priceExponent: e.priceExponent,
            liqPrice: e.liqPrice,
            capPrice: e.capPrice,
            thetaE7: e.thetaE7,
            floorBps: e.floorBps,
            capBps: e.capBps,
            startTime: e.startTime,
            endTime: e.endTime,
            leverage: e.leverage
        });
    }

    /// @notice Closes a sold position and moves the sale through the pool's books.
    /// @dev The stake and its max profit are released; the valuation and the loser fee leave the total (the user's
    ///      part and every fee: `outOfPool`); `transferred` counts what the user gets; the early-sell, winner and loser
    ///      fees accrue in the pending fees. Then the position closes (slot 0 kept, slot 1 cleared). Each counter is
    ///      checked (`MathOverflow`).
    /// @param p The position's storage.
    /// @param split The sale's split.
    function _recordSale(Position storage p, SellSplit memory split) private {
        PoolState storage pool = _getFlashOptionStorage().pool;
        _releaseMargin(pool, p.stake, p.capBps);
        // can't underflow: checkSell kept the valuation within free money plus this stake, and the loser fee is at
        // most the rest of the stake
        pool.total -= LeverageMath.outOfPool(split);
        pool.transferred = _add64(pool.transferred, split.toUser);
        _accrueFees(LeverageMath.fees(split));
        _closePosition(p);
    }

    /// @notice Emits {PositionSold} from its fields.
    /// @param e The event's fields.
    function _emitSold(Sold memory e) private {
        emit PositionSold({
            positionId: e.positionId,
            user: e.user,
            side: e.side,
            stake: e.stake,
            price: e.price,
            publishTime: e.publishTime,
            gNowBps: e.gNowBps,
            valuation: e.valuation,
            sellAmount: e.sellAmount,
            sellFee: e.sellFee,
            winnerFee: e.winnerFee,
            loserFee: e.loserFee,
            leverage: e.leverage
        });
    }

    /// @notice Pulls exactly the stake from the user, with their EIP-3009 authorisation.
    /// @dev Only the contract, the payee, can submit the authorisation, so nobody can front-run it, and nothing stays
    ///      approved. The balance must rise by exactly the stake (`TransferAmountMismatch`). That also catches USDG's
    ///      silent no-op when the nonce, the position id, was already used or cancelled: no revert and no transfer.
    /// @param o The order.
    /// @param a The user's authorisation.
    function _pullStake(OpenOrder calldata o, StakeAuth calldata a) private {
        IERC20 token = _getFlashOptionStorage().token;
        uint256 balanceBefore = token.balanceOf(address(this));
        // The balance read around the pull is the check itself: nothing can re-enter (`nonReentrant`), and any
        // other change to the balance during the call fails it, as `received` must equal the stake exactly.
        // See audit/static-analysis.md.
        // slither-disable-next-line reentrancy-balance
        IUSDG(address(token))
            .receiveWithAuthorization({
                from: o.user,
                to: address(this),
                value: o.stake,
                validAfter: a.validAfter,
                validBefore: a.validBefore,
                nonce: o.positionId,
                signature: a.signature
            });
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != o.stake) revert TransferAmountMismatch(o.stake, received);
    }

    /// @notice The checks on the order itself: the brakes, the deadline, the market, the position id and the
    ///         user's signature (docs/ARCHITECTURE.md §8.2, checks 1 to 5).
    /// @param o The order.
    /// @param signature The user's signature of it.
    /// @return m The market's storage.
    /// @return index The market's index, which the position records.
    function _checkOrder(
        OpenOrder calldata o,
        bytes calldata signature
    )
        private
        view
        returns (Market storage m, uint16 index)
    {
        Layout storage $ = _getFlashOptionStorage();
        if ($.halted) revert Halted();
        if (block.timestamp > o.deadline) revert OrderExpired();
        (m, index) = _market(o.marketId, o.leverage); // the leverage the user signed picks the market
        if (!m.enabled) revert LeverageDisabled();
        if (m.paused) revert LeveragePaused();
        if ($.breaker.tripped) revert BreakerTripped();
        if (o.positionId == bytes32(0) || $.positions[o.positionId].status != Status.None) revert PositionIdUsed();
        _checkSignature(o.user, _openOrderDigest(o), signature);
    }

    /// @notice The checks on the terms, in this order: the market's bounds, the entry tick's time and `notBefore`, the
    ///         lines and the open gate (docs/ARCHITECTURE.md §8.2, checks 6 to 10).
    /// @dev The position's clock starts at the entry tick, not when the transaction lands, so a slow transaction never
    ///      lengthens a bet. Free money is the pool's total less the stakes it holds.
    /// @param m The market's storage.
    /// @param o The order.
    /// @param t The relayer's terms.
    /// @return e The fields of {PositionOpened}.
    /// @return maxProfit The most the position can win, which the pool must keep covered while it is open.
    function _checkTerms(
        Market storage m,
        OpenOrder calldata o,
        OpenTerms calldata t
    )
        private
        view
        returns (Opened memory e, uint64 maxProfit)
    {
        ConfigLib.validateOpen({
            m: m,
            stake: o.stake,
            durationSecs: o.durationSecs,
            thetaE7: t.thetaE7,
            floorBps: t.floorBps,
            capBps: t.capBps
        });
        LeverageMath.checkEntryTime(block.timestamp, t.entryPublishTime, m.entryMaxAgeSecs, m.clockSkewSecs);
        if (t.entryPublishTime < o.notBefore) revert PriceBeforeOrder();
        (e.liqPrice, e.capPrice) = LeverageMath.lines({
            entry: t.entryPrice,
            side: o.side,
            leverage: m.leverage, // the market's own
            thetaE7: t.thetaE7,
            capBps: t.capBps
        });
        maxProfit = LeverageMath.maxProfit(o.stake, t.capBps);
        PoolState storage pool = _getFlashOptionStorage().pool;
        LeverageMath.openGate({
            totalOwed: pool.totalOwed,
            maxTotalOwed: m.maxTotalOwed,
            openMaxProfit: pool.openMaxProfit,
            newMaxProfit: maxProfit,
            free: pool.total - pool.lockedMargin,
            maxExposureBps: m.maxExposureBps
        });

        e.positionId = o.positionId;
        e.user = o.user;
        e.marketId = o.marketId;
        e.side = o.side;
        e.stake = o.stake;
        e.entryPrice = t.entryPrice;
        e.priceExponent = m.priceExponent;
        e.thetaE7 = t.thetaE7;
        e.leverage = m.leverage; // the bet keeps it
        e.floorBps = t.floorBps;
        e.capBps = t.capBps;
        e.startTime = t.entryPublishTime;
        // can't overflow: checkEntryTime keeps the tick within the clock skew of block.timestamp
        e.endTime = t.entryPublishTime + o.durationSecs;
    }

    /// @notice The checks on the sale order and its tick: the brakes, the deadline, the position, the user's signature,
    ///         the sell window, the tick's time and `notBefore` (docs/ARCHITECTURE.md §8.3, checks 1 to 8).
    /// @param s The order.
    /// @param signature The position's user's signature of it.
    /// @param t The relayer's terms.
    /// @return p The position's storage.
    /// @return m Its market's storage.
    function _checkSale(
        SellOrder calldata s,
        bytes calldata signature,
        SellTerms calldata t
    )
        private
        view
        returns (Position storage p, Market storage m)
    {
        Layout storage $ = _getFlashOptionStorage();
        if ($.halted) revert Halted();
        if (block.timestamp > s.deadline) revert OrderExpired();
        p = $.positions[s.positionId];
        if (p.status == Status.None) revert UnknownPosition(s.positionId);
        m = $.markets[p.marketIdx];
        if (!m.enabled) revert LeverageDisabled();
        if (m.paused) revert LeveragePaused();
        if ($.breaker.tripped) revert BreakerTripped();
        if (p.status != Status.Open) revert PositionNotOpen();
        _checkSignature(p.user, _sellOrderDigest(s), signature);

        uint48 startTime = p.startTime;
        // can't overflow: startTime is an entry tick's time, within the clock skew of a past block's timestamp
        uint48 endTime = startTime + p.durationSecs;
        LeverageMath.checkSellWindow({
            startTime: startTime,
            endTime: endTime,
            publishTime: t.publishTime,
            minDelaySecs: m.sellMinDelaySecs,
            cutoffSecs: m.sellCutoffSecs
        });
        // The sale must also land before the bet ends. A tick inside the window may still be up to its maximum age
        // old, so a sale priced just before the cutoff could otherwise land after the expiry, when settle can end the
        // same bet.
        if (block.timestamp >= endTime) revert SellWindowClosed();
        LeverageMath.checkEntryTime(block.timestamp, t.publishTime, m.entryMaxAgeSecs, m.clockSkewSecs);
        if (t.publishTime < s.notBefore) revert PriceBeforeOrder();
    }

    /// @notice The checks on the price and the amounts, in this order, and the sale's split (docs/ARCHITECTURE.md
    ///         §8.3, checks 9 and 10).
    /// @dev Free money is measured with the position's stake still held (`freeBefore`), for both the payability check
    ///      and the loser fee. The relayer's valuation is bounded by what the position pays at this
    ///      price (`gNow`), so a sale can never pay more than a settle at the same price would.
    /// @param p The position's storage.
    /// @param m Its market's storage.
    /// @param s The order.
    /// @param t The relayer's terms.
    /// @return e The fields of {PositionSold}.
    /// @return split The sale's split.
    function _priceSale(
        Position storage p,
        Market storage m,
        SellOrder calldata s,
        SellTerms calldata t
    )
        private
        view
        returns (Sold memory e, SellSplit memory split)
    {
        if (t.price <= 0) revert InvalidPrice();
        if (LeverageMath.touched(t.price, p.liqPrice, p.side)) revert LiquidateInstead(s.positionId);
        e.stake = p.stake;
        e.gNowBps = LeverageMath.gBps({
            entry: p.entryPrice,
            price: t.price,
            side: p.side,
            leverage: p.leverage, // the bet's own, copied from its market at open
            floorBps: p.floorBps,
            capBps: p.capBps
        });
        PoolState storage pool = _getFlashOptionStorage().pool;
        uint64 freeBefore = pool.total - pool.lockedMargin;
        LeverageMath.checkSell({
            stake: e.stake,
            gNowBps: e.gNowBps,
            valuation: t.valuation,
            sellAmount: t.sellAmount,
            minAmount: s.minAmount,
            maxSellFeeBps: m.maxSellFeeBps,
            totalOwed: pool.totalOwed,
            freeBefore: freeBefore
        });
        split = LeverageMath.sellSplit({
            stake: e.stake,
            valuation: t.valuation,
            sellAmount: t.sellAmount,
            freeBefore: freeBefore,
            poolFloor: pool.poolFloor
        });

        e.positionId = s.positionId;
        e.user = p.user;
        e.leverage = p.leverage;
        e.side = p.side;
        e.price = t.price;
        e.publishTime = t.publishTime;
        e.valuation = t.valuation;
        e.sellAmount = t.sellAmount;
        e.sellFee = split.sellFee;
        e.winnerFee = split.winnerFee;
        e.loserFee = split.loserFee;
    }
}
