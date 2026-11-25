// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DrainerImplementationMock
/// @notice What a leaked upgrader key could install (`test/access/KeyBlastRadius.t.sol`): an implementation the
///         proxy accepts, whose one function sends the proxy's whole balance of a token to any address. It shows the
///         upgrader key alone can take the whole pool, which is why mainnet holds it in the 48-hour timelock
///         (docs/ARCHITECTURE.md §4.2).
/// @dev UUPS's `upgradeToAndCall` only asks the new implementation for `proxiableUUID`, which must be the ERC-1967
///      implementation slot, so that is all this needs. It has no upgrade function of its own: once installed, the
///      proxy could never be upgraded again.
contract DrainerImplementationMock {
    using SafeERC20 for IERC20;

    /// @dev The ERC-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The answer UUPS's `upgradeToAndCall` checks before it installs this implementation.
    function proxiableUUID() external pure returns (bytes32) {
        return _IMPLEMENTATION_SLOT;
    }

    /// @notice Sends this contract's (the proxy's) whole balance of `token` to `to`.
    function drain(IERC20 token, address to) external {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }
}
