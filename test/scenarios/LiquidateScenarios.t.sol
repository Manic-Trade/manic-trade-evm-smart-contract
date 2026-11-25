// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {Position, Side} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Liquidate_Scenario_Test
/// @notice Liquidating bets end to end, with every expected number to the base unit: a long and a short on their
///         lines and beyond them, the ticks a liquidation accepts, the 3% loser fee at the floor and one unit below
///         it, free money measured per position in batch order, and the batch size limit. The base bet is a $10
///         one-minute BTC long (θ 3 bp, floor 1.3x, cap 4x, at $83,884).
/// @dev Every liquidation runs through `_expectLiquidated`, which also checks the books, the slots, the logs and the
///      balances against its own model. A batch holds at most 100 ids; a position listed twice in one is skipped the
///      second time (the tree test covers it). The floor is set with `setPoolFloor`, which accepts any value of at
///      least $500.
contract Liquidate_Scenario_Test is Settlement_Base_Test {
    /// @dev Liquidates a long at its line (equality), not one unit inside it.
    function test_ALongAtItsLineButNotOneUnitInside() external {
        Position memory p = _bet(users.alice, "long", Side.Call);
        _expectLiquidateReverts(
            p.liqPrice + 1,
            p.startTime,
            _ids("long"),
            abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, bytes32("long"))
        );
        Ending[] memory endings = _expectLiquidated(p.liqPrice, p.startTime, _ids("long"));
        assertEq(endings[0].loserFee, 300_000, "3% of the $10 stake: free money is above the floor");
    }

    /// @dev Liquidates a short at its line (equality), not one unit inside it.
    function test_AShortAtItsLineButNotOneUnitInside() external {
        Position memory p = _bet(users.alice, "short", Side.Put);
        _expectLiquidateReverts(
            p.liqPrice - 1,
            p.startTime,
            _ids("short"),
            abi.encodeWithSelector(Errors.LiquidationPriceNotReached.selector, bytes32("short"))
        );
        _expectLiquidated(p.liqPrice, p.startTime, _ids("short"));
    }

    /// @dev Liquidates a long and a short beyond their lines ($500 past each).
    function test_ALongAndAShortBeyondTheirLines() external {
        Position memory long = _bet(users.alice, "long", Side.Call);
        Position memory short = _bet(users.bob, "short", Side.Put);
        int64 move = 500 * Examples.USD;
        _expectLiquidated(long.liqPrice - move, long.startTime, _ids("long"));
        _expectLiquidated(short.liqPrice + move, short.startTime, _ids("short"));
    }

    /// @dev Accepts a tick at the start time, but not one second outside the position's life or from the future; and
    ///      a tick at the end time, but not one second after.
    function test_ATickInsideThePositionsLifeAndNotFromTheFuture() external {
        Position memory p = _bet(users.alice, "long", Side.Call);
        bytes memory outside = abi.encodeWithSelector(Errors.InvalidLiquidationWindow.selector, bytes32("long"));
        _expectLiquidateReverts(p.liqPrice, p.startTime - 1, _ids("long"), outside);
        _expectLiquidateReverts(p.liqPrice, _end(p) + 1, _ids("long"), outside);
        // Inside the position's life, but 30 seconds ahead of the chain's clock and its 5-second skew.
        uint48 future = uint48(block.timestamp) + 30;
        assertLe(future, _end(p), "the future tick is inside the position's life");
        _expectLiquidateReverts(
            p.liqPrice, future, _ids("long"), abi.encodeWithSelector(Errors.PriceFromFuture.selector)
        );
        _expectLiquidated(p.liqPrice, p.startTime, _ids("long"));

        // At the end, once the chain's clock is there.
        Position memory q = _bet(users.alice, "second long", Side.Call);
        vm.warp(_end(q));
        _expectLiquidateReverts(
            q.liqPrice,
            _end(q) + 1,
            _ids("second long"),
            abi.encodeWithSelector(Errors.InvalidLiquidationWindow.selector, bytes32("second long"))
        );
        _expectLiquidated(q.liqPrice, _end(q), _ids("second long"));
    }

    /// @dev Rejects a zero or negative price.
    function test_RevertWhen_ThePriceIsZeroOrNegative() external {
        Position memory p = _bet(users.alice, "long", Side.Call);
        bytes memory invalid = abi.encodeWithSelector(Errors.InvalidPrice.selector);
        _expectLiquidateReverts(0, p.startTime, _ids("long"), invalid);
        _expectLiquidateReverts(-1, p.startTime, _ids("long"), invalid);
        _expectLiquidated(p.liqPrice, p.startTime, _ids("long"));
    }

    /// @dev Charges the loser fee when free money is exactly the pool floor, and skips it one unit below.
    function test_TheLoserFeeAtTheFloorButNotOneUnitBelow() external {
        Position memory a = _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.alice, "b", Side.Call);

        _setFloor(_free());
        Ending[] memory charged = _expectLiquidated(a.liqPrice, a.startTime, _ids("a"));
        assertEq(charged[0].loserFee, 300_000, "3% of $10");

        _setFloor(_free() + 1);
        Ending[] memory skipped = _expectLiquidated(b.liqPrice, b.startTime, _ids("b"));
        assertEq(skipped[0].loserFee, 0, "no fee below the floor");
    }

    /// @dev Measures free money per position in batch order: the first stake can lift the second to the floor.
    function test_FreeMoneyIsMeasuredPerPositionInBatchOrder() external {
        Position memory c = _bet(users.alice, "c", Side.Call);
        _bet(users.alice, "d", Side.Call);

        // Free money is one $10 stake short of the floor until c's stake is released.
        _setFloor(_free() + c.stake);
        Ending[] memory endings = _expectLiquidated(c.liqPrice, c.startTime, _ids("c", "d"));
        assertEq(endings[0].loserFee, 0, "c pays nothing");
        assertEq(endings[1].loserFee, 300_000, "only the second position pays");
    }

    /// @dev Liquidates 100 positions in one batch, then the 101st alone, but not 101 at once: a batch holds at most
    ///      100.
    function test_OneHundredPositionsInOneBatchThenTheHundredAndFirstAlone() external {
        _fund(users.bob, 1600e6); // the exposure gate needs $30 of free money per bet
        bytes32[] memory all = new bytes32[](101);
        Position memory p;
        for (uint256 i; i < 101; ++i) {
            all[i] = keccak256(abi.encode("bet", i));
            p = _bet(users.alice, all[i], Side.Call);
        }
        bytes memory tooLarge = abi.encodeWithSelector(Errors.BatchSizeTooLarge.selector);
        _expectLiquidateReverts(p.liqPrice, p.startTime, all, tooLarge);

        bytes32[] memory hundred = new bytes32[](100);
        for (uint256 i; i < 100; ++i) {
            hundred[i] = all[i];
        }
        _expectLiquidated(p.liqPrice, p.startTime, hundred);
        _expectLiquidated(p.liqPrice, p.startTime, _ids(all[100]));
        assertEq(LayoutReader.pool(address(flashOption)).openPositions, 0, "all 101 liquidated");
    }

    /// @dev The pool's free money: what it holds beyond the open positions' stakes.
    function _free() private view returns (uint64) {
        return LayoutReader.pool(address(flashOption)).total - LayoutReader.pool(address(flashOption)).lockedMargin;
    }

    /// @dev The admin sets the pool's floor.
    function _setFloor(uint64 poolFloor) private {
        assertGe(poolFloor, Defaults.POOL_FLOOR, "a floor the contract accepts");
        vm.prank(users.admin);
        flashOption.setPoolFloor(poolFloor);
    }
}
