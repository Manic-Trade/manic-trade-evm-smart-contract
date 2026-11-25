// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vm} from "forge-std/Vm.sol";

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {InitParams} from "../../../src/types/ParamTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockDecimalsToken} from "../../mocks/MockDecimalsToken.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Initialize_Concrete_Test
/// @notice Every branch of `initialize`, from test/concrete/initialize/initialize.tree (kept in step by
///         `bulloak check`), in the contract's check order (docs/ARCHITECTURE.md §8.1).
/// @dev Each revert test breaks its own check and every later one, while every earlier check passes. Getting its own
///      error therefore also proves that no later check runs first. The boundaries are tested exactly here;
///      test/fuzz/InitializeFuzz.t.sol covers every value between them.
contract Initialize_Concrete_Test is Base_Test {
    /// @dev The checks of `initialize`, in the order it runs them.
    enum Check {
        Addresses,
        Decimals,
        Floor,
        RefundDelay,
        Breaker
    }

    function test_RevertWhen_CalledOnTheImplementation() external {
        // it should revert
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_defaultInitParams());
    }

    function test_RevertGiven_TheProxyIsAlreadyInitialized() external {
        // it should revert
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        flashOption.initialize(_defaultInitParams());
    }

    /// @dev Each test below deploys a fresh proxy, which `_deployProxy` initializes in the same transaction.
    modifier givenTheProxyIsNotInitialized() {
        _;
    }

    function test_RevertWhen_AnAddressIsZero() external givenTheProxyIsNotInitialized {
        // it should revert: each of the nine address fields in turn, including the last of two openers and settlers
        for (uint256 field; field < 9; ++field) {
            InitParams memory p = _failingFrom(Check.Addresses);
            _zeroAddressField(p, field);
            vm.expectRevert(Errors.ZeroAddress.selector);
            _deployProxy(p);
        }
    }

    modifier whenEveryAddressIsSet() {
        _;
    }

    function test_RevertWhen_TheTokenHasFewerThan6OrMoreThan9Decimals()
        external
        givenTheProxyIsNotInitialized
        whenEveryAddressIsSet
    {
        // it should revert, naming the decimals: the nearest value on each side of the range, and both extremes
        uint8[4] memory decimals = [uint8(0), 5, 10, type(uint8).max];
        for (uint256 i; i < decimals.length; ++i) {
            InitParams memory p = _failingFrom(Check.Decimals);
            p.token = IERC20(address(new MockDecimalsToken(decimals[i])));
            vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenDecimals.selector, decimals[i]));
            _deployProxy(p);
        }
    }

    modifier whenTheTokenHas6To9Decimals() {
        _;
    }

    function test_RevertWhen_ThePoolFloorIsBelow500WholeTokens()
        external
        givenTheProxyIsNotInitialized
        whenEveryAddressIsSet
        whenTheTokenHas6To9Decimals
    {
        // it should revert: one base unit under 500 whole tokens at 6 decimals...
        InitParams memory p = _failingFrom(Check.Floor);
        p.poolFloor = Defaults.POOL_FLOOR - 1;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        _deployProxy(p);

        // ...and at 9, where 500 whole tokens is 500e9: the bound scales with the decimals
        p.token = IERC20(address(new MockDecimalsToken(9)));
        p.poolFloor = 500e9 - 1;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        _deployProxy(p);
    }

    modifier whenThePoolFloorIsAtLeast500WholeTokens() {
        _;
    }

    function test_RevertWhen_TheRefundDelayIsBetween1SecondAnd1Hour()
        external
        givenTheProxyIsNotInitialized
        whenEveryAddressIsSet
        whenTheTokenHas6To9Decimals
        whenThePoolFloorIsAtLeast500WholeTokens
    {
        // it should revert: at both ends of the forbidden range
        uint48[2] memory delays = [uint48(1), 1 hours - 1];
        for (uint256 i; i < delays.length; ++i) {
            InitParams memory p = _failingFrom(Check.RefundDelay);
            p.refundDelaySecs = delays[i];
            vm.expectRevert(Errors.InvalidRefundDelay.selector);
            _deployProxy(p);
        }
    }

    modifier whenTheRefundDelayIs0OrAtLeast1Hour() {
        _;
    }

    function test_RevertWhen_TheBreakerWindowIsOutside60To86400Seconds()
        external
        givenTheProxyIsNotInitialized
        whenEveryAddressIsSet
        whenTheTokenHas6To9Decimals
        whenThePoolFloorIsAtLeast500WholeTokens
        whenTheRefundDelayIs0OrAtLeast1Hour
    {
        // it should revert: just outside each end, and both extremes
        uint32[4] memory windows = [uint32(0), 59, 86_401, type(uint32).max];
        for (uint256 i; i < windows.length; ++i) {
            InitParams memory p = _failingFrom(Check.Breaker);
            p.breakerWindowSecs = windows[i];
            vm.expectRevert(Errors.InvalidBreakerParams.selector);
            _deployProxy(p);
        }
    }

    function test_WhenTheBreakerWindowIs60To86400Seconds()
        external
        givenTheProxyIsNotInitialized
        whenEveryAddressIsSet
        whenTheTokenHas6To9Decimals
        whenThePoolFloorIsAtLeast500WholeTokens
        whenTheRefundDelayIs0OrAtLeast1Hour
    {
        InitParams memory p = _defaultInitParams();
        vm.recordLogs();
        ManicFlashOption proxy = ManicFlashOption(_deployProxy(p));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // it should grant each role to exactly its holders
        _assertRoleHolders(proxy);

        // it should make the default admin every role's admin
        bytes32[6] memory roles = _roles(proxy);
        for (uint256 i; i < roles.length; ++i) {
            assertEq(proxy.getRoleAdmin(roles[i]), proxy.DEFAULT_ADMIN_ROLE(), "role admin");
        }
        assertEq(proxy.defaultAdmin(), users.admin, "default admin");
        assertEq(proxy.defaultAdminDelay(), Defaults.ADMIN_TRANSFER_DELAY, "admin transfer delay");
        (address pendingAdmin, uint48 schedule) = proxy.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0), "no pending admin");
        assertEq(schedule, 0, "no admin transfer scheduled");

        // it should store every setting
        _assertStoredSettings(address(proxy), p);

        // it should set the EIP-712 domain
        _assertDomain(proxy);

        // it should emit the setup events in order
        _assertSetupLogs(logs, address(proxy), p);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The default settings with the check `from` and every later check broken. Every earlier check passes.
    function _failingFrom(Check from) private returns (InitParams memory p) {
        p = _defaultInitParams();
        if (uint8(from) <= uint8(Check.Decimals)) p.token = IERC20(address(new MockDecimalsToken(5)));
        if (uint8(from) <= uint8(Check.Floor)) p.poolFloor = 0;
        if (uint8(from) <= uint8(Check.RefundDelay)) p.refundDelaySecs = 1;
        p.breakerWindowSecs = 0; // the last check, so always broken
    }

    /// @dev Zeroes address field `field`, in the order `initialize` checks them. Openers and settlers get a second,
    ///      zero entry, so the test proves every element is checked, not only the first.
    function _zeroAddressField(InitParams memory p, uint256 field) private pure {
        if (field == 0) p.admin = address(0);
        else if (field == 1) p.upgrader = address(0);
        else if (field == 2) p.operator = address(0);
        else if (field == 3) p.guardian = address(0);
        else if (field == 4) p.openers = _pair(p.openers[0], address(0));
        else if (field == 5) p.settlers = _pair(p.settlers[0], address(0));
        else if (field == 6) p.token = IERC20(address(0));
        else if (field == 7) p.feeRecipient = address(0);
        else p.rewardsRecipient = address(0);
    }

    function _pair(address first, address second) private pure returns (address[] memory pair) {
        pair = new address[](2);
        pair[0] = first;
        pair[1] = second;
    }

    /// @dev The six roles, in the same order as `_holders`.
    function _roles(ManicFlashOption proxy) private view returns (bytes32[6] memory) {
        return [
            proxy.DEFAULT_ADMIN_ROLE(),
            proxy.UPGRADER_ROLE(),
            proxy.OPERATOR_ROLE(),
            proxy.GUARDIAN_ROLE(),
            proxy.OPENER_ROLE(),
            proxy.SETTLER_ROLE()
        ];
    }

    function _holders() private view returns (address[6] memory) {
        return [users.admin, users.upgrader, users.operator, users.guardian, users.opener, users.settler];
    }

    /// @dev Every role × every account: an account holds a role exactly when it is that role's holder. The
    ///      recipients, the plain users and the deployer (this contract) hold nothing.
    function _assertRoleHolders(ManicFlashOption proxy) private view {
        bytes32[6] memory roles = _roles(proxy);
        address[6] memory holders = _holders();
        address[12] memory accounts = [
            users.admin,
            users.upgrader,
            users.operator,
            users.guardian,
            users.opener,
            users.settler,
            users.feeRecipient,
            users.rewardsRecipient,
            users.alice,
            users.bob,
            users.eve,
            address(this)
        ];
        for (uint256 r; r < roles.length; ++r) {
            for (uint256 a; a < accounts.length; ++a) {
                assertEq(
                    proxy.hasRole(roles[r], accounts[a]), accounts[a] == holders[r], "role held by exactly its holder"
                );
            }
        }
    }

    /// @dev Each field, and each whole value slot of the `Layout`, so nothing else was written.
    function _assertStoredSettings(address proxy, InitParams memory p) private view {
        assertEq(LayoutReader.token(proxy), address(p.token), "token");
        assertEq(LayoutReader.tokenDecimals(proxy), Defaults.DECIMALS, "tokenDecimals");
        assertFalse(LayoutReader.halted(proxy), "not halted");
        assertEq(LayoutReader.marketCount(proxy), 0, "no markets");
        assertEq(LayoutReader.refundDelaySecs(proxy), p.refundDelaySecs, "refundDelaySecs");
        assertEq(LayoutReader.feeRecipient(proxy), p.feeRecipient, "feeRecipient");
        assertEq(LayoutReader.rewardsRecipient(proxy), p.rewardsRecipient, "rewardsRecipient");
        assertEq(LayoutReader.pool(proxy).poolFloor, p.poolFloor, "poolFloor");
        assertEq(LayoutReader.breaker(proxy).maxNetProfit, p.breakerMaxNetProfit, "breaker maxNetProfit");
        assertEq(LayoutReader.breaker(proxy).windowSecs, p.breakerWindowSecs, "breaker windowSecs");

        uint256 slot0 =
            uint256(uint160(address(p.token))) | uint256(Defaults.DECIMALS) << 160 | uint256(p.refundDelaySecs) << 192;
        assertEq(LayoutReader.word(proxy, 0), slot0, "slot 0: token, decimals, refund delay; not halted, no markets");
        assertEq(LayoutReader.word(proxy, 3), 0, "slot 3: no stakes, no exposure, nothing owed");
        assertEq(LayoutReader.word(proxy, 4), p.poolFloor, "slot 4: only the floor");
        assertEq(LayoutReader.word(proxy, 5), 0, "slot 5: no fees, nothing claimable or paid");
        assertEq(LayoutReader.word(proxy, 6), 0, "slot 6: nothing recovered or withdrawn");
        assertEq(LayoutReader.word(proxy, 7), uint256(p.breakerWindowSecs) << 184, "slot 7: only the window");
        assertEq(LayoutReader.word(proxy, 8), p.breakerMaxNetProfit, "slot 8: the limit");
    }

    /// @dev ERC-5267: name and version, bound to this chain and this proxy; no salt, no extensions.
    function _assertDomain(ManicFlashOption proxy) private view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = proxy.eip712Domain();
        assertEq(uint8(fields), 0x0f, "fields: name, version, chainId, verifyingContract");
        assertEq(name, Defaults.EIP712_NAME, "name");
        assertEq(version, Defaults.EIP712_VERSION, "version");
        assertEq(chainId, block.chainid, "chain id");
        assertEq(verifyingContract, address(proxy), "verifying contract is the proxy");
        assertEq(salt, bytes32(0), "no salt");
        assertEq(extensions.length, 0, "no extensions");
    }

    /// @dev The proxy's whole log, in order: the upgrade to the implementation, a role grant per holder, the four
    ///      setting events, then `Initialized(1)`.
    function _assertSetupLogs(Vm.Log[] memory logs, address proxy, InitParams memory p) private view {
        assertEq(logs.length, 12, "Upgraded + 6 RoleGranted + 4 settings + Initialized");
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, proxy, "every log comes from the proxy");
        }
        _assertLog(logs[0], _topics(IERC1967.Upgraded.selector, _word(address(implementation))), "", "Upgraded");

        bytes32[6] memory roles = _roles(ManicFlashOption(proxy));
        address[6] memory holders = _holders();
        for (uint256 i; i < roles.length; ++i) {
            bytes32[] memory topics = new bytes32[](4);
            topics[0] = IAccessControl.RoleGranted.selector;
            topics[1] = roles[i];
            topics[2] = _word(holders[i]);
            topics[3] = _word(address(this)); // the deployer, the sender of initialize
            _assertLog(logs[1 + i], topics, "", "RoleGranted");
        }

        _assertLog(logs[7], _topics(Events.PoolFloorUpdated.selector), abi.encode(p.poolFloor), "PoolFloorUpdated");
        bytes32[] memory recipients = new bytes32[](3);
        recipients[0] = Events.RecipientsUpdated.selector;
        recipients[1] = _word(p.feeRecipient);
        recipients[2] = _word(p.rewardsRecipient);
        _assertLog(logs[8], recipients, "", "RecipientsUpdated");
        _assertLog(
            logs[9], _topics(Events.RefundDelayUpdated.selector), abi.encode(p.refundDelaySecs), "RefundDelayUpdated"
        );
        _assertLog(
            logs[10],
            _topics(Events.CircuitBreakerUpdated.selector),
            abi.encode(p.breakerMaxNetProfit, p.breakerWindowSecs),
            "CircuitBreakerUpdated"
        );
        _assertLog(logs[11], _topics(Initializable.Initialized.selector), abi.encode(uint64(1)), "Initialized");
    }

    function _assertLog(
        Vm.Log memory log,
        bytes32[] memory topics,
        bytes memory data,
        string memory label
    )
        private
        pure
    {
        assertEq(log.topics.length, topics.length, string.concat(label, ": topic count"));
        for (uint256 i; i < topics.length; ++i) {
            assertEq(log.topics[i], topics[i], string.concat(label, ": topic"));
        }
        assertEq(log.data, data, string.concat(label, ": data"));
    }

    function _topics(bytes32 signature) private pure returns (bytes32[] memory topics) {
        topics = new bytes32[](1);
        topics[0] = signature;
    }

    function _topics(bytes32 signature, bytes32 first) private pure returns (bytes32[] memory topics) {
        topics = new bytes32[](2);
        topics[0] = signature;
        topics[1] = first;
    }

    function _word(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
