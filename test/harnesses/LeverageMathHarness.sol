// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {LeverageMath} from "../../src/libraries/LeverageMath.sol";
import {RepaySplit, SellSplit, SettleSplit} from "../../src/types/MathTypes.sol";
import {Side, WithdrawPurpose} from "../../src/types/StorageTypes.sol";

/// @title LeverageMathHarness
/// @author Manic
/// @notice Exposes `LeverageMath`'s internal functions as external calls, so tests can call them and check their
///         reverts with `vm.expectRevert` (which only catches reverts from a call, not from inlined internal code).
/// @dev One wrapper per library function and constant, with the same names. No logic of its own.
contract LeverageMathHarness {
    function BPS() external pure returns (uint256) {
        return LeverageMath.BPS;
    }

    function E7() external pure returns (uint256) {
        return LeverageMath.E7;
    }

    function MAX_LEVERAGE_CAP_BPS() external pure returns (uint16) {
        return LeverageMath.MAX_LEVERAGE_CAP_BPS;
    }

    function WINNER_FEE_BPS() external pure returns (uint16) {
        return LeverageMath.WINNER_FEE_BPS;
    }

    function LOSER_FEE_BPS() external pure returns (uint16) {
        return LeverageMath.LOSER_FEE_BPS;
    }

    function SEED_RECOVERY_CAP_TOKENS() external pure returns (uint64) {
        return LeverageMath.SEED_RECOVERY_CAP_TOKENS;
    }

    function MIN_LEVERAGE() external pure returns (uint16) {
        return LeverageMath.MIN_LEVERAGE;
    }

    function MAX_LEVERAGE() external pure returns (uint16) {
        return LeverageMath.MAX_LEVERAGE;
    }

    function floorDiv(int256 a, int256 b) external pure returns (int256) {
        return LeverageMath.floorDiv(a, b);
    }

    function leverageAllowed(uint16 leverage) external pure returns (bool) {
        return LeverageMath.leverageAllowed(leverage);
    }

    function thetaWithinLimit(uint32 thetaE7, uint16 leverage) external pure returns (bool) {
        return LeverageMath.thetaWithinLimit(thetaE7, leverage);
    }

    function capReachable(uint16 capBps, uint16 leverage) external pure returns (bool) {
        return LeverageMath.capReachable(capBps, leverage);
    }

    function lines(
        int64 entry,
        Side side,
        uint16 leverage,
        uint32 thetaE7,
        uint16 capBps
    )
        external
        pure
        returns (int64, int64)
    {
        return LeverageMath.lines(entry, side, leverage, thetaE7, capBps);
    }

    function capLine(int64 entry, Side side, uint16 leverage, uint16 capBps) external pure returns (int64) {
        return LeverageMath.capLine(entry, side, leverage, capBps);
    }

    function gBps(
        int64 entry,
        int64 price,
        Side side,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        external
        pure
        returns (uint16)
    {
        return LeverageMath.gBps(entry, price, side, leverage, floorBps, capBps);
    }

    function payout(uint64 stake, uint16 multipleBps) external pure returns (uint64) {
        return LeverageMath.payout(stake, multipleBps);
    }

    function maxProfit(uint64 stake, uint16 capBps) external pure returns (uint64) {
        return LeverageMath.maxProfit(stake, capBps);
    }

    function touched(int64 price, int64 liqPrice, Side side) external pure returns (bool) {
        return LeverageMath.touched(price, liqPrice, side);
    }

    function checkLiquidation(
        bytes32 positionId,
        uint256 startTime,
        uint256 endTime,
        int64 liqPrice,
        Side side,
        int64 price,
        uint256 publishTime,
        uint256 currentTime,
        uint8 clockSkewSecs
    )
        external
        pure
    {
        LeverageMath.checkLiquidation({
            positionId: positionId,
            startTime: startTime,
            endTime: endTime,
            liqPrice: liqPrice,
            side: side,
            price: price,
            publishTime: publishTime,
            currentTime: currentTime,
            clockSkewSecs: clockSkewSecs
        });
    }

    function checkEntryTime(
        uint256 currentTime,
        uint256 publishTime,
        uint8 maxAgeSecs,
        uint8 clockSkewSecs
    )
        external
        pure
    {
        LeverageMath.checkEntryTime(currentTime, publishTime, maxAgeSecs, clockSkewSecs);
    }

    function openGate(
        uint64 totalOwed,
        uint64 maxTotalOwed,
        uint64 openMaxProfit,
        uint64 newMaxProfit,
        uint64 free,
        uint32 maxExposureBps
    )
        external
        pure
    {
        LeverageMath.openGate(totalOwed, maxTotalOwed, openMaxProfit, newMaxProfit, free, maxExposureBps);
    }

    function fee(uint64 amount, uint16 feeBps) external pure returns (uint64) {
        return LeverageMath.fee(amount, feeBps);
    }

    function winnerFee(uint64 profitPaid) external pure returns (uint64) {
        return LeverageMath.winnerFee(profitPaid);
    }

    function loserFee(uint64 loss, uint64 freeBefore, uint64 poolFloor) external pure returns (uint64) {
        return LeverageMath.loserFee(loss, freeBefore, poolFloor);
    }

    function settleSplit(
        uint64 payoutAmount,
        uint64 stake,
        uint64 freeBefore,
        uint64 totalOwed,
        uint64 poolFloor
    )
        external
        pure
        returns (SettleSplit memory)
    {
        return LeverageMath.settleSplit(payoutAmount, stake, freeBefore, totalOwed, poolFloor);
    }

    function toUser(SettleSplit memory split) external pure returns (uint64) {
        return LeverageMath.toUser(split);
    }

    function outOfPool(SettleSplit memory split) external pure returns (uint64) {
        return LeverageMath.outOfPool(split);
    }

    function checkSellWindow(
        uint256 startTime,
        uint256 endTime,
        uint256 publishTime,
        uint16 minDelaySecs,
        uint16 cutoffSecs
    )
        external
        pure
    {
        LeverageMath.checkSellWindow(startTime, endTime, publishTime, minDelaySecs, cutoffSecs);
    }

    function checkSell(
        uint64 stake,
        uint16 gNowBps,
        uint64 valuation,
        uint64 sellAmount,
        uint64 minAmount,
        uint16 maxSellFeeBps,
        uint64 totalOwed,
        uint64 freeBefore
    )
        external
        pure
    {
        LeverageMath.checkSell({
            stake: stake,
            gNowBps: gNowBps,
            valuation: valuation,
            sellAmount: sellAmount,
            minAmount: minAmount,
            maxSellFeeBps: maxSellFeeBps,
            totalOwed: totalOwed,
            freeBefore: freeBefore
        });
    }

    function sellSplit(
        uint64 stake,
        uint64 valuation,
        uint64 sellAmount,
        uint64 freeBefore,
        uint64 poolFloor
    )
        external
        pure
        returns (SellSplit memory)
    {
        return LeverageMath.sellSplit(stake, valuation, sellAmount, freeBefore, poolFloor);
    }

    function fees(SellSplit memory split) external pure returns (uint64) {
        return LeverageMath.fees(split);
    }

    function outOfPool(SellSplit memory split) external pure returns (uint64) {
        return LeverageMath.outOfPool(split);
    }
}
