// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockFeeOnTransferToken
/// @notice A 6-decimal token that burns 1 base unit of every transfer, so the receiver gets one unit less than was
///         sent. `fund` must refuse it (`TransferAmountMismatch`), because the pool's books would count money that
///         never arrived.
contract MockFeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    /// @dev Transfers between two accounts lose 1 unit to a burn; mints and burns are unchanged.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }
        super._update(from, address(0), 1);
        super._update(from, to, value - 1);
    }
}
