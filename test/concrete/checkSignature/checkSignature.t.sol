// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder} from "../../../src/types/OrderTypes.sol";
import {Side} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {ManicFlashOptionHarness} from "../../harnesses/ManicFlashOptionHarness.sol";
import {MockERC1271Wallet} from "../../mocks/MockERC1271Wallet.sol";
import {MockOddERC1271Wallet} from "../../mocks/MockOddERC1271Wallet.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {OrderSigner} from "../../utils/OrderSigner.sol";

/// @title CheckSignature_Concrete_Test
/// @notice Every branch of `_checkSignature`, the check `open` and `sell` use, from
///         test/concrete/checkSignature/checkSignature.tree (docs/ARCHITECTURE.md §7, security checklist SIG-6),
///         called through `ManicFlashOptionHarness`.
/// @dev The digest is a real one: alice's order to open a $25 BTC call, hashed by the contract's `hashOpenOrder`.
///      ECDSA is tried first; only when it fails does the contract ask the signer (ERC-1271).
contract CheckSignature_Concrete_Test is Base_Test {
    ManicFlashOptionHarness internal harness;
    uint256 internal aliceKey;
    uint256 internal bobKey;
    bytes32 internal digest;

    function setUp() public override {
        super.setUp();
        harness = _deployHarness(_defaultInitParams());
        (, aliceKey) = makeAddrAndKey("alice");
        (, bobKey) = makeAddrAndKey("bob");
        OpenOrder memory o = OpenOrder({
            positionId: keccak256("alice's position"),
            user: users.alice,
            marketId: Defaults.BTC,
            leverage: Defaults.LEVERAGE,
            side: Side.Call,
            stake: 25e6,
            durationSecs: 60,
            notBefore: uint48(block.timestamp),
            deadline: uint48(block.timestamp + 30)
        });
        digest = harness.hashOpenOrder(o);
    }

    function test_WhenTheSignatureRecoversToTheSigner() external {
        // it should accept it, even if the signer has code
        bytes memory signature = OrderSigner.sign(aliceKey, digest);
        harness.exposed_checkSignature(users.alice, digest, signature);

        // Alice's address gets code, as an EOA does with an EIP-7702 delegation. Her own key still verifies, and the
        // contract never asks her account: its delegate, which refuses everything, is never called.
        address refusesAll = address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.Revert));
        vm.etch(users.alice, abi.encodePacked(hex"ef0100", refusesAll));
        vm.expectCall(users.alice, abi.encodePacked(IERC1271.isValidSignature.selector), 0);
        harness.exposed_checkSignature(users.alice, digest, signature);
    }

    modifier whenTheSignatureDoesNotRecoverToTheSigner() {
        _;
    }

    function test_RevertWhen_TheSignerHasNoCode() external whenTheSignatureDoesNotRecoverToTheSigner {
        // it should revert: alice has no code, so only her own key, on this digest, can sign for her
        bytes memory good = OrderSigner.sign(aliceKey, digest);
        (bytes32 r, bytes32 s, uint8 v) = OrderSigner.split(good);
        bytes[10] memory bad = [
            OrderSigner.sign(bobKey, digest), // another key
            OrderSigner.sign(aliceKey, keccak256("another digest")), // her key, another digest
            OrderSigner.highS(good), // the malleable twin
            abi.encodePacked(r, s, uint8(0)), // v as a recovery id, not 27 or 28
            abi.encodePacked(r, s, uint8(1)),
            abi.encodePacked(r, s, uint8(29)),
            abi.encodePacked(r, s | bytes32(uint256(v - 27) << 255)), // 64-byte EIP-2098 compact form
            abi.encodePacked(good, uint8(0)), // 66 bytes
            new bytes(65), // all zero
            new bytes(0) // empty
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Errors.InvalidSignature.selector);
            harness.exposed_checkSignature(users.alice, digest, bad[i]);
        }

        // The malleable twin is a real signature: the ecrecover precompile accepts it. Only its high `s` is refused.
        (bytes32 r2, bytes32 s2, uint8 v2) = OrderSigner.split(OrderSigner.highS(good));
        assertEq(ecrecover(digest, v2, r2, s2), users.alice, "the precompile accepts the twin");

        // A zero signer never passes: no signature recovers to the zero address, and it has no code to ask.
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(address(0), digest, new bytes(65));
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(address(0), digest, good);
    }

    modifier whenTheSignerHasCode() {
        _;
    }

    function test_WhenItsIsValidSignatureReturnsTheMagicValue()
        external
        whenTheSignatureDoesNotRecoverToTheSigner
        whenTheSignerHasCode
    {
        // it should accept it: a contract wallet owned by alice approves her signature, after ECDSA failed (the
        // signature recovers to alice, not to the wallet)
        MockERC1271Wallet wallet = new MockERC1271Wallet(users.alice);
        bytes memory signature = OrderSigner.sign(aliceKey, digest);
        // OpenZeppelin sends the signature without the ABI's trailing padding, so match the call on its start.
        vm.expectCall(address(wallet), abi.encodePacked(IERC1271.isValidSignature.selector, digest), 1);
        harness.exposed_checkSignature(address(wallet), digest, signature);
    }

    function test_RevertWhen_ItsIsValidSignatureGivesAnyOtherAnswer()
        external
        whenTheSignatureDoesNotRecoverToTheSigner
        whenTheSignerHasCode
    {
        // it should revert, for every answer but the exact 32-byte magic value
        bytes memory signature = OrderSigner.sign(aliceKey, digest);
        MockERC1271Wallet refusing = new MockERC1271Wallet(users.alice);
        refusing.setRejectAll(true);
        address[7] memory signers = [
            address(new MockERC1271Wallet(users.bob)), // bob's wallet: not his signature, so 0x00000000
            address(refusing), // alice's wallet, refusing everything: 0xffffffff
            address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.Nothing)),
            address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.Revert)),
            address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.ShortMagic)),
            address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.WrongValue)),
            address(usdg) // a contract with no isValidSignature at all
        ];
        for (uint256 i; i < signers.length; ++i) {
            vm.expectRevert(Errors.InvalidSignature.selector);
            harness.exposed_checkSignature(signers[i], digest, signature);
        }
    }
}
