// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../../src/types/ParamTypes.sol";
import {PoolState, Position, WithdrawPurpose} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {OrderSigner} from "../../utils/OrderSigner.sol";

/// @title Brakes_Concrete_Test
/// @notice docs/ARCHITECTURE.md §8.10, column by column: what the halt, a market pause and a tripped circuit breaker
///         stop, and what they never stop. The pool's functions: funding, withdrawals, claims and fee sweeps all work
///         with every brake engaged at once, so money can always come in, and no claim or fee is ever held up by a
///         brake. `open` and `sell`: each brake alone stops them. `liquidate`, `settle` and `repay`: only the halt
///         stops them, so a bet can always end, and an IOU be repaid, once the halt is released. `refundExpired`: no
///         brake stops it, so a stake can always come back if the backend stops.
/// @dev The halt and the pause are engaged through their own functions. A trip of the circuit breaker is written
///      straight into storage (`_tripBreaker`: tripping it for real takes a window's worth of winnings, which
///      test/concrete/breaker/ does), and the operator's `resetBreaker` releases it. The pending fees and alice's
///      claimable balance are written into storage too. Every written amount is backed by minted tokens.
contract Brakes_Concrete_Test is Base_Test {
    uint64 internal constant FREE = 1500e6;
    uint64 internal constant AMOUNT = 100e6;
    uint64 internal constant FEES = 10e6;
    uint64 internal constant CLAIMABLE = 10e6;

    function setUp() public override {
        super.setUp();
        _fund(users.bob, FREE);
        _writeLayout(address(flashOption), 5, 0, 64, FEES); // pool.feesPending
        _writeLayout(address(flashOption), 5, 64, 64, CLAIMABLE); // pool.totalClaimable
        vm.store(
            address(flashOption),
            keccak256(abi.encode(users.alice, LayoutReader.ROOT + 13)),
            bytes32(uint256(CLAIMABLE))
        );
        _mintUsdg(address(flashOption), FEES + CLAIMABLE);

        // Every brake engaged.
        vm.startPrank(users.guardian);
        flashOption.setHalted(true);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        vm.stopPrank();
        _tripBreaker();
    }

    function test_ThePoolFunctionsWorkWithEveryBrakeEngaged() external {
        assertTrue(LayoutReader.halted(address(flashOption)), "halted");
        assertTrue(LayoutReader.market(address(flashOption), 0).paused, "BTC paused");
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "breaker tripped");

        _fund(users.alice, AMOUNT); // anyone funds
        vm.prank(users.admin);
        flashOption.withdraw(WithdrawPurpose.Rewards, AMOUNT);
        vm.prank(users.eve); // anyone claims for alice
        flashOption.claim(users.alice);
        vm.prank(users.eve); // anyone sweeps
        flashOption.sweepFees();

        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.total, FREE, "funded, then withdrew the same amount");
        assertEq(pool.rewardsWithdrawn, AMOUNT, "rewards withdrawn");
        assertEq(pool.totalClaimable, 0, "claimed");
        assertEq(pool.feesPending, 0, "swept");
        assertEq(usdg.balanceOf(users.alice), CLAIMABLE, "alice is paid");
        assertEq(usdg.balanceOf(users.rewardsRecipient), AMOUNT, "the rewards recipient is paid");
        assertEq(usdg.balanceOf(users.feeRecipient), FEES, "the fee recipient is paid");
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev Releases the brakes one at a time, in the order `open` checks them: each one still engaged stops it with
    ///      its own error. The operator resets the breaker last.
    function test_OpenStopsUnderEachBrake() external {
        uint256 aliceKey = _keyOf("alice");
        OpenOrder memory o = _order(users.alice, keccak256("alice's bet"));
        _mintUsdg(users.alice, o.stake);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        OpenTerms memory t = _terms();

        _expectOpenStopped(o, signature, t, a, Errors.Halted.selector);
        vm.prank(users.operator);
        flashOption.setHalted(false);
        _expectOpenStopped(o, signature, t, a, Errors.LeveragePaused.selector);
        vm.prank(users.operator);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        _expectOpenStopped(o, signature, t, a, Errors.BreakerTripped.selector);
        _resetBreaker();

        // A market switched off stops it too.
        ConfigParams memory c = _enabledConfig();
        c.enabled = false;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _expectOpenStopped(o, signature, t, a, Errors.LeverageDisabled.selector);

        // With every brake released, the same order opens.
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, _enabledConfig());
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
        assertEq(LayoutReader.pool(address(flashOption)).openPositions, 1, "opened");
    }

    /// @dev Both bets are opened with every brake released, then every brake is engaged again and the market is
    ///      switched off as well. The halt stops both endings; with only the halt released, both end their bets.
    function test_LiquidateAndSettleStopOnlyForTheHalt() external {
        vm.startPrank(users.operator);
        flashOption.setHalted(false);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        vm.stopPrank();
        _resetBreaker();
        uint256 aliceKey = _keyOf("alice");
        _open(aliceKey, _order(users.alice, "liquidated"), _terms());
        _open(aliceKey, _order(users.alice, "settled"), _terms());
        Position memory p = LayoutReader.position(address(flashOption), "liquidated");
        bytes32[] memory liquidated = new bytes32[](1);
        liquidated[0] = "liquidated";
        bytes32[] memory settled = new bytes32[](1);
        settled[0] = "settled";

        vm.startPrank(users.guardian);
        flashOption.setHalted(true);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        vm.stopPrank();
        ConfigParams memory c = _enabledConfig();
        c.enabled = false;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _tripBreaker();

        // The halt stops both.
        vm.expectRevert(Errors.Halted.selector);
        vm.prank(users.settler);
        flashOption.liquidate(Defaults.BTC, Defaults.LEVERAGE, p.liqPrice, p.startTime, liquidated);
        uint48 end = p.startTime + p.durationSecs;
        vm.warp(end);
        vm.expectRevert(Errors.Halted.selector);
        vm.prank(users.settler);
        flashOption.settle(Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE, end, settled);

        // With only the halt released, a paused, switched-off market with a tripped breaker still ends both.
        vm.prank(users.operator);
        flashOption.setHalted(false);
        vm.startPrank(users.settler);
        assertEq(
            flashOption.liquidate(Defaults.BTC, Defaults.LEVERAGE, p.liqPrice, p.startTime, liquidated), 1, "liquidated"
        );
        assertEq(flashOption.settle(Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE, end, settled), 1, "settled");
        vm.stopPrank();
        assertEq(LayoutReader.pool(address(flashOption)).openPositions, 0, "both ended");
        assertEq(usdg.balanceOf(users.alice), Defaults.STAKE, "the flat bet returned its stake");
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev Alice's bet is opened with every brake released. Then all four are engaged at once (the halt, the market
    ///      switched off, the pause, the breaker) and released one at a time in the order `sell` checks them: each
    ///      one still engaged stops it with its own error, and with all of them released the same order sells.
    function test_SellStopsUnderEachBrake() external {
        vm.startPrank(users.operator);
        flashOption.setHalted(false);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        vm.stopPrank();
        _resetBreaker();
        uint256 aliceKey = _keyOf("alice");
        _open(aliceKey, _order(users.alice, "sold"), _terms());
        SellOrder memory s = SellOrder({
            positionId: "sold",
            minAmount: Defaults.STAKE,
            notBefore: uint48(block.timestamp),
            deadline: uint48(block.timestamp) + Defaults.ORDER_LIFETIME
        });
        bytes memory signature = OrderSigner.sign(aliceKey, flashOption.hashSellOrder(s));
        SellTerms memory t = SellTerms({
            price: Defaults.ENTRY_PRICE,
            publishTime: uint48(block.timestamp),
            valuation: Defaults.STAKE,
            sellAmount: Defaults.STAKE
        });

        vm.startPrank(users.guardian);
        flashOption.setHalted(true);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        vm.stopPrank();
        ConfigParams memory c = _enabledConfig();
        c.enabled = false;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _tripBreaker();

        _expectSellStopped(s, signature, t, Errors.Halted.selector);
        vm.prank(users.operator);
        flashOption.setHalted(false);
        _expectSellStopped(s, signature, t, Errors.LeverageDisabled.selector);
        c.enabled = true;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _expectSellStopped(s, signature, t, Errors.LeveragePaused.selector);
        vm.prank(users.operator);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        _expectSellStopped(s, signature, t, Errors.BreakerTripped.selector);
        _resetBreaker();

        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
        assertEq(usdg.balanceOf(users.alice), Defaults.STAKE, "sold flat: the stake back");
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev Two IOUs are made on a small pool with every brake released ($20 of free money; two winners at the 4x cap
    ///      are owed $10 and $30), and the pool is topped up. Then every brake is engaged on it, the market switched
    ///      off too. The halt stops `repay`; with only the halt released, eve, who holds no role, repays both.
    function test_RepayStopsOnlyForTheHalt() external {
        _useSmallPool(20e6);
        uint256 aliceKey = _keyOf("alice");
        _open(aliceKey, _order(users.alice, "a"), _terms());
        _open(aliceKey, _order(users.alice, "b"), _terms());
        Position memory p = LayoutReader.position(address(flashOption), "a");
        uint48 end = p.startTime + p.durationSecs;
        vm.warp(end);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "a";
        ids[1] = "b";
        vm.prank(users.settler);
        flashOption.settle(Defaults.BTC, Defaults.LEVERAGE, Examples.priceAt(300), end, ids);
        assertEq(LayoutReader.pool(address(flashOption)).totalOwed, 40_000_000, "two IOUs");
        _fund(users.bob, 100e6);

        vm.startPrank(users.guardian);
        flashOption.setHalted(true);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        vm.stopPrank();
        // Switched off (which also puts the open gate back on: `repay` doesn't read it).
        ConfigParams memory c = Defaults.marketConfig();
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _tripBreaker();

        vm.expectRevert(Errors.Halted.selector);
        vm.prank(users.eve);
        flashOption.repay(50);
        vm.prank(users.operator);
        flashOption.setHalted(false);
        vm.prank(users.eve);
        assertEq(flashOption.repay(50), 2, "both repaid, with the market paused and off and the breaker tripped");
        assertEq(LayoutReader.pool(address(flashOption)).totalOwed, 0, "nobody is owed");
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev The outage the safety refund is for (ARCHITECTURE §8.6, §15 rule 14). Alice's and bob's bets are opened
    ///      with every brake released, then the backend stops: the guardian halts and pauses, the operator switches
    ///      the market off, and the breaker trips. A day after the bets' expiry, eve, who holds no role, refunds both
    ///      with every brake still engaged. When the backend comes back and the halt is released, its late settle of
    ///      the same bets skips both, so nothing is paid twice.
    function test_RefundRunsUnderEveryBrake() external {
        vm.startPrank(users.operator);
        flashOption.setHalted(false);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, false);
        vm.stopPrank();
        _resetBreaker();
        _open(_keyOf("alice"), _order(users.alice, "a"), _terms());
        _open(_keyOf("bob"), _order(users.bob, "b"), _terms());
        Position memory p = LayoutReader.position(address(flashOption), "a");
        uint48 end = p.startTime + p.durationSecs;
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "a";
        ids[1] = "b";

        vm.startPrank(users.guardian);
        flashOption.setHalted(true);
        flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        vm.stopPrank();
        ConfigParams memory c = _enabledConfig();
        c.enabled = false;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _tripBreaker();

        vm.warp(end + Defaults.REFUND_DELAY);
        vm.prank(users.eve);
        assertEq(flashOption.refundExpired(ids), 2, "both refunded, with every brake engaged");
        assertEq(usdg.balanceOf(users.alice), Defaults.STAKE, "alice's stake back");
        assertEq(usdg.balanceOf(users.bob), Defaults.STAKE, "bob's stake back");

        vm.prank(users.operator);
        flashOption.setHalted(false);
        vm.prank(users.settler);
        assertEq(
            flashOption.settle(Defaults.BTC, Defaults.LEVERAGE, Defaults.ENTRY_PRICE, end, ids),
            0,
            "the late settle skips both"
        );
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.openPositions, 0, "no open bet");
        assertEq(pool.total, FREE, "only free money is left");
        _assertBooksBalanced(address(flashOption));
    }

    /// @dev Trips the circuit breaker by writing its flag straight into storage: its own tests
    ///      (test/concrete/breaker/) trip it for real, through the counts of the endings.
    function _tripBreaker() private {
        _writeLayout(address(flashOption), 7, 176, 8, 1); // breaker.tripped
    }

    /// @dev The operator resets the circuit breaker.
    function _resetBreaker() private {
        vm.prank(users.operator);
        flashOption.resetBreaker();
    }

    function _expectSellStopped(SellOrder memory s, bytes memory signature, SellTerms memory t, bytes4 brake) private {
        vm.expectRevert(brake);
        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
    }

    function _expectOpenStopped(
        OpenOrder memory o,
        bytes memory signature,
        OpenTerms memory t,
        StakeAuth memory a,
        bytes4 brake
    )
        private
    {
        vm.expectRevert(brake);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
    }
}
