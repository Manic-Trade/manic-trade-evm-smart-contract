// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title MockOddERC1271Wallet
/// @notice A contract wallet that answers every `isValidSignature` call wrongly, in one of four ways. The contract must
///         take none of them for "valid": only the exact 32-byte magic value `0x1626ba7e` counts (ERC-1271).
/// @dev It answers through `fallback`, so the reply is returned exactly as written, not ABI-encoded.
contract MockOddERC1271Wallet {
    /// @notice The wrong answers.
    enum Answer {
        Nothing, // returns no data at all
        Revert, // reverts
        ShortMagic, // returns the 4-byte magic value, not padded to 32 bytes
        WrongValue // returns 32 bytes that are not the magic value
    }

    /// @notice This wallet's answer.
    Answer public immutable answer;

    constructor(Answer answer_) {
        answer = answer_;
    }

    // The point of this mock: it answers every call, `isValidSignature` included, with raw bytes of its choosing,
    // which only a fallback can do.
    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata) external returns (bytes memory) {
        if (answer == Answer.Revert) revert("MockOddERC1271Wallet: no");
        if (answer == Answer.ShortMagic) return abi.encodePacked(bytes4(0x1626ba7e));
        if (answer == Answer.WrongValue) return abi.encode(bytes32(uint256(0x1626ba7e)));
        return "";
    }
}
