// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

// The getters keep the constants' UPPER_SNAKE names (see @dev below), so the mixed-case lints are off in this file.
/* solhint-disable func-name-mixedcase */
// forge-lint: disable-start(mixed-case-function)

/// @title IManicFlashOptionRoles
/// @author Manic
/// @notice The ids of the contract's roles, for OpenZeppelin's `hasRole`, `grantRole` and `revokeRole`. Who holds each
///         role on mainnet, and what it may do, is in docs/ARCHITECTURE.md §4.2.
/// @dev Each id is the keccak256 of its name (OpenZeppelin's convention), and `DEFAULT_ADMIN_ROLE` is 0x00. Every
///      role's admin is `DEFAULT_ADMIN_ROLE`, which only one account holds: the 48-hour timelock on mainnet. The
///      getters keep the constants' UPPER_SNAKE names, as OpenZeppelin's own `DEFAULT_ADMIN_ROLE()` does, so the
///      mixed-case lints are switched off for this file.
/// @custom:security-contact See SECURITY.md
interface IManicFlashOptionRoles {
    /// @notice The upgrader: the only role that can upgrade the implementation. The timelock on mainnet.
    /// @return The role's id: keccak256("UPGRADER_ROLE").
    function UPGRADER_ROLE() external view returns (bytes32);

    /// @notice The operator: market settings, enabling markets, unpausing, unhalting and resetting the circuit
    ///         breaker. None of these moves money. The admin Safe on mainnet, acting at once.
    /// @return The role's id: keccak256("OPERATOR_ROLE").
    function OPERATOR_ROLE() external view returns (bytes32);

    /// @notice The guardian: halts the contract, pauses a market and revokes a relayer key. It can only take power
    ///         away, never add it.
    /// @return The role's id: keccak256("GUARDIAN_ROLE").
    function GUARDIAN_ROLE() external view returns (bytes32);

    /// @notice The opening relayer: the backend accounts that open and sell positions. It is trusted for the price
    ///         only.
    /// @return The role's id: keccak256("OPENER_ROLE").
    function OPENER_ROLE() external view returns (bytes32);

    /// @notice The settling relayer: the backend accounts that liquidate and settle positions, kept separate from the
    ///         openers so that one leaked key can't do both.
    /// @return The role's id: keccak256("SETTLER_ROLE").
    function SETTLER_ROLE() external view returns (bytes32);
}
// forge-lint: disable-end(mixed-case-function)
