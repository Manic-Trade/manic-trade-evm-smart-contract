// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title MockDecimalsToken
/// @notice A token with nothing but `decimals()`, so tests can set the proxy up with any number of decimals and check
///         `initialize`'s 6-to-9 rule and the floor's scaling.
contract MockDecimalsToken {
    /// @notice The token's decimals, fixed at deployment.
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}
