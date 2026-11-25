// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {OpenOrder, OpenTerms, SellOrder, StakeAuth} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Breaker, PoolState, Position, Side, Status, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {ManicFlashOptionV2Mock} from "../mocks/ManicFlashOptionV2Mock.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title Leverage_Upgrade_Test
/// @notice A V1 → V2 upgrade over real state (docs/ARCHITECTURE.md §4.2, §5, §13; security checklist UPG-3,
///         UPG-6).
///         V1 first builds up everything the contract keeps, through its own functions: money withdrawn, settings
///         changed, more markets (ETH, and BTC at 500x and 100x beside 1000x, with the tier values), a relayer granted
///         and revoked, an admin transfer begun, a loser liquidated, six 1000x winners and one each at 500x and 100x
///         settled into a pool too small to pay them all (so five are owed, of all three leverages, and one of those
///         repaid), a frozen winner whose payouts wait in `claimable`, and three bets still open, one per leverage.
///         Every field of the pool's books and every breaker counter is then set.
///         The upgrader then upgrades to `ManicFlashOptionV2Mock`, which appends `newSetting` to `Layout`, and sets it
///         with `initializeV2`, a `reinitializer(2)`, in the same `upgradeToAndCall`.
/// @dev Three layers of proof:
///      - the upgrade's storage writes, recorded by Foundry's state-diff recorder: it changes exactly the
///        implementation slot, the initializer version and the new field, and no other byte of any account's
///        storage;
///      - every view, read before and after: V2's code reads every value V1 stored, each market's leverage and each
///        bet's among them (`getPosition` recomputes each bet's cap price at its own leverage);
///      - V2 then ends, repays, refunds, opens and sells over V1's bets, each step checked by the settlement checkers
///        (every log, every field of the books, every slot and every balance against their own model). The open
///        100x put settles at a moved price, so what it pays depends on the leverage V2 reads.
///      The layout itself is checked by the upgrades plugin, in test/upgrade/layout/ (CI's upgrade-safety job).
contract Leverage_Upgrade_Test is Settlement_Base_Test {
    /// @dev The bets V1 opens, all at the same second.
    bytes32 internal constant LOSER = keccak256("bob's put, liquidated");
    bytes32 internal constant OPEN_CALL = keccak256("alice's 5-minute call, open at the upgrade");
    bytes32 internal constant OPEN_PUT = keccak256("bob's 5-minute 100x put, open at the upgrade");
    bytes32 internal constant REFUNDABLE = keccak256("eve's 2-minute 500x call, never settled");
    /// @dev The winners at 500x and 100x, settled after the 1000x ones have spent free money, so they are owed.
    bytes32 internal constant WINNER_500 = keccak256("alice's $50 500x call that wins");
    bytes32 internal constant WINNER_100 = keccak256("bob's $50 100x call that wins");
    /// @dev BTC's markets besides the test market's 1000x.
    uint16 internal constant L500 = 500;
    uint16 internal constant L100 = 100;
    /// @dev Where V2 settles the open 100x put: 10 bp below its entry, which it pays 1.1x for at 100x.
    int64 internal constant PUT_WIN_PRICE = Examples.P0 - 10 * Examples.BP;
    /// @dev A bet signed under V1 and opened under V2.
    bytes32 internal constant SIGNED_BEFORE = keccak256("alice's call, signed before the upgrade");
    uint256 internal constant WINNERS = 6;
    /// @dev The most IOUs one `repay` call reaches (`_MAX_REPAY` in SettlementModule).
    uint256 internal constant MAX_REPAY = 50;

    /// @dev The money V1 takes out first, while nobody is owed: the seed back, and rewards, which leave free money just
    ///      above the $500 floor ($1,500 − $5 − $990 = $505).
    uint64 internal constant SEED_BACK = 5e6;
    uint64 internal constant REWARDS = 990e6;
    /// @dev The winners' stake: the most the market allows ($50), so six of them owe more than the pool holds.
    uint64 internal constant BIG_STAKE = 50e6;
    /// @dev A tick $300 above the entry: past the put's line, and every call at its 4x cap.
    int64 internal constant WIN_PRICE_DOLLARS = 300;
    /// @dev The top-up before V1's one repayment, more than the head IOU, and the one before V2 repays the rest.
    uint64 internal constant TOP_UP = 160e6;
    uint64 internal constant REPAY_FUNDS = 2000e6;
    /// @dev Settings V1 changes from their defaults.
    uint48 internal constant REFUND_DELAY = 1 hours;
    uint64 internal constant BREAKER_LIMIT = 5000e6;
    uint32 internal constant BREAKER_WINDOW = 2 hours;
    /// @dev The value `initializeV2` gives the field V2 appends.
    uint64 internal constant NEW_SETTING = 42e6;
    /// @dev The sale V2 makes, as in test/concrete/sell/: at +$8 the $10 call pays $13.
    int64 internal constant SALE_PRICE_DOLLARS = 8;
    uint64 internal constant VALUATION = 12_500_000;
    uint64 internal constant SELL_AMOUNT = 12_000_000;
    uint64 internal constant MIN_AMOUNT = 11_640_000;
    uint48 internal constant SALE_DELAY = 20;
    /// @dev When V1's story starts: 2026-11-13 00:00 UTC, as in the invariant suite.
    uint256 internal constant START = 1_794_528_000;

    /// @dev The storage slots an upgrade may change: OpenZeppelin's ERC-1967 implementation slot, and its
    ///      `Initializable` namespace, whose first 8 bytes hold the initializer version.
    bytes32 internal constant IMPLEMENTATION_SLOT = ERC1967Utils.IMPLEMENTATION_SLOT;
    bytes32 internal immutable INITIALIZABLE_SLOT = _erc7201("openzeppelin.storage.Initializable");
    /// @dev Where V2's appended field lives: the first slot after `Layout`.
    bytes32 internal constant APPENDED_SLOT = bytes32(LayoutReader.ROOT + 14);

    /// @dev One storage slot an upgrade changed: its value before, and after.
    struct SlotChange {
        address account;
        bytes32 slot;
        bytes32 oldValue;
        bytes32 newValue;
    }

    ManicFlashOptionV2Mock internal v2;
    address internal opener2;
    address internal newAdmin;
    address internal newFeeRecipient;
    address internal newRewardsRecipient;
    /// @dev Every bet V1 opened, and when they started.
    bytes32[] internal ids;
    uint48 internal start;
    /// @dev The views read by `_views`, label by label.
    string[] internal viewLabels;
    bytes[] internal viewValues;

    function setUp() public override {
        // A real date, as on a chain: with the clock below one window's length, the breaker's first window would
        // never roll over from 0.
        vm.warp(START);
        super.setUp();
        v2 = ManicFlashOptionV2Mock(deployCode("ManicFlashOptionV2Mock.sol:ManicFlashOptionV2Mock"));
        opener2 = makeAddr("opener2");
        newAdmin = makeAddr("newAdmin");
        newFeeRecipient = makeAddr("newFeeRecipient");
        newRewardsRecipient = makeAddr("newRewardsRecipient");
        vm.label(address(v2), "ManicFlashOptionV2Mock (implementation)");

        _changeEverySetting();
        _openTheBets();
        _endSomeBets();
        _assertEveryValueIsSet();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The upgrade itself
    // ---------------------------------------------------------------------------------------------------------------

    function test_UpgradeChangesOnlyTheImplementationTheVersionAndTheNewField() external {
        (SlotChange[] memory changes, VmSafe.Log[] memory logs) = _upgradeToV2();

        // it should change three slots of the proxy, and no other byte of any account's storage
        assertEq(changes.length, 3, "three slots changed");
        _assertChange(changes[0], IMPLEMENTATION_SLOT, uint160(address(implementation)), uint160(address(v2)));
        _assertChange(changes[1], INITIALIZABLE_SLOT, 1, 2);
        _assertChange(changes[2], APPENDED_SLOT, 0, NEW_SETTING);

        // it should emit {Upgraded} and {Initialized}, and nothing else
        assertEq(logs.length, 2, "two logs");
        assertEq(logs[0].emitter, address(flashOption), "Upgraded: emitter");
        assertEq(logs[0].topics.length, 2, "Upgraded: topics");
        assertEq(logs[0].topics[0], IERC1967.Upgraded.selector, "Upgraded: event");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(v2)))), "Upgraded: implementation");
        assertEq(logs[0].data.length, 0, "Upgraded: no data");
        assertEq(logs[1].emitter, address(flashOption), "Initialized: emitter");
        assertEq(logs[1].topics.length, 1, "Initialized: topics");
        assertEq(logs[1].topics[0], Initializable.Initialized.selector, "Initialized: event");
        assertEq(logs[1].data, abi.encode(uint64(2)), "Initialized: version 2");

        // it should run V2's code, with the new field set
        assertEq(UnsafeUpgrades.getImplementationAddress(address(flashOption)), address(v2), "implementation");
        assertTrue(_proxyAsV2().isV2(), "the proxy runs V2");
        assertEq(_proxyAsV2().newSetting(), NEW_SETTING, "the new field");
    }

    function test_UpgradeKeepsEveryValueV1Stored() external {
        (bytes[] memory before, string[] memory labels) = _views();
        _upgradeToV2();
        (bytes[] memory afterwards,) = _views();

        // it should read every value V1 stored, through V2's code
        assertEq(afterwards.length, before.length, "the same views");
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterwards[i], before[i], labels[i]);
        }
    }

    function test_RevertWhen_AnInitializerRunsAgain() external {
        _upgradeToV2();

        // it should revert: the reinitializer ran inside the upgrade, so it can't run again, even for the upgrader
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(users.upgrader);
        _proxyAsV2().initializeV2(NEW_SETTING + 1);

        // it should revert: nor can V1's initializer
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(users.admin);
        flashOption.initialize(_defaultInitParams());

        assertEq(_proxyAsV2().newSetting(), NEW_SETTING, "the new field kept");
        assertEq(_initializedVersion(), 2, "version 2");
    }

    function test_RevertWhen_TheImplementationIsInitializedDirectly() external {
        // it should revert: V2's constructor locks its own initializers, so nobody can set it up and act as its admin
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(_defaultInitParams());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(users.upgrader);
        v2.initializeV2(NEW_SETTING);
    }

    function test_RevertWhen_SomeoneElseRunsTheReinitializerAnUpgradeSkipped() external {
        // An upgrade that forgot its reinitializer: only the implementation changes.
        (SlotChange[] memory changes,) = _upgrade(address(v2), "");
        assertEq(changes.length, 1, "only the implementation slot");
        _assertChange(changes[0], IMPLEMENTATION_SLOT, uint160(address(implementation)), uint160(address(v2)));
        assertEq(_proxyAsV2().newSetting(), 0, "the new field unset");
        assertEq(_initializedVersion(), 1, "still version 1");

        // it should revert: every role holder but the upgrader, the recipients and the users
        address[] memory others = _everyoneBut(users.upgrader, users.upgrader);
        bytes32 upgraderRole = flashOption.UPGRADER_ROLE();
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], upgraderRole
                )
            );
            vm.prank(others[i]);
            _proxyAsV2().initializeV2(NEW_SETTING);
        }

        // it should let the upgrader run it, once
        vm.prank(users.upgrader);
        _proxyAsV2().initializeV2(NEW_SETTING);
        assertEq(_proxyAsV2().newSetting(), NEW_SETTING, "the new field");
        assertEq(_initializedVersion(), 2, "version 2");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // V2 at work on V1's state
    // ---------------------------------------------------------------------------------------------------------------

    function test_V2RepaysEndsRefundsAndPaysWhatV1Left() external {
        _upgradeToV2();
        Position memory openCall = LayoutReader.position(address(flashOption), OPEN_CALL);
        Position memory refundable = LayoutReader.position(address(flashOption), REFUNDABLE);

        // it should repay every IOU V1 left, from the head
        _fund(users.bob, REPAY_FUNDS);
        _expectRepaid(MAX_REPAY, users.alice);
        assertEq(flashOption.getPool().owedPositions, 0, "nobody owed");

        // it should settle the two bets still open at the upgrade, at their end, each in a batch of its own market and
        // at its own leverage: the 1000x call flat, the 100x put 10 bp in the money (1.1x)
        vm.warp(_end(openCall));
        _settleTheOpenBets(_end(openCall));

        // it should refund the bet nobody settled, once its delay has passed (eve is still frozen, so it waits for her)
        vm.warp(_end(refundable) + REFUND_DELAY);
        _expectRefunded(_ids(REFUNDABLE), users.alice);
        assertEq(flashOption.getPool().openPositions, 0, "no bet open");

        // it should pay eve, once unfrozen, everything that waited for her
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.eve);
        _expectClaim(users.eve);

        // it should sweep the fees, to the fee recipient V1 set
        _expectSweep();

        // it should let the admin withdraw again, now that nobody is owed
        uint64 rewards = flashOption.freeMoney() - flashOption.getPool().poolFloor;
        uint256 balanceBefore = usdg.balanceOf(newRewardsRecipient);
        vm.prank(users.admin);
        flashOption.withdraw(WithdrawPurpose.Rewards, rewards);
        assertEq(usdg.balanceOf(newRewardsRecipient), balanceBefore + rewards, "rewards withdrawn");
        assertEq(flashOption.freeMoney(), flashOption.getPool().poolFloor, "free money down to the floor");
        _assertBooksBalanced(address(flashOption));
    }

    function test_V2OpensAndSellsOrdersSignedBeforeTheUpgrade() external {
        // Alice signs a bet and its sale under V1.
        OpenOrder memory o = _order(users.alice, SIGNED_BEFORE);
        o.deadline = uint48(block.timestamp) + SALE_DELAY + Defaults.ORDER_LIFETIME;
        bytes memory openSignature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        SellOrder memory s = _sellOrder(SIGNED_BEFORE, MIN_AMOUNT);
        s.deadline = o.deadline;
        bytes memory sellSignature = _signSell(aliceKey, s);
        bytes32 domain = _domainSeparator();

        _upgradeToV2();
        assertEq(_domainSeparator(), domain, "the same signing domain");
        // A sale waits for an empty queue, so V2 first repays V1's IOUs.
        _fund(users.bob, REPAY_FUNDS);
        _expectRepaid(MAX_REPAY, users.eve);

        // it should open the bet signed under V1
        _mintUsdg(users.alice, o.stake);
        vm.prank(users.opener);
        flashOption.open(o, openSignature, _terms(), a);
        Position memory p = LayoutReader.position(address(flashOption), SIGNED_BEFORE);
        assertEq(p.user, users.alice, "alice's bet");
        assertEq(uint8(p.status), uint8(Status.Open), "open");

        // it should sell it with the sale signed under V1
        vm.warp(p.startTime + SALE_DELAY);
        _expectSold(s, sellSignature, _sellTerms(Examples.priceAt(SALE_PRICE_DOLLARS), VALUATION, SELL_AMOUNT));
    }

    function test_V2KeepsTheRolesAndThePendingAdminTransfer() external {
        _upgradeToV2();

        // it should keep the relayer the guardian revoked under V1 out
        OpenOrder memory o = _order(users.alice, SIGNED_BEFORE);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        OpenTerms memory t = _terms();
        bytes32 openerRole = flashOption.OPENER_ROLE();
        _mintUsdg(users.alice, o.stake);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, opener2, openerRole)
        );
        vm.prank(opener2);
        flashOption.open(o, signature, t, a);

        // it should let the new admin V1 nominated accept, once the delay has passed
        (address pending, uint48 schedule) = flashOption.pendingDefaultAdmin();
        assertEq(pending, newAdmin, "the pending admin");
        vm.warp(schedule + 1);
        vm.prank(newAdmin);
        flashOption.acceptDefaultAdminTransfer();
        assertEq(flashOption.defaultAdmin(), newAdmin, "the new admin");
        assertFalse(flashOption.hasRole(flashOption.DEFAULT_ADMIN_ROLE(), users.admin), "the old admin is out");

        // it should give the new admin the admin's powers
        vm.prank(newAdmin);
        flashOption.setRefundDelay(Defaults.REFUND_DELAY);
        assertEq(flashOption.refundDelaySecs(), Defaults.REFUND_DELAY, "set by the new admin");
    }

    function test_RollingBackToV1KeepsEveryValue() external {
        _upgradeToV2();
        (bytes[] memory before, string[] memory labels) = _views();

        // it should change only the implementation slot
        (SlotChange[] memory changes, VmSafe.Log[] memory logs) = _upgrade(address(implementation), "");
        assertEq(changes.length, 1, "one slot changed");
        _assertChange(changes[0], IMPLEMENTATION_SLOT, uint160(address(v2)), uint160(address(implementation)));
        assertEq(logs.length, 1, "one log");
        assertEq(logs[0].topics[0], IERC1967.Upgraded.selector, "Upgraded");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(implementation)))), "back to V1");

        // it should read every value as V2 did; V1 ignores the field V2 appended, which stays as it was
        (bytes[] memory afterwards,) = _views();
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterwards[i], before[i], labels[i]);
        }
        assertEq(uint256(vm.load(address(flashOption), APPENDED_SLOT)), NEW_SETTING, "V2's field kept");
        assertEq(_initializedVersion(), 2, "the version stays 2");

        // it should end V1's bets as before, each at its own leverage
        Position memory openCall = LayoutReader.position(address(flashOption), OPEN_CALL);
        vm.warp(_end(openCall));
        _settleTheOpenBets(_end(openCall));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // V1's state
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Takes money out while nobody is owed, then moves every setting away from its default and leaves a role
    ///      change half done.
    function _changeEverySetting() private {
        bytes32 openerRole = flashOption.OPENER_ROLE();
        vm.startPrank(users.admin);
        flashOption.withdraw(WithdrawPurpose.SeedRecovery, SEED_BACK);
        flashOption.withdraw(WithdrawPurpose.Rewards, REWARDS);
        flashOption.setRecipients(newFeeRecipient, newRewardsRecipient);
        flashOption.setRefundDelay(REFUND_DELAY);
        flashOption.setBreaker(BREAKER_LIMIT, BREAKER_WINDOW);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        flashOption.createMarket(Defaults.BTC, L500, Defaults.PRICE_EXPONENT, LeverageConfigs.planned(L500));
        flashOption.createMarket(Defaults.BTC, L100, Defaults.PRICE_EXPONENT, LeverageConfigs.planned(L100));
        flashOption.grantRole(openerRole, opener2);
        flashOption.beginDefaultAdminTransfer(newAdmin);
        vm.stopPrank();

        // BTC's markets switched on with the exposure gate off, so winners can be owed more than the pool holds.
        // `validate` refuses the gate off (ADR 0009), so it is switched off in storage, as only an upgrade could now.
        uint16[3] memory leverages = [Defaults.LEVERAGE, L500, L100];
        for (uint256 i; i < leverages.length; ++i) {
            ConfigParams memory c = LeverageConfigs.planned(leverages[i]);
            c.enabled = true;
            vm.prank(users.operator);
            flashOption.setConfig(Defaults.BTC, leverages[i], c);
            _switchOffOpenGate(address(flashOption), Defaults.BTC, leverages[i]);
        }

        vm.startPrank(users.guardian);
        flashOption.setPaused(Defaults.ETH, Defaults.LEVERAGE, true);
        flashOption.revokeRelayer(openerRole, opener2);
        vm.stopPrank();
    }

    /// @dev Opens every bet at the same second: a 1000x put that will lose, six $50 1000x calls and one each at 500x
    ///      and 100x that will win, a 5-minute call at 1000x and put at 100x, and a 2-minute call at 500x. Then freezes
    ///      eve, so what the pool pays her waits in `claimable`.
    function _openTheBets() private {
        start = uint48(block.timestamp);
        _betFor(users.bob, LOSER, Defaults.LEVERAGE, Side.Put, BIG_STAKE, Defaults.DURATION);
        address[3] memory bettors = [users.alice, users.bob, users.eve];
        for (uint256 i; i < WINNERS; ++i) {
            _betFor(bettors[i % 3], _winner(i), Defaults.LEVERAGE, Side.Call, BIG_STAKE, Defaults.DURATION);
        }
        _betFor(users.alice, WINNER_500, L500, Side.Call, BIG_STAKE, Defaults.DURATION);
        _betFor(users.bob, WINNER_100, L100, Side.Call, BIG_STAKE, Defaults.DURATION);
        _betFor(users.alice, OPEN_CALL, Defaults.LEVERAGE, Side.Call, Defaults.STAKE, 300);
        _betFor(users.bob, OPEN_PUT, L100, Side.Put, Defaults.STAKE, 300);
        _betFor(users.eve, REFUNDABLE, L500, Side.Call, Defaults.STAKE, 120);
        vm.prank(usdgAdmin);
        usdg.freeze(users.eve);
    }

    /// @dev Liquidates the put half-way, settles the six 1000x calls at their 4x cap (free money pays the first three;
    ///      the fourth is paid in part and the last three are owed), then the 500x and the 100x call, each in a batch
    ///      of its own market (both owed: free money is spent), then tops the pool up and repays the head IOU.
    function _endSomeBets() private {
        int64 winPrice = Examples.priceAt(WIN_PRICE_DOLLARS);
        vm.warp(start + Defaults.DURATION / 2);
        _expectLiquidated(winPrice, start + Defaults.DURATION / 2, _ids(LOSER));

        bytes32[] memory winners = new bytes32[](WINNERS);
        for (uint256 i; i < WINNERS; ++i) {
            winners[i] = _winner(i);
        }
        vm.warp(start + Defaults.DURATION);
        _expectSettled(winPrice, start + Defaults.DURATION, winners);
        batchLeverage = L500;
        _expectSettled(winPrice, start + Defaults.DURATION, _ids(WINNER_500));
        batchLeverage = L100;
        _expectSettled(winPrice, start + Defaults.DURATION, _ids(WINNER_100));
        batchLeverage = Defaults.LEVERAGE;

        _fund(users.bob, TOP_UP);
        _expectRepaid(1, users.alice);
    }

    /// @dev Every field of the pool's books and every breaker counter is set, so the upgrade has something to lose.
    function _assertEveryValueIsSet() private view {
        PoolState memory p = flashOption.getPool();
        assertGt(p.total, 0, "total");
        assertGt(p.lockedMargin, 0, "lockedMargin");
        assertGt(p.openMaxProfit, 0, "openMaxProfit");
        assertGt(p.totalOwed, 0, "totalOwed");
        assertGt(p.poolFloor, 0, "poolFloor");
        assertGt(p.nextQueueSeq, 0, "nextQueueSeq");
        assertGt(p.nextRepaySeq, 0, "nextRepaySeq: one IOU repaid");
        assertEq(p.openPositions, 3, "three bets open");
        assertGe(p.owedPositions, 2, "at least two IOUs left");
        assertGt(p.feesPending, 0, "feesPending");
        assertGt(p.totalClaimable, 0, "totalClaimable");
        assertGt(p.transferred, 0, "transferred");
        assertGt(p.feesPaid, 0, "feesPaid");
        assertEq(p.seedRecovered, SEED_BACK, "seedRecovered");
        assertEq(p.rewardsWithdrawn, REWARDS, "rewardsWithdrawn");
        Breaker memory b = flashOption.getBreaker();
        assertGt(b.profitOut, 0, "profitOut");
        assertGt(b.lossIn, 0, "lossIn");
        assertGt(b.windowStart, 0, "windowStart");
        assertEq(b.windowSecs, BREAKER_WINDOW, "windowSecs");
        assertEq(b.maxNetProfit, BREAKER_LIMIT, "maxNetProfit");
        assertGt(flashOption.claimableOf(users.eve), 0, "eve's payouts wait for her");
        // The bets V1 leaves: open at each of the three leverages, and owed at each of them.
        assertEq(_leverageHeldBy(OPEN_CALL), Defaults.LEVERAGE, "an open bet at 1000x");
        assertEq(_leverageHeldBy(REFUNDABLE), L500, "an open bet at 500x");
        assertEq(_leverageHeldBy(OPEN_PUT), L100, "an open bet at 100x");
        bool[3] memory owedAt;
        for (uint64 seq = p.nextRepaySeq; seq < p.nextQueueSeq; ++seq) {
            uint16 owedLeverage = _leverageHeldBy(LayoutReader.iouQueue(address(flashOption), seq));
            owedAt[owedLeverage == Defaults.LEVERAGE ? 0 : owedLeverage == L500 ? 1 : 2] = true;
        }
        assertTrue(owedAt[0] && owedAt[1] && owedAt[2], "IOUs at every leverage");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Upgrades to V2 and sets its new field in the same call.
    function _upgradeToV2() private returns (SlotChange[] memory, VmSafe.Log[] memory) {
        return _upgrade(address(v2), abi.encodeCall(ManicFlashOptionV2Mock.initializeV2, (NEW_SETTING)));
    }

    /// @dev The upgrader calls `upgradeToAndCall(impl, data)`, with its storage writes and logs recorded.
    /// @return changes Every slot, of every account, whose value the call changed.
    /// @return logs Every log the call emitted.
    function _upgrade(
        address impl,
        bytes memory data
    )
        private
        returns (SlotChange[] memory changes, VmSafe.Log[] memory logs)
    {
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(users.upgrader);
        flashOption.upgradeToAndCall(impl, data);
        changes = _changes(vm.stopAndReturnStateDiff());
        logs = vm.getRecordedLogs();
    }

    /// @dev Folds the recorded storage writes into one change per slot, from its first value to its last, and keeps
    ///      the slots whose value differs. Writes inside a reverted call are dropped.
    function _changes(Vm.AccountAccess[] memory accesses) private pure returns (SlotChange[] memory changes) {
        uint256 writes;
        for (uint256 i; i < accesses.length; ++i) {
            writes += accesses[i].storageAccesses.length;
        }
        changes = new SlotChange[](writes);
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = accesses[i].storageAccesses[j];
                if (!s.isWrite || s.reverted) continue;
                uint256 k;
                while (k < n && (changes[k].account != s.account || changes[k].slot != s.slot)) {
                    ++k;
                }
                if (k == n) changes[n++] = SlotChange(s.account, s.slot, s.previousValue, s.newValue);
                else changes[k].newValue = s.newValue;
            }
        }
        uint256 changed;
        for (uint256 k; k < n; ++k) {
            if (changes[k].oldValue != changes[k].newValue) changes[changed++] = changes[k];
        }
        assembly ("memory-safe") {
            mstore(changes, changed)
        }
    }

    /// @dev `c` is the proxy's `slot`, changed from `oldValue` to `newValue`.
    function _assertChange(SlotChange memory c, bytes32 slot, uint256 oldValue, uint256 newValue) private view {
        assertEq(c.account, address(flashOption), "a slot of the proxy");
        assertEq(c.slot, slot, "the slot");
        assertEq(uint256(c.oldValue), oldValue, "its old value");
        assertEq(uint256(c.newValue), newValue, "its new value");
    }

    /// @dev Every view of the contract and of the OpenZeppelin bases, encoded one by one with a label, so two reads
    ///      compare value by value.
    function _views() private returns (bytes[] memory, string[] memory) {
        delete viewLabels;
        delete viewValues;
        _see("token", abi.encode(flashOption.token()));
        _see("halted", abi.encode(flashOption.halted()));
        _see("refundDelaySecs", abi.encode(flashOption.refundDelaySecs()));
        (address feeRecipient, address rewardsRecipient) = flashOption.recipients();
        _see("recipients", abi.encode(feeRecipient, rewardsRecipient));
        _see("version", abi.encode(flashOption.version()));
        _see("marketCount", abi.encode(flashOption.marketCount()));
        for (uint16 i; i < flashOption.marketCount(); ++i) {
            (bytes32 marketId, uint16 marketLeverage) = flashOption.marketIdAt(i);
            _see(
                string.concat("market ", vm.toString(i)),
                abi.encode(marketId, marketLeverage, flashOption.getMarket(marketId, marketLeverage))
            );
        }
        _see("pool", abi.encode(flashOption.getPool()));
        _see("freeMoney", abi.encode(flashOption.freeMoney()));
        _see("breaker", abi.encode(flashOption.getBreaker()));
        (uint64 headSeq, bytes32 headId, uint64 headOwed) = flashOption.queueHead();
        _see("queueHead", abi.encode(headSeq, headId, headOwed));
        for (uint256 seq; seq < flashOption.getPool().nextQueueSeq; ++seq) {
            _see(
                string.concat("iouQueue ", vm.toString(seq)),
                abi.encode(LayoutReader.iouQueue(address(flashOption), uint64(seq)))
            );
        }
        for (uint256 i; i < ids.length; ++i) {
            (Position memory p, uint48 endTime, int64 capPrice) = flashOption.getPosition(ids[i]);
            _see(string.concat("position ", vm.toString(ids[i])), abi.encode(p, endTime, capPrice));
        }
        address[3] memory bettors = [users.alice, users.bob, users.eve];
        for (uint256 i; i < bettors.length; ++i) {
            _see(string.concat("claimable ", vm.toString(bettors[i])), abi.encode(flashOption.claimableOf(bettors[i])));
        }
        _seeRoles();
        _see("eip712Domain", _eip712Domain());
        _see("balance", abi.encode(usdg.balanceOf(address(flashOption))));
        return (viewValues, viewLabels);
    }

    /// @dev The roles: every role's holders among everyone involved, every role's admin, and the default admin's
    ///      rules (the admin, the pending transfer, the delays).
    function _seeRoles() private {
        bytes32[6] memory roles = [
            flashOption.DEFAULT_ADMIN_ROLE(),
            flashOption.UPGRADER_ROLE(),
            flashOption.OPERATOR_ROLE(),
            flashOption.GUARDIAN_ROLE(),
            flashOption.OPENER_ROLE(),
            flashOption.SETTLER_ROLE()
        ];
        address[11] memory everyone = _everyone();
        for (uint256 r; r < roles.length; ++r) {
            _see(string.concat("role admin ", vm.toString(roles[r])), abi.encode(flashOption.getRoleAdmin(roles[r])));
            for (uint256 i; i < everyone.length; ++i) {
                _see(
                    string.concat("hasRole ", vm.toString(roles[r]), " ", vm.toString(everyone[i])),
                    abi.encode(flashOption.hasRole(roles[r], everyone[i]))
                );
            }
            _see(
                string.concat("hasRole ", vm.toString(roles[r]), " opener2"),
                abi.encode(flashOption.hasRole(roles[r], opener2))
            );
            _see(
                string.concat("hasRole ", vm.toString(roles[r]), " newAdmin"),
                abi.encode(flashOption.hasRole(roles[r], newAdmin))
            );
        }
        _see("defaultAdmin", abi.encode(flashOption.defaultAdmin()));
        (address pending, uint48 schedule) = flashOption.pendingDefaultAdmin();
        _see("pendingDefaultAdmin", abi.encode(pending, schedule));
        _see("defaultAdminDelay", abi.encode(flashOption.defaultAdminDelay()));
        (uint48 newDelay, uint48 delaySchedule) = flashOption.pendingDefaultAdminDelay();
        _see("pendingDefaultAdminDelay", abi.encode(newDelay, delaySchedule));
    }

    function _see(string memory label, bytes memory value) private {
        viewLabels.push(label);
        viewValues.push(value);
    }

    /// @dev The signing domain, as EIP-5267 reports it.
    function _eip712Domain() private view returns (bytes memory) {
        (
            bytes1 fields,
            string memory name,
            string memory domainVersion,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = flashOption.eip712Domain();
        return abi.encode(fields, name, domainVersion, chainId, verifyingContract, salt, extensions);
    }

    /// @dev The EIP-712 domain separator the orders are signed under, recomputed from the domain the contract reports.
    function _domainSeparator() private view returns (bytes32) {
        (, string memory name, string memory domainVersion, uint256 chainId, address verifyingContract,,) =
            flashOption.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(domainVersion)),
                chainId,
                verifyingContract
            )
        );
    }

    /// @dev Anyone claims for `account`; checks that all of its claimable balance reaches it.
    function _expectClaim(address account) private {
        uint64 owed = flashOption.claimableOf(account);
        uint64 totalClaimable = flashOption.getPool().totalClaimable;
        uint256 balance = usdg.balanceOf(account);
        uint256 held = usdg.balanceOf(address(flashOption));
        assertGt(owed, 0, "something to claim");
        vm.prank(users.alice);
        flashOption.claim(account);
        assertEq(usdg.balanceOf(account), balance + owed, "paid to the account");
        assertEq(usdg.balanceOf(address(flashOption)), held - owed, "out of the contract");
        assertEq(flashOption.claimableOf(account), 0, "nothing left to claim");
        assertEq(flashOption.getPool().totalClaimable, totalClaimable - owed, "the books");
    }

    /// @dev Anyone sweeps the fees; checks that they all reach the fee recipient V1 set.
    function _expectSweep() private {
        uint64 fees = flashOption.getPool().feesPending;
        uint256 balance = usdg.balanceOf(newFeeRecipient);
        assertGt(fees, 0, "fees to sweep");
        vm.prank(users.bob);
        flashOption.sweepFees();
        assertEq(usdg.balanceOf(newFeeRecipient), balance + fees, "paid to the fee recipient");
        assertEq(flashOption.getPool().feesPending, 0, "no fee pending");
    }

    /// @dev Opens `user`'s bet on BTC's market at `marketLeverage` with this stake and length, at the middle of the
    ///      length's θ range, and remembers its id. At 1000x it takes the base terms' floor and cap (1.3x, 4x);
    ///      at 500x and 100x, the tier's lowest floor and highest cap.
    function _betFor(
        address user,
        bytes32 id,
        uint16 marketLeverage,
        Side side,
        uint64 stake,
        uint16 durationSecs
    )
        private
    {
        OpenOrder memory o = _order(user, id);
        o.leverage = marketLeverage;
        o.side = side;
        o.stake = stake;
        o.durationSecs = durationSecs;
        OpenTerms memory t = _terms();
        ConfigParams memory c = LeverageConfigs.planned(marketLeverage);
        t.thetaE7 = _theta(c, durationSecs);
        if (marketLeverage != Defaults.LEVERAGE) (t.floorBps, t.capBps) = (c.floorMinBps, c.capMaxBps);
        _betWith(o, t);
        ids.push(id);
    }

    /// @dev The middle of the θ range the settings `c` allow for `durationSecs`.
    function _theta(ConfigParams memory c, uint16 durationSecs) private pure returns (uint32) {
        for (uint256 i; i < c.durations.length; ++i) {
            if (c.durations[i].durationSecs == durationSecs) {
                return (c.durations[i].thetaMinE7 + c.durations[i].thetaMaxE7) / 2;
            }
        }
        revert("no such duration");
    }

    function _winner(uint256 i) private pure returns (bytes32) {
        return keccak256(abi.encode("a $50 call that wins", i));
    }

    /// @dev The leverage the bet `id` holds.
    function _leverageHeldBy(bytes32 id) private view returns (uint16) {
        return LayoutReader.position(address(flashOption), id).leverage;
    }

    /// @dev Settles the 5-minute bets V1 left open, at their expiry second `end`, each in a batch of its own market:
    ///      the 1000x call at the entry price (1x), the 100x put 10 bp below it (1.1x at 100x).
    function _settleTheOpenBets(uint48 end) private {
        _expectSettled(Defaults.ENTRY_PRICE, end, _ids(OPEN_CALL));
        batchLeverage = L100;
        _expectSettled(PUT_WIN_PRICE, end, _ids(OPEN_PUT));
        batchLeverage = Defaults.LEVERAGE;
    }

    function _proxyAsV2() private view returns (ManicFlashOptionV2Mock) {
        return ManicFlashOptionV2Mock(address(flashOption));
    }

    /// @dev The proxy's initializer version: the first 8 bytes of OpenZeppelin's `Initializable` namespace.
    function _initializedVersion() private view returns (uint64) {
        return uint64(uint256(vm.load(address(flashOption), INITIALIZABLE_SLOT)));
    }

    /// @dev The slot of an ERC-7201 namespace.
    function _erc7201(string memory id) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
