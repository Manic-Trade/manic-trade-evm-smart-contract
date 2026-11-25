// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Side} from "../../src/types/StorageTypes.sol";

/// @notice What settling one position does, as `Calculations.settle` computes it.
struct Settlement {
    uint16 g; // the payout multiple, in bps
    uint64 payout; // stake × g, before fees
    uint64 paid; // profit paid now, before the winner fee
    uint64 owed; // profit queued as an IOU
    uint64 winnerFee; // 2% of `paid`
    uint64 loserFee; // 3% of the loss, or 0 below the floor
    uint64 toUser; // what the user receives now
    uint64 outOfPool; // what leaves the pool's total: the user's part and both fees
}

/// @notice What selling one position early does, as `Calculations.sell` computes it.
struct Sale {
    uint16 gNow; // the payout multiple at the sale's price, in bps
    uint64 toUser; // what the user receives: the sale amount less the winner fee
    uint64 sellFee; // the early-sell fee: the valuation less the sale amount
    uint64 winnerFee; // 2% of the profit taken (the sale amount above the stake)
    uint64 loserFee; // 3% of the loss in the valuation, or 0 below the floor
    uint64 outOfPool; // what leaves the pool's total: the valuation and the loser fee
}

/// @notice What one repayment of an IOU does, as `Calculations.repay` computes it.
struct Repayment {
    uint64 amount; // taken off the IOU and out of the pool: as much as free money allows
    uint64 winnerFee; // 2% of the amount
    uint64 toUser; // what the owner receives: the amount less the winner fee
    uint64 remaining; // what stays owed
}

