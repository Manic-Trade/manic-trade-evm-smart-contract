// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {PoolState, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";

/// @title Pool_Fuzz_Test
/// @notice The pool module's money, for random amounts:
///         - funding adds exactly what arrives;
///         - a withdrawal succeeds exactly when its definition says, takes only free money above the floor and the
///           open bets' max profit, and pays exactly the purpose's recipient.
///         `LeverageMath.checkWithdraw` is fuzzed on its own in LeverageMathMoneyFuzz.t.sol. This proves the module's
///         wiring around it: free money read as total minus the stakes held, the purpose's counter and recipient, and
///         the transfer.
/// @dev The stakes held and the open max profit are written straight into storage, backed by funded tokens. Inputs
///      are bounded with `bound`, never `vm.assume`. CI runs 10,000 cases per property.
contract Pool_Fuzz_Test is Base_Test {
    /// @dev One random withdrawal: the pool's state, then the request.
    struct Case {
        uint64 funded;
        uint64 locked;
        uint64 openMaxProfit;
        uint64 seedRecovered;
        uint64 amount;
        bool isSeed;
    }

    function testFuzz_FundingAddsExactlyWhatArrives(uint64 first, uint64 second) external {
        first = uint64(bound(first, 1, type(uint64).max / 2));
        second = uint64(bound(second, 1, type(uint64).max / 2));
        _fund(users.alice, first);
        _fund(users.bob, second);
        assertEq(LayoutReader.pool(address(flashOption)).total, uint256(first) + second, "total");
        assertEq(usdg.balanceOf(address(flashOption)), uint256(first) + second, "balance");
    }

    /// @dev `mode` steers the amount to each region of the definition, so every outcome comes up often: exactly zero;
    ///      past the floor; just past the open bets' cover; small (where the seed cap decides); or anywhere up to the
    ///      free money. Uniform amounts would almost never hit zero or the floor.
    function testFuzz_AWithdrawalTakesOnlyWhatItsDefinitionAllows(
        uint64 funded,
        uint64 locked,
        uint64 openMaxProfit,
        uint64 seedRecovered,
        uint64 amount,
        bool isSeed,
        uint8 mode
    )
        external
    {
        Case memory c;
        c.funded = uint64(bound(funded, 1, 1e15));
        c.locked = uint64(bound(locked, 0, c.funded));
        c.openMaxProfit = uint64(bound(openMaxProfit, 0, c.funded - c.locked));
        c.seedRecovered = uint64(bound(seedRecovered, 0, Defaults.SEED_RECOVERY_CAP + 100e6)); // past the cap too
        c.amount = _steer(amount, mode, c);
        c.isSeed = isSeed;

        _fund(users.bob, c.funded);
        _writeLayout(address(flashOption), 3, 64, 64, c.locked); // pool.lockedMargin
        _writeLayout(address(flashOption), 3, 128, 64, c.openMaxProfit); // pool.openMaxProfit
        _writeLayout(address(flashOption), 6, 0, 64, c.seedRecovered); // pool.seedRecovered
        _withdrawAndCheck(c, _expected(c));
    }

    /// @dev The amount in the region `mode` picks.
    function _steer(uint64 amount, uint8 mode, Case memory c) private pure returns (uint64) {
        uint256 free = uint256(c.funded) - c.locked;
        uint256 floor = Defaults.POOL_FLOOR;
        uint256 headroom = free >= floor + c.openMaxProfit ? free - floor - c.openMaxProfit : 0;
        mode %= 5;
        if (mode == 0) return 0;
        if (mode == 1) return uint64(bound(amount, free >= floor ? free - floor + 1 : 1, free + floor));
        if (mode == 2) return uint64(bound(amount, headroom + 1, headroom + 10));
        if (mode == 3) {
            // Small amounts, where the seed cap decides: up to a little past the cap, within the headroom.
            uint256 small = Defaults.SEED_RECOVERY_CAP + 100e6;
            if (headroom < small) small = headroom;
            return uint64(bound(amount, 1, small >= 1 ? small : 1));
        }
        return uint64(bound(amount, 0, free));
    }

    /// @dev The definition (ARCHITECTURE §8.1), in check order, in 256-bit arithmetic: the error `c` must get, or
    ///      none.
    function _expected(Case memory c) private pure returns (bytes4) {
        uint256 free = uint256(c.funded) - c.locked;
        if (c.amount == 0) return Errors.InvalidAmount.selector;
        if (free < uint256(c.amount) + Defaults.POOL_FLOOR) return Errors.BelowPoolFloor.selector;
        if (free - c.amount - Defaults.POOL_FLOOR < c.openMaxProfit) return Errors.OpenExposureNotCovered.selector;
        bool pastSeedCap = uint256(c.seedRecovered) + c.amount > Defaults.SEED_RECOVERY_CAP;
        if (c.isSeed && pastSeedCap) return Errors.SeedRecoveryExceeded.selector;
        return bytes4(0);
    }

    /// @dev Withdraws, then checks the outcome against `expected`, and on success the books, the cover and the payee.
    function _withdrawAndCheck(Case memory c, bytes4 expected) private {
        address recipient = c.isSeed ? users.feeRecipient : users.rewardsRecipient;
        vm.prank(users.admin);
        try flashOption.withdraw(c.isSeed ? WithdrawPurpose.SeedRecovery : WithdrawPurpose.Rewards, c.amount) {
            assertEq(expected, bytes4(0), "withdrew what its definition refuses");
            PoolState memory pool = LayoutReader.pool(address(flashOption));
            assertEq(pool.total, c.funded - c.amount, "total");
            uint256 freeAfter = uint256(pool.total) - pool.lockedMargin;
            assertGe(freeAfter, uint256(Defaults.POOL_FLOOR) + c.openMaxProfit, "floor + open max profit covered");
            assertEq(usdg.balanceOf(recipient), c.amount, "the purpose's recipient is paid");
            uint64 counter = c.isSeed ? pool.seedRecovered : pool.rewardsWithdrawn;
            assertEq(counter, (c.isSeed ? c.seedRecovered : 0) + c.amount, "the purpose's counter");
            _assertBooksBalanced(address(flashOption));
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), expected, "refused for the wrong reason, or refused a valid withdrawal");
        }
    }
}
