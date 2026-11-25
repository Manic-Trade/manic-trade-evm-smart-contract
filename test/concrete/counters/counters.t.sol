// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {Position, Side} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Counters_Concrete_Test
/// @notice The pool's two 32-bit counters refuse to wrap (docs/ARCHITECTURE.md §6.5): an open with `openPositions`
///         at its largest value, and a settle that would queue an IOU with `owedPositions` at its largest, revert
///         `MathOverflow`. One below the largest, each call counts.
/// @dev Reaching either value takes about 4.3 billion positions, so each test writes the counter straight into
///      storage: `Layout` slot 4, byte 24 (`openPositions`) and byte 28 (`owedPositions`), as in
///      docs/storage-layout.md. The pool's 64-bit amounts all go through `_add64`, whose overflow `fund`'s tests
///      cover.
contract Counters_Concrete_Test is Settlement_Base_Test {
    uint256 internal constant OPEN_POSITIONS_BIT = 24 * 8;
    uint256 internal constant OWED_POSITIONS_BIT = 28 * 8;

    function test_RevertWhen_TheOpenCountIsAtItsLargest() external {
        // One below the largest, alice's bet opens and the count reaches it.
        _writeLayout(address(flashOption), 4, OPEN_POSITIONS_BIT, 32, type(uint32).max - 1);
        _bet(users.alice, "the last one", Side.Call);
        assertEq(LayoutReader.pool(address(flashOption)).openPositions, type(uint32).max, "the largest count");

        // At the largest, the next bet is refused.
        OpenOrder memory o = _order(users.bob, "one too many");
        _mintUsdg(users.bob, o.stake);
        bytes memory signature = _signOrder(flashOption, bobKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, bobKey, o);
        vm.expectRevert(Errors.MathOverflow.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);
    }

    /// @dev On a pool seeded with $20 (no exposure gate), two winners at the 4x cap: settled together, the first is
    ///      paid the $20 and owed $10, and the second is owed its whole $30, so the batch queues two IOUs.
    function test_RevertWhen_TheIouCountIsAtItsLargest() external {
        _useSmallPool(20e6);
        _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.bob, "b", Side.Call);
        vm.warp(_end(b));

        // Two below the largest, both IOUs queue and the count reaches it.
        uint256 clean = vm.snapshotState();
        _writeLayout(address(flashOption), 4, OWED_POSITIONS_BIT, 32, type(uint32).max - 2);
        _settle(Examples.priceAt(300), _end(b), _ids("a", "b"));
        assertEq(LayoutReader.pool(address(flashOption)).owedPositions, type(uint32).max, "the largest count");
        vm.revertToState(clean);

        // One below the largest, the second IOU is refused, and with it the whole batch.
        _writeLayout(address(flashOption), 4, OWED_POSITIONS_BIT, 32, type(uint32).max - 1);
        _expectSettleReverts(
            Examples.priceAt(300), _end(b), _ids("a", "b"), abi.encodeWithSelector(Errors.MathOverflow.selector)
        );
    }
}
