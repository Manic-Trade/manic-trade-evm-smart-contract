// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, SellOrder} from "../../src/types/OrderTypes.sol";
import {Side} from "../../src/types/StorageTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {ManicFlashOptionHarness} from "../harnesses/ManicFlashOptionHarness.sol";
import {OrderSigner} from "../utils/OrderSigner.sol";

/// @title Order_Fuzz_Test
/// @notice The signed orders, for random keys and orders (docs/ARCHITECTURE.md §7):
///         - an order signed by its user always verifies, and signed by any other key it never does;
///         - changing any one field of either order changes its digest, so no field is left out of the signature;
///         - a signature is bound to its chain (security checklist SIG-1).
/// @dev The digests come from the harness's own `hashOpenOrder` and `hashSellOrder`, and the check is its
///      `_checkSignature`, so both use the same domain. An order's fields are drawn from one seed, so the enum can
///      never be out of range. Inputs are bounded with `bound`, never `vm.assume`. CI runs 10,000 cases per property.
contract Order_Fuzz_Test is Base_Test {
    ManicFlashOptionHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = _deployHarness(_defaultInitParams());
    }

    function testFuzz_AnOrderSignedByItsUserVerifies(uint256 key, uint256 seed) external view {
        key = _key(key);
        address user = vm.addr(key);
        bytes32 digest = harness.hashOpenOrder(_openOrder(user, seed));
        harness.exposed_checkSignature(user, digest, OrderSigner.sign(key, digest));
        digest = harness.hashSellOrder(_sellOrder(seed));
        harness.exposed_checkSignature(user, digest, OrderSigner.sign(key, digest));
    }

    function testFuzz_AnOrderSignedByAnyOtherKeyIsRefused(uint256 key, uint256 otherKey, uint256 seed) external {
        key = _key(key);
        otherKey = _key(otherKey);
        if (otherKey == key) otherKey = key == OrderSigner.SECP256K1_N - 1 ? 1 : key + 1;
        address user = vm.addr(key);
        bytes32 digest = harness.hashOpenOrder(_openOrder(user, seed));
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(user, digest, OrderSigner.sign(otherKey, digest));
        digest = harness.hashSellOrder(_sellOrder(seed));
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(user, digest, OrderSigner.sign(otherKey, digest));
    }

    function testFuzz_ChangingAnyFieldOfAnOpenOrderChangesItsDigest(
        uint256 seed,
        uint8 field,
        uint256 noise
    )
        external
        view
    {
        OpenOrder memory o = _openOrder(users.alice, seed);
        bytes32 before = harness.hashOpenOrder(o);
        uint256 flip = noise | 1; // odd, so XOR-ing any of its low bits into a field changes it
        field %= 9;
        if (field == 0) o.positionId ^= bytes32(flip);
        else if (field == 1) o.user = address(uint160(o.user) ^ uint160(flip));
        else if (field == 2) o.marketId ^= bytes32(flip);
        else if (field == 8) o.leverage ^= uint16(flip); // the leverage is signed too (ADR 0008)
        else if (field == 3) o.side = o.side == Side.Call ? Side.Put : Side.Call;
        else if (field == 4) o.stake ^= uint64(flip);
        else if (field == 5) o.durationSecs ^= uint16(flip);
        else if (field == 6) o.notBefore ^= uint48(flip);
        else o.deadline ^= uint48(flip);
        assertNotEq(harness.hashOpenOrder(o), before, "a changed field must change the digest");
    }

    function testFuzz_ChangingAnyFieldOfASellOrderChangesItsDigest(
        uint256 seed,
        uint8 field,
        uint256 noise
    )
        external
        view
    {
        SellOrder memory s = _sellOrder(seed);
        bytes32 before = harness.hashSellOrder(s);
        uint256 flip = noise | 1;
        field %= 4;
        if (field == 0) s.positionId ^= bytes32(flip);
        else if (field == 1) s.minAmount ^= uint64(flip);
        else if (field == 2) s.notBefore ^= uint48(flip);
        else s.deadline ^= uint48(flip);
        assertNotEq(harness.hashSellOrder(s), before, "a changed field must change the digest");
    }

    function testFuzz_ASignatureIsBoundToItsChain(uint256 key, uint256 seed, uint64 otherChainId) external {
        key = _key(key);
        address user = vm.addr(key);
        OpenOrder memory o = _openOrder(user, seed);
        bytes memory signature = OrderSigner.sign(key, harness.hashOpenOrder(o));
        uint256 home = block.chainid;
        otherChainId = uint64(bound(otherChainId, 1, type(uint64).max));
        if (otherChainId == home) ++otherChainId;

        vm.chainId(otherChainId);
        bytes32 there = harness.hashOpenOrder(o);
        vm.expectRevert(Errors.InvalidSignature.selector);
        harness.exposed_checkSignature(user, there, signature);

        vm.chainId(home);
        harness.exposed_checkSignature(user, harness.hashOpenOrder(o), signature);
    }

    /// @dev A valid secp256k1 private key: 1 to N - 1.
    function _key(uint256 key) private pure returns (uint256) {
        return bound(key, 1, OrderSigner.SECP256K1_N - 1);
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

    /// @dev A sell order, every field drawn from `seed`.
    function _sellOrder(uint256 seed) private pure returns (SellOrder memory s) {
        s.positionId = keccak256(abi.encode(seed, "positionId"));
        s.minAmount = uint64(seed >> 8);
        s.notBefore = uint48(seed >> 72);
        s.deadline = uint48(seed >> 120);
    }
}
