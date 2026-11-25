// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {IManicFlashOptionAdmin} from "../../../src/interfaces/IManicFlashOptionAdmin.sol";
import {IManicFlashOptionPool} from "../../../src/interfaces/IManicFlashOptionPool.sol";
import {IManicFlashOptionSettlement} from "../../../src/interfaces/IManicFlashOptionSettlement.sol";
import {IManicFlashOptionTrading} from "../../../src/interfaces/IManicFlashOptionTrading.sol";
import {IManicFlashOptionViews} from "../../../src/interfaces/IManicFlashOptionViews.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {ConfigParams, InitParams} from "../../../src/types/ParamTypes.sol";
import {PoolState, Status, WithdrawPurpose} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockReentrantToken} from "../../mocks/MockReentrantToken.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {OrderSigner} from "../../utils/OrderSigner.sol";

/// @title Reentrancy_Concrete_Test
/// @notice Every function that moves tokens is entered again from inside its own transfer, into every state-changing
///         function, and the guard refuses every one (docs/security-checklist.md RE-1; docs/ARCHITECTURE.md §15
///         rule 3).
/// @dev USDG has no transfer hooks, but its issuer can upgrade it, so the token is treated as untrusted.
///      `MockReentrantToken` calls back into the proxy before it moves anything. `nonReentrant` is the first modifier,
///      so the guard refuses the callback before any role check: the token holds no role, and the error is still the
///      guard's. `_callbacks` lists every state-changing function of the admin, trading, settlement and pool
///      interfaces, and `test_TheCallbacksCoverEveryStateChangingFunction` fails when one is added without a
///      callback. `open` is entered again from inside its stake pull. `settle`, `sell`, `repay` and `refundExpired`
///      pay through `_pay`, which never reverts on a refused transfer, so a refused callback shows as the payout
///      waiting in `claimable` and the call going through. `liquidate` makes no external call, so it can only be
///      entered from the others. The getters are read from inside a guarded call too: each one refuses (read-only
///      reentrancy, ARCHITECTURE §15 rule 12), and answers once the call is over.
contract Reentrancy_Concrete_Test is Base_Test {
    /// @dev What each outer call moves, and the books it needs: free money, pending fees and alice's claimable balance.
    uint64 internal constant AMOUNT = 1e6;
    uint64 internal constant FREE = 1500e6;
    uint64 internal constant FEES = 10e6;
    uint64 internal constant CLAIMABLE = 10e6;

    /// @dev The functions that move tokens, entered from outside.
    enum Outer {
        Fund,
        Withdraw,
        Claim,
        SweepFees,
        Open
    }

    MockReentrantToken internal token;
    ManicFlashOption internal proxy;
    /// @dev Alice's order for the base bet on `proxy`, and her signature of it.
    OpenOrder internal order;
    bytes internal orderSignature;

    function setUp() public override {
        super.setUp();
        token = new MockReentrantToken();
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(token));
        proxy = ManicFlashOption(_deployProxy(p));

        // Free money, funded the real way while the token is disarmed.
        token.mint(users.bob, FREE);
        vm.startPrank(users.bob);
        token.approve(address(proxy), FREE);
        proxy.fund(FREE);
        vm.stopPrank();
        // Pending fees and a claimable balance for alice, written into storage and backed by tokens.
        _writeLayout(address(proxy), 5, 0, 64, FEES); // pool.feesPending
        _writeLayout(address(proxy), 5, 64, 64, CLAIMABLE); // pool.totalClaimable
        vm.store(
            address(proxy), keccak256(abi.encode(users.alice, LayoutReader.ROOT + 13)), bytes32(uint256(CLAIMABLE))
        );
        token.mint(address(proxy), FEES + CLAIMABLE);
        // Alice can fund, and open the base bet on BTC.
        token.mint(users.alice, AMOUNT + Defaults.STAKE);
        vm.prank(users.alice);
        token.approve(address(proxy), AMOUNT);
        vm.prank(users.admin);
        proxy.createMarket(Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        proxy.setConfig(Defaults.BTC, Defaults.LEVERAGE, _enabledConfig());
        order = _order(users.alice, keccak256("alice's bet"));
        orderSignature = _signOrder(proxy, _keyOf("alice"), order);
    }

    function test_TheCallbacksCoverEveryStateChangingFunction() external view {
        bytes[] memory calls = _callbacks();
        bytes4 pool;
        // `initialize` has no callback: it runs once, in the deploy transaction, and reverts `InvalidInitialization`
        // after that.
        bytes4 admin = IManicFlashOptionAdmin.initialize.selector;
        bytes4 trading;
        bytes4 settlement;
        for (uint256 i; i < calls.length; ++i) {
            if (i < 4) pool ^= bytes4(calls[i]);
            else if (i < 14) admin ^= bytes4(calls[i]);
            else if (i < 16) trading ^= bytes4(calls[i]);
            else settlement ^= bytes4(calls[i]);
        }
        assertEq(trading, type(IManicFlashOptionTrading).interfaceId, "every trading function has a callback");
        assertEq(settlement, type(IManicFlashOptionSettlement).interfaceId, "every settlement function has a callback");
        assertEq(pool, type(IManicFlashOptionPool).interfaceId, "every pool function has a callback");
        assertEq(admin, type(IManicFlashOptionAdmin).interfaceId, "every admin function has a callback");
    }

    /// @dev The getters below are every function of the views interface but the hash helpers and `version`, which
    ///      read none of the contract's books.
    function test_TheGetterCallsCoverEveryGuardedGetter() external view {
        bytes[] memory getters = _getterCalls();
        bytes4 views = IManicFlashOptionViews.hashOpenOrder.selector ^ IManicFlashOptionViews.hashSellOrder.selector
            ^ IManicFlashOptionViews.version.selector;
        for (uint256 i; i < getters.length; ++i) {
            views ^= bytes4(getters[i]);
        }
        assertEq(views, type(IManicFlashOptionViews).interfaceId, "every getter is listed");
    }

    function test_RevertWhen_AGetterIsReadFromInsideAGuardedCall() external {
        // it should revert for every getter read from inside fund's pull, and each answers once the call is over
        bytes[] memory getters = _getterCalls();
        bytes memory refused = abi.encodeWithSelector(
            MockReentrantToken.CallbackReverted.selector,
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        for (uint256 i; i < getters.length; ++i) {
            token.setCallback(address(proxy), getters[i]);
            vm.expectRevert(refused);
            vm.prank(users.alice);
            proxy.fund(AMOUNT);
            (bool answered,) = address(proxy).staticcall(getters[i]);
            assertTrue(answered, "answers outside a guarded call");
        }
    }

    function test_RevertWhen_FundIsEnteredAgainFromItsPull() external {
        // it should revert for every callback, and fund once the token stops calling back
        _assertEveryCallbackIsRefused(Outer.Fund);
        assertEq(LayoutReader.pool(address(proxy)).total, FREE + AMOUNT, "funded");
    }

    function test_RevertWhen_WithdrawIsEnteredAgainFromItsTransfer() external {
        // it should revert for every callback, and withdraw once the token stops calling back
        _assertEveryCallbackIsRefused(Outer.Withdraw);
        assertEq(token.balanceOf(users.rewardsRecipient), AMOUNT, "withdrawn");
    }

    function test_RevertWhen_ClaimIsEnteredAgainFromItsTransfer() external {
        // it should revert for every callback, and pay alice once the token stops calling back
        uint256 before = token.balanceOf(users.alice);
        _assertEveryCallbackIsRefused(Outer.Claim);
        assertEq(token.balanceOf(users.alice), before + CLAIMABLE, "claimed");
    }

    function test_RevertWhen_SweepFeesIsEnteredAgainFromItsTransfer() external {
        // it should revert for every callback, and sweep once the token stops calling back
        _assertEveryCallbackIsRefused(Outer.SweepFees);
        assertEq(token.balanceOf(users.feeRecipient), FEES, "swept");
    }

    function test_RevertWhen_OpenIsEnteredAgainFromItsStakePull() external {
        // it should revert for every callback, and open alice's bet once the token stops calling back
        _assertEveryCallbackIsRefused(Outer.Open);
        assertEq(LayoutReader.pool(address(proxy)).openPositions, 1, "opened");
        assertEq(token.balanceOf(users.alice), AMOUNT, "her stake is in the pool; her funding money is not");
    }

    function test_WhenSettleIsEnteredAgainFromItsPayout() external {
        // it should keep alice's payout in claimable for every callback, and pay her once the token stops calling back
        bytes[] memory calls = _callbacks();
        uint256 aliceKey = _keyOf("alice");
        for (uint256 i; i <= calls.length; ++i) {
            // A new bet for each callback, opened while the token is disarmed, settled flat at its expiry second.
            token.setCallback(address(0), "");
            OpenOrder memory o = _order(users.alice, keccak256(abi.encode("settled", i)));
            token.mint(users.alice, o.stake);
            OpenTerms memory t = _terms();
            bytes memory signature = _signOrder(proxy, aliceKey, o);
            vm.prank(users.opener);
            proxy.open(o, signature, t, _anyAuth());
            vm.warp(t.entryPublishTime + o.durationSecs);
            bytes32[] memory ids = new bytes32[](1);
            ids[0] = o.positionId;

            uint64 claimableBefore = LayoutReader.claimable(address(proxy), users.alice);
            uint256 balanceBefore = token.balanceOf(users.alice);
            if (i < calls.length) {
                token.setCallback(address(proxy), calls[i]);
                vm.expectCall(address(proxy), calls[i]);
            } else {
                token.setCallback(address(0), "");
            }
            vm.prank(users.settler);
            assertEq(
                proxy.settle(Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE, uint48(block.timestamp), ids),
                1,
                "settled"
            );

            assertEq(uint8(LayoutReader.position(address(proxy), o.positionId).status), uint8(Status.Closed), "closed");
            uint64 deferred = i < calls.length ? o.stake : 0;
            assertEq(LayoutReader.claimable(address(proxy), users.alice), claimableBefore + deferred, "deferred");
            assertEq(token.balanceOf(users.alice), balanceBefore + o.stake - deferred, "paid");
            PoolState memory pool = LayoutReader.pool(address(proxy));
            assertGe(
                token.balanceOf(address(proxy)),
                uint256(pool.total) + pool.feesPending + pool.totalClaimable,
                "balance covers total + fees + claimable"
            );
        }
    }

    function test_WhenSellIsEnteredAgainFromItsPayout() external {
        // it should keep alice's proceeds in claimable for every callback, and pay her once the token stops calling
        // back
        bytes[] memory calls = _callbacks();
        uint256 aliceKey = _keyOf("alice");
        for (uint256 i; i <= calls.length; ++i) {
            // A new bet for each callback, opened while the token is disarmed, sold flat at once.
            token.setCallback(address(0), "");
            OpenOrder memory o = _order(users.alice, keccak256(abi.encode("sold", i)));
            token.mint(users.alice, o.stake);
            bytes memory openSignature = _signOrder(proxy, aliceKey, o);
            vm.prank(users.opener);
            proxy.open(o, openSignature, _terms(), _anyAuth());
            SellOrder memory s = SellOrder({
                positionId: o.positionId,
                minAmount: o.stake,
                notBefore: uint48(block.timestamp),
                deadline: uint48(block.timestamp) + Defaults.ORDER_LIFETIME
            });
            bytes memory sellSignature = OrderSigner.sign(aliceKey, proxy.hashSellOrder(s));
            SellTerms memory t = SellTerms({
                price: Defaults.ENTRY_PRICE,
                publishTime: uint48(block.timestamp),
                valuation: o.stake,
                sellAmount: o.stake
            });

            uint64 claimableBefore = LayoutReader.claimable(address(proxy), users.alice);
            uint256 balanceBefore = token.balanceOf(users.alice);
            if (i < calls.length) {
                token.setCallback(address(proxy), calls[i]);
                vm.expectCall(address(proxy), calls[i]);
            } else {
                token.setCallback(address(0), "");
            }
            vm.prank(users.opener);
            proxy.sell(s, sellSignature, t);

            assertEq(uint8(LayoutReader.position(address(proxy), o.positionId).status), uint8(Status.Closed), "closed");
            uint64 deferred = i < calls.length ? o.stake : 0;
            assertEq(LayoutReader.claimable(address(proxy), users.alice), claimableBefore + deferred, "deferred");
            assertEq(token.balanceOf(users.alice), balanceBefore + o.stake - deferred, "paid");
        }
    }

    function test_WhenRepayIsEnteredAgainFromItsPayout() external {
        // it should keep alice's repayment in claimable for every callback, and pay her once the token stops calling
        // back
        bytes[] memory calls = _callbacks();
        ManicFlashOption small = _smallPoolOverThisToken(1e6);
        _queueOneIouEach(small, calls.length + 1);
        _fundWithThisToken(small, uint64(30e6 * (calls.length + 1)));

        for (uint256 i; i <= calls.length; ++i) {
            bytes32 head = LayoutReader.iouQueue(address(small), uint64(i));
            uint64 amount = LayoutReader.position(address(small), head).owed;
            uint64 toUser = amount - amount * 200 / 10_000;
            uint64 claimableBefore = LayoutReader.claimable(address(small), users.alice);
            uint256 balanceBefore = token.balanceOf(users.alice);
            if (i < calls.length) {
                token.setCallback(address(small), calls[i]);
                vm.expectCall(address(small), calls[i]);
            } else {
                token.setCallback(address(0), "");
            }
            vm.prank(users.eve);
            assertEq(small.repay(1), 1, "repaid");

            assertEq(uint8(LayoutReader.position(address(small), head).status), uint8(Status.Closed), "closed");
            uint64 deferred = i < calls.length ? toUser : 0;
            assertEq(LayoutReader.claimable(address(small), users.alice), claimableBefore + deferred, "deferred");
            assertEq(token.balanceOf(users.alice), balanceBefore + toUser - deferred, "paid");
        }
        assertEq(LayoutReader.pool(address(small)).totalOwed, 0, "the queue is empty");
    }

    function test_WhenRefundExpiredIsEnteredAgainFromItsPayout() external {
        // it should keep alice's refund in claimable for every callback, and pay her once the token stops calling back
        bytes[] memory calls = _callbacks();
        uint256 aliceKey = _keyOf("alice");
        for (uint256 i; i <= calls.length; ++i) {
            // A new bet for each callback, opened while the token is disarmed, refunded a day after its expiry.
            token.setCallback(address(0), "");
            OpenOrder memory o = _order(users.alice, keccak256(abi.encode("refunded", i)));
            token.mint(users.alice, o.stake);
            OpenTerms memory t = _terms();
            bytes memory signature = _signOrder(proxy, aliceKey, o);
            vm.prank(users.opener);
            proxy.open(o, signature, t, _anyAuth());
            vm.warp(t.entryPublishTime + o.durationSecs + Defaults.REFUND_DELAY);
            bytes32[] memory ids = new bytes32[](1);
            ids[0] = o.positionId;

            uint64 claimableBefore = LayoutReader.claimable(address(proxy), users.alice);
            uint256 balanceBefore = token.balanceOf(users.alice);
            if (i < calls.length) {
                token.setCallback(address(proxy), calls[i]);
                vm.expectCall(address(proxy), calls[i]);
            } else {
                token.setCallback(address(0), "");
            }
            vm.prank(users.eve);
            assertEq(proxy.refundExpired(ids), 1, "refunded");

            assertEq(uint8(LayoutReader.position(address(proxy), o.positionId).status), uint8(Status.Closed), "closed");
            uint64 deferred = i < calls.length ? o.stake : 0;
            assertEq(LayoutReader.claimable(address(proxy), users.alice), claimableBefore + deferred, "deferred");
            assertEq(token.balanceOf(users.alice), balanceBefore + o.stake - deferred, "paid");
        }
    }

    /// @dev Makes `outer` once for each callback, with the token armed to make that callback, and expects the guard to
    ///      refuse it every time. Then, with the token disarmed, makes `outer` once more, which must succeed: the
    ///      refusals came from the reentry and nothing else.
    function _assertEveryCallbackIsRefused(Outer outer) private {
        bytes[] memory calls = _callbacks();
        bytes memory refused = abi.encodeWithSelector(
            MockReentrantToken.CallbackReverted.selector,
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        for (uint256 i; i < calls.length; ++i) {
            token.setCallback(address(proxy), calls[i]);
            vm.expectRevert(refused);
            _enter(outer);
        }
        token.setCallback(address(0), "");
        _enter(outer);
    }

    /// @dev Calls `outer` the way its caller would: anyone funds, the admin withdraws, a stranger claims for alice and
    ///      sweeps the fees, and the opener opens alice's bet (this token checks no authorisation).
    function _enter(Outer outer) private {
        if (outer == Outer.Fund) {
            vm.prank(users.alice);
            proxy.fund(AMOUNT);
        } else if (outer == Outer.Withdraw) {
            vm.prank(users.admin);
            proxy.withdraw(WithdrawPurpose.Rewards, AMOUNT);
        } else if (outer == Outer.Claim) {
            vm.prank(users.eve);
            proxy.claim(users.alice);
        } else if (outer == Outer.SweepFees) {
            vm.prank(users.eve);
            proxy.sweepFees();
        } else {
            vm.prank(users.opener);
            proxy.open(order, orderSignature, _terms(), _anyAuth());
        }
    }

    /// @dev A new proxy over this token, disarmed, whose pool holds only `free`, with BTC's exposure gate off.
    function _smallPoolOverThisToken(uint64 free) private returns (ManicFlashOption small) {
        token.setCallback(address(0), "");
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(token));
        small = ManicFlashOption(_deployProxy(p));
        ConfigParams memory c = Defaults.marketConfig();
        vm.prank(users.admin);
        small.createMarket(Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, c);
        c.enabled = true;
        vm.prank(users.operator);
        small.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _switchOffOpenGate(address(small), Defaults.BTC, Defaults.LEVERAGE);
        _fundWithThisToken(small, free);
    }

    /// @dev Opens `n` of alice's base bets on `small` and settles them at the 4x cap: the first is paid what free
    ///      money there is and owed the rest; every later one is owed its whole $30 profit.
    function _queueOneIouEach(ManicFlashOption small, uint256 n) private {
        uint256 aliceKey = _keyOf("alice");
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            OpenOrder memory o = _order(users.alice, keccak256(abi.encode("iou", i)));
            ids[i] = o.positionId;
            token.mint(users.alice, o.stake);
            bytes memory signature = _signOrder(small, aliceKey, o);
            vm.prank(users.opener);
            small.open(o, signature, _terms(), _anyAuth());
        }
        uint48 end = uint48(block.timestamp) + Defaults.DURATION;
        vm.warp(end);
        vm.prank(users.settler);
        small.settle(Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE + 300 * 1e8, end, ids);
        assertEq(LayoutReader.pool(address(small)).owedPositions, n, "one IOU each");
    }

    /// @dev Bob funds `target` with `amount` of this token.
    function _fundWithThisToken(ManicFlashOption target, uint64 amount) private {
        token.mint(users.bob, amount);
        vm.startPrank(users.bob);
        token.approve(address(target), amount);
        target.fund(amount);
        vm.stopPrank();
    }

    /// @dev One call to every getter that reads the books, with well-formed arguments.
    function _getterCalls() private view returns (bytes[] memory calls) {
        calls = new bytes[](13);
        calls[0] = abi.encodeCall(IManicFlashOptionViews.getPosition, (order.positionId));
        calls[1] = abi.encodeCall(IManicFlashOptionViews.getMarket, (Defaults.BTC, Defaults.LEVERAGE));
        calls[2] = abi.encodeCall(IManicFlashOptionViews.marketIdAt, (0));
        calls[3] = abi.encodeCall(IManicFlashOptionViews.marketCount, ());
        calls[4] = abi.encodeCall(IManicFlashOptionViews.getPool, ());
        calls[5] = abi.encodeCall(IManicFlashOptionViews.freeMoney, ());
        calls[6] = abi.encodeCall(IManicFlashOptionViews.claimableOf, (users.alice));
        calls[7] = abi.encodeCall(IManicFlashOptionViews.queueHead, ());
        calls[8] = abi.encodeCall(IManicFlashOptionViews.getBreaker, ());
        calls[9] = abi.encodeCall(IManicFlashOptionViews.token, ());
        calls[10] = abi.encodeCall(IManicFlashOptionViews.halted, ());
        calls[11] = abi.encodeCall(IManicFlashOptionViews.refundDelaySecs, ());
        calls[12] = abi.encodeCall(IManicFlashOptionViews.recipients, ());
    }

    /// @dev A stake authorisation this token doesn't check.
    function _anyAuth() private view returns (StakeAuth memory) {
        return StakeAuth({validAfter: block.timestamp - 1, validBefore: block.timestamp + 60, signature: ""});
    }

    /// @dev One call into every state-changing function: the pool's four first, then the admin's ten, then the
    ///      trading two, then the four of settlement. The guard is each function's first check, so the arguments
    ///      only need to be well formed.
    function _callbacks() private view returns (bytes[] memory calls) {
        calls = new bytes[](20);
        calls[0] = abi.encodeCall(IManicFlashOptionPool.fund, (AMOUNT));
        calls[1] = abi.encodeCall(IManicFlashOptionPool.withdraw, (WithdrawPurpose.Rewards, AMOUNT));
        calls[2] = abi.encodeCall(IManicFlashOptionPool.claim, (users.alice));
        calls[3] = abi.encodeCall(IManicFlashOptionPool.sweepFees, ());
        calls[4] = abi.encodeCall(
            IManicFlashOptionAdmin.createMarket,
            (Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig())
        );
        ConfigParams memory enabled = _enabledConfig();
        calls[5] = abi.encodeCall(IManicFlashOptionAdmin.setConfig, (Defaults.BTC, Defaults.LEVERAGE, enabled));
        calls[6] = abi.encodeCall(IManicFlashOptionAdmin.setPaused, (Defaults.BTC, Defaults.LEVERAGE, true));
        calls[7] = abi.encodeCall(IManicFlashOptionAdmin.setHalted, (true));
        calls[8] = abi.encodeCall(IManicFlashOptionAdmin.setPoolFloor, (Defaults.POOL_FLOOR));
        calls[9] = abi.encodeCall(IManicFlashOptionAdmin.setRecipients, (users.feeRecipient, users.rewardsRecipient));
        calls[10] = abi.encodeCall(IManicFlashOptionAdmin.setRefundDelay, (Defaults.REFUND_DELAY));
        calls[11] = abi.encodeCall(
            IManicFlashOptionAdmin.setBreaker, (Defaults.BREAKER_MAX_NET_PROFIT, Defaults.BREAKER_WINDOW)
        );
        calls[12] = abi.encodeCall(IManicFlashOptionAdmin.resetBreaker, ());
        calls[13] = abi.encodeCall(IManicFlashOptionAdmin.revokeRelayer, (proxy.OPENER_ROLE(), users.opener));
        OpenTerms memory t = _terms();
        calls[14] = abi.encodeCall(IManicFlashOptionTrading.open, (order, orderSignature, t, _anyAuth()));
        SellOrder memory s =
            SellOrder({positionId: order.positionId, minAmount: 0, notBefore: 0, deadline: uint48(block.timestamp)});
        SellTerms memory st =
            SellTerms({price: Defaults.ENTRY_PRICE, publishTime: uint48(block.timestamp), valuation: 0, sellAmount: 0});
        calls[15] = abi.encodeCall(IManicFlashOptionTrading.sell, (s, orderSignature, st));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = order.positionId;
        calls[16] = abi.encodeCall(
            IManicFlashOptionSettlement.liquidate,
            (Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE, uint48(block.timestamp), ids)
        );
        calls[17] = abi.encodeCall(
            IManicFlashOptionSettlement.settle,
            (Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE, uint48(block.timestamp), ids)
        );
        calls[18] = abi.encodeCall(IManicFlashOptionSettlement.refundExpired, (ids));
        calls[19] = abi.encodeCall(IManicFlashOptionSettlement.repay, (1));
    }
}
