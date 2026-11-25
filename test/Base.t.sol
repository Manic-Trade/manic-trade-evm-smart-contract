// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ManicFlashOption} from "../src/ManicFlashOption.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../src/types/OrderTypes.sol";
import {ConfigParams, InitParams} from "../src/types/ParamTypes.sol";
import {Market, Side} from "../src/types/StorageTypes.sol";
import {ManicFlashOptionHarness} from "./harnesses/ManicFlashOptionHarness.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {Defaults} from "./utils/Defaults.sol";
import {LayoutReader} from "./utils/LayoutReader.sol";
import {LayoutWriter} from "./utils/LayoutWriter.sol";
import {OrderSigner} from "./utils/OrderSigner.sol";
import {UsdgSigner} from "./utils/UsdgSigner.sol";
import {Users} from "./utils/Users.sol";

/// @title Base_Test
/// @notice The shared set-up of every test that runs the contract behind its proxy: the users, the mock USDG, the
///         implementation, a proxy initialized with the default settings in the same transaction that deploys it, as
///         the deploy script will (docs/ARCHITECTURE.md §15 rule 2), and the BTC market, created by the admin and
///         switched on by the operator.
/// @dev The proxy is deployed with `UnsafeUpgrades`: no FFI, and coverage still works. The upgrades plugin's checks
///      run outside Foundry, in test/upgrade/layout/check.py (docs/CONVENTIONS.md §9). A test that needs other
///      settings builds them from `_defaultInitParams()` and calls `_deployProxy`.
abstract contract Base_Test is Test {
    Users internal users;
    MockUSDG internal usdg;
    /// @dev The mock USDG's admin: mints, freezes and pauses.
    address internal usdgAdmin;
    ManicFlashOption internal implementation;
    /// @dev The proxy, typed as the contract.
    ManicFlashOption internal flashOption;

    function setUp() public virtual {
        users = Users({
            admin: makeAddr("admin"),
            upgrader: makeAddr("upgrader"),
            operator: makeAddr("operator"),
            guardian: makeAddr("guardian"),
            opener: makeAddr("opener"),
            settler: makeAddr("settler"),
            feeRecipient: makeAddr("feeRecipient"),
            rewardsRecipient: makeAddr("rewardsRecipient"),
            alice: makeAddr("alice"),
            bob: makeAddr("bob"),
            eve: makeAddr("eve")
        });
        _useToken();
        implementation = new ManicFlashOption();
        flashOption = ManicFlashOption(_deployProxy(_defaultInitParams()));

        // The default market: created switched off by the admin, then switched on by the operator, as on mainnet.
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, _enabledConfig());

        vm.label(address(usdg), "USDG");
        vm.label(address(implementation), "ManicFlashOption (implementation)");
        vm.label(address(flashOption), "ManicFlashOption (proxy)");
    }

    /// @dev The default settings: one opener, one settler, USDG, the lowest floor, a 24-hour refund delay and the
    ///      default circuit breaker.
    function _defaultInitParams() internal view returns (InitParams memory) {
        address[] memory openers = new address[](1);
        openers[0] = users.opener;
        address[] memory settlers = new address[](1);
        settlers[0] = users.settler;
        return InitParams({
            admin: users.admin,
            adminTransferDelay: Defaults.ADMIN_TRANSFER_DELAY,
            upgrader: users.upgrader,
            operator: users.operator,
            guardian: users.guardian,
            openers: openers,
            settlers: settlers,
            token: IERC20(address(usdg)),
            poolFloor: Defaults.POOL_FLOOR,
            feeRecipient: users.feeRecipient,
            rewardsRecipient: users.rewardsRecipient,
            refundDelaySecs: Defaults.REFUND_DELAY,
            breakerMaxNetProfit: Defaults.BREAKER_MAX_NET_PROFIT,
            breakerWindowSecs: Defaults.BREAKER_WINDOW
        });
    }

    /// @dev The launch settings, switched on.
    function _enabledConfig() internal pure returns (ConfigParams memory c) {
        c = Defaults.marketConfig();
        c.enabled = true;
    }

    /// @dev Every user, so a role gate can be tested against all who lack the role.
    function _everyone() internal view returns (address[11] memory) {
        return [
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
            users.eve
        ];
    }

    /// @dev Every user but `a` and `b` (pass the same address twice for one holder).
    function _everyoneBut(address a, address b) internal view returns (address[] memory others) {
        address[11] memory all = _everyone();
        others = new address[](11);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i] != a && all[i] != b) others[n++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(others, n) // shrink the array to the users kept
        }
    }

    /// @dev Market `index` in raw storage equals the given id, leverage, exponent, pause and settings, field by field.
    function _assertMarket(
        uint16 index,
        bytes32 marketId,
        uint16 marketLeverage,
        int8 priceExponent,
        bool paused,
        ConfigParams memory c
    )
        internal
        view
    {
        Market memory m = LayoutReader.market(address(flashOption), index);
        assertEq(m.marketId, marketId, "marketId");
        assertEq(m.leverage, marketLeverage, "leverage");
        assertEq(m.enabled, c.enabled, "enabled");
        assertEq(m.paused, paused, "paused");
        assertEq(m.priceExponent, priceExponent, "priceExponent");
        assertEq(m.entryMaxAgeSecs, c.entryMaxAgeSecs, "entryMaxAgeSecs");
        assertEq(m.clockSkewSecs, c.clockSkewSecs, "clockSkewSecs");
        assertEq(m.floorMinBps, c.floorMinBps, "floorMinBps");
        assertEq(m.floorMaxBps, c.floorMaxBps, "floorMaxBps");
        assertEq(m.capMinBps, c.capMinBps, "capMinBps");
        assertEq(m.capMaxBps, c.capMaxBps, "capMaxBps");
        assertEq(m.maxSellFeeBps, c.maxSellFeeBps, "maxSellFeeBps");
        assertEq(m.sellMinDelaySecs, c.sellMinDelaySecs, "sellMinDelaySecs");
        assertEq(m.sellCutoffSecs, c.sellCutoffSecs, "sellCutoffSecs");
        assertEq(m.maxExposureBps, c.maxExposureBps, "maxExposureBps");
        assertEq(m.minStake, c.minStake, "minStake");
        assertEq(m.maxStake, c.maxStake, "maxStake");
        assertEq(m.maxTotalOwed, c.maxTotalOwed, "maxTotalOwed");
        for (uint256 i; i < 5; ++i) {
            assertEq(m.durations[i].durationSecs, c.durations[i].durationSecs, "durationSecs");
            assertEq(m.durations[i].thetaMinE7, c.durations[i].thetaMinE7, "thetaMinE7");
            assertEq(m.durations[i].thetaMaxE7, c.durations[i].thetaMaxE7, "thetaMaxE7");
            assertEq(m.durations[i].enabled, c.durations[i].enabled, "rule enabled");
        }
    }

    /// @dev Sets `usdg`, the token every test runs with, and `usdgAdmin`, who freezes and pauses it: a new mock
    ///      of USDG, which the mock's own admin also mints. The fork tests (`test/fork/`) use the real token.
    function _useToken() internal virtual {
        usdgAdmin = makeAddr("usdgAdmin");
        usdg = new MockUSDG("Global Dollar", "USDG", usdgAdmin);
    }

    /// @dev Mints `amount` USDG to `to`.
    function _mintUsdg(address to, uint256 amount) internal virtual {
        vm.prank(usdgAdmin);
        usdg.mint(to, amount);
    }

    /// @dev `funder` funds the pool with `amount` new USDG.
    function _fund(address funder, uint64 amount) internal {
        _mintUsdg(funder, amount);
        vm.startPrank(funder);
        usdg.approve(address(flashOption), amount);
        flashOption.fund(amount);
        vm.stopPrank();
    }

    /// @dev Moves every test helper to a new proxy whose pool holds only `free`, with BTC's exposure gate off, so
    ///      winners can be owed.
    function _useSmallPool(uint64 free) internal {
        flashOption = ManicFlashOption(_deployProxy(_defaultInitParams()));
        ConfigParams memory c = Defaults.marketConfig();
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        c.enabled = true;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _switchOffOpenGate(address(flashOption), Defaults.BTC, Defaults.LEVERAGE);
        _fund(users.bob, free);
    }

    /// @dev Switches off the open gate of `target`'s market of `marketId` at `marketLeverage`
    ///      (`LayoutWriter.switchOffOpenGate`), and checks that only the gate changed. `validate` refuses the gate off
    ///      (ADR 0009), so only an upgrade could reach this state: with the gate on, free money always covers the open
    ///      bets' max profit and no winner is ever owed. The tests of the IOU path, which stays in the code as a
    ///      backstop, start here. A later `setConfig` puts the gate back on.
    function _switchOffOpenGate(address target, bytes32 marketId, uint16 marketLeverage) internal {
        uint16 indexPlusOne = LayoutReader.marketIndexPlusOne(target, marketId, marketLeverage);
        assertGt(indexPlusOne, 0, "the market exists");
        uint16 index = indexPlusOne - 1;
        uint256 word = LayoutReader.marketWord(target, index, 1);
        assertEq(LayoutWriter.switchOffOpenGate(target, marketId, marketLeverage), index, "the market's index");
        uint256 mask = uint256(type(uint32).max) << 152;
        assertEq(LayoutReader.market(target, index).maxExposureBps, 0, "the open gate is off");
        assertEq(LayoutReader.marketWord(target, index, 1) | mask, word | mask, "the rest of the slot");
    }

    /// @dev Switches on BTC's market at `marketLeverage` with the settings `c`, creating it first unless it exists (the
    ///      test market, 1000x, always does): created switched off, as `createMarket` requires, then given `c` switched
    ///      on. Sets `c.enabled` to true in the caller's copy too.
    function _useBtcAt(uint16 marketLeverage, ConfigParams memory c) internal {
        if (LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.BTC, marketLeverage) == 0) {
            c.enabled = false;
            vm.prank(users.admin);
            flashOption.createMarket(Defaults.BTC, marketLeverage, Defaults.PRICE_EXPONENT, c);
        }
        c.enabled = true;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, marketLeverage, c);
    }

    /// @dev The leverage of a fuzz case's market, from `seed`. Half the cases take one the contract's limits or the
    ///      plans name: 1x to 4x, where a short can't reach every cap; 100x, 500x and 1000x, the planned markets; and
    ///      10,000x, the highest. The other half take any leverage from 1x to 10,000x.
    function _leverageFor(uint256 seed) internal pure returns (uint16) {
        uint16[8] memory picks = [uint16(1), 2, 3, 4, 100, 500, 1000, 10_000];
        if (seed % 2 == 0) return picks[(seed >> 1) % picks.length];
        // casting to uint16 is safe: bounded to 10,000
        return uint16(bound(seed >> 1, 1, 10_000));
    }

    /// @dev A price from `raw` within 4 / L of `entry` either way, L being `marketLeverage`, and never below 1: 0.4% at
    ///      1000x. With the launch config fitted to L (`LeverageConfigs.launchAt`), that range holds a bet's line, at
    ///      most 0.735 / L from its entry, and its cap line, at most 3 / L from it (below 4x, less than the entry).
    function _priceNear(int64 entry, uint16 marketLeverage, int256 raw) internal pure returns (int64) {
        int256 span = int256(entry) * 4 / int256(uint256(marketLeverage));
        int256 lowest = int256(entry) - span;
        int256 highest = int256(entry) + span;
        if (lowest < 1) lowest = 1;
        if (highest > type(int64).max) highest = type(int64).max;
        // casting to int64 is safe: bounded to [1, int64's maximum]
        return int64(bound(raw, lowest, highest));
    }

    /// @dev Writes `value` into the `bits`-bit field at bit `shift` of `Layout` slot `offset` of `target`, keeping the
    ///      rest of the slot. Sets up book states no public function can reach yet (open positions, IOUs, fees).
    function _writeLayout(address target, uint256 offset, uint256 shift, uint256 bits, uint256 value) internal {
        bytes32 slot = bytes32(LayoutReader.ROOT + offset);
        uint256 mask = ((uint256(1) << bits) - 1) << shift;
        uint256 word = uint256(vm.load(target, slot));
        vm.store(target, slot, bytes32((word & ~mask) | ((value << shift) & mask)));
    }

    /// @dev The core books invariant (ARCHITECTURE §12, 1): the token balance covers the pool, the pending fees and
    ///      every claimable balance.
    function _assertBooksBalanced(address target) internal view {
        uint256 books = uint256(LayoutReader.pool(target).total) + LayoutReader.pool(target).feesPending
            + LayoutReader.pool(target).totalClaimable;
        assertGe(usdg.balanceOf(target), books, "balance covers total + fees + claimable");
    }

    /// @dev A proxy over `ManicFlashOptionHarness`, with `p` and the BTC market switched on, for tests of internal
    ///      helpers.
    function _deployHarness(InitParams memory p) internal returns (ManicFlashOptionHarness harness) {
        harness = ManicFlashOptionHarness(
            UnsafeUpgrades.deployUUPSProxy(
                address(new ManicFlashOptionHarness()), abi.encodeCall(ManicFlashOption.initialize, (p))
            )
        );
        vm.label(address(harness), "ManicFlashOption (harness proxy)");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Opening positions. Bettors sign with the keys `makeAddrAndKey` derives from their names.
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The private key behind `makeAddr(name)`.
    function _keyOf(string memory name) internal returns (uint256 key) {
        (, key) = makeAddrAndKey(name);
    }

    /// @dev `user`'s order for the base terms (`Defaults`): a $10 BTC call for 60 seconds, signed now and valid for
    ///      30 seconds.
    function _order(address user, bytes32 positionId) internal view returns (OpenOrder memory) {
        return OpenOrder({
            positionId: positionId,
            user: user,
            marketId: Defaults.BTC,
            leverage: Defaults.LEVERAGE,
            side: Side.Call,
            stake: Defaults.STAKE,
            durationSecs: Defaults.DURATION,
            notBefore: uint48(block.timestamp),
            deadline: uint48(block.timestamp) + Defaults.ORDER_LIFETIME
        });
    }

    /// @dev The relayer's terms for the base bet, at a tick published now.
    function _terms() internal view returns (OpenTerms memory) {
        return OpenTerms({
            entryPrice: Defaults.ENTRY_PRICE,
            entryPublishTime: uint48(block.timestamp),
            thetaE7: Defaults.THETA,
            floorBps: Defaults.FLOOR_BPS,
            capBps: Defaults.CAP_BPS
        });
    }

    /// @dev `key`'s signature of `o`, under `target`'s domain.
    function _signOrder(ManicFlashOption target, uint256 key, OpenOrder memory o) internal view returns (bytes memory) {
        return OrderSigner.sign(key, target.hashOpenOrder(o));
    }

    /// @dev `key`'s EIP-3009 authorisation for `target` to receive exactly `o.stake` from `o.user`, with the position
    ///      id as its nonce, valid from a second ago for `Defaults.AUTH_LIFETIME`.
    function _stakeAuth(
        ManicFlashOption target,
        uint256 key,
        OpenOrder memory o
    )
        internal
        view
        returns (StakeAuth memory a)
    {
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + Defaults.AUTH_LIFETIME;
        UsdgSigner.Authorization memory auth = UsdgSigner.Authorization({
            from: o.user,
            to: address(target),
            value: o.stake,
            validAfter: a.validAfter,
            validBefore: a.validBefore,
            nonce: o.positionId
        });
        a.signature = UsdgSigner.sign(key, UsdgSigner.authorizationDigest(address(usdg), auth, true));
    }

    /// @dev Mints `o.stake` to `o.user`, then has the opener open `o` on `leverage` with `t`, signed by `key`.
    function _open(uint256 key, OpenOrder memory o, OpenTerms memory t) internal {
        _mintUsdg(o.user, o.stake);
        bytes memory signature = _signOrder(flashOption, key, o);
        StakeAuth memory a = _stakeAuth(flashOption, key, o);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
    }

    /// @dev Deploys a proxy over `implementation` and calls `initialize(p)` in the same transaction.
    function _deployProxy(InitParams memory p) internal returns (address) {
        bytes memory init = abi.encodeCall(ManicFlashOption.initialize, (p));
        return UnsafeUpgrades.deployUUPSProxy(address(implementation), init);
    }
}
