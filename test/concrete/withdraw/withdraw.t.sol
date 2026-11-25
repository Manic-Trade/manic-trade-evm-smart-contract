// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {PoolState, WithdrawPurpose} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Withdraw_Concrete_Test
/// @notice Every branch of `withdraw`, from test/concrete/withdraw/withdraw.tree (docs/ARCHITECTURE.md §8.1), on the
///         design's example: $1,500 free, a $500 floor and $300 of open max profit, so at most $700 can go.
/// @dev The checks themselves are `LeverageMath.checkWithdraw`, proven in test/unit/LeverageMathChecks.t.sol and
///      test/fuzz/LeverageMathMoneyFuzz.t.sol; these tests prove the wiring, the order, the books, the recipients and
///      the transfers. The open max profit, the owed total and the seed already recovered are written straight into
///      storage.
///      Each revert test also breaks every later check, so its own error proves the order.
contract Withdraw_Concrete_Test is Base_Test {
    uint64 internal constant FREE = 1500e6;
    uint64 internal constant OPEN_MAX_PROFIT = 300e6;
    /// @dev 1,500 - 500 floor - 300 open max profit.
    uint64 internal constant MAX_WITHDRAWAL = 700e6;

    function setUp() public override {
        super.setUp();
        _fund(users.bob, FREE);
        _writeLayout(address(flashOption), 3, 128, 64, OPEN_MAX_PROFIT); // pool.openMaxProfit
    }

    function test_RevertWhen_TheCallerIsNotTheAdmin() external {
        // it should revert: every user but the admin, with a zero amount too
        address[] memory callers = _everyoneBut(users.admin, users.admin);
        bytes32 adminRole = flashOption.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], adminRole)
            );
            vm.prank(callers[i]);
            flashOption.withdraw(WithdrawPurpose.Rewards, 0);
        }
    }

    modifier whenTheCallerIsTheAdmin() {
        vm.startPrank(users.admin);
        _;
        vm.stopPrank();
    }

    function test_RevertWhen_TheAmountIsZero() external whenTheCallerIsTheAdmin {
        // it should revert, with a winner owed as well
        _setTotalOwed(1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        flashOption.withdraw(WithdrawPurpose.Rewards, 0);
    }

    modifier whenTheAmountIsNotZero() {
        _;
    }

    function test_RevertGiven_WinnersAreOwed() external whenTheCallerIsTheAdmin whenTheAmountIsNotZero {
        // it should revert: even one base unit owed blocks every withdrawal, here one that breaks every later check too
        _setTotalOwed(1);
        vm.expectRevert(Errors.OwedOutstanding.selector);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, FREE);
    }

    modifier givenNobodyIsOwed() {
        _;
    }

    function test_RevertWhen_FreeMoneyWouldFallBelowTheFloor()
        external
        whenTheCallerIsTheAdmin
        whenTheAmountIsNotZero
        givenNobodyIsOwed
    {
        // it should revert: $1,000 is all above the floor, so one unit more breaks it (and the later checks)
        vm.expectRevert(Errors.BelowPoolFloor.selector);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, 1000e6 + 1);
    }

    modifier whenFreeMoneyStaysAtOrAboveTheFloor() {
        _;
    }

    function test_RevertWhen_TheOpenBetsMaxProfitWouldBeLeftUncovered()
        external
        whenTheCallerIsTheAdmin
        whenTheAmountIsNotZero
        givenNobodyIsOwed
        whenFreeMoneyStaysAtOrAboveTheFloor
    {
        // it should revert: $700 and one unit keeps the floor but leaves the $300 of open max profit short (and passes
        // the seed cap too)
        vm.expectRevert(Errors.OpenExposureNotCovered.selector);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, MAX_WITHDRAWAL + 1);
    }

    modifier whenTheOpenBetsStayCovered() {
        _;
    }

    function test_RevertWhen_SeedRecoveryWouldPass500WholeTokens()
        external
        whenTheCallerIsTheAdmin
        whenTheAmountIsNotZero
        givenNobodyIsOwed
        whenFreeMoneyStaysAtOrAboveTheFloor
        whenTheOpenBetsStayCovered
    {
        // it should revert: $300 already recovered, so $200 and one unit passes the $500 cap
        _writeLayout(address(flashOption), 6, 0, 64, 300e6); // pool.seedRecovered
        vm.expectRevert(Errors.SeedRecoveryExceeded.selector);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, 200e6 + 1);
    }

    modifier whenTheWithdrawalIsWithinEveryLimit() {
        _;
    }

    function test_RevertWhen_TheTransferToTheRecipientFails()
        external
        whenTheCallerIsTheAdmin
        whenTheAmountIsNotZero
        givenNobodyIsOwed
        whenFreeMoneyStaysAtOrAboveTheFloor
        whenTheOpenBetsStayCovered
        whenTheWithdrawalIsWithinEveryLimit
    {
        // it should revert, and leave the books and every balance untouched: each recipient is frozen in turn
        uint256[4] memory slotsBefore = _poolSlots();
        vm.stopPrank();
        vm.startPrank(usdgAdmin);
        usdg.freeze(users.rewardsRecipient);
        usdg.freeze(users.feeRecipient);
        vm.stopPrank();
        vm.startPrank(users.admin);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        flashOption.withdraw(WithdrawPurpose.Rewards, MAX_WITHDRAWAL);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, 1);
        uint256[4] memory slotsAfter = _poolSlots();
        for (uint256 i; i < 4; ++i) {
            assertEq(slotsAfter[i], slotsBefore[i], "the pool's books, slots 3 to 6");
        }
        assertEq(usdg.balanceOf(address(flashOption)), FREE, "nothing left the contract");
        assertEq(usdg.balanceOf(users.rewardsRecipient), 0, "the rewards recipient got nothing");
        assertEq(usdg.balanceOf(users.feeRecipient), 0, "the fee recipient got nothing");
    }

    function test_WhenTheTransferSucceeds()
        external
        whenTheCallerIsTheAdmin
        whenTheAmountIsNotZero
        givenNobodyIsOwed
        whenFreeMoneyStaysAtOrAboveTheFloor
        whenTheOpenBetsStayCovered
        whenTheWithdrawalIsWithinEveryLimit
    {
        _writeLayout(address(flashOption), 6, 0, 64, 300e6); // pool.seedRecovered: $300 already back
        PoolState memory before = LayoutReader.pool(address(flashOption));

        // Seed recovery up to exactly the $500 cap, to the fee recipient.
        // it should emit {PoolWithdrawn}
        vm.expectEmit(address(flashOption));
        emit Events.PoolWithdrawn(WithdrawPurpose.SeedRecovery, 200e6, users.feeRecipient);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, 200e6);
        // it should take the amount out of the pool total
        // it should add it to the purpose's counter
        // it should send it to the purpose's recipient
        PoolState memory mid = LayoutReader.pool(address(flashOption));
        assertEq(mid.total, before.total - 200e6, "total after seed recovery");
        assertEq(mid.seedRecovered, Defaults.SEED_RECOVERY_CAP, "seed recovered: exactly the cap");
        assertEq(mid.rewardsWithdrawn, 0, "rewards untouched");
        assertEq(usdg.balanceOf(users.feeRecipient), 200e6, "the fee recipient got the seed back");

        // Rewards: now $1,300 free, so exactly $500 more can go before the $300 of open bets is uncovered.
        vm.expectEmit(address(flashOption));
        emit Events.PoolWithdrawn(WithdrawPurpose.Rewards, 500e6, users.rewardsRecipient);
        flashOption.withdraw(WithdrawPurpose.Rewards, 500e6);
        PoolState memory afterwards = LayoutReader.pool(address(flashOption));
        assertEq(afterwards.total, before.total - 700e6, "total after both");
        assertEq(afterwards.rewardsWithdrawn, 500e6, "rewards withdrawn");
        assertEq(afterwards.seedRecovered, Defaults.SEED_RECOVERY_CAP, "seed unchanged by rewards");
        assertEq(usdg.balanceOf(users.rewardsRecipient), 500e6, "the rewards recipient got the rewards");
        assertEq(usdg.balanceOf(address(flashOption)), FREE - MAX_WITHDRAWAL, "the contract paid both");
        assertEq(afterwards.openMaxProfit, OPEN_MAX_PROFIT, "open max profit untouched");
        assertEq(afterwards.lockedMargin, before.lockedMargin, "locked margin untouched");
        assertEq(afterwards.poolFloor, before.poolFloor, "floor untouched");
        _assertBooksBalanced(address(flashOption));

        // Not one base unit more: free money is now exactly floor + open max profit.
        vm.expectRevert(Errors.OpenExposureNotCovered.selector);
        flashOption.withdraw(WithdrawPurpose.Rewards, 1);
    }

    /// @dev The pool's four slots (`Layout` slots 3 to 6), word for word.
    function _poolSlots() private view returns (uint256[4] memory words) {
        for (uint256 i; i < 4; ++i) {
            words[i] = LayoutReader.word(address(flashOption), 3 + i);
        }
    }

    /// @dev Writes `pool.totalOwed` straight into storage.
    function _setTotalOwed(uint64 owed) private {
        _writeLayout(address(flashOption), 3, 192, 64, owed);
    }
}