/// @title Calculations
/// @author Manic
/// @notice Independent expected values for tests. These functions compute the same results as `LeverageMath` and
///         `ConfigLib` by a different route and never call them, so a test comparing the two can catch a bug in
///         either.
library Calculations {
    /// @notice The payout multiple at `leverage`, computed without `floorDiv`: a non-negative move divides with plain
    ///         `/` (which floors for non-negative numbers), and a negative move uses
    ///         `-ceil(|move| × L × 1e4 / entry)`, which is the floor of a negative quotient. Entry and price must be
    ///         positive, and the leverage 1x to 10,000x.
    function gBps(
        int64 entry,
        int64 price,
        Side side,
        uint16 leverage,
        uint16 floorBps,
        uint16 capBps
    )
        internal
        pure
        returns (uint16)
    {
        int256 favourableMove = side == Side.Call ? int256(price) - entry : int256(entry) - price;
        uint256 entryAbs = uint256(int256(entry));
        uint256 scale = uint256(leverage) * 10_000; // 1e7 at 1000x: a move of 1 bp is worth L bps of the stake
        int256 r;
        if (favourableMove >= 0) {
            r = int256((uint256(favourableMove) * scale) / entryAbs);
        } else {
            r = -int256(Math.ceilDiv(uint256(-favourableMove) * scale, entryAbs));
        }
        int256 g = 10_000 + r;
        if (r > 0 && g < int256(uint256(floorBps))) g = int256(uint256(floorBps));
        if (g > int256(uint256(capBps))) g = int256(uint256(capBps));
        if (g < 0) g = 0;
        return uint16(uint256(g));
    }

    /// @notice Whether a market's settings are valid at `leverage`, written as one conjunction of the rules in
    ///         docs/ARCHITECTURE.md §8.1, including `entryMaxAgeSecs > 0`, an open gate of 1 bp to 100% and a clock
    ///         skew of at most 30 seconds (ADR 0009). Each rule is checked over every rule pair, not with an early
    ///         exit, so it shares no structure with `ConfigLib`; the two leverage rules are written another way too: a
    ///         cap below (L + 1) × 1x, and a widest line of at most (1e7 − 1) / L.
    function isValidConfig(ConfigParams memory c, uint16 leverage) internal pure returns (bool ok) {
        ok = leverage >= 1 && leverage <= 10_000;
        ok = ok && c.minStake > 0 && c.minStake <= c.maxStake;
        ok = ok && c.floorMinBps > 10_000 && c.floorMinBps <= c.floorMaxBps;
        ok = ok && c.capMinBps > 10_000 && c.capMinBps <= c.capMaxBps && c.capMaxBps <= 40_000;
        ok = ok && c.floorMaxBps <= c.capMaxBps;
        // A short gains at most L × its stake (the price can't fall below 0), so it can only reach a cap below (L+1)x.
        ok = ok && uint256(c.capMaxBps) < (uint256(leverage) + 1) * 10_000;
        uint256 widestTheta = leverage == 0 ? 0 : (1e7 - 1) / leverage; // the largest θ with θ × L < 1e7
        ok = ok && c.maxSellFeeBps <= 10_000;
        ok = ok && c.entryMaxAgeSecs > 0;
        ok = ok && c.maxExposureBps >= 1 && c.maxExposureBps <= 10_000;
        ok = ok && c.clockSkewSecs <= 30;
        for (uint256 i; i < 5; ++i) {
            bool unused = c.durations[i].durationSecs == 0;
            bool empty = c.durations[i].thetaMinE7 == 0 && c.durations[i].thetaMaxE7 == 0 && !c.durations[i].enabled;
            bool thetaOk = c.durations[i].thetaMinE7 > 0 && c.durations[i].thetaMinE7 <= c.durations[i].thetaMaxE7
                && c.durations[i].thetaMaxE7 <= widestTheta;
            ok = ok && (unused ? empty : thetaOk);
            for (uint256 j; j < 5; ++j) {
                bool duplicate = i != j && !unused && c.durations[j].durationSecs == c.durations[i].durationSecs;
                ok = ok && !duplicate;
            }
        }
    }

    /// @notice What settling a position pays and keeps, computed straight from the rules of docs/ARCHITECTURE.md §8.5
    ///         and §9, without `LeverageMath`.
    /// @dev The user's own stake comes back first, all of it on a win; profit is paid from free money only while
    ///      nobody is owed, and the rest is owed. The winner fee is 2% of the profit paid now, the loser fee 3% of the
    ///      loss while free money is at or above the floor. Each fee rounds down.
    /// @param stake The position's stake.
    /// @param g The payout multiple at the final price, in bps (from `gBps`).
    /// @param free The pool's free money with this position's stake still held.
    /// @param totalOwed The pool's total owed before this position.
    /// @param poolFloor The pool's floor.
    function settle(
        uint64 stake,
        uint16 g,
        uint64 free,
        uint64 totalOwed,
        uint64 poolFloor
    )
        internal
        pure
        returns (Settlement memory r)
    {
        r.g = g;
        r.payout = uint64(uint256(stake) * g / 10_000);
        uint64 own = r.payout < stake ? r.payout : stake;
        uint64 profit = r.payout - own;
        if (totalOwed == 0) r.paid = profit < free ? profit : free;
        r.owed = profit - r.paid;
        r.winnerFee = uint64(uint256(r.paid) * 200 / 10_000);
        r.loserFee = free >= poolFloor ? uint64(uint256(stake - own) * 300 / 10_000) : 0;
        r.toUser = own + r.paid - r.winnerFee;
        r.outOfPool = own + r.paid + r.loserFee;
    }

    /// @notice What an early sale pays and keeps, computed straight from the rules of docs/ARCHITECTURE.md §8.3 and
    ///         §9, without `LeverageMath`.
    /// @dev The winner fee is 2% of what the user takes above the stake; the early-sell fee is what the relayer keeps
    ///      back from the valuation; the loser fee is 3% of the valuation's shortfall from the stake while free money
    ///      is at or above the floor. Each fee rounds down. `gNow` is left for the caller.
    /// @param stake The position's stake.
    /// @param valuation The relayer's valuation.
    /// @param sellAmount The relayer's sale amount.
    /// @param free The pool's free money with this position's stake still held.
    /// @param poolFloor The pool's floor.
    function sell(
        uint64 stake,
        uint64 valuation,
        uint64 sellAmount,
        uint64 free,
        uint64 poolFloor
    )
        internal
        pure
        returns (Sale memory r)
    {
        uint64 profit = sellAmount > stake ? sellAmount - stake : 0;
        r.winnerFee = uint64(uint256(profit) * 200 / 10_000);
        r.toUser = sellAmount - r.winnerFee;
        r.sellFee = valuation - sellAmount;
        uint64 loss = stake > valuation ? stake - valuation : 0;
        r.loserFee = free >= poolFloor ? uint64(uint256(loss) * 300 / 10_000) : 0;
        r.outOfPool = valuation + r.loserFee;
    }

    /// @notice What repaying an IOU of `owed` from `free` money does, computed straight from the rules of
    ///         docs/ARCHITECTURE.md §8.7, without `LeverageMath`: as much as free money allows, with 2% of it as the
    ///         winner fee, rounded down.
    function repay(uint64 owed, uint64 free) internal pure returns (Repayment memory r) {
        r.amount = owed < free ? owed : free;
        r.winnerFee = uint64(uint256(r.amount) * 200 / 10_000);
        r.toUser = r.amount - r.winnerFee;
        r.remaining = owed - r.amount;
    }

    /// @notice The loser fee of a liquidation: 3% of the stake while free money is at or above the floor, rounded
    ///         down; otherwise nothing.
    function liquidationFee(uint64 stake, uint64 free, uint64 poolFloor) internal pure returns (uint64) {
        return free >= poolFloor ? uint64(uint256(stake) * 300 / 10_000) : 0;
    }

    /// @notice The most a position can win above its stake: `stake × (cap − 1)`, rounded down.
    function maxProfit(uint64 stake, uint16 capBps) internal pure returns (uint64) {
        return uint64(uint256(stake) * (capBps - 10_000) / 10_000);
    }
}
