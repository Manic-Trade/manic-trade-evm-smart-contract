// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @notice The accounts every test uses: one per role holder, the two recipients, and plain users. `Base_Test` creates
///         and labels them, so traces show names instead of addresses.
/// @dev On mainnet the admin and the upgrader are the same 48-hour timelock. The tests keep them apart, so each gate is
///      proven on its own.
struct Users {
    address admin; // DEFAULT_ADMIN_ROLE
    address upgrader; // UPGRADER_ROLE
    address operator; // OPERATOR_ROLE
    address guardian; // GUARDIAN_ROLE
    address opener; // OPENER_ROLE
    address settler; // SETTLER_ROLE
    address feeRecipient; // receives swept fees and seed recovery
    address rewardsRecipient; // receives rewards withdrawals
    address alice; // a bettor
    address bob; // a bettor
    address eve; // an attacker: holds no role
}
