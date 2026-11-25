// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title MockFalseToken
/// @notice A 6-decimal token whose `transfer` returns false instead of reverting, as some older tokens do when they
///         refuse a transfer. `_pay` must treat that as a refusal and keep the payout claimable.
contract MockFalseToken {
    uint8 public constant decimals = 6;

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
