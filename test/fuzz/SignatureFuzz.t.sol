// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder} from "../../src/types/OrderTypes.sol";
import {Side} from "../../src/types/StorageTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {ManicFlashOptionHarness} from "../harnesses/ManicFlashOptionHarness.sol";
import {OrderLibHarness} from "../harnesses/OrderLibHarness.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {MockOddERC1271Wallet} from "../mocks/MockOddERC1271Wallet.sol";
import {OrderSigner} from "../utils/OrderSigner.sol";

/// @title Signature_Fuzz_Test
/// @notice `_checkSignature`, the check `open` and `sell` make, for random keys, digests and bytes
///         (docs/ARCHITECTURE.md §7, security checklist SIG-1 and SIG-6). Every way a signature can be wrong is
///         refused with `InvalidSignature`:
///         - a signature made for another domain: another contract, another name or another version (another chain
///           is in OrderFuzz.t.sol);
///         - the malleable twin of a real signature, a `v` other than 27 or 28, any length but 65 bytes (the 64-byte
///           compact form included), and random bytes, also for the zero address;
///         - for an ERC-1271 wallet, anything but its owner's signature of that very digest, and any answer but the
///           exact magic value;
///         - for an EIP-7702 account (an EOA with code), anything but its own key. When its own key signed, its code
///           is never even asked.
/// @dev The concrete tests (test/concrete/checkSignature/) show each case for one key and one digest; these show it
///      for any. A digest is any 32 bytes, since the check never looks inside it; but ECDSA signs a digest mod N, the
///      curve's order, so two digests equal mod N are one digest to it (N and 0, found by the deep fuzz run of
///      2026-11-19). Inputs are bounded with `bound`, never `vm.assume`. CI runs 10,000 cases per property.
contract Signature_Fuzz_Test is Base_Test {
    /// @dev The deep fuzz run's counterexample (2026-11-19) to
    ///      `testFuzz_AWalletPassesOnlyItsOwnersSignatureOfThatDigest`: these two keys, a digest of N and another of 0.
    uint256 internal constant FOUND_OWNER_KEY = 35_894;
    uint256 internal constant FOUND_OTHER_KEY = 19_362;

    /// @dev EIP-712's domain type hash: what a domain separator hashes, field by field.
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev An EIP-712 domain, as `eip712Domain()` reports it.
    struct Domain {
        string name;
        string version;
        uint256 chainId;
        address verifyingContract;
    }

    ManicFlashOptionHarness internal harness;
    OrderLibHarness internal orderLib;

    function setUp() public override {
        super.setUp();
        harness = _deployHarness(_defaultInitParams());
        orderLib = new OrderLibHarness();
    }

    /// @dev A signature for the same order under another domain (one of its contract, name or version changed) is
    ///      refused; under the contract's own domain, the same key's signature passes. The test builds both digests
    ///      itself, and first checks its own digest equals the contract's, so the domain is the one the contract uses.
    function testFuzz_ASignatureForAnotherDomainIsRefused(
        uint256 key,
        uint256 seed,
        uint8 field,
        address otherContract,
        uint256 noise
    )
        external
    {
        key = _key(key);
        OpenOrder memory o = _openOrder(vm.addr(key), seed);
        bytes32 structHash = orderLib.hashOpenOrderStruct(o);
        Domain memory home = _domain();
        bytes32 digest = _digest(home, structHash);
        assertEq(digest, harness.hashOpenOrder(o), "the test's digest is the contract's");

        Domain memory other = _changed(home, field, otherContract, noise);
        bytes memory elsewhere = OrderSigner.sign(key, _digest(other, structHash));
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(o.user, digest, elsewhere);
        harness.exposed_checkSignature(o.user, digest, OrderSigner.sign(key, digest));
    }

    /// @dev The malleable twin of a real signature (`s' = N - s`, the other `v`) recovers to the same signer at the
    ///      precompile, and is still refused: only the low-`s` form passes.
    function testFuzz_TheMalleableTwinOfAnySignatureIsRefused(uint256 key, bytes32 digest) external {
        key = _key(key);
        address signer = vm.addr(key);
        bytes memory signature = OrderSigner.sign(key, digest);
        bytes memory twin = OrderSigner.highS(signature);
        (bytes32 r, bytes32 s, uint8 v) = OrderSigner.split(twin);
        assertEq(ecrecover(digest, v, r, s), signer, "the twin is a real signature: the precompile takes it");

        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(signer, digest, twin);
        harness.exposed_checkSignature(signer, digest, signature);
    }

    /// @dev A real `r` and `s` with any `v` but 27 or 28 (a recovery id of 0 or 1 included) is refused.
    function testFuzz_AnyVButTwentySevenOrTwentyEightIsRefused(uint256 key, bytes32 digest, uint8 v) external {
        key = _key(key);
        (bytes32 r, bytes32 s,) = OrderSigner.split(OrderSigner.sign(key, digest));
        if (v == 27 || v == 28) v += 2; // 29 or 30
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(vm.addr(key), digest, abi.encodePacked(r, s, v));
    }

    /// @dev A real signature at any other length is refused: cut short, or padded with any bytes. At 64 bytes it is
    ///      the EIP-2098 compact form of the same signature, which the contract doesn't take either.
    function testFuzz_AnyLengthButSixtyFiveIsRefused(
        uint256 key,
        bytes32 digest,
        uint256 length,
        bytes32 filler
    )
        external
    {
        key = _key(key);
        bytes memory signature = OrderSigner.sign(key, digest);
        length = bound(length, 0, 130);
        if (length == 65) length = 64;
        bytes memory bad;
        if (length == 64) {
            (bytes32 r, bytes32 s, uint8 v) = OrderSigner.split(signature);
            bad = abi.encodePacked(r, s | bytes32(uint256(v - 27) << 255)); // yParity in the top bit of s
        } else {
            bad = new bytes(length);
            for (uint256 i; i < length; ++i) {
                bad[i] = i < 65 ? signature[i] : filler[i % 32];
            }
        }
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(vm.addr(key), digest, bad);
    }

    /// @dev 65 random bytes never pass for a key's address, nor for the zero address, which no signature recovers to
    ///      and which has no code to ask. (Passing for the key would mean forging its signature: about one chance in
    ///      2^160.)
    function testFuzz_RandomBytesNeverPass(uint256 key, bytes32 digest, bytes32 r, bytes32 s, uint8 v) external {
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(vm.addr(_key(key)), digest, signature);
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(address(0), digest, signature);
    }

    /// @dev An ERC-1271 wallet passes its owner's signature of the digest, and nothing else: not another key's, and
    ///      not its owner's signature of another digest.
    function testFuzz_AWalletPassesOnlyItsOwnersSignatureOfThatDigest(
        uint256 ownerKey,
        uint256 otherKey,
        bytes32 digest,
        bytes32 otherDigest
    )
        external
    {
        ownerKey = _key(ownerKey);
        otherKey = _otherKey(otherKey, ownerKey);
        // Another digest must differ mod N: one equal mod N is the same digest to ECDSA, and accepts the same
        // signatures (`test_DigestsEqualModNAcceptEachOthersSignatures`).
        if (uint256(otherDigest) % OrderSigner.SECP256K1_N == uint256(digest) % OrderSigner.SECP256K1_N) {
            otherDigest = bytes32(addmod(uint256(digest), 1, OrderSigner.SECP256K1_N));
        }
        address wallet = address(new MockERC1271Wallet(vm.addr(ownerKey)));

        harness.exposed_checkSignature(wallet, digest, OrderSigner.sign(ownerKey, digest));
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(wallet, digest, OrderSigner.sign(otherKey, digest));
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(wallet, digest, OrderSigner.sign(ownerKey, otherDigest));
    }

    /// @dev The deep fuzz run's counterexample (2026-11-19) holds now: a digest of N, and another of 0.
    function test_TheDeepRunCounterexampleHolds() external {
        this.testFuzz_AWalletPassesOnlyItsOwnersSignatureOfThatDigest(
            FOUND_OWNER_KEY, FOUND_OTHER_KEY, bytes32(OrderSigner.SECP256K1_N), bytes32(0)
        );
    }

    /// @dev ECDSA signs a digest mod N, the curve's order, so digests equal mod N accept each other's signatures: a
    ///      key's signature of 0 passes for N, and its signature of N for 0, from the key's account and from its wallet
    ///      (the signatures differ, since the signer's nonce comes from the digest's bytes). The contract signs nothing
    ///      but EIP-712 digests, keccak-256 hashes, which are N or above with odds of about 4e-39; a fuzz test's
    ///      "other digest" must differ mod N, not just differ.
    function test_DigestsEqualModNAcceptEachOthersSignatures() external {
        bytes32 n = bytes32(OrderSigner.SECP256K1_N);
        bytes memory signatureOfZero = OrderSigner.sign(FOUND_OWNER_KEY, bytes32(0));
        bytes memory signatureOfN = OrderSigner.sign(FOUND_OWNER_KEY, n);
        address account = vm.addr(FOUND_OWNER_KEY);
        address wallet = address(new MockERC1271Wallet(account));
        harness.exposed_checkSignature(account, n, signatureOfZero);
        harness.exposed_checkSignature(account, bytes32(0), signatureOfN);
        harness.exposed_checkSignature(wallet, n, signatureOfZero);
        harness.exposed_checkSignature(wallet, bytes32(0), signatureOfN);
    }

    /// @dev A wallet that answers wrongly (nothing, a revert, the magic value unpadded, another 32-byte value) never
    ///      passes, whatever it is shown: a real signature or random bytes.
    function testFuzz_AWalletThatAnswersWronglyNeverPasses(
        uint8 answer,
        uint256 key,
        bytes32 digest,
        bool real
    )
        external
    {
        address wallet = address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer(answer % 4)));
        bytes memory signature = real ? OrderSigner.sign(_key(key), digest) : abi.encodePacked(digest, key);
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(wallet, digest, signature);
    }

    /// @dev An EOA with code, as one with an EIP-7702 delegation has, still verifies with its own key, and its code
    ///      isn't even asked; any other key fails, since the code (here, a delegate that refuses everything) says no.
    function testFuzz_AnEip7702AccountVerifiesWithItsOwnKeyOnly(
        uint256 key,
        uint256 otherKey,
        bytes32 digest
    )
        external
    {
        key = _key(key);
        otherKey = _otherKey(otherKey, key);
        address account = vm.addr(key);
        address refusesAll = address(new MockOddERC1271Wallet(MockOddERC1271Wallet.Answer.Revert));
        vm.etch(account, abi.encodePacked(hex"ef0100", refusesAll));

        // Another key: ECDSA recovers someone else, so the contract asks the account, whose code refuses.
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(account, digest, OrderSigner.sign(otherKey, digest));
        // Its own key: ECDSA passes, and the account is never asked. (`expectCall` counts every call to the end of the
        // test, so this check comes last.)
        vm.expectCall(account, abi.encodePacked(IERC1271.isValidSignature.selector), 0);
        harness.exposed_checkSignature(account, digest, OrderSigner.sign(key, digest));
    }

    /// @dev A valid secp256k1 private key: 1 to N - 1.
    function _key(uint256 key) private pure returns (uint256) {
        return bound(key, 1, OrderSigner.SECP256K1_N - 1);
    }

    /// @dev A valid key other than `key`.
    function _otherKey(uint256 other, uint256 key) private pure returns (uint256) {
        other = _key(other);
        return other != key ? other : (key == OrderSigner.SECP256K1_N - 1 ? 1 : key + 1);
    }

    /// @dev The contract's own domain.
    function _domain() private view returns (Domain memory d) {
        (, d.name, d.version, d.chainId, d.verifyingContract,,) = harness.eip712Domain();
    }

    /// @dev `d` with one field changed: field 0, the contract (to `otherContract`, or its neighbour if that is the
    ///      same); field 1, the name (to a number's digits, never "Manic Flash Option"); field 2, the version (to
    /// "1.<n>", never "1").
    function _changed(
        Domain memory d,
        uint8 field,
        address otherContract,
        uint256 noise
    )
        private
        pure
        returns (Domain memory c)
    {
        c = Domain({name: d.name, version: d.version, chainId: d.chainId, verifyingContract: d.verifyingContract});
        field %= 3;
        if (field == 0) {
            if (otherContract == d.verifyingContract) otherContract = address(uint160(otherContract) ^ 1);
            c.verifyingContract = otherContract;
        } else if (field == 1) {
            c.name = vm.toString(noise);
        } else {
            c.version = string.concat(d.version, ".", vm.toString(noise));
        }
    }

    /// @dev The EIP-712 digest of `structHash` under `d`: keccak256(0x1901 ‖ domain separator ‖ struct hash).
    function _digest(Domain memory d, bytes32 structHash) private pure returns (bytes32) {
        bytes32 separator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes(d.name)), keccak256(bytes(d.version)), d.chainId, d.verifyingContract
            )
        );
        return keccak256(abi.encodePacked(hex"1901", separator, structHash));
    }

    /// @dev An open order for `user`, every other field drawn from `seed`.
    function _openOrder(address user, uint256 seed) private pure returns (OpenOrder memory o) {
        o.positionId = keccak256(abi.encode(seed, "positionId"));
        o.user = user;
        o.marketId = keccak256(abi.encode(seed, "marketId"));
        o.leverage = uint16(seed >> 168);
        o.side = seed % 2 == 0 ? Side.Call : Side.Put;
        o.stake = uint64(seed >> 8);
        o.durationSecs = uint16(seed >> 72);
        o.notBefore = uint48(seed >> 88);
        o.deadline = uint48(seed >> 136);
    }
}
