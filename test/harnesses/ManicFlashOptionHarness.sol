// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ManicFlashOption} from "../../src/ManicFlashOption.sol";

/// @title ManicFlashOptionHarness
/// @notice The contract plus external entry points into its internal helpers, so tests can call them through a proxy
///         before the functions that use them exist: `_pay` is first called by settle and sell, and `_checkSignature`
///         by open and sell.
/// @dev Deployed only as a test implementation behind a proxy; never in production.
contract ManicFlashOptionHarness is ManicFlashOption {
    /// @notice Calls `_pay(to, amount, positionId)`.
    function exposed_pay(address to, uint64 amount, bytes32 positionId) external {
        _pay(to, amount, positionId);
    }

    /// @notice Calls `_checkSignature(signer, digest, signature)`.
    function exposed_checkSignature(address signer, bytes32 digest, bytes calldata signature) external view {
        _checkSignature(signer, digest, signature);
    }
}
