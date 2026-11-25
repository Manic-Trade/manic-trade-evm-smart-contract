// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ManicFlashOption} from "../src/ManicFlashOption.sol";
import {InitParams} from "../src/types/ParamTypes.sol";
import {Breaker, PoolState} from "../src/types/StorageTypes.sol";
import {BaseScript} from "./Base.s.sol";

/// @title Deploy
/// @notice Deploys the contract: the implementation, then the ERC-1967 proxy, which calls `initialize` in its own
///         constructor, so nobody can initialize it first (ARCHITECTURE §15 rule 2). Every setting comes from the
///         chain's table in chains.toml. Then checks every value the setup wrote, and records the addresses.
/// @dev The markets and the pool's money come after, in Configure.s.sol. Refuses a chain whose record already has a
///      live proxy: that one is upgraded (Upgrade.s.sol), never replaced.
///
///      GIT_COMMIT=$(git rev-parse HEAD) forge script script/Deploy.s.sol --rpc-url robinhood_testnet \
///        --account <deployer> --broadcast
contract Deploy is BaseScript {
    /// @notice The implementation's version and its EIP-712 domain: what `version()` and `eip712Domain()` must say.
    string internal constant VERSION = "1.0.0";
    string internal constant EIP712_NAME = "Manic Flash Option";
    string internal constant EIP712_VERSION = "1";

    /// @notice Re-checks the recorded deployment on the live chain, sending nothing: `forge script` runs `run()`'s
    ///         checks before it broadcasts, so this is the check after (`forge script ... --sig "verify()"`, no
    ///         `--broadcast`). Passes while the deployment is as `Deploy` left it: no market yet, an empty pool.
    function verify() external view {
        Inputs memory i = _inputs();
        Record memory r = _loadRecord();
        require(r.proxy.code.length > 0, "Deploy verify: no live proxy in the record");
        check(ManicFlashOption(r.proxy), r.implementation, _initParams(i, _token(i, r)), i.deployer);
    }

    /// @notice Deploys, checks and records the contract.
    /// @return proxy The proxy, typed as the contract.
    function run() external returns (ManicFlashOption proxy) {
        Inputs memory i = _inputs();
        Record memory r = _loadRecord();
        require(r.proxy.code.length == 0, "Deploy: the record has a live proxy on this chain; upgrade it instead");
        InitParams memory p = _initParams(i, _token(i, r));

        uint256 startBlock = _chainBlockNumber();
        vm.startBroadcast(i.deployer);
        ManicFlashOption implementation;
        (implementation, proxy) = deploy(p);
        vm.stopBroadcast();

        check(proxy, address(implementation), p, i.deployer);
        r.deployer = i.deployer;
        r.token = address(p.token);
        r.implementation = address(implementation);
        r.proxy = address(proxy);
        r.version = VERSION;
        r.startBlock = startBlock;
        r.commit = vm.envOr("GIT_COMMIT", string("unknown"));
        _saveRecord(r);
    }

    /// @notice The two deployments: the implementation, then the proxy, initialized with `p` in its constructor.
    /// @param p The setup.
    /// @return implementation The implementation.
    /// @return proxy The proxy, typed as the contract.
    function deploy(InitParams memory p) public returns (ManicFlashOption implementation, ManicFlashOption proxy) {
        implementation = new ManicFlashOption();
        proxy = ManicFlashOption(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ManicFlashOption.initialize, (p))))
        );
    }

    /// @notice Reverts, naming the value, unless the deployment is exactly what `p` describes: the proxy and its
    ///         implementation, the version and signing domain, every role, the token, the floor, the recipients, the
    ///         refund delay and the breaker, with no market and an empty pool. The deployer holds only the roles `p`
    ///         gives it.
    /// @param proxy The proxy.
    /// @param implementation The implementation it must point at.
    /// @param p The setup.
    /// @param deployer The account that deployed it.
    function check(ManicFlashOption proxy, address implementation, InitParams memory p, address deployer) public view {
        // The proxy, the implementation and the code.
        require(_implementationOf(address(proxy)) == implementation, "Deploy check: the proxy's implementation");
        uint256 size = implementation.code.length;
        require(size > 0 && size <= MAX_CODE_SIZE, "Deploy check: the implementation's code size");
        require(_initializedVersion(implementation) == type(uint64).max, "Deploy check: the implementation is locked");
        require(_initializedVersion(address(proxy)) == 1, "Deploy check: the proxy is initialized once");
        require(_same(proxy.version(), VERSION), "Deploy check: version");
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            proxy.eip712Domain();
        require(_same(name, EIP712_NAME) && _same(version, EIP712_VERSION), "Deploy check: the EIP-712 name, version");
        require(chainId == block.chainid && verifyingContract == address(proxy), "Deploy check: the EIP-712 domain");

        // The roles.
        require(proxy.defaultAdmin() == p.admin, "Deploy check: admin");
        require(proxy.defaultAdminDelay() == p.adminTransferDelay, "Deploy check: the admin transfer delay");
        require(proxy.hasRole(proxy.UPGRADER_ROLE(), p.upgrader), "Deploy check: upgrader");
        require(proxy.hasRole(proxy.OPERATOR_ROLE(), p.operator), "Deploy check: operator");
        require(proxy.hasRole(proxy.GUARDIAN_ROLE(), p.guardian), "Deploy check: guardian");
        for (uint256 j; j < p.openers.length; ++j) {
            require(proxy.hasRole(proxy.OPENER_ROLE(), p.openers[j]), "Deploy check: an opener");
        }
        for (uint256 j; j < p.settlers.length; ++j) {
            require(proxy.hasRole(proxy.SETTLER_ROLE(), p.settlers[j]), "Deploy check: a settler");
        }
        _checkDeployerRoles(proxy, p, deployer);

        // The settings, and nothing else yet.
        require(address(proxy.token()) == address(p.token), "Deploy check: token");
        PoolState memory pool = proxy.getPool();
        require(pool.poolFloor == p.poolFloor, "Deploy check: the pool floor");
        require(pool.total == 0 && pool.openPositions == 0, "Deploy check: the pool is empty");
        (address feeRecipient, address rewardsRecipient) = proxy.recipients();
        require(feeRecipient == p.feeRecipient, "Deploy check: the fee recipient");
        require(rewardsRecipient == p.rewardsRecipient, "Deploy check: the rewards recipient");
        require(proxy.refundDelaySecs() == p.refundDelaySecs, "Deploy check: the refund delay");
        Breaker memory b = proxy.getBreaker();
        require(b.maxNetProfit == p.breakerMaxNetProfit, "Deploy check: the breaker's limit");
        require(b.windowSecs == p.breakerWindowSecs, "Deploy check: the breaker's window");
        require(!b.tripped, "Deploy check: the breaker is not tripped");
        require(!proxy.halted(), "Deploy check: not halted");
        require(proxy.marketCount() == 0, "Deploy check: no market yet");
    }

    /// @dev Reverts if the deployer holds a role `p` doesn't give it (ARCHITECTURE §4.2: the deployer gets none of its
    ///      own; on the testnet chains.toml makes it the admin, upgrader, operator and guardian).
    function _checkDeployerRoles(ManicFlashOption proxy, InitParams memory p, address deployer) private view {
        bool opener;
        for (uint256 j; j < p.openers.length; ++j) {
            opener = opener || p.openers[j] == deployer;
        }
        bool settler;
        for (uint256 j; j < p.settlers.length; ++j) {
            settler = settler || p.settlers[j] == deployer;
        }
        require(
            proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), deployer) == (p.admin == deployer)
                && proxy.hasRole(proxy.UPGRADER_ROLE(), deployer) == (p.upgrader == deployer)
                && proxy.hasRole(proxy.OPERATOR_ROLE(), deployer) == (p.operator == deployer)
                && proxy.hasRole(proxy.GUARDIAN_ROLE(), deployer) == (p.guardian == deployer)
                && proxy.hasRole(proxy.OPENER_ROLE(), deployer) == opener
                && proxy.hasRole(proxy.SETTLER_ROLE(), deployer) == settler,
            "Deploy check: the deployer holds a role it was not given"
        );
    }

    /// @dev Whether two strings are equal.
    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
