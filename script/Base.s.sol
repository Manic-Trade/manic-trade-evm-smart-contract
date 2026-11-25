// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Script} from "forge-std/Script.sol";

import {InitParams} from "../src/types/ParamTypes.sol";

/// @title BaseScript
/// @notice What every script shares: the chain's inputs, from script/config/chains.toml, and its deployment record,
///         deployments/<chainId>.json, which each script reads and writes back (docs/CONVENTIONS.md §10).
/// @dev Each script sends its transactions from the chain's `deployer` (`vm.startBroadcast(deployer)`), so the wallet
///      given to `forge script` must be that account, and a test can run the same `run()` with no key at all.
abstract contract BaseScript is Script {
    /// @notice A chain's inputs: one table of chains.toml, whose header comment says what each field is.
    struct Inputs {
        string name;
        address deployer;
        address admin;
        uint48 adminTransferDelay;
        address upgrader;
        address operator;
        address guardian;
        address[] openers;
        address[] settlers;
        address token;
        uint64 poolFloor;
        address feeRecipient;
        address rewardsRecipient;
        uint48 refundDelaySecs;
        uint64 breakerMaxNetProfit;
        uint32 breakerWindowSecs;
        uint16[] leverages;
        uint16[] enabled;
        uint64 poolFunding;
    }

    /// @notice A chain's deployment record: what the scripts deployed there, and where to start reading its events.
    struct Record {
        address deployer; // who sent the transactions
        address token; // the token the proxy uses
        bool tokenIsMock; // whether `token` is our mock (DeployMockUsdg.s.sol), whose admin is the deployer
        address implementation; // the proxy's current implementation
        address proxy; // the contract's address: the one the backend and the app use
        string version; // the implementation's `version()`
        uint256 startBlock; // the chain's latest block before the deployment: index the proxy's events from here
        string commit; // the git commit the implementation was built from (GIT_COMMIT)
    }

    /// @notice Where the inputs are.
    string internal constant CHAINS = "script/config/chains.toml";

    /// @notice Robinhood Chain's runtime code limit, in bytes (docs/adr/0007-robinhood-code-size-limit.md).
    uint256 internal constant MAX_CODE_SIZE = 98_304;

    /// @notice The ERC-1967 implementation slot: `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice OpenZeppelin 5's `Initializable` storage (ERC-7201 "openzeppelin.storage.Initializable"), whose first
    ///         field is the initialized version: 1 after `initialize`, all ones once initializers are disabled.
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @notice The chain's own latest block number, for a check by hand (`forge script ... --sig
    /// "chainBlockNumber()"`).
    /// @return The block number.
    function chainBlockNumber() external returns (uint256) {
        return _chainBlockNumber();
    }

    /// @notice This chain's inputs, for a check by hand (`forge script ... --sig "inputs()"`) and for the tests.
    /// @return The inputs.
    function inputs() external view returns (Inputs memory) {
        return _inputs();
    }

    /// @notice This chain's table of chains.toml. Reverts if the chain has none, so a script never runs on a chain
    ///         nobody prepared, and if a value doesn't fit its type.
    /// @return i The inputs.
    function _inputs() internal view returns (Inputs memory i) {
        string memory toml = vm.readFile(_chainsFile());
        string memory k = string.concat(".", vm.toString(block.chainid));
        require(
            vm.keyExistsToml(toml, k), string.concat("chains.toml has no table for chain ", vm.toString(block.chainid))
        );
        i.name = vm.parseTomlString(toml, string.concat(k, ".name"));
        i.deployer = vm.parseTomlAddress(toml, string.concat(k, ".deployer"));
        i.admin = vm.parseTomlAddress(toml, string.concat(k, ".admin"));
        i.adminTransferDelay = SafeCast.toUint48(vm.parseTomlUint(toml, string.concat(k, ".admin_transfer_delay")));
        i.upgrader = vm.parseTomlAddress(toml, string.concat(k, ".upgrader"));
        i.operator = vm.parseTomlAddress(toml, string.concat(k, ".operator"));
        i.guardian = vm.parseTomlAddress(toml, string.concat(k, ".guardian"));
        i.openers = vm.parseTomlAddressArray(toml, string.concat(k, ".openers"));
        i.settlers = vm.parseTomlAddressArray(toml, string.concat(k, ".settlers"));
        i.token = vm.parseTomlAddress(toml, string.concat(k, ".token"));
        i.poolFloor = SafeCast.toUint64(vm.parseTomlUint(toml, string.concat(k, ".pool_floor")));
        i.feeRecipient = vm.parseTomlAddress(toml, string.concat(k, ".fee_recipient"));
        i.rewardsRecipient = vm.parseTomlAddress(toml, string.concat(k, ".rewards_recipient"));
        i.refundDelaySecs = SafeCast.toUint48(vm.parseTomlUint(toml, string.concat(k, ".refund_delay_secs")));
        i.breakerMaxNetProfit = SafeCast.toUint64(vm.parseTomlUint(toml, string.concat(k, ".breaker_max_net_profit")));
        i.breakerWindowSecs = SafeCast.toUint32(vm.parseTomlUint(toml, string.concat(k, ".breaker_window_secs")));
        i.leverages = _toUint16s(vm.parseTomlUintArray(toml, string.concat(k, ".leverages")));
        i.enabled = _toUint16s(vm.parseTomlUintArray(toml, string.concat(k, ".enabled")));
        i.poolFunding = SafeCast.toUint64(vm.parseTomlUint(toml, string.concat(k, ".pool_funding")));
        for (uint256 j; j < i.enabled.length; ++j) {
            require(_contains(i.leverages, i.enabled[j]), "chains.toml: an enabled leverage is not in `leverages`");
        }
    }

    /// @notice The inputs file: chains.toml. A test points it at a fixture.
    function _chainsFile() internal view virtual returns (string memory) {
        return CHAINS;
    }

    /// @notice `initialize`'s parameters from the inputs, with `token` as the token.
    /// @param i The inputs.
    /// @param token The token the proxy will use.
    /// @return The parameters.
    function _initParams(Inputs memory i, address token) internal pure returns (InitParams memory) {
        return InitParams({
            admin: i.admin,
            adminTransferDelay: i.adminTransferDelay,
            upgrader: i.upgrader,
            operator: i.operator,
            guardian: i.guardian,
            openers: i.openers,
            settlers: i.settlers,
            token: IERC20(token),
            poolFloor: i.poolFloor,
            feeRecipient: i.feeRecipient,
            rewardsRecipient: i.rewardsRecipient,
            refundDelaySecs: i.refundDelaySecs,
            breakerMaxNetProfit: i.breakerMaxNetProfit,
            breakerWindowSecs: i.breakerWindowSecs
        });
    }

    /// @notice The token for this chain: chains.toml's `token`, or the mock in the record when that is the zero
    /// address.
    /// @param i The inputs.
    /// @param r The record.
    /// @return token The token's address, which has code.
    function _token(Inputs memory i, Record memory r) internal view returns (address token) {
        if (i.token != address(0)) {
            token = i.token;
        } else {
            require(r.tokenIsMock, "no token: chains.toml's is zero and the record has no mock (run DeployMockUsdg)");
            token = r.token;
        }
        require(token.code.length > 0, "the token has no code on this chain");
    }

    /// @notice This chain's record file.
    function _recordPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    /// @notice This chain's record; all zero if there is none yet.
    /// @return r The record.
    function _loadRecord() internal view returns (Record memory r) {
        string memory path = _recordPath();
        if (!vm.exists(path)) return r;
        string memory json = vm.readFile(path);
        r.deployer = _address(json, ".deployer");
        r.token = _address(json, ".token");
        r.tokenIsMock = vm.keyExistsJson(json, ".tokenIsMock") && vm.parseJsonBool(json, ".tokenIsMock");
        r.implementation = _address(json, ".implementation");
        r.proxy = _address(json, ".proxy");
        r.version = vm.keyExistsJson(json, ".version") ? vm.parseJsonString(json, ".version") : "";
        r.startBlock = vm.keyExistsJson(json, ".startBlock") ? vm.parseJsonUint(json, ".startBlock") : 0;
        r.commit = vm.keyExistsJson(json, ".commit") ? vm.parseJsonString(json, ".commit") : "";
    }

    /// @notice Writes `r` as this chain's record, replacing the file.
    /// @param r The record.
    function _saveRecord(Record memory r) internal {
        string memory o = "record";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "deployer", r.deployer);
        vm.serializeAddress(o, "token", r.token);
        vm.serializeBool(o, "tokenIsMock", r.tokenIsMock);
        vm.serializeAddress(o, "implementation", r.implementation);
        vm.serializeAddress(o, "proxy", r.proxy);
        vm.serializeString(o, "version", r.version);
        vm.serializeUint(o, "startBlock", r.startBlock);
        string memory json = vm.serializeString(o, "commit", r.commit);
        vm.writeJson(json, _recordPath());
    }

    /// @notice The chain's own latest block number, from its RPC (`eth_blockNumber`): the number its events and its
    ///         explorer use. On Robinhood Chain, an Arbitrum Orbit chain, `block.number` inside the EVM is the parent
    ///         chain's block number (ArbOS), and Foundry reproduces that, so it can't say where to index from. Without
    ///         an RPC (a test), `block.number`.
    function _chainBlockNumber() internal returns (uint256 number) {
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory data) {
            for (uint256 j; j < data.length; ++j) {
                number = (number << 8) | uint8(data[j]);
            }
        } catch {
            number = block.number;
        }
    }

    /// @notice The implementation an ERC-1967 proxy points at.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @notice The initialized version of a contract built on OpenZeppelin 5's `Initializable`.
    function _initializedVersion(address target) internal view returns (uint64) {
        return uint64(uint256(vm.load(target, INITIALIZABLE_SLOT)));
    }

    /// @notice Whether `list` holds `value`.
    function _contains(uint16[] memory list, uint16 value) internal pure returns (bool) {
        for (uint256 j; j < list.length; ++j) {
            if (list[j] == value) return true;
        }
        return false;
    }

    /// @dev The address at `key` of `json`, or zero if the key is missing.
    function _address(string memory json, string memory key) private view returns (address) {
        return vm.keyExistsJson(json, key) ? vm.parseJsonAddress(json, key) : address(0);
    }

    /// @dev Each value as a `uint16`, reverting on one that doesn't fit.
    function _toUint16s(uint256[] memory values) private pure returns (uint16[] memory out) {
        out = new uint16[](values.length);
        for (uint256 j; j < values.length; ++j) {
            out[j] = SafeCast.toUint16(values[j]);
        }
    }
}
