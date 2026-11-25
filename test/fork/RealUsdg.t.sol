// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, StakeAuth} from "../../src/types/OrderTypes.sol";
import {Position, Side, Status, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {MockOddERC1271Wallet} from "../mocks/MockOddERC1271Wallet.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {UsdgSigner} from "../utils/UsdgSigner.sol";
import {Fork_Base_Test} from "./ForkBase.t.sol";

/// @title Leverage_Fork_Test
/// @notice The contract on the real USDG, on a fork of Robinhood Chain mainnet (docs/ARCHITECTURE.md §13; security
///         checklist TOK-2, TOK-3, TOK-5, SIG-6):
///         - a stake comes in by EIP-3009 from every kind of signer: an EOA, an ERC-1271 wallet, and an account with
///           an EIP-7702 delegation;
///         - a winner frozen by USDG's asset-protection role before the batch is paid later, and the rest of the batch
///           at once (TOK-2);
///         - USDG paused by its pause role: every payout waits, opens and claims are refused with the token's
///           own error, and everything is paid once it resumes (TOK-3);
///         - an authorization the user cancels first is a silent no-op on the real token too, so the open is refused
///           (`TransferAmountMismatch`, TOK-5);
///         - every way money leaves the contract (a sale, the fee sweep, a withdrawal, an IOU's repayment) moves real
///           USDG.
/// @dev Each ending is checked by the settlement checkers against their model: every log (the real token's `Transfer`
///      logs included), every field of the books, every slot and every balance. The model predicts a deferred payout
///      from the real token's `paused` and `isFrozen`.
contract Leverage_Fork_Test is Fork_Base_Test {
    /// @dev The gas a payout needs before it starts (`FlashOptionBase._MIN_PAY_GAS`): more than a USDG transfer uses,
    /// so a relayer can't starve a transfer into failing and have it taken for a refusal (ARCHITECTURE §8.8).
    uint256 internal constant PAYOUT_GAS_FLOOR = 60_000;

    function test_AStakeComesInFromAnEoaByItsOwnSignature() external {
        Position memory p = _bet(users.alice, "alice's bet", Side.Call);
        assertEq(uint8(p.status), uint8(Status.Open), "open");
        assertEq(usdg.balanceOf(users.alice), 0, "the stake came from alice");
        vm.warp(_end(p));
        _expectSettled(p.entryPrice, _end(p), _ids("alice's bet"));
        assertEq(usdg.balanceOf(users.alice), p.stake, "a flat bet pays the stake back");
    }

    function test_AStakeComesInFromAnErc1271WalletByItsOwnersSignature() external {
        MockERC1271Wallet wallet = new MockERC1271Wallet(users.alice);
        OpenOrder memory o = _order(address(wallet), "the wallet's bet");
        _mintUsdg(address(wallet), o.stake);
        // Alice signs both; the contract asks the wallet for the order, and USDG asks it for the stake (ERC-1271).
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);

        Position memory p = LayoutReader.position(address(flashOption), o.positionId);
        assertEq(p.user, address(wallet), "the wallet's bet");
        assertEq(usdg.balanceOf(address(wallet)), 0, "the stake came from the wallet");
        vm.warp(_end(p));
        _expectSettled(p.entryPrice, _end(p), _ids(o.positionId));
        assertEq(usdg.balanceOf(address(wallet)), o.stake, "paid back to the wallet");
    }

    function test_AStakeComesInFromAnEip7702AccountByItsOwnKey() external {
        // Alice's account delegates to code that refuses every ERC-1271 question: her own key must be enough, for the
        // contract and for USDG alike.
        address refusesAll = address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.Revert));
        vm.etch(users.alice, abi.encodePacked(hex"ef0100", refusesAll));
        Position memory p = _bet(users.alice, "alice's bet", Side.Call);
        assertEq(usdg.balanceOf(users.alice), 0, "the stake came from alice's account");
        vm.warp(_end(p));
        _expectSettled(p.entryPrice, _end(p), _ids("alice's bet"));
        assertEq(usdg.balanceOf(users.alice), p.stake, "paid back to her account");
    }

    function test_AWinnerFrozenBeforeTheBatchIsPaidOnceUnfrozen() external {
        _bet(users.alice, "alice's call", Side.Call);
        Position memory p = _bet(users.bob, "bob's call", Side.Call);
        vm.warp(_end(p));
        // USDG's asset-protection role freezes alice before the batch runs.
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);

        // +10 bp: both win 2x. Alice's payout waits in `claimable`; bob's is paid in the same batch.
        _expectSettled(_up(p, 10), _end(p), _ids("alice's call", "bob's call"));
        uint64 waiting = flashOption.claimableOf(users.alice);
        assertGt(waiting, 0, "alice's payout waits");
        assertEq(flashOption.claimableOf(users.bob), 0, "bob was paid at once");

        // While she is frozen, the token itself refuses her claim; once unfrozen, it pays.
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        flashOption.claim(users.alice);
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.alice);
        _expectClaimed(users.alice, waiting);
    }

    function test_APausedTokenDefersEveryPayoutAndRefusesOpensUntilItResumes() external {
        _bet(users.alice, "alice's call", Side.Call);
        Position memory p = _bet(users.bob, "bob's call", Side.Call);
        vm.warp(_end(p));
        vm.prank(usdgAdmin);
        usdg.pause();

        // Every payout of the batch waits.
        _expectSettled(_up(p, 10), _end(p), _ids("alice's call", "bob's call"));
        uint64 alices = flashOption.claimableOf(users.alice);
        uint64 bobs = flashOption.claimableOf(users.bob);
        assertGt(alices, 0, "alice's payout waits");
        assertGt(bobs, 0, "bob's payout waits");

        // A new bet can't take its stake, and nobody can claim: the token's own error.
        OpenOrder memory o = _order(users.eve, "eve's bet");
        _mintUsdg(users.eve, o.stake);
        bytes memory signature = _signOrder(flashOption, eveKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, eveKey, o);
        vm.expectRevert(MockUSDG.ContractPaused.selector);
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);
        vm.expectRevert(MockUSDG.ContractPaused.selector);
        flashOption.claim(users.bob);

        // Once USDG resumes, both are paid.
        vm.prank(usdgAdmin);
        usdg.unpause();
        _expectClaimed(users.alice, alices);
        _expectClaimed(users.bob, bobs);
    }

    function test_AnAuthorizationCancelledFirstMovesNothingSoTheOpenIsRefused() external {
        OpenOrder memory o = _order(users.alice, "alice's bet");
        _mintUsdg(users.alice, o.stake);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);

        // Alice cancels the authorization (its nonce is the position id) on the token itself.
        bytes memory cancel =
            UsdgSigner.sign(aliceKey, UsdgSigner.cancelDigest(address(usdg), users.alice, o.positionId));
        usdg.cancelAuthorization(users.alice, o.positionId, cancel);

        // The real token then moves nothing and doesn't revert, so only the balance check stops the open.
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferAmountMismatch.selector, o.stake, 0));
        vm.prank(users.opener);
        flashOption.open(o, signature, _terms(), a);
        assertEq(usdg.balanceOf(users.alice), o.stake, "alice keeps her stake");
        assertEq(uint8(LayoutReader.position(address(flashOption), o.positionId).status), uint8(Status.None), "no bet");
    }

    function test_EveryPaymentOutMovesRealUsdg() external {
        // A sale: alice's call sold at its entry price, for its stake less a 1% fee.
        Position memory p = _bet(users.alice, "alice's call", Side.Call);
        vm.warp(p.startTime + 10);
        _expectSale("alice's call", p.entryPrice, p.stake, p.stake - p.stake / 100, 0);
        // A liquidation: bob's put, on its line. Its loser fee and the sale's fee wait to be swept.
        Position memory put = _bet(users.bob, "bob's put", Side.Put);
        _expectLiquidated(put.liqPrice, uint48(block.timestamp), _ids("bob's put"));

        // The fee sweep pays the fee recipient.
        uint64 fees = flashOption.getPool().feesPending;
        assertGt(fees, 0, "fees to sweep");
        uint256 before = usdg.balanceOf(users.feeRecipient);
        flashOption.sweepFees();
        assertEq(usdg.balanceOf(users.feeRecipient), before + fees, "the fee recipient was paid");

        // A withdrawal pays the rewards recipient: everything above the floor.
        uint64 rewards = flashOption.freeMoney() - flashOption.getPool().poolFloor;
        before = usdg.balanceOf(users.rewardsRecipient);
        vm.prank(users.admin);
        flashOption.withdraw(WithdrawPurpose.Rewards, rewards);
        assertEq(usdg.balanceOf(users.rewardsRecipient), before + rewards, "the rewards recipient was paid");
        _assertBooksBalanced(address(flashOption));
    }

    function test_AnIouIsRepaidInRealUsdg() external {
        // A pool with $1 of free money: alice's 4x winner is paid $1 and owed the rest.
        _useSmallPool(1e6);
        Position memory p = _bet(users.alice, "alice's call", Side.Call);
        vm.warp(_end(p));
        _expectSettled(_up(p, 40), _end(p), _ids("alice's call"));
        assertEq(uint8(LayoutReader.position(address(flashOption), "alice's call").status), uint8(Status.Owed), "owed");

        // A top-up, then anyone repays the queue: alice is paid in real USDG.
        _fund(users.bob, 100e6);
        _expectRepaid(1, users.eve);
        Status status = LayoutReader.position(address(flashOption), "alice's call").status;
        assertEq(uint8(status), uint8(Status.Closed), "repaid");
    }

    function test_ATransferToANewHolderCostsLessThanThePayoutGasFloor() external {
        // Measured as `_pay` meets it: a contract calling the token, in a transaction of its own, so every slot is
        // cold, and the recipient a new holder, so its balance goes from zero (the dearest write).
        TransferGasProbe probe = new TransferGasProbe();
        _mintUsdg(address(probe), 2e6);
        uint256 real = probe.measure(address(usdg), makeAddr("a new holder"), 1e6);
        // The mock, for comparison: ARCHITECTURE §8.8 quotes its cost.
        MockUSDG mock = new MockUSDG("Global Dollar", "USDG", usdgAdmin);
        deal(address(mock), address(probe), 2e6);
        uint256 mocked = probe.measure(address(mock), makeAddr("a new holder"), 1e6);
        emit log_named_uint("gas, a real USDG transfer to a new holder", real);
        emit log_named_uint("gas, the same on the mock", mocked);
        assertLt(real, PAYOUT_GAS_FLOOR, "a real transfer fits under the payout's gas floor");
    }

    /// @dev The price `bp` basis points above `p`'s entry.
    function _up(Position memory p, int64 bp) private pure returns (int64) {
        return p.entryPrice + (p.entryPrice * bp) / 10_000;
    }

    /// @dev Anyone claims for `account`, who receives exactly `amount` of real USDG, and the books stay balanced.
    function _expectClaimed(address account, uint64 amount) private {
        uint256 before = usdg.balanceOf(account);
        flashOption.claim(account);
        assertEq(usdg.balanceOf(account), before + amount, "paid what waited");
        assertEq(flashOption.claimableOf(account), 0, "nothing left to claim");
        _assertBooksBalanced(address(flashOption));
    }
}

/// @title TransferGasProbe
/// @notice Measures what one token transfer costs its caller, as the contract's `_pay` meets it.
contract TransferGasProbe {
    /// @notice Transfers `amount` of `token` to `to`, and returns the gas the call used.
    function measure(address token, address to, uint256 amount) external returns (uint256 used) {
        uint256 before = gasleft();
        bool ok = IERC20(token).transfer(to, amount);
        used = before - gasleft();
        require(ok, "the transfer failed");
    }
}
