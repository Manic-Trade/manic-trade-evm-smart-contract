// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, OpenTerms} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {PoolState, Position, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Repay_Fuzz_Test
/// @notice `repay`, for random queues (docs/ARCHITECTURE.md §8.7): any queue of IOUs from up to three owners, repaid
///         from any free money in two calls with any `maxCount`, an owner possibly frozen, matches the checkers' model
///         in every field. The queue stays first in, first out, open stakes are never touched, and the contract holds
///         exactly its books.
/// @dev The queue is made the real way: a small pool (exposure gate off), 1 to 12 bets of random stakes and caps,
///      settled at the cap, so the first are paid while free money lasts and the rest are owed. One bet is left open,
///      so its stake is in the books for repay not to touch. Inputs are bounded with `bound`, never `vm.assume`. CI
///      runs 10,000 cases.
contract Repay_Fuzz_Test is Settlement_Base_Test {
    function testFuzz_RepayMatchesTheModel(
        uint64 seed,
        uint8 count,
        uint256 salt,
        uint64 firstTopUp,
        uint64 secondTopUp,
        uint8 firstMax,
        uint8 secondMax,
        uint8 frozen
    )
        external
    {
        _useSmallPool(uint64(bound(seed, 1, 100e6)));
        count = uint8(bound(count, 1, 12));
        bytes32[] memory ids = new bytes32[](count);
        Position memory p;
        for (uint256 i; i < count; ++i) {
            ids[i] = keccak256(abi.encode(salt, i));
            p = _openRandom(_bettor(uint256(ids[i])), ids[i], uint256(keccak256(abi.encode(ids[i]))));
        }
        // An open bet whose stake repay must never touch: it expires a minute after the others.
        vm.warp(block.timestamp + 1);
        Position memory open = _bet(users.alice, "open", Side.Call);
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(300), _end(p), ids);
        if (frozen % 4 < 3) {
            vm.prank(usdgAdmin);
            usdg.freeze(_bettor(frozen));
        }

        // Two calls, each after a top-up of any size (none included).
        _topUp(firstTopUp);
        _expectRepaid(bound(firstMax, 1, 50), users.eve);
        _topUp(secondTopUp);
        _expectRepaid(bound(secondMax, 1, 50), users.eve);

        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.lockedMargin, open.stake, "the open stake is untouched");
        assertLe(pool.nextRepaySeq, pool.nextQueueSeq, "the head never passes the tail");
        assertEq(
            usdg.balanceOf(address(flashOption)),
            uint256(pool.total) + pool.feesPending + pool.totalClaimable,
            "the contract holds exactly its books"
        );
    }

    /// @dev Opens a bet for `user` with a random stake, floor and cap inside the market's rules, from `x`.
    function _openRandom(address user, bytes32 id, uint256 x) private returns (Position memory) {
        ConfigParams memory c = _enabledConfig();
        OpenOrder memory o = _order(user, id);
        o.stake = uint64(bound(uint64(x), c.minStake, c.maxStake));
        OpenTerms memory t = _terms();
        t.floorBps = uint16(bound(uint16(x >> 64), c.floorMinBps, c.floorMaxBps));
        t.capBps = uint16(bound(uint16(x >> 80), t.floorBps > c.capMinBps ? t.floorBps : c.capMinBps, c.capMaxBps));
        return _betWith(o, t);
    }

    /// @dev Funds the pool with up to $200 more, unless `amount` bounds to zero. The funder is never a bettor, so
    ///      never frozen.
    function _topUp(uint64 amount) private {
        amount = uint64(bound(amount, 0, 200e6));
        if (amount > 0) _fund(makeAddr("funder"), amount);
    }

    /// @dev Alice, bob or eve, from `x`.
    function _bettor(uint256 x) private view returns (address) {
        uint256 who = x % 3;
        return who == 0 ? users.alice : who == 1 ? users.bob : users.eve;
    }
}
