// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

import {LayoutReader} from "./LayoutReader.sol";

/// @title LayoutWriter
/// @notice Writes a setting straight into the contract's storage, for a state no function can reach any more.
/// @dev It uses the slot map that `LayoutReader` decodes (docs/storage-layout.md).
library LayoutWriter {
    /// @dev Foundry's cheatcode address.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Switches off the open gate of `target`'s market of `marketId` at `leverage`: writes 0 over its stored
    ///         `maxExposureBps` (the market's slot 1, bits 152 to 183) and keeps the rest of the slot.
    /// @dev `validate` refuses 0 (ADR 0009), so only an upgrade could do this now. With the gate on, free money always
    ///      covers the open bets' max profit, and no winner is ever owed. The tests of the IOU path, which stays in the
    ///      code as a backstop, start from here. A later `setConfig` puts the gate back on.
    /// @return index The market's index.
    function switchOffOpenGate(address target, bytes32 marketId, uint16 leverage) internal returns (uint16 index) {
        uint16 indexPlusOne = LayoutReader.marketIndexPlusOne(target, marketId, leverage);
        require(indexPlusOne != 0, "LayoutWriter: no such market");
        index = indexPlusOne - 1;
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(index), LayoutReader.ROOT + 9))) + 1);
        uint256 mask = uint256(type(uint32).max) << 152;
        VM.store(target, slot, bytes32(uint256(VM.load(target, slot)) & ~mask));
    }
}
