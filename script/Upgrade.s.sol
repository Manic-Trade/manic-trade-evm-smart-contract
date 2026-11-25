// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ManicFlashOption} from "../src/ManicFlashOption.sol";
import {BaseScript} from "./Base.s.sol";

/// @title Upgrade
/// @notice Upgrades the recorded proxy to a new implementation built from this checkout: deploys it, then calls
///         `upgradeToAndCall` from the upgrader, with `data` (a reinitializer's call, or nothing). Then checks the
/// proxy points at it, and that every setting, role, market and book reads exactly as before, and records it.
/// @dev The testnet process of ARCHITECTURE §4.2. On mainnet the upgrader is the timelock, so the Safe schedules
///      `upgradeToAndCall` instead, and this script only shows what to check.
///      **First, run the layout check** against the deployed version's build-info, which is kept in
///      deployments/<chainId>/build-info-v<version>/: `python3 test/upgrade/layout/check.py`. It runs OpenZeppelin's
///      upgrades plugin outside Foundry, so no script needs FFI (docs/CONVENTIONS.md §10).
///
///      forge script script/Upgrade.s.sol --rpc-url robinhood_testnet --account <upgrader> --broadcast
///      forge script script/Upgrade.s.sol --sig "runWithCall(bytes)" <calldata> ...   (with a reinitializer's call)
contract Upgrade is BaseScript {
    /// @notice The snapshot of the recorded proxy on the live chain, sending nothing. Run it before and after an
    ///         upgrade's broadcast (`forge script ... --sig "liveSnapshot()"`): the two must be equal. `run()` checks
    /// the same before it broadcasts, on a fork; this is the check on the chain itself.
    /// @return The snapshot.
    function liveSnapshot() external view returns (bytes32) {
        Record memory r = _loadRecord();
        require(r.proxy.code.length > 0, "Upgrade: no live proxy in the record");
        return snapshot(ManicFlashOption(r.proxy), _inputs());
    }

    /// @notice Re-checks the recorded upgrade on the live chain, sending nothing (`--sig "verify()"`): the proxy points
    ///         at the record's implementation, which fits the size limit, is locked, and reports the record's version.
    function verify() external view {
        Record memory r = _loadRecord();
        require(r.proxy.code.length > 0, "Upgrade verify: no live proxy in the record");
        require(_implementationOf(r.proxy) == r.implementation, "Upgrade verify: the proxy's implementation");
        uint256 size = r.implementation.code.length;
        require(size > 0 && size <= MAX_CODE_SIZE, "Upgrade verify: the implementation's code size");
        require(
            _initializedVersion(r.implementation) == type(uint64).max, "Upgrade verify: the implementation is locked"
        );
        require(
            keccak256(bytes(ManicFlashOption(r.proxy).version())) == keccak256(bytes(r.version)),
            "Upgrade verify: version"
        );
    }

    /// @notice Upgrades with no call.
    /// @return implementation The new implementation.
    function run() external returns (address implementation) {
        return _upgrade("");
    }

    /// @notice Upgrades, calling `data` on the proxy in the same transaction (`forge script` refuses two functions
    ///         named `run`).
    /// @param data The call.
    /// @return implementation The new implementation.
    function runWithCall(bytes memory data) external returns (address implementation) {
        return _upgrade(data);
    }

    /// @dev The upgrade, its check, and the record.
    function _upgrade(bytes memory data) private returns (address implementation) {
        Inputs memory i = _inputs();
        Record memory r = _loadRecord();
        require(r.proxy.code.length > 0, "Upgrade: no live proxy in the record");
        ManicFlashOption proxy = ManicFlashOption(r.proxy);
        require(_implementationOf(r.proxy) == r.implementation, "Upgrade: the record's implementation is not live");
        bytes32 before = snapshot(proxy, i);

        vm.startBroadcast(i.upgrader);
        implementation = _newImplementation();
        proxy.upgradeToAndCall(implementation, data);
        vm.stopBroadcast();

        check(proxy, implementation, before, i);
        r.implementation = implementation;
        r.version = proxy.version();
        r.commit = vm.envOr("GIT_COMMIT", string("unknown"));
        _saveRecord(r);
    }

    /// @notice Reverts unless the proxy points at `implementation`, which is locked and fits the size limit, and
    ///         everything `snapshot` reads is as it was before.
    /// @param proxy The proxy.
    /// @param implementation The new implementation.
    /// @param before The snapshot taken before the upgrade.
    /// @param i The inputs, which name the role holders.
    function check(ManicFlashOption proxy, address implementation, bytes32 before, Inputs memory i) public view {
        require(_implementationOf(address(proxy)) == implementation, "Upgrade check: the proxy's implementation");
        uint256 size = implementation.code.length;
        require(size > 0 && size <= MAX_CODE_SIZE, "Upgrade check: the implementation's code size");
        require(_initializedVersion(implementation) == type(uint64).max, "Upgrade check: the implementation is locked");
        require(snapshot(proxy, i) == before, "Upgrade check: a setting, role, market or book changed");
    }

    /// @notice A hash of everything an upgrade must keep: the token, the recipients, the refund delay, the brakes, the
    ///         pool's books, the breaker, every market, and every role of the holders chains.toml names.
    /// @param proxy The proxy.
    /// @param i The inputs.
    /// @return The hash.
    function snapshot(ManicFlashOption proxy, Inputs memory i) public view returns (bytes32) {
        (address feeRecipient, address rewardsRecipient) = proxy.recipients();
        bytes memory state = abi.encode(
            proxy.token(),
            feeRecipient,
            rewardsRecipient,
            proxy.refundDelaySecs(),
            proxy.halted(),
            proxy.getPool(),
            proxy.getBreaker(),
            proxy.defaultAdmin(),
            proxy.defaultAdminDelay()
        );
        uint16 count = proxy.marketCount();
        for (uint16 j; j < count; ++j) {
            (bytes32 marketId, uint16 leverage) = proxy.marketIdAt(j);
            state = abi.encode(state, proxy.getMarket(marketId, leverage));
        }
        state = abi.encode(
            state,
            proxy.hasRole(proxy.UPGRADER_ROLE(), i.upgrader),
            proxy.hasRole(proxy.OPERATOR_ROLE(), i.operator),
            proxy.hasRole(proxy.GUARDIAN_ROLE(), i.guardian)
        );
        for (uint256 j; j < i.openers.length; ++j) {
            state = abi.encode(state, proxy.hasRole(proxy.OPENER_ROLE(), i.openers[j]));
        }
        for (uint256 j; j < i.settlers.length; ++j) {
            state = abi.encode(state, proxy.hasRole(proxy.SETTLER_ROLE(), i.settlers[j]));
        }
        return keccak256(state);
    }

    /// @notice Deploys the new implementation: this checkout's `ManicFlashOption`. A test overrides it to upgrade to a
    ///         mock of the next version.
    /// @return The implementation.
    function _newImplementation() internal virtual returns (address) {
        return address(new ManicFlashOption());
    }
}
