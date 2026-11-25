// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

/// @title OrderSigner
/// @notice Signs order digests the way the backend does, and builds the broken signatures the tests need.
/// @dev A signature is 65 bytes, `r || s || v`, the format `ECDSA.tryRecover` and the backend use. Foundry's
///      `vm.sign` is deterministic (RFC 6979), like alloy's, so the same key and digest always give the same bytes.
library OrderSigner {
    /// @dev Foundry's cheatcode address.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The order of secp256k1's group. A valid `s` is at most half of it.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice `key`'s signature of `digest`, as 65 bytes `r ‖ s ‖ v`.
    function sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice The malleable twin of a valid signature: the same `r`, `s' = N - s` and the other `v`. The `ecrecover`
    ///         precompile accepts it for the same signer; OpenZeppelin's ECDSA refuses it, because `s'` is high.
    function highS(bytes memory signature) internal pure returns (bytes memory) {
        (bytes32 r, bytes32 s, uint8 v) = split(signature);
        return abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }

    /// @notice The three parts of a 65-byte signature.
    function split(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "OrderSigner: not 65 bytes");
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }
}
