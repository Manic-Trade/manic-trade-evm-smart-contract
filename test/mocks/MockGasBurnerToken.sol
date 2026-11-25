// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

/// @title MockGasBurnerToken
/// @notice A 6-decimal token whose `transfer` runs out of gas. It stands for a payout starved of gas: `_pay` must
///         revert (`InsufficientGasForPayout`), not push the winner into `claimable`.
/// @dev With a `burner`, the transfer calls it first and the gas runs out there, one call deeper, as it would in a
///      token that checks a compliance registry. Behind a proxy, as USDG is, the gas runs out one call deeper again.
///      Each level keeps back 1/64 of the gas it passes on (EIP-150) and hands it back when it reverts, so the deeper
///      the gas runs out, the more gas comes back to `_pay`.
contract MockGasBurnerToken {
    uint8 public constant decimals = 6;

    /// @dev Where the gas runs out: in `transfer` itself when unset, otherwise in a call to this contract.
    GasBurner public immutable burner;

    uint256 internal counter;

    constructor(GasBurner burner_) {
        burner = burner_;
    }

    function transfer(address, uint256) external returns (bool) {
        if (address(burner) != address(0)) burner.burn();
        while (true) {
            ++counter;
        }
        return true;
    }
}

/// @title GasBurner
/// @notice Loops until it runs out of gas; `MockGasBurnerToken` calls it to run out of gas one call deeper.
contract GasBurner {
    uint256 internal counter;

    function burn() external {
        while (true) {
            ++counter;
        }
    }
}
