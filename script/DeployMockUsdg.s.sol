// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {BaseScript} from "./Base.s.sol";

/// @title DeployMockUsdg
/// @notice Deploys the test token on a chain with no USDG (the Robinhood testnet), and records it, so Deploy.s.sol
///         gives it to the proxy. Its admin, who alone mints, pauses and freezes, is the chain's deployer.
/// @dev The token is test/mocks/MockUSDG.sol, the mock every contract test runs: it copies the real USDG's checks,
///      errors and signatures, and a weekly fork test holds it to the live token step by step. So the backend
///      signs for it exactly as for USDG on mainnet: same EIP-712 name ("Global Dollar") and version ("1"), and the
///      same EIP-3009 authorisations. Refuses a chain whose chains.toml names a real token, and Robinhood mainnet.
///
///      forge script script/DeployMockUsdg.s.sol --rpc-url robinhood_testnet --account <deployer> --broadcast
contract DeployMockUsdg is BaseScript {
    /// @notice Robinhood Chain mainnet, which has the real USDG.
    uint256 internal constant ROBINHOOD_MAINNET = 4663;

    /// @notice The mock's name and symbol: the real token's, since the name is also its EIP-712 domain name.
    string internal constant NAME = "Global Dollar";
    string internal constant SYMBOL = "USDG";

    /// @notice Deploys the mock, checks it, and records it.
    /// @return token The mock.
    function run() external returns (MockUSDG token) {
        require(block.chainid != ROBINHOOD_MAINNET, "DeployMockUsdg: mainnet has the real USDG");
        Inputs memory i = _inputs();
        require(i.token == address(0), "DeployMockUsdg: chains.toml names this chain's token; no mock is needed");
        Record memory r = _loadRecord();
        require(r.proxy.code.length == 0, "DeployMockUsdg: a proxy is already deployed with the recorded token");

        vm.startBroadcast(i.deployer);
        token = new MockUSDG(NAME, SYMBOL, i.deployer);
        vm.stopBroadcast();

        check(token, i.deployer);
        r.deployer = i.deployer;
        r.token = address(token);
        r.tokenIsMock = true;
        _saveRecord(r);
    }

    /// @notice Reverts unless `token` is a fresh mock with `admin` as its admin.
    /// @param token The mock.
    /// @param admin Its expected admin.
    function check(MockUSDG token, address admin) public view {
        require(address(token).code.length > 0, "MockUSDG check: no code");
        require(token.admin() == admin, "MockUSDG check: admin");
        require(token.decimals() == 6, "MockUSDG check: decimals");
        require(keccak256(bytes(token.name())) == keccak256(bytes(NAME)), "MockUSDG check: name");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes(SYMBOL)), "MockUSDG check: symbol");
        require(token.totalSupply() == 0, "MockUSDG check: supply");
        require(!token.paused(), "MockUSDG check: paused");
    }
}
