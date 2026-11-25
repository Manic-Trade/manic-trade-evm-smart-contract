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
}
