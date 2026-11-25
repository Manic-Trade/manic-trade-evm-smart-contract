// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ManicFlashOption} from "../../src/ManicFlashOption.sol";

/// @title ManicFlashOptionV2Mock
/// @notice A second implementation for the upgrade tests: the same contract, plus one storage field appended to
///         `Layout`, the reinitializer that sets it, and two functions only V2 has.
/// @dev A real V2 declares its new field at the end of `Layout` itself (src/base/FlashOptionStorage.sol, "new fields go
///      below this line only"); test/upgrade/layout/variants/01-append-field.patch is that change, and the upgrades
///      plugin passes it. This mock can't edit src/, and it can't declare a second struct with `Layout`'s ERC-7201
///      storage-location annotation either: the plugin refuses two structs on one namespace, for every contract in the
///      build. So it reaches the same slot by position. `Layout` takes 14 slots, 9 of values and 5 mapping roots
///      (test/unit/FlashOptionStorage.t.sol pins them), so the first field appended to it starts at the namespace's
/// root plus 14.
contract ManicFlashOptionV2Mock is ManicFlashOption {
    /// @notice What V2 appends to `Layout`.
    /// @param newSetting A setting V1 doesn't have, set once by `initializeV2`.
    struct Appended {
        uint64 newSetting;
    }

    /// @notice Where V2's appended fields start: the namespace's root (manic.storage.FlashOption,
    /// FlashOptionStorage.sol) plus 14, the first slot after `Layout`'s last field, `claimable`.
    uint256 internal constant APPENDED_SLOT = 0xf273be9a24eeab036a40c6c3509d6aa7cccb8da2ecbd9965c4f2a996a54c2200 + 14;

    /// @notice Sets the field V2 appends. The upgrader calls it inside `upgradeToAndCall`, in the same transaction as
    ///         the upgrade, so the field is never left unset (docs/ARCHITECTURE.md §4.2, security checklist UPG-3).
    /// @dev `reinitializer(2)` lets it run once, and only on a proxy whose initializers ran up to version 1. The role
    ///      check covers an upgrade that skipped it: nobody but the upgrader can run it later. Inside
    ///      `upgradeToAndCall` the caller is still the upgrader, because the proxy reaches it by `delegatecall`.
    /// @param value The new setting's value.
    function initializeV2(uint64 value) external reinitializer(2) onlyRole(UPGRADER_ROLE) {
        _appended().newSetting = value;
    }

    /// @notice The field V2 appended.
    /// @return The value `initializeV2` set, or 0 before it ran.
    function newSetting() external view returns (uint64) {
        return _appended().newSetting;
    }

    /// @notice Only this implementation has it, so a test can tell which code the proxy runs.
    /// @return Always true.
    function isV2() external pure returns (bool) {
        return true;
    }

    /// @notice Points at V2's appended fields.
    /// @return a The fields at `APPENDED_SLOT`.
    function _appended() private pure returns (Appended storage a) {
        // forge-lint: disable-next-item(inline-assembly)
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            a.slot := APPENDED_SLOT
        }
    }
}
