// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MockERC1271Wallet
/// @author Manic
/// @notice A minimal contract wallet (ERC-1271): it approves a signature when its owner's key signed the digest.
///         Tests use it to check that tokens and the leverage contract accept signatures from contract wallets.
/// @dev `setRejectAll(true)` makes it refuse every signature, to test the failure path.
contract MockERC1271Wallet is IERC1271 {
    /// @notice The EOA whose ECDSA signatures this wallet accepts.
    address public immutable owner;

    /// @notice When true, `isValidSignature` refuses everything.
    bool public rejectAll;

    /// @param owner_ The EOA whose signatures the wallet accepts.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Turns "refuse every signature" on or off.
    /// @param reject True to refuse every signature.
    function setRejectAll(bool reject) external {
        rejectAll = reject;
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue) {
        if (rejectAll) return 0xffffffff;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == owner ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}
