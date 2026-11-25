// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Test} from "forge-std/Test.sol";

/// @title Toolchain_Test
/// @notice Proves the pinned toolchain works before any contract code exists:
///         - the cancun EVM target is active, so transient storage runs;
///         - the OpenZeppelin base and upgradeable packages resolve through `remappings.txt`;
///         - OpenZeppelin's transient reentrancy guard, which the contract will use, works.
/// @dev If someone changes `evm_version` to a fork older than cancun, the build fails: OpenZeppelin's
///      `TransientSlot` and the assembly below use TLOAD/TSTORE, which earlier targets reject at compile time.
///      If a remapping breaks, the imports above stop resolving. See docs/adr/0004-toolchain.md.
contract Toolchain_Test is Test {
    /// @dev TSTORE/TLOAD (EIP-1153) exist from the cancun fork on. A value written with TSTORE is readable
    ///      with TLOAD for the rest of the transaction, then cleared.
    function test_TransientStorageRoundTrips() public {
        uint256 value;
        assembly {
            tstore(0, 42)
            value := tload(0)
        }
        assertEq(value, 42, "tload must return what tstore wrote in the same transaction");
    }

    /// @dev The upgradeable package compiles against our copy of the base package, and UUPS reports the
    ///      standard ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
    function test_UupsUsesTheErc1967ImplementationSlot() public {
        UupsProbe implementation = new UupsProbe();
        bytes32 erc1967ImplementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(implementation.proxiableUUID(), erc1967ImplementationSlot);
    }

    /// @dev A function guarded by OpenZeppelin's transient `nonReentrant` runs normally when entered once.
    function test_TransientGuardAllowsASingleEntry() public {
        GuardProbe probe = new GuardProbe();
        probe.enter({reenter: false});
        assertEq(probe.entries(), 1);
    }

    /// @dev Re-entering the same guarded function in one transaction reverts with the library's error.
    function test_RevertWhen_TransientGuardIsReentered() public {
        GuardProbe probe = new GuardProbe();
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        probe.enter({reenter: true});
    }
}

/// @notice The smallest possible UUPS implementation, used only to read `proxiableUUID()`.
/// @dev The upgrade gate is open because this contract is never deployed behind a proxy.
contract UupsProbe is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
}

/// @notice Calls itself back when asked to, so the test can check that the transient guard blocks it.
contract GuardProbe is ReentrancyGuardTransient {
    uint256 public entries;

    function enter(bool reenter) external nonReentrant {
        entries += 1;
        if (reenter) this.enter({reenter: false});
    }
}
