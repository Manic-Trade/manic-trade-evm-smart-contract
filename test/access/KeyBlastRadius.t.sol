// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Market, PoolState, Position, Side, WithdrawPurpose} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {DrainerImplementationMock} from "../mocks/DrainerImplementationMock.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title KeyBlastRadius_Test
/// @notice What each key can do alone if it leaks (docs/ARCHITECTURE.md §4.2, security checklist AC-1, AC-2 and
///         AC-4). Each test plays one stolen key, with no other, doing the worst it can, and pins the bound.
/// @dev The keys, worst first:
///      - the upgrader and the admin: everything. The upgrader installs any code; the admin grants itself any role.
///        That is why mainnet holds both in the 48-hour timelock, which anyone can watch and the guardian can cancel;
///      - the opener and the settler: they name the prices, since the relayer is the oracle. They can cost users
///        their stakes, and, betting from wallets of their own, take profit until the payout circuit breaker trips
///        (the fake-price loop: `FakePriceLoop.t.sol`, and the breaker's own test in `test/concrete/breaker/`);
///      - the operator: it loosens the limits `validate` leaves open, undoes the guardian's stops and re-arms the
///        breaker, but moves no money;
///      - the guardian: it can only stop things;
///      - everyone else: the functions anyone may call never pay the caller.
///      The base bet is a $10 BTC call for a minute at $83,884, θ 3 bp, floor 1.3x, cap 4x.
contract KeyBlastRadius_Test is Settlement_Base_Test {
    // ---------------------------------------------------------------------------------------------------------------
    // The relayer keys
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A leaked opener key and alice's signed order: the key picks the entry, since the relayer is the oracle.
    ///      Opened 1% above the real price, the bet is past its line at once, and the honest settler liquidates it at
    ///      the real price: alice loses her $10 stake, and none of the $90 more she holds. Her signature covers every
    ///      other term, so the key can't open the order at another stake, side or leverage, open it twice, or open an
    ///      order after its deadline.
    function test_ALeakedOpenerKeyCanCostAUserHerStakeAndNoMore() external {
        _mintUsdg(users.alice, 100e6);
        OpenOrder memory o = _order(users.alice, "alice's order");
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        OpenTerms memory t = _terms();
        t.entryPrice = Examples.P0 + Examples.P0 / 100;

        OpenOrder memory bigger = _order(users.alice, "alice's order");
        bigger.stake = 50e6;
        _expectOpenRefused(bigger, signature, t, a, abi.encodeWithSelector(Errors.InvalidSignature.selector));
        OpenOrder memory flipped = _order(users.alice, "alice's order");
        flipped.side = Side.Put;
        _expectOpenRefused(flipped, signature, t, a, abi.encodeWithSelector(Errors.InvalidSignature.selector));
        _useBtcAt(500, LeverageConfigs.planned(500));
        OpenOrder memory lower = _order(users.alice, "alice's order");
        lower.leverage = 500;
        _expectOpenRefused(lower, signature, t, a, abi.encodeWithSelector(Errors.InvalidSignature.selector));

        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
        _expectOpenRefused(o, signature, t, a, abi.encodeWithSelector(Errors.PositionIdUsed.selector));
        _expectLiquidated(Examples.P0, uint48(block.timestamp), _ids("alice's order"));
        assertEq(usdg.balanceOf(users.alice), 90e6, "alice lost her stake, and only her stake");

        OpenOrder memory late = _order(users.alice, "alice's late order");
        bytes memory lateSignature = _signOrder(flashOption, aliceKey, late);
        StakeAuth memory lateAuth = _stakeAuth(flashOption, aliceKey, late);
        vm.warp(late.deadline + 1);
        _expectOpenRefused(
            late, lateSignature, _terms(), lateAuth, abi.encodeWithSelector(Errors.OrderExpired.selector)
        );
    }

    /// @dev A leaked settler key ends every open bet at once, each at a price past its line, though the real price
    ///      never moved: alice's call below, bob's put above. Both lose their stakes, but nothing leaves the contract:
    ///      the pool keeps the stakes, less the loser fees waiting to be swept, and the key is paid nothing. Nor can it
    ///      settle a bet early: a tick at the bet's end is refused until the chain's clock is within the clock skew of
    ///      it (5 seconds at launch).
    function test_ALeakedSettlerKeyCanEndEveryOpenBetButTakesNothing() external {
        Position memory call = _bet(users.alice, "alice's call", Side.Call);
        Position memory put = _bet(users.bob, "bob's put", Side.Put);
        uint256 held = usdg.balanceOf(address(flashOption));

        _expectLiquidated(Examples.priceAt(-300), call.startTime, _ids("alice's call"));
        _expectLiquidated(Examples.priceAt(300), put.startTime, _ids("bob's put"));
        assertEq(usdg.balanceOf(address(flashOption)), held, "nothing left the contract");
        assertEq(usdg.balanceOf(users.settler), 0, "the key was paid nothing");

        Position memory p = _bet(users.eve, "eve's call", Side.Call);
        uint8 skew = Defaults.marketConfig().clockSkewSecs;
        vm.warp(_end(p) - skew - 1);
        _expectSettleReverts(
            Examples.P0, _end(p), _ids("eve's call"), abi.encodeWithSelector(Errors.NotExpired.selector)
        );
        vm.warp(_end(p) - skew);
        _expectSettled(Examples.P0, _end(p), _ids("eve's call"));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The operator and the guardian
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A leaked operator key sets the loosest settings `validate` lets through: the open gate at 100%, the owed
    ///      limit off, the oldest price a `uint8` holds (255 seconds), a 30-second clock skew, a 100% cap on the
    ///      early-sell fee, and any stake. One step further is refused: a cap above 4x, the open gate off or above
    ///      100%, and a clock skew over 30 seconds (ADR 0009). The price age, the owed limit, the stakes and the sell
    ///      window stay unbounded. It also lifts the guardian's stops and re-arms the breaker. None of it moves money:
    ///      the books and the contract's balance are as they were, and the key holds nothing.
    function test_ALeakedOperatorKeyCanLoosenTheLimitsButMovesNoMoney() external {
        _bet(users.alice, "alice's call", Side.Call);
        PoolState memory books = LayoutReader.pool(address(flashOption));
        uint256 held = usdg.balanceOf(address(flashOption));
        ConfigParams memory c = _enabledConfig();
        c.maxExposureBps = 10_000;
        c.maxTotalOwed = type(uint64).max;
        c.entryMaxAgeSecs = type(uint8).max;
        c.clockSkewSecs = 30;
        c.maxSellFeeBps = 10_000;
        c.minStake = 1;
        c.maxStake = type(uint64).max;

        vm.startPrank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        c.capMaxBps = 40_001;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        c.capMaxBps = 40_000;
        c.maxExposureBps = 0;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        c.maxExposureBps = 10_001;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        c.maxExposureBps = 10_000;
        c.clockSkewSecs = 31;
        vm.expectRevert(Errors.InvalidLeverageParams.selector);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        Market memory m = LayoutReader.market(address(flashOption), 0);
        assertEq(m.maxExposureBps, 10_000, "the gate stays on, at 100% at most");
        assertEq(m.clockSkewSecs, 30, "the skew stays at 30 seconds at most");
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        flashOption.setHalted(false);
        flashOption.resetBreaker();
        vm.stopPrank();

        _assertPool(LayoutReader.pool(address(flashOption)), books);
        assertEq(usdg.balanceOf(address(flashOption)), held, "nothing left the contract");
        assertEq(usdg.balanceOf(users.operator), 0, "the key holds nothing");
    }

    /// @dev A leaked guardian key does the worst it can: it halts everything, pauses BTC and revokes both relayer
    ///      keys. It can't revoke any other role, or undo a stop. Alice's stake still comes back: the safety refund
    ///      works while halted, and anyone may run it. The operator then lifts the stops, the admin grants the keys
    ///      back, and trading resumes.
    function test_ALeakedGuardianKeyCanOnlyStopThingsAndUsersStillGetTheirMoney() external {
        Position memory p = _bet(users.alice, "alice's call", Side.Call);
        bytes32 openerRole = flashOption.OPENER_ROLE();
        bytes32 settlerRole = flashOption.SETTLER_ROLE();
        bytes32 operatorRole = flashOption.OPERATOR_ROLE();

        vm.startPrank(users.guardian);
        flashOption.setHalted(true);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        flashOption.revokeRelayer(openerRole, users.opener);
        flashOption.revokeRelayer(settlerRole, users.settler);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRelayerRole.selector, operatorRole));
        flashOption.revokeRelayer(operatorRole, users.operator);
        vm.expectRevert(Errors.OnlyOperatorCanUnhalt.selector);
        flashOption.setHalted(false);
        vm.stopPrank();

        vm.warp(_end(p) + Defaults.REFUND_DELAY);
        _expectRefunded(_ids("alice's call"), users.eve);

        vm.startPrank(users.operator);
        flashOption.setHalted(false);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        vm.stopPrank();
        vm.startPrank(users.admin);
        flashOption.grantRole(openerRole, users.opener);
        flashOption.grantRole(settlerRole, users.settler);
        vm.stopPrank();
        _bet(users.bob, "bob's call", Side.Call);
        assertEq(usdg.balanceOf(users.guardian), 0, "the key holds nothing");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The timelocked keys
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A leaked upgrader key installs code that sends the proxy's whole balance to the attacker, in one call: the
    ///      pool, the pending fees and the open stakes. Nothing in the contract can stop an upgrade; only the 48-hour
    ///      timelock that holds this key on mainnet can.
    function test_ALeakedUpgraderKeyCanReplaceTheCodeAndTakeEverything() external {
        _bet(users.alice, "alice's call", Side.Call);
        uint256 held = usdg.balanceOf(address(flashOption));
        DrainerImplementationMock drainer = new DrainerImplementationMock();

        vm.prank(users.upgrader);
        flashOption.upgradeToAndCall(
            address(drainer), abi.encodeCall(DrainerImplementationMock.drain, (IERC20(address(usdg)), users.eve))
        );
        assertEq(usdg.balanceOf(address(flashOption)), 0, "the contract is empty");
        assertEq(usdg.balanceOf(users.eve), held, "the attacker has it all");
    }

    /// @dev A leaked admin key, alone, is bounded in what it can withdraw: free money above the floor and the open
    ///      bets' most profit, to the recipients it names ($970 here, with $1,500 free, a $500 floor and an open bet
    ///      that can win $30). One unit more is refused. But the admin administers every role: it makes itself the
    ///      upgrader, and the upgrader can take everything. Only the 48-hour timelock that holds this key on mainnet
    ///      stands in the way.
    function test_ALeakedAdminKeyIsBoundedAloneButCanGrantItselfAnyRole() external {
        _bet(users.alice, "alice's call", Side.Call);
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        uint64 most = pool.total - pool.lockedMargin - pool.poolFloor - pool.openMaxProfit;
        assertEq(most, 970e6, "free money above the floor and the open bet's most profit");
        bytes32 upgraderRole = flashOption.UPGRADER_ROLE();
        DrainerImplementationMock drainer = new DrainerImplementationMock();

        vm.startPrank(users.admin);
        flashOption.setRecipients(users.eve, users.eve);
        vm.expectRevert(Errors.OpenExposureNotCovered.selector);
        flashOption.withdraw(WithdrawPurpose.Rewards, most + 1);
        flashOption.withdraw(WithdrawPurpose.Rewards, most);
        assertEq(usdg.balanceOf(users.eve), most, "the most it can withdraw");

        flashOption.grantRole(upgraderRole, users.admin);
        flashOption.upgradeToAndCall(
            address(drainer), abi.encodeCall(DrainerImplementationMock.drain, (IERC20(address(usdg)), users.eve))
        );
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(flashOption)), 0, "then everything, as the upgrader");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Everyone else
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Eve, holding no role, runs each function anyone may call: a claim pays the account it names (bob, whose
    ///      payout waited while USDG froze him), the fee sweep pays the fee recipient, and the refund pays the bettor.
    ///      Eve gains nothing.
    function test_WhatAnyoneMayCallPaysTheAccountItIsForNeverTheCaller() external {
        Position memory a = _bet(users.alice, "alice's call", Side.Call);
        Position memory b = _bet(users.bob, "bob's call", Side.Call);
        Position memory loser = _bet(users.alice, "a loser", Side.Call);
        _expectLiquidated(loser.liqPrice, loser.startTime, _ids("a loser"));
        vm.warp(_end(b));
        vm.prank(usdgAdmin);
        usdg.freeze(users.bob);
        _expectSettled(Examples.priceAt(300), _end(b), _ids("bob's call"));
        vm.prank(usdgAdmin);
        usdg.unfreeze(users.bob);

        uint64 waiting = flashOption.claimableOf(users.bob);
        uint256 bobBefore = usdg.balanceOf(users.bob);
        vm.prank(users.eve);
        flashOption.claim(users.bob);
        assertEq(usdg.balanceOf(users.bob), bobBefore + waiting, "the claim paid bob");

        uint64 fees = flashOption.getPool().feesPending;
        vm.prank(users.eve);
        flashOption.sweepFees();
        assertEq(usdg.balanceOf(users.feeRecipient), fees, "the sweep paid the fee recipient");

        vm.warp(_end(a) + Defaults.REFUND_DELAY);
        _expectRefunded(_ids("alice's call"), users.eve);
        assertEq(usdg.balanceOf(users.eve), 0, "eve gained nothing");
    }

    /// @dev On a pool with $1 of free money, alice's winner at the 4x cap is owed most of its $40. After a top-up,
    ///      eve repays the queue: alice is paid, and eve gains nothing.
    function test_AnyoneMayRepayButTheIouPaysItsUser() external {
        _useSmallPool(1e6);
        Position memory p = _bet(users.alice, "alice's call", Side.Call);
        vm.warp(_end(p));
        _expectSettled(Examples.priceAt(300), _end(p), _ids("alice's call"));
        _fund(users.bob, 100e6);
        _expectRepaid(1, users.eve);
        assertEq(usdg.balanceOf(users.eve), 0, "eve gained nothing");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Expects the opener's `open` of `o` with these to revert with `reason`.
    function _expectOpenRefused(
        OpenOrder memory o,
        bytes memory signature,
        OpenTerms memory t,
        StakeAuth memory a,
        bytes memory reason
    )
        private
    {
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
    }
}
