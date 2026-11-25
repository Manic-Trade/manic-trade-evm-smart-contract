// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {Test} from "forge-std/Test.sol";

import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {UsdgSigner} from "../utils/UsdgSigner.sol";

/// @title MockUSDG_Unit_Test
/// @notice Proves `MockUSDG` behaves like the real Paxos USDG on Robinhood Chain, so every contract test built on it
///         sees the same successes and failures the live token would produce.
/// @dev Sections: metadata and EIP-712 domain, admin powers, ERC-20 transfers, EIP-2612 permits, EIP-3009
///      authorizations, and signature forms (EOA, ERC-1271 wallet, an EOA with code as under EIP-7702, malleable
///      signatures). The real token's values were read from chain 4663 on 2026-11-09. See test/mocks/MockUSDG.sol for
///      the sources, and docs/adr/0002-eip3009-stake-pull.md for why EIP-3009 matters to the leverage contract.
contract MockUSDG_Unit_Test is Test {
    using UsdgSigner for address;

    /// @dev The live USDG on Robinhood Chain mainnet and its EIP-712 domain separator, read on 2026-11-09.
    address internal constant LIVE_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    bytes32 internal constant LIVE_DOMAIN_SEPARATOR =
        0x7a3d7400b27830f4f91c2c16a082486d67c1befecaec2f53b33f1f35d5b62036;

    /// @dev secp256k1 curve order, used to build a malleable (high-s) copy of a valid signature.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256 internal constant ONE_USDG = 1_000_000;
    uint256 internal constant START_BALANCE = 1000 * ONE_USDG;

    MockUSDG internal token;
    address internal admin;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    address internal spender;

    function setUp() public {
        vm.warp(1_800_000_000);
        admin = makeAddr("admin");
        (alice, aliceKey) = makeAddrAndKey("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");

        token = new MockUSDG("Global Dollar", "USDG", admin);
        vm.prank(admin);
        token.mint(alice, START_BALANCE);
    }

    // ===============================================================================================================
    // Metadata and EIP-712 domain
    // ===============================================================================================================

    function test_MatchesTheRealTokensMetadataAndTypeHashes() public view {
        assertEq(token.name(), "Global Dollar");
        assertEq(token.symbol(), "USDG");
        assertEq(token.decimals(), 6);
        assertEq(token.EIP712_VERSION_PREFIX(), hex"1901");
        // Values read from the live token; each also equals the keccak256 of its EIP type string.
        assertEq(token.PERMIT_TYPEHASH(), 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9);
        assertEq(token.PERMIT_TYPEHASH(), UsdgSigner.PERMIT_TYPEHASH);
        assertEq(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267
        );
        assertEq(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), UsdgSigner.TRANSFER_WITH_AUTHORIZATION_TYPEHASH);
        assertEq(
            token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8
        );
        assertEq(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), UsdgSigner.RECEIVE_WITH_AUTHORIZATION_TYPEHASH);
        assertEq(
            token.CANCEL_AUTHORIZATION_TYPEHASH(), 0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429
        );
        assertEq(token.CANCEL_AUTHORIZATION_TYPEHASH(), UsdgSigner.CANCEL_AUTHORIZATION_TYPEHASH);
        assertEq(token.MAX_NONCE_INCREMENT(), 100);
    }

    /// @dev The strongest parity check available without a fork: the mock, placed at the live token's address on
    ///      chain 4663, produces exactly the live token's domain separator.
    function test_DomainSeparatorEqualsTheLiveTokensAtTheSameAddressAndChain() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        deployCodeTo("MockUSDG.sol:MockUSDG", abi.encode("Global Dollar", "USDG", admin), LIVE_USDG);
        assertEq(MockUSDG(LIVE_USDG).DOMAIN_SEPARATOR(), LIVE_DOMAIN_SEPARATOR);
    }

    function test_DomainSeparatorFollowsTheChainId() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "a fork must change the domain, so old signatures stop working");
    }

    // ===============================================================================================================
    // Admin: mint, pause, freeze, wipe
    // ===============================================================================================================

    function test_MintCreditsTheRecipientAndTheSupply() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit MockUSDG.SupplyIncreased(bob, 5 * ONE_USDG);
        vm.expectEmit(true, true, false, true, address(token));
        emit MockUSDG.Transfer(address(0), bob, 5 * ONE_USDG);
        vm.prank(admin);
        token.mint(bob, 5 * ONE_USDG);

        assertEq(token.balanceOf(bob), 5 * ONE_USDG);
        assertEq(token.totalSupply(), START_BALANCE + 5 * ONE_USDG);
    }

    function test_RevertWhen_MintToAFrozenAddress() public {
        vm.startPrank(admin);
        token.freeze(bob);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.mint(bob, ONE_USDG);
        vm.stopPrank();
    }

    function test_RevertWhen_AdminFunctionsAreCalledByAnyoneElse() public {
        vm.startPrank(alice);
        vm.expectRevert(MockUSDG.NotAdmin.selector);
        token.mint(alice, ONE_USDG);
        vm.expectRevert(MockUSDG.NotAdmin.selector);
        token.pause();
        vm.expectRevert(MockUSDG.NotAdmin.selector);
        token.freeze(bob);
        vm.expectRevert(MockUSDG.NotAdmin.selector);
        token.wipeFrozenAddress(bob);
        vm.expectRevert(MockUSDG.NotAdmin.selector);
        token.setAdmin(alice);
        vm.stopPrank();
    }

    function test_SetAdminHandsOverEveryPower() public {
        vm.expectEmit(true, true, false, false, address(token));
        emit MockUSDG.AdminChanged(admin, bob);
        vm.prank(admin);
        token.setAdmin(bob);

        assertEq(token.admin(), bob);
        vm.prank(bob);
        token.pause();
        vm.prank(admin);
        vm.expectRevert(MockUSDG.NotAdmin.selector);
        token.unpause();
    }

    function test_PauseAndUnpauseEmitAndToggle() public {
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, false, address(token));
        emit MockUSDG.Pause();
        token.pause();
        assertTrue(token.paused());

        vm.expectRevert(MockUSDG.AlreadyPaused.selector);
        token.pause();

        vm.expectEmit(false, false, false, false, address(token));
        emit MockUSDG.Unpause();
        token.unpause();
        assertFalse(token.paused());

        vm.expectRevert(MockUSDG.AlreadyUnPaused.selector);
        token.unpause();
        vm.stopPrank();
    }

    function test_FreezeAndUnfreezeEmitAndToggle() public {
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, false, address(token));
        emit MockUSDG.FreezeAddress(bob);
        token.freeze(bob);
        assertTrue(token.isFrozen(bob));

        // Freezing twice is allowed, as on the real token.
        token.freeze(bob);
        assertTrue(token.isFrozen(bob));

        vm.expectEmit(true, false, false, false, address(token));
        emit MockUSDG.UnfreezeAddress(bob);
        token.unfreeze(bob);
        assertFalse(token.isFrozen(bob));
        vm.stopPrank();
    }

    function test_WipeFrozenAddressDestroysTheWholeBalance() public {
        vm.startPrank(admin);
        token.freeze(alice);
        vm.expectEmit(true, false, false, false, address(token));
        emit MockUSDG.FrozenAddressWiped(alice);
        vm.expectEmit(true, false, false, true, address(token));
        emit MockUSDG.SupplyDecreased(alice, START_BALANCE);
        vm.expectEmit(true, true, false, true, address(token));
        emit MockUSDG.Transfer(alice, address(0), START_BALANCE);
        token.wipeFrozenAddress(alice);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_RevertWhen_WipingAnAddressThatIsNotFrozen() public {
        vm.prank(admin);
        vm.expectRevert(MockUSDG.AddressNotFrozen.selector);
        token.wipeFrozenAddress(alice);
    }

    // ===============================================================================================================
    // ERC-20 transfers and approvals
    // ===============================================================================================================

    function test_TransferMovesTheBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit MockUSDG.Transfer(alice, bob, 10 * ONE_USDG);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 * ONE_USDG));

        assertEq(token.balanceOf(alice), START_BALANCE - 10 * ONE_USDG);
        assertEq(token.balanceOf(bob), 10 * ONE_USDG);
    }

    function test_RevertWhen_TransferWhilePaused() public {
        vm.prank(admin);
        token.pause();
        vm.prank(alice);
        vm.expectRevert(MockUSDG.ContractPaused.selector);
        token.transfer(bob, ONE_USDG);
    }

    function test_RevertWhen_TransferFromAFrozenSender() public {
        vm.prank(admin);
        token.freeze(alice);
        vm.prank(alice);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.transfer(bob, ONE_USDG);
    }

    /// @dev This is the failure that would block a whole settle batch if the leverage contract pushed payouts without
    ///      a fallback (docs/security-checklist.md TOK-2).
    function test_RevertWhen_TransferToAFrozenRecipient() public {
        vm.prank(admin);
        token.freeze(bob);
        vm.prank(alice);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.transfer(bob, ONE_USDG);
    }

    function test_RevertWhen_TransferToTheZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(MockUSDG.ZeroAddress.selector);
        token.transfer(address(0), ONE_USDG);
    }

    function test_RevertWhen_TransferMoreThanTheBalance() public {
        vm.prank(alice);
        vm.expectRevert(MockUSDG.InsufficientFunds.selector);
        token.transfer(bob, START_BALANCE + 1);
    }

    function test_TransferFromDecrementsEvenAMaximumAllowance() public {
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, bob, ONE_USDG);

        assertEq(token.allowance(alice, spender), type(uint256).max - ONE_USDG, "no infinite-allowance shortcut");
        assertEq(token.balanceOf(bob), ONE_USDG);
    }

    function test_RevertWhen_TransferFromByAFrozenSpender() public {
        vm.prank(alice);
        token.approve(spender, ONE_USDG);
        vm.prank(admin);
        token.freeze(spender);
        vm.prank(spender);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.transferFrom(alice, bob, ONE_USDG);
    }

    function test_RevertWhen_TransferFromAboveTheAllowance() public {
        vm.prank(alice);
        token.approve(spender, ONE_USDG);
        vm.prank(spender);
        vm.expectRevert(MockUSDG.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, ONE_USDG + 1);
    }

    function test_RevertWhen_ApproveBreaksARule() public {
        vm.startPrank(alice);
        vm.expectRevert(MockUSDG.ZeroAddress.selector);
        token.approve(address(0), ONE_USDG);
        vm.stopPrank();

        vm.prank(admin);
        token.freeze(spender);
        vm.prank(alice);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.approve(spender, ONE_USDG);

        vm.prank(admin);
        token.pause();
        vm.prank(alice);
        vm.expectRevert(MockUSDG.ContractPaused.selector);
        token.approve(bob, ONE_USDG);
    }

    function test_IncreaseAndDecreaseApproval() public {
        vm.startPrank(alice);
        token.increaseApproval(spender, 3 * ONE_USDG);
        assertEq(token.allowance(alice, spender), 3 * ONE_USDG);
        token.decreaseApproval(spender, ONE_USDG);
        assertEq(token.allowance(alice, spender), 2 * ONE_USDG);
        token.decreaseApproval(spender, 10 * ONE_USDG);
        assertEq(token.allowance(alice, spender), 0, "a decrease past zero stops at zero");
        vm.expectRevert(MockUSDG.ZeroValue.selector);
        token.increaseApproval(spender, 0);
        vm.stopPrank();
    }

    function testFuzz_TransferConservesTheSupply(uint256 amount) public {
        amount = bound(amount, 0, START_BALANCE);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), START_BALANCE);
        assertEq(token.totalSupply(), START_BALANCE);
    }

    // ===============================================================================================================
    // EIP-2612 permit
    // ===============================================================================================================

    function test_PermitWithAnEoaSignatureSetsTheAllowance() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            UsdgSigner.sign(aliceKey, address(token).permitDigest(alice, spender, 7 * ONE_USDG, deadline));

        vm.expectEmit(true, true, false, true, address(token));
        emit MockUSDG.Approval(alice, spender, 7 * ONE_USDG);
        token.permit(alice, spender, 7 * ONE_USDG, deadline, sig);

        assertEq(token.allowance(alice, spender), 7 * ONE_USDG);
        assertEq(token.nonces(alice), 1);
    }

    function test_PermitWithTheVrsForm() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            UsdgSigner.signVrs(aliceKey, address(token).permitDigest(alice, spender, ONE_USDG, deadline));
        token.permit(alice, spender, ONE_USDG, deadline, v, r, s);
        assertEq(token.allowance(alice, spender), ONE_USDG);
    }

    function test_PermitFromAnErc1271Wallet() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            UsdgSigner.sign(aliceKey, address(token).permitDigest(address(wallet), spender, ONE_USDG, deadline));
        token.permit(address(wallet), spender, ONE_USDG, deadline, sig);
        assertEq(token.allowance(address(wallet), spender), ONE_USDG);
    }

    function test_RevertWhen_PermitHasExpired() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).permitDigest(alice, spender, ONE_USDG, deadline));
        vm.expectRevert(MockUSDG.PermitExpired.selector);
        token.permit(alice, spender, ONE_USDG, deadline, sig);
    }

    function test_RevertWhen_PermitIsSignedByAnotherKey() public {
        (, uint256 eveKey) = makeAddrAndKey("eve");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = UsdgSigner.sign(eveKey, address(token).permitDigest(alice, spender, ONE_USDG, deadline));
        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.permit(alice, spender, ONE_USDG, deadline, sig);
    }

    function test_RevertWhen_PermitIsReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).permitDigest(alice, spender, ONE_USDG, deadline));
        token.permit(alice, spender, ONE_USDG, deadline, sig);
        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.permit(alice, spender, ONE_USDG, deadline, sig);
    }

    function test_RevertWhen_PermitWhilePausedOrFrozen() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).permitDigest(alice, spender, ONE_USDG, deadline));

        vm.prank(admin);
        token.freeze(spender);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.permit(alice, spender, ONE_USDG, deadline, sig);

        vm.startPrank(admin);
        token.unfreeze(spender);
        token.pause();
        vm.stopPrank();
        vm.expectRevert(MockUSDG.ContractPaused.selector);
        token.permit(alice, spender, ONE_USDG, deadline, sig);
    }

    function test_CancelPermitsInvalidatesPermitsAlreadySigned() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).permitDigest(alice, spender, ONE_USDG, deadline));

        vm.expectEmit(true, false, false, true, address(token));
        emit MockUSDG.PermitInvalidated(alice, 1);
        vm.prank(alice);
        token.cancelPermits(1);

        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.permit(alice, spender, ONE_USDG, deadline, sig);

        vm.prank(alice);
        vm.expectRevert(MockUSDG.InvalidNonceCount.selector);
        token.cancelPermits(101);
    }

    // ===============================================================================================================
    // EIP-3009 transfer and receive with authorization
    // ===============================================================================================================

    /// @dev The call the leverage contract makes to pull a stake: the payee (here bob, standing in for the contract)
    ///      submits the payer's signed authorization for exactly `value`.
    function test_ReceiveWithAuthorizationMovesExactlyTheValue() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, 25 * ONE_USDG, "stake-1");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));

        vm.expectEmit(true, true, false, false, address(token));
        emit MockUSDG.AuthorizationUsed(alice, a.nonce);
        vm.expectEmit(true, true, false, true, address(token));
        emit MockUSDG.Transfer(alice, bob, 25 * ONE_USDG);
        vm.prank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);

        assertEq(token.balanceOf(bob), 25 * ONE_USDG);
        assertEq(token.balanceOf(alice), START_BALANCE - 25 * ONE_USDG);
        assertTrue(token.authorizationState(alice, a.nonce));
    }

    function test_ReceiveWithAuthorizationInTheVrsForm() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "stake-vrs");
        (uint8 v, bytes32 r, bytes32 s) = UsdgSigner.signVrs(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, v, r, s);
        assertEq(token.balanceOf(bob), ONE_USDG);
    }

    function test_RevertWhen_ReceiveIsSubmittedByAnyoneButThePayee() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "front-run");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(spender);
        vm.expectRevert(MockUSDG.CallerMustBePayee.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    /// @dev `validAfter` is strict: at exactly `validAfter` the authorization is not valid yet.
    function test_RevertWhen_TheAuthorizationIsNotValidYet() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "early");
        a.validAfter = block.timestamp;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        vm.expectRevert(MockUSDG.AuthorizationInvalid.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    /// @dev `validBefore` is strict too: at exactly `validBefore` the authorization has expired.
    function test_RevertWhen_TheAuthorizationHasExpired() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "late");
        a.validBefore = block.timestamp;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        vm.expectRevert(MockUSDG.AuthorizationExpired.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    /// @dev The behaviour the leverage contract must defend against: a second use of the same nonce does NOT revert.
    ///      It emits `AuthorizationAlreadyUsed` and moves nothing, so only a balance check notices.
    function test_AReusedNonceMovesNothingAndDoesNotRevert() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, 4 * ONE_USDG, "reused");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.startPrank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);

        vm.expectEmit(true, true, false, false, address(token));
        emit MockUSDG.AuthorizationAlreadyUsed(alice, a.nonce);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 4 * ONE_USDG, "the second call moved nothing");
        assertEq(token.balanceOf(alice), START_BALANCE - 4 * ONE_USDG);
    }

    /// @dev A payer can cancel a signed authorization before it is used. The later receive then silently moves
    ///      nothing, which the leverage contract must also catch with its balance check.
    function test_ACancelledNonceMovesNothingAndDoesNotRevert() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, 4 * ONE_USDG, "cancelled");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        bytes memory cancelSig = UsdgSigner.sign(aliceKey, address(token).cancelDigest(alice, a.nonce));

        vm.expectEmit(true, true, false, false, address(token));
        emit MockUSDG.AuthorizationCanceled(alice, a.nonce);
        token.cancelAuthorization(alice, a.nonce, cancelSig);
        assertTrue(token.authorizationState(alice, a.nonce));

        vm.expectEmit(true, true, false, false, address(token));
        emit MockUSDG.AuthorizationAlreadyUsed(alice, a.nonce);
        vm.prank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);

        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), START_BALANCE);
    }

    function test_RevertWhen_TheAuthorizationIsSignedByAnotherKey() public {
        (, uint256 eveKey) = makeAddrAndKey("eve");
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "forged");
        bytes memory sig = UsdgSigner.sign(eveKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    /// @dev The type hash is part of the signature, so a payee-only authorization can't be submitted by anyone through
    ///      `transferWithAuthorization`.
    function test_RevertWhen_AReceiveSignatureIsUsedForTransfer() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "wrong-type");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(spender);
        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.transferWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    function test_TransferWithAuthorizationCanBeSubmittedByAnyone() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "any-relayer");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, false));
        vm.prank(spender);
        token.transferWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
        assertEq(token.balanceOf(bob), ONE_USDG);
    }

    function test_RevertWhen_AnAuthorizationIsUsedWhilePaused() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "paused");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(admin);
        token.pause();
        vm.prank(bob);
        vm.expectRevert(MockUSDG.ContractPaused.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    function test_RevertWhen_ThePayerOrThePayeeIsFrozen() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "frozen");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));

        vm.prank(admin);
        token.freeze(alice);
        vm.prank(bob);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);

        vm.startPrank(admin);
        token.unfreeze(alice);
        token.freeze(bob);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(MockUSDG.AddressFrozen.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    function testFuzz_ReceiveWithAuthorizationMovesExactlyTheValue(uint256 value, bytes32 nonce) public {
        value = bound(value, 0, START_BALANCE);
        UsdgSigner.Authorization memory a = _authorization(alice, bob, value, "");
        a.nonce = nonce;
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
        assertEq(token.balanceOf(bob), value);
        assertEq(token.balanceOf(alice), START_BALANCE - value);
    }

    // ===============================================================================================================
    // Signature forms
    // ===============================================================================================================

    function test_ReceiveWithAuthorizationFromAnErc1271Wallet() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(alice);
        vm.prank(admin);
        token.mint(address(wallet), 10 * ONE_USDG);

        UsdgSigner.Authorization memory a = _authorization(address(wallet), bob, 3 * ONE_USDG, "wallet");
        bytes memory sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
        assertEq(token.balanceOf(bob), 3 * ONE_USDG);

        wallet.setRejectAll(true);
        a.nonce = keccak256("wallet-2");
        sig = UsdgSigner.sign(aliceKey, address(token).authorizationDigest(a, true));
        vm.prank(bob);
        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    /// @dev Under EIP-7702 an EOA can carry code. The real token checks ECDSA first (OpenZeppelin 4.9 order), so the
    ///      owner's plain signature still works. OpenZeppelin 5.x `SignatureChecker` would ask the code through
    ///      ERC-1271 instead and reject it; the last assertion shows that difference, which is why the leverage
    ///      contract checks ECDSA first too (docs/ARCHITECTURE.md §7).
    function test_AcceptsAPlainSignatureFromAnAddressWithCode() public {
        vm.etch(alice, hex"5f5ff3"); // PUSH0 PUSH0 RETURN: any code, no ERC-1271 support
        UsdgSigner.Authorization memory a = _authorization(alice, bob, 2 * ONE_USDG, "eip7702");
        bytes32 digest = address(token).authorizationDigest(a, true);
        bytes memory sig = UsdgSigner.sign(aliceKey, digest);

        vm.prank(bob);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
        assertEq(token.balanceOf(bob), 2 * ONE_USDG);

        assertFalse(SignatureChecker.isValidSignatureNow(alice, digest, sig), "OZ 5 rejects it; the token doesn't");
    }

    /// @dev For every valid (r, s, v) there is a second valid signature (r, n - s, v ^ 1). OpenZeppelin's ECDSA
    ///      rejects the high-s copy, so a signature can't be re-shaped into a "new" one.
    function test_RevertWhen_TheSignatureIsMalleable() public {
        UsdgSigner.Authorization memory a = _authorization(alice, bob, ONE_USDG, "malleable");
        (uint8 v, bytes32 r, bytes32 s) = UsdgSigner.signVrs(aliceKey, address(token).authorizationDigest(a, true));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.prank(bob);
        vm.expectRevert(MockUSDG.InvalidSignature.selector);
        token.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, flippedV, r, highS);
    }

    // ===============================================================================================================
    // Helpers
    // ===============================================================================================================

    /// @dev An authorization valid from one second ago for one minute, with a nonce derived from `label`.
    function _authorization(
        address from,
        address to,
        uint256 value,
        string memory label
    )
        internal
        view
        returns (UsdgSigner.Authorization memory)
    {
        return UsdgSigner.Authorization({
            from: from,
            to: to,
            value: value,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60,
            nonce: keccak256(bytes(label))
        });
    }
}
