// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionPool} from "../../../src/interfaces/IManicFlashOptionPool.sol";
import {PoolState, WithdrawPurpose} from "../../../src/types/StorageTypes.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {BaseHandler, HandlerSetup} from "./BaseHandler.sol";

/// @title PoolHandler
/// @notice The pool's money in and out (docs/ARCHITECTURE.md §8.1, §8.8): the funder tops it up, the admin withdraws
///         for seed recovery or rewards, anyone claims a payout that waited or sweeps the fees, and someone sends
///         tokens straight to the contract.
/// @dev Each call either goes through or is refused with the error the handler predicts: the withdrawal checks in
///      their order (§12 #6), nothing to claim or sweep, and the token's pause or a frozen recipient at the transfer,
///      which reverts the whole call. A donation is minted straight to the contract, and the store adds it up: the
///      books must never count it (§12 #1).
contract PoolHandler is BaseHandler {
    constructor(HandlerSetup memory s) BaseHandler(s) {}

    /// @notice The funder adds $1 to $100 to the pool: top-ups small enough that a run's winners can still outrun a
    ///         small pool. While the token is paused, the pull is refused.
    /// @param amount The amount, bounded to $1 to $100.
    function fund(uint256 amount) external instrumented("fund") {
        uint64 a = uint64(_bound(amount, 1e6, 100e6));
        if (usdg.paused()) {
            // Nothing is approved: approving would be refused too, and `transferFrom` checks the pause first.
            (bool ok, bytes memory reason) = _attempt("fund", funder, abi.encodeCall(IManicFlashOptionPool.fund, (a)));
            _checkRefusal(13, "fund", ok, reason, abi.encodeWithSelector(MockUSDG.ContractPaused.selector));
            _refuse();
            return;
        }
        _mint(funder, a);
        vm.startPrank(funder);
        usdg.approve(address(flashOption), a);
        flashOption.fund(a);
        vm.stopPrank();
        _done();
    }

    /// @notice The admin withdraws for seed recovery or rewards: any amount the checks allow, or, one call in four
    ///         (and whenever nothing is allowed), more than that, which must be refused with the first check it fails.
    ///         Half of those ask 1 to 3 base units past the tightest limit, so each check's boundary is hit, the seed
    ///         cap's included; the rest ask up to $100 past it. A withdrawal that goes through must leave free money at
    ///         or above the floor plus every open bet's max profit (§12 #6).
    /// @param seed Picks the purpose, and whether and by how much to ask for too much, each drawn on its own.
    /// @param amount The amount to try within what is allowed.
    function withdraw(uint256 seed, uint256 amount) external instrumented("withdraw") {
        WithdrawPurpose purpose = _pick(seed, 1, 0, 1) == 0 ? WithdrawPurpose.SeedRecovery : WithdrawPurpose.Rewards;
        uint256 room = _withdrawable(purpose);
        uint64 a;
        if (_pick(seed, 2, 0, 3) == 0 || room == 0) {
            a = uint64(room + (_pick(seed, 3, 0, 1) == 0 ? _pick(seed, 4, 1, 3) : _pick(seed, 4, 1, 100e6)));
        } else {
            a = uint64(_bound(amount, 1, room));
        }
        bytes memory refusal = _withdrawRefusal(purpose, a);
        if (refusal.length > 0) {
            (bool ok, bytes memory reason) =
                _attempt("withdraw", users.admin, abi.encodeCall(IManicFlashOptionPool.withdraw, (purpose, a)));
            // The pool's own checks protect invariant 6; the token's refusals are invariant 13's.
            bool token = bytes4(refusal) == MockUSDG.ContractPaused.selector
                || bytes4(refusal) == MockUSDG.AddressFrozen.selector;
            _checkRefusal(token ? 13 : 6, "withdraw", ok, reason, refusal);
            _refuse();
            return;
        }
        vm.prank(users.admin);
        flashOption.withdraw(purpose, a);
        PoolState memory pool = _pool();
        if (pool.total - pool.lockedMargin < uint256(pool.poolFloor) + pool.openMaxProfit) {
            store.recordBreach(6, "withdraw: left free money below the floor plus the open max profit");
        }
        _done();
    }

    /// @notice Anyone claims an account's payouts that waited. One call in four tries an account with nothing to
    ///         claim, which must be refused; so must a claim while the token is paused or the account frozen, and the
    ///         balance then stays claimable.
    /// @param seed Picks the caller and the account.
    function claim(uint256 seed) external instrumented("claim") {
        address account = _claimant(seed);
        uint64 amount = LayoutReader.claimable(address(flashOption), account);
        if (amount == 0 && seed % 4 != 0) {
            _skip();
            return;
        }
        bytes memory refusal;
        if (amount == 0) refusal = abi.encodeWithSelector(Errors.NothingToClaim.selector);
        else if (usdg.paused()) refusal = abi.encodeWithSelector(MockUSDG.ContractPaused.selector);
        else if (usdg.isFrozen(account)) refusal = abi.encodeWithSelector(MockUSDG.AddressFrozen.selector);
        address caller = _anyone(seed);
        if (refusal.length > 0) {
            bytes memory data = abi.encodeCall(IManicFlashOptionPool.claim, (account));
            (bool ok, bytes memory reason) = _attempt("claim", caller, data);
            _checkRefusal(13, "claim", ok, reason, refusal);
            _refuse();
            return;
        }
        vm.prank(caller);
        flashOption.claim(account);
        _done();
    }

    /// @notice Anyone sweeps the pending fees to the fee recipient. With none pending, or while the token is paused
    ///         or the fee recipient frozen, it must be refused, and the fees stay pending.
    /// @param seed Picks the caller.
    function sweepFees(uint256 seed) external instrumented("sweepFees") {
        bytes memory refusal;
        if (_pool().feesPending == 0) refusal = abi.encodeWithSelector(Errors.InvalidAmount.selector);
        else if (usdg.paused()) refusal = abi.encodeWithSelector(MockUSDG.ContractPaused.selector);
        else if (usdg.isFrozen(users.feeRecipient)) refusal = abi.encodeWithSelector(MockUSDG.AddressFrozen.selector);
        address caller = _anyone(seed);
        if (refusal.length > 0) {
            (bool ok, bytes memory reason) =
                _attempt("sweepFees", caller, abi.encodeCall(IManicFlashOptionPool.sweepFees, ()));
            _checkRefusal(13, "sweepFees", ok, reason, refusal);
            _refuse();
            return;
        }
        vm.prank(caller);
        flashOption.sweepFees();
        _done();
    }

    /// @notice Someone sends $0.000001 to $100 straight to the contract, outside `fund`. The books must never count it.
    /// @param amount The amount, bounded to 1 base unit to $100.
    function donate(uint256 amount) external instrumented("donate") {
        uint256 a = _bound(amount, 1, 100e6);
        _mint(address(flashOption), a);
        store.addDonation(a);
        _done();
    }

    /// @dev The most `purpose` may withdraw now: free money above the floor and the open max profit, and for seed
    ///      recovery no more than what is left of the 500-token cap. Zero while anyone is owed.
    function _withdrawable(WithdrawPurpose purpose) private view returns (uint256 room) {
        PoolState memory pool = _pool();
        if (pool.totalOwed != 0) return 0;
        uint256 free = pool.total - pool.lockedMargin;
        uint256 kept = uint256(pool.poolFloor) + pool.openMaxProfit;
        room = free > kept ? free - kept : 0;
        if (purpose == WithdrawPurpose.SeedRecovery) {
            uint256 left = Defaults.SEED_RECOVERY_CAP - pool.seedRecovered;
            if (left < room) room = left;
        }
    }

    /// @dev The error the contract must refuse a withdrawal of `amount` with, in its check order (§8.1), or "" if it
    ///      must go through. The transfer comes last: the token's pause, or the recipient frozen.
    function _withdrawRefusal(WithdrawPurpose purpose, uint64 amount) private view returns (bytes memory) {
        PoolState memory pool = _pool();
        uint256 free = pool.total - pool.lockedMargin;
        if (pool.totalOwed != 0) return abi.encodeWithSelector(Errors.OwedOutstanding.selector);
        if (free < uint256(amount) + pool.poolFloor) return abi.encodeWithSelector(Errors.BelowPoolFloor.selector);
        if (free - amount - pool.poolFloor < pool.openMaxProfit) {
            return abi.encodeWithSelector(Errors.OpenExposureNotCovered.selector);
        }
        if (
            purpose == WithdrawPurpose.SeedRecovery && uint256(pool.seedRecovered) + amount > Defaults.SEED_RECOVERY_CAP
        ) {
            return abi.encodeWithSelector(Errors.SeedRecoveryExceeded.selector);
        }
        address to = purpose == WithdrawPurpose.SeedRecovery ? users.feeRecipient : users.rewardsRecipient;
        if (usdg.paused()) return abi.encodeWithSelector(MockUSDG.ContractPaused.selector);
        if (usdg.isFrozen(to)) return abi.encodeWithSelector(MockUSDG.AddressFrozen.selector);
        return "";
    }

    /// @dev An account with payouts waiting, if any, else any known account.
    function _claimant(uint256 seed) private view returns (address) {
        uint256 first = _pick(seed, 2, 0, known.length - 1);
        for (uint256 j; j < known.length; ++j) {
            address account = known[(first + j) % known.length];
            if (LayoutReader.claimable(address(flashOption), account) > 0) return account;
        }
        return known[first];
    }
}
