// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {BaseScript} from "../../script/Base.s.sol";
import {Configure} from "../../script/Configure.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployMockUsdg} from "../../script/DeployMockUsdg.s.sol";
import {Smoke} from "../../script/Smoke.s.sol";
import {Upgrade} from "../../script/Upgrade.s.sol";
import {MarketSettings} from "../../script/config/MarketSettings.sol";
import {ManicFlashOption} from "../../src/ManicFlashOption.sol";
import {Position, Status} from "../../src/types/StorageTypes.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {Examples} from "../utils/Examples.sol";

/// @title Scripts_Sequence_Test
/// @notice The deploy scripts end to end, as on a real chain, through their own `run()`, with chains.toml's anvil
///         table (forge test's chain id is anvil's, 31337): the mock token, the deployment, the markets and the pool,
///         a bet opened and settled the way the backend makes it, and an upgrade. The only test that writes the
///         anvil record, deployments/31337.json (git-ignored), so no other test races it.
contract Scripts_Sequence_Test is Test {
    string internal constant RECORD = "deployments/31337.json";
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    /// @dev OpenZeppelin 5's `Initializable` storage, by the ERC-7201 formula.
    bytes32 internal constant INITIALIZABLE_SLOT =
        keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff));

    BaseScript.Inputs internal inputs;
    MockUSDG internal token;
    ManicFlashOption internal proxy;
    uint256 internal deployBlock;

    function test_TheScriptsDeployConfigureBetAndUpgrade() public {
        vm.warp(1_800_000_000); // a real chain's clock: the scripts sign authorisations valid from a minute ago
        if (vm.exists(RECORD)) vm.removeFile(RECORD);
        _deployAndConfigure();
        _betThroughSmoke();
        address implementation = _upgrade();
        _checkRecord(implementation);

        // A second deployment on the same chain is refused: the live proxy is upgraded, never replaced.
        Deploy again = Deploy(vm.deployCode("Deploy.s.sol:Deploy"));
        vm.expectRevert(bytes("Deploy: the record has a live proxy on this chain; upgrade it instead"));
        again.run();
        DeployMockUsdg mockAgain = DeployMockUsdg(vm.deployCode("DeployMockUsdg.s.sol:DeployMockUsdg"));
        vm.expectRevert(bytes("DeployMockUsdg: a proxy is already deployed with the recorded token"));
        mockAgain.run();

        // After trading, the pool is no longer at its target, which `verify()` reports: it checks a fresh setup.
        vm.expectRevert(bytes("Configure check: the pool's funding"));
        Configure(vm.deployCode("Configure.s.sol:Configure")).verify();
    }

    /// @dev The token, then the contract, then the markets and the pool: each script checks its own work and records
    ///      it. Configuring again changes nothing.
    function _deployAndConfigure() private {
        Deploy deploy = Deploy(vm.deployCode("Deploy.s.sol:Deploy"));
        inputs = deploy.inputs();
        token = DeployMockUsdg(vm.deployCode("DeployMockUsdg.s.sol:DeployMockUsdg")).run();
        vm.roll(1234); // a test has no RPC: the record takes block.number
        deployBlock = block.number;
        proxy = deploy.run();
        deploy.verify(); // the check after the broadcast, from the record
        assertEq(address(proxy.token()), address(token), "the proxy uses the mock");
        assertEq(token.admin(), inputs.deployer, "the deployer mints");

        Configure configure = Configure(vm.deployCode("Configure.s.sol:Configure"));
        configure.run();
        configure.verify();
        vm.expectRevert(bytes("Deploy check: the pool is empty"));
        deploy.verify(); // Deploy's state is gone once funded and configured, so its verify() no longer passes
        assertEq(proxy.marketCount(), 3, "three markets");
        assertEq(proxy.getPool().total, inputs.poolFunding, "the pool is funded to the target");
        assertEq(token.balanceOf(address(proxy)), inputs.poolFunding, "and holds it");
        uint256 supply = token.totalSupply();
        configure.run();
        assertEq(proxy.marketCount(), 3, "no market created twice");
        assertEq(proxy.getPool().total, inputs.poolFunding, "not funded twice");
        assertEq(token.totalSupply(), supply, "nothing minted twice");

        // `verify()` reads the live chain and fixes nothing: a market switched off after Configure fails it, where a
        // dry run of `run()` would switch it back on and pass. Configure then puts it right.
        vm.prank(inputs.operator);
        proxy.setConfig(MarketSettings.BTC, 100, MarketSettings.btc(100)); // switched off
        vm.expectRevert(bytes("Configure check: the settings of BTC at 100x"));
        configure.verify();
        configure.run();
        configure.verify();
    }

    /// @dev A bet: the user signs, the first opener opens, and at its expiry the first settler settles it, 1 bp up.
    function _betThroughSmoke() private {
        (address user, uint256 userKey) = makeAddrAndKey("smoke user");
        vm.prank(inputs.deployer);
        token.mint(user, 10e6);
        vm.setEnv("SMOKE_USER_KEY", vm.toString(userKey));
        Smoke smoke = Smoke(vm.deployCode("Smoke.s.sol:Smoke"));
        int64 price = Examples.P0;
        (bytes32 id, bytes memory openCall) = smoke.prepareOpen(1000, price);
        vm.prank(inputs.openers[0]);
        (bool ok,) = address(proxy).call(openCall);
        assertTrue(ok, "the first opener's open goes through");
        (Position memory p, uint48 endTime,) = proxy.getPosition(id);
        assertEq(uint8(p.status), uint8(Status.Open), "open");
        assertEq(p.user, user, "the user's");
        assertEq(token.balanceOf(user), 0, "the stake was pulled");
        vm.warp(endTime);
        smoke.settle(id, price + price / 10_000);
        (p,,) = proxy.getPosition(id);
        assertEq(uint8(p.status), uint8(Status.Closed), "settled");
        assertGt(token.balanceOf(user), 10e6, "a right call is paid more than its stake");
    }

    /// @dev The upgrade: a new implementation, and everything else as it was (the script checks that itself), then
    ///      the checks an operator runs on the live chain after the broadcast: the same live snapshot, and `verify()`,
    ///      which fails once the new implementation is no longer locked.
    function _upgrade() private returns (address implementation) {
        Upgrade upgrade = Upgrade(vm.deployCode("Upgrade.s.sol:Upgrade"));
        bytes32 snapshotBefore = upgrade.liveSnapshot();
        address before = address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT))));
        implementation = upgrade.run();
        assertNotEq(implementation, before, "a new implementation");
        assertEq(address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), implementation, "live");
        assertEq(proxy.version(), "1.0.0", "the same version");
        assertEq(upgrade.liveSnapshot(), snapshotBefore, "the live snapshot is unchanged");
        upgrade.verify();
        vm.store(implementation, INITIALIZABLE_SLOT, bytes32(0));
        vm.expectRevert(bytes("Upgrade verify: the implementation is locked"));
        upgrade.verify();
        vm.store(implementation, INITIALIZABLE_SLOT, bytes32(uint256(type(uint64).max)));
        vm.store(address(proxy), IMPLEMENTATION_SLOT, bytes32(uint256(uint160(before))));
        vm.expectRevert(bytes("Upgrade verify: the proxy's implementation"));
        upgrade.verify();
        vm.store(address(proxy), IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
        vm.mockCall(address(proxy), abi.encodeWithSignature("version()"), abi.encode("9.9.9"));
        vm.expectRevert(bytes("Upgrade verify: version"));
        upgrade.verify();
        vm.clearMockedCalls();
        upgrade.verify();
    }

    /// @dev The record says where everything is.
    function _checkRecord(address implementation) private view {
        string memory json = vm.readFile(RECORD);
        assertEq(vm.parseJsonUint(json, ".chainId"), 31_337, "chainId");
        assertEq(vm.parseJsonAddress(json, ".deployer"), inputs.deployer, "deployer");
        assertEq(vm.parseJsonAddress(json, ".token"), address(token), "token");
        assertTrue(vm.parseJsonBool(json, ".tokenIsMock"), "tokenIsMock");
        assertEq(vm.parseJsonAddress(json, ".proxy"), address(proxy), "proxy");
        assertEq(vm.parseJsonAddress(json, ".implementation"), implementation, "implementation");
        assertEq(vm.parseJsonString(json, ".version"), "1.0.0", "version");
        assertEq(vm.parseJsonUint(json, ".startBlock"), deployBlock, "the block before the deployment");
    }
}
