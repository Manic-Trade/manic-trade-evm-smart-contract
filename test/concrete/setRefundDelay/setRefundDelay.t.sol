// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {Position, Side} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title SetRefundDelay_Concrete_Test
/// @notice Every branch of `setRefundDelay`, from test/concrete/setRefundDelay/setRefundDelay.tree
///         (docs/ARCHITECTURE.md §8.1, §8.6).
/// @dev The delay shares `_setRefundDelay` with `initialize`, whose tests cover the same bounds at deployment. A
///      refund reads the delay when it runs, so a change reaches positions already open: the last test tries one
///      position's refund under three delays in turn.
contract SetRefundDelay_Concrete_Test is Settlement_Base_Test {
    /// @dev The delay's bits in `Layout` slot 0 (docs/storage-layout.md).
    uint256 internal constant DELAY_BITS = uint256(type(uint48).max) << 192;

    function test_RevertWhen_TheCallerIsNotTheAdmin() external {
        // it should revert: every user but the admin, with a delay that is too short as well
        address[] memory callers = _everyoneBut(users.admin, users.admin);
        bytes32 adminRole = flashOption.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], adminRole)
            );
            vm.prank(callers[i]);
            flashOption.setRefundDelay(1);
        }
    }

    modifier whenTheCallerIsTheAdmin() {
        _;
    }

    function test_RevertWhen_TheDelayIs1To3599Seconds() external whenTheCallerIsTheAdmin {
        // it should revert: 1 second, half an hour, and 1 second under an hour
        uint48[3] memory refused = [uint48(1), 30 minutes, 1 hours - 1];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(Errors.InvalidRefundDelay.selector);
            _setDelay(refused[i]);
        }
        assertEq(LayoutReader.refundDelaySecs(address(flashOption)), Defaults.REFUND_DELAY, "unchanged");
    }

    function test_WhenTheDelayIs0OrAtLeast1Hour() external whenTheCallerIsTheAdmin {
        // The launch's 24 hours again (unchanged, and it still emits), then off, the shortest, and the longest.
        uint48[4] memory accepted = [Defaults.REFUND_DELAY, 0, 1 hours, type(uint48).max];
        uint256 others = LayoutReader.word(address(flashOption), 0) & ~DELAY_BITS;
        for (uint256 i; i < accepted.length; ++i) {
            // it should emit {RefundDelayUpdated}
            vm.expectEmit(address(flashOption));
            emit Events.RefundDelayUpdated(accepted[i]);
            _setDelay(accepted[i]);

            // it should store the delay, and nothing else in its slot
            assertEq(LayoutReader.refundDelaySecs(address(flashOption)), accepted[i], "stored");
            assertEq(flashOption.refundDelaySecs(), accepted[i], "and read back");
            assertEq(LayoutReader.word(address(flashOption), 0) & ~DELAY_BITS, others, "the rest of slot 0");
        }

        // it should apply to positions already open: alice's bet, one hour past its expiry, is too early under the
        // 24-hour delay, can't be refunded at all with the refund switched off, and is refunded under a 1-hour delay.
        Position memory p = _bet(users.alice, "alice's call", Side.Call);
        vm.warp(_end(p) + 1 hours);
        bytes32[] memory ids = _ids("alice's call");
        _setDelay(Defaults.REFUND_DELAY);
        _expectRefundReverts(ids, abi.encodeWithSelector(Errors.RefundTooEarly.selector, bytes32("alice's call")));
        _setDelay(0);
        _expectRefundReverts(ids, abi.encodeWithSelector(Errors.RefundDisabled.selector));
        _setDelay(1 hours);
        _expectRefunded(ids, users.eve);
    }

    /// @dev The admin sets the refund delay to `secs`.
    function _setDelay(uint48 secs) private {
        vm.prank(users.admin);
        flashOption.setRefundDelay(secs);
    }
}
