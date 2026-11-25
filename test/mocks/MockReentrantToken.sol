// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockReentrantToken
/// @notice A 6-decimal token that calls back into a contract from inside a transfer, before it moves anything, as a
///         token with transfer hooks could: an ERC-777-style token, or USDG after an upgrade by its issuer. It proves
///         that every state-changing function is `nonReentrant` (docs/security-checklist.md RE-1).
/// @dev `setCallback(target, data)` arms it. Every later transfer between two accounts (not a mint) first calls
///      `target` with `data`. If that call reverts, the transfer reverts with `CallbackReverted(reason)`, so a test
///      sees both that the callback was made and why it was refused. `setCallback(address(0), "")` disarms it.
///      `receiveWithAuthorization` is EIP-3009's pull without the signature check: only the payee may call it, as on
///      USDG, so `open` can be entered again from inside its stake pull.
contract MockReentrantToken is ERC20 {
    /// @notice The callback reverted; `reason` is its revert data.
    error CallbackReverted(bytes reason);

    /// @notice `receiveWithAuthorization` was called by someone other than the payee (USDG's own error name).
    error CallerMustBePayee();

    /// @dev The contract to call back into; the zero address when disarmed.
    address public callbackTarget;
    /// @dev The call to make.
    bytes public callbackData;

    constructor() ERC20("Reentrant Token", "REENTER") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    /// @dev Moves `value` from `from` to the caller, who must be `to`; the authorisation itself is not checked.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32,
        bytes calldata
    )
        external
    {
        if (msg.sender != to) revert CallerMustBePayee();
        _transfer(from, to, value);
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    /// @dev Calls back first, then moves the tokens. Mints and burns never call back.
    function _update(address from, address to, uint256 value) internal override {
        if (callbackTarget != address(0) && from != address(0) && to != address(0)) {
            (bool success, bytes memory reason) = callbackTarget.call(callbackData);
            if (!success) revert CallbackReverted(reason);
        }
        super._update(from, to, value);
    }
}
