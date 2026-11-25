// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

/// @notice The token functions the signing helpers read. Both `MockUSDG` and the real USDG implement them.
interface IUsdgSigningView {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
}

/// @title UsdgSigner
/// @author Manic
/// @notice Builds and signs USDG's EIP-2612 permits and EIP-3009 authorizations in tests, the same way the backend's
///         custody signer will sign them for users.
/// @dev Works with `MockUSDG` and with the real USDG on a fork, because both use the same type hashes and an
///      EIP-712 domain of (name, "1", chainId, token address). Signatures are returned as `r ‖ s ‖ v` bytes, the
///      form the bytes-signature functions take.
library UsdgSigner {
    /// @dev The Foundry cheat-code address, so a library can call `vm.sign`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    // Adjacent string literals are joined by the compiler, so each type string is exactly the EIP-3009 one.
    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /// @notice One EIP-3009 authorization, as the payer signs it.
    struct Authorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    /// @notice The digest of a permit for `owner`'s current nonce.
    function permitDigest(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    )
        internal
        view
        returns (bytes32)
    {
        uint256 nonce = IUsdgSigningView(token).nonces(owner);
        return _digest(token, keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)));
    }

    /// @notice The digest of a `TransferWithAuthorization` or `ReceiveWithAuthorization`.
    /// @param receive_ True for `ReceiveWithAuthorization` (payee-only), false for `TransferWithAuthorization`.
    function authorizationDigest(address token, Authorization memory a, bool receive_) internal view returns (bytes32) {
        bytes32 typeHash = receive_ ? RECEIVE_WITH_AUTHORIZATION_TYPEHASH : TRANSFER_WITH_AUTHORIZATION_TYPEHASH;
        bytes32 structHash =
            keccak256(abi.encode(typeHash, a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce));
        return _digest(token, structHash);
    }

    /// @notice The digest of a `CancelAuthorization`.
    function cancelDigest(address token, address authorizer, bytes32 nonce) internal view returns (bytes32) {
        return _digest(token, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
    }

    /// @notice Signs `digest` with `privateKey` and returns the signature as `r ‖ s ‖ v`.
    function sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Signs `digest` and returns `(v, r, s)` separately, for the v,r,s function variants.
    function signVrs(uint256 privateKey, bytes32 digest) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        return VM.sign(privateKey, digest);
    }

    function _digest(address token, bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", IUsdgSigningView(token).DOMAIN_SEPARATOR(), structHash));
    }
}
