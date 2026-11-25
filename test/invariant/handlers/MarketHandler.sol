// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BaseHandler, HandlerSetup} from "./BaseHandler.sol";

/// @title MarketHandler
/// @notice Moves the world the contract lives in: the price, tick by tick, and the chain's clock.
/// @dev The moves are sized to the bets of BTC's three markets, which share the one price. A tick moves the price by up
///      to 8 bp, and a bet's line sits 2.25 to 17.64 bp from its entry (1000x's launch θ range is 2.25 to 7.35 bp;
///      the tiers reach 11.76 bp at 500x and 17.64 bp at 100x), so some bets are liquidated and others run to their
///      end. One tick in eight jumps up to 40 bp, past every line and every cap at 1000x (4x is +30 bp) and 500x
///      (2.5x is +30 bp); one in thirty-two leaps up to 120 bp, past every cap at 100x too (2x is +100 bp). So
///      winners can win big at once at every leverage. Most warps are 1 to 120 seconds, the length of the bets, so
///      they expire as the run goes on.
contract MarketHandler is BaseHandler {
    /// @dev The largest price move an ordinary tick makes, × 1e7 of the price: 8 bp.
    int256 internal constant MAX_MOVE_E7 = 8000;

    /// @dev The largest jump, × 1e7 of the price: 40 bp.
    int256 internal constant MAX_JUMP_E7 = 40_000;

    /// @dev The largest leap, × 1e7 of the price: 120 bp.
    int256 internal constant MAX_LEAP_E7 = 120_000;

    constructor(HandlerSetup memory s) BaseHandler(s) {}

    /// @notice The price moves by `moveE7` × 1e-7 of itself: at most 8 bp either way; when `kind` is a multiple of
    ///         eight, at most 40 bp; and when it is a multiple of thirty-two, at most 120 bp.
    function movePrice(int256 moveE7, uint8 kind) external instrumented("movePrice") {
        int256 most = kind % 32 == 0 ? MAX_LEAP_E7 : kind % 8 == 0 ? MAX_JUMP_E7 : MAX_MOVE_E7;
        moveE7 = _bound(moveE7, -most, most);
        int256 price = store.price();
        // casting to int64 is safe: the price moves by at most 1.2% per tick from $83,884
        store.setPrice(int64(price + (price * moveE7) / 1e7));
        _done();
    }

    /// @notice Time passes: 1 to 120 seconds, or, one call in eight, 1 to 3 hours, so refund delays pass and the
    ///         breaker's windows roll over.
    function warp(uint256 seed) external instrumented("warp") {
        uint256 secs = seed % 8 == 0 ? _pick(seed, 1, 1 hours, 3 hours) : _pick(seed, 1, 1, 120);
        vm.warp(block.timestamp + secs);
        _done();
    }
}
