// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, StakeAuth} from "../../src/types/OrderTypes.sol";
import {Breaker, Position} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Breaker_Fuzz_Test
/// @notice The payout circuit breaker (docs/ARCHITECTURE.md §8.11) over random sequences: any limit (off one time in
///         four, up to $10 one time in four, otherwise up to $300) and any window, then 1 to 10 steps, each after a
///         random wait (half under a minute, half up to two windows). Each step opens a long and ends it one of five
///         ways: settled at a random winning price (+$1 to +$300), settled at a random losing one (-$1 to -$25, short
///         of the line), liquidated, or sold at a profit or at a loss (the sale quotes of the unit tests: a $12.50
///         valuation sold for $12 at +$8, and $9 sold for $8.60 at -$8). After every call, the checkers' model
///         matches the breaker's 6 fields and its trip event. Whenever the breaker has tripped, a new bet is refused
///         with `BreakerTripped`, and the operator's reset clears it, zeroes the counters and starts the window, so
///         the sequence goes on.
/// @dev The pool holds $11,500 of free money, so no winner is ever owed and no sale meets a queue. Settled bets
///      stake $1 to $50; sold ones stake $10, the stake those quotes are for. Inputs are bounded with `bound`,
///      never `vm.assume`. CI runs 10,000 cases.
contract Breaker_Fuzz_Test is Settlement_Base_Test {
    function testFuzz_TheBreakerFollowsItsDefinition(uint256 salt, uint64 limit, uint32 window, uint8 steps) external {
        _fund(users.bob, 10_000e6);
        // Off one time in four, up to $10 one time in four (so it trips often), otherwise up to $300.
        uint256 kind = limit % 4;
        limit = kind == 0 ? 0 : uint64(bound(limit, 1, kind == 1 ? 10e6 : 300e6));
        window = uint32(bound(window, 60, 1 days));
        vm.prank(users.admin);
        flashOption.setBreaker(limit, window);
        steps = uint8(bound(steps, 1, 10));
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(salt, i)));
            // Half the waits are under a minute, so winnings build up in one window; half often cross one.
            vm.warp(block.timestamp + ((x >> 200) % 2 == 0 ? x % 60 : x % (2 * uint256(window))));
            if (LayoutReader.breaker(address(flashOption)).tripped) _expectStoppedThenReset(i);
            _step(i, x);
        }
    }

    /// @dev Opens a long for alice, bob or eve, and ends it the way `x` picks, through the checkers.
    function _step(uint256 i, uint256 x) private {
        bytes32 id = keccak256(abi.encode("step", i));
        uint256 kind = (x >> 8) % 5;
        OpenOrder memory o = _order(_bettor(x >> 16), id);
        o.stake = kind >= 3 ? Defaults.STAKE : uint64(bound(x >> 24, 1e6, 50e6));
        Position memory p = _betWith(o, _terms());
        if (kind == 0) {
            vm.warp(_end(p));
            _expectSettled(_dollarsFromEntry(int256(bound(x >> 64, 1, 300))), _end(p), _ids(id));
        } else if (kind == 1) {
            vm.warp(_end(p));
            _expectSettled(_dollarsFromEntry(-int256(bound(x >> 64, 1, 25))), _end(p), _ids(id));
        } else if (kind == 2) {
            _expectLiquidated(p.liqPrice, p.startTime, _ids(id));
        } else if (kind == 3) {
            _expectSale(id, Examples.priceAt(8), 12_500_000, 12_000_000, 11_640_000);
        } else {
            _expectSale(id, Examples.priceAt(-8), 9_000_000, 8_600_000, 8_600_000);
        }
    }

    /// @dev With the breaker tripped, a new bet is refused; then the operator resets it.
    function _expectStoppedThenReset(uint256 i) private {
        OpenOrder memory o = _order(users.alice, keccak256(abi.encode("stopped", i)));
        _mintUsdg(users.alice, o.stake);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        vm.expectRevert(Errors.BreakerTripped.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);

        vm.prank(users.operator);
        flashOption.resetBreaker();
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        assertFalse(b.tripped, "the reset clears the trip");
        assertEq(b.profitOut, 0, "zeroes the profit out");
        assertEq(b.lossIn, 0, "and the losses in");
        assertEq(b.windowStart, block.timestamp, "and starts the window now");
    }

    /// @dev The price `dollars` whole dollars from the base entry.
    function _dollarsFromEntry(int256 dollars) private pure returns (int64) {
        // casting to int64 is safe because `dollars` is bounded to -25..300
        // forge-lint: disable-next-line(unsafe-typecast)
        return Examples.priceAt(int64(dollars));
    }

    /// @dev Alice, bob or eve, from `x`.
    function _bettor(uint256 x) private view returns (address) {
        uint256 who = x % 3;
        return who == 0 ? users.alice : who == 1 ? users.bob : users.eve;
    }
}
