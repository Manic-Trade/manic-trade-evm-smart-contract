// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder} from "../../../src/types/OrderTypes.sol";
import {PoolState, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title RefundExpired_Concrete_Test
/// @notice Every branch of `refundExpired`, from test/concrete/refundExpired/refundExpired.tree (docs/ARCHITECTURE.md
///         §8.6): alice's $10 call and bob's $10 put, opened together, expire at the same second, and the backend
///         never ends them. Eve, who holds no role, refunds them once the 24-hour delay has passed: anyone may.
/// @dev The checks are tested in order: the switch even with an empty batch, then the batch's size, then each id.
///      Success is checked by `_expectRefunded`, which walks the batch with its own model and compares every log,
///      every pool field, every slot of every id and every balance. Each success is at exactly the expiry plus the
///      delay, the first second a refund may run.
contract RefundExpired_Concrete_Test is Settlement_Base_Test {
    bytes32 internal constant A = keccak256("alice's call");
    bytes32 internal constant B = keccak256("bob's put");

    /// @dev The second both bets expire at. Their refunds open `Defaults.REFUND_DELAY` later.
    uint48 internal end;

    function setUp() public override {
        super.setUp();
        end = _end(_bet(users.alice, A, Side.Call));
        _bet(users.bob, B, Side.Put);
    }

    function test_RevertGiven_TheRefundIsSwitchedOff() external {
        // it should revert, before the batch is checked: an empty batch too, and a year after the expiry
        vm.prank(users.admin);
        flashOption.setRefundDelay(0);
        vm.warp(end + 365 days);
        _expectRefundReverts(new bytes32[](0), abi.encodeWithSelector(Errors.RefundDisabled.selector));
        _expectRefundReverts(_ids(A), abi.encodeWithSelector(Errors.RefundDisabled.selector));
    }

    modifier givenTheRefundIsSwitchedOn() {
        _;
    }

    function test_RevertWhen_TheBatchIsEmptyOrHoldsMoreThan100Ids() external givenTheRefundIsSwitchedOn {
        // it should revert: 0 and 101 ids
        vm.warp(end + Defaults.REFUND_DELAY);
        _expectRefundReverts(new bytes32[](0), abi.encodeWithSelector(Errors.EmptyBatch.selector));
        _expectRefundReverts(_repeat(A, 101), abi.encodeWithSelector(Errors.BatchSizeTooLarge.selector));

        // 1 and 100 are accepted: alice's call alone, then bob's put 100 times, refunded once and skipped 99 times.
        _expectRefunded(_ids(A), users.eve);
        Ending[] memory endings = _expectRefunded(_repeat(B, 100), users.eve);
        assertFalse(endings[0].skipped, "refunded once");
        assertTrue(endings[99].skipped, "then skipped");
    }

    modifier whenTheBatchHolds1To100Ids() {
        _;
    }

    function test_RevertWhen_AnIdWasNeverOpened() external givenTheRefundIsSwitchedOn whenTheBatchHolds1To100Ids {
        // it should revert, naming the id, even after a position it could refund
        vm.warp(end + Defaults.REFUND_DELAY);
        _expectRefundReverts(
            _ids(A, "never opened"), abi.encodeWithSelector(Errors.UnknownPosition.selector, bytes32("never opened"))
        );
        assertEq(uint8(LayoutReader.position(address(flashOption), A).status), uint8(Status.Open), "alice's is open");
    }

    modifier whenEveryIdWasOpened() {
        _;
    }

    function test_GivenAPositionHasAlreadyEnded()
        external
        givenTheRefundIsSwitchedOn
        whenTheBatchHolds1To100Ids
        whenEveryIdWasOpened
    {
        bytes32[] memory batch = _endEveryWay();

        // it should skip it
        // it should refund the rest of the batch
        Ending[] memory endings = _expectRefunded(batch, users.eve);
        assertFalse(endings[0].skipped, "the open bet is refunded");
        for (uint256 i = 1; i < batch.length; ++i) {
            assertTrue(endings[i].skipped, "every ended one is skipped");
        }
        assertEq(uint8(endings[2].status), uint8(Status.Owed), "the IOU, as owed");
        assertEq(uint8(endings[6].status), uint8(Status.Closed), "the second listing, as closed");
        assertEq(LayoutReader.position(address(flashOption), "owed").owed, 10_000_000, "the IOU is untouched");
    }

    modifier givenThePositionsAreOpen() {
        _;
    }

    function test_RevertWhen_TheDelayHasNotPassedSinceTheExpiryOfAPosition()
        external
        givenTheRefundIsSwitchedOn
        whenTheBatchHolds1To100Ids
        whenEveryIdWasOpened
        givenThePositionsAreOpen
    {
        // Eve's bet, opened 30 seconds after alice's and bob's, expires 30 seconds after theirs.
        vm.warp(end - 30);
        assertEq(_end(_bet(users.eve, "eve's call", Side.Call)), end + 30, "eve's expires 30 seconds later");

        // it should revert, naming the id: one second before the expiry plus the delay
        vm.warp(end + Defaults.REFUND_DELAY - 1);
        _expectRefundReverts(_ids(A), abi.encodeWithSelector(Errors.RefundTooEarly.selector, A));

        // At exactly that second alice's and bob's could be refunded, but eve's can't yet, and it names itself.
        vm.warp(end + Defaults.REFUND_DELAY);
        _expectRefundReverts(
            _ids(A, B, "eve's call"), abi.encodeWithSelector(Errors.RefundTooEarly.selector, bytes32("eve's call"))
        );

        // A delay too long ever to pass is only too early: the expiry plus the delay can't overflow.
        vm.prank(users.admin);
        flashOption.setRefundDelay(type(uint48).max);
        _expectRefundReverts(_ids(A), abi.encodeWithSelector(Errors.RefundTooEarly.selector, A));
    }

    modifier whenTheDelayHasPassedSinceTheExpiryOfEveryOpenPosition() {
        _;
    }

    function test_RevertWhen_APayoutHasTooLittleGas()
        external
        givenTheRefundIsSwitchedOn
        whenTheBatchHolds1To100Ids
        whenEveryIdWasOpened
        givenThePositionsAreOpen
        whenTheDelayHasPassedSinceTheExpiryOfEveryOpenPosition
    {
        // it should revert: a caller that starves the call can't push alice's refund into claimable. Every gas limit
        // up to the least that refunds reverts, some of them with `InsufficientGasForPayout`.
        vm.warp(end + Defaults.REFUND_DELAY);
        bytes memory call_ = abi.encodeCall(flashOption.refundExpired, (_ids(A)));
        bytes32 starved = keccak256(abi.encodeWithSelector(Errors.InsufficientGasForPayout.selector));
        bool sawTheGuard;
        bool refunded;
        for (uint256 gasLimit = 20_000; gasLimit < 400_000 && !refunded; gasLimit += 1000) {
            vm.prank(users.eve);
            bytes memory reason;
            (refunded, reason) = address(flashOption).call{gas: gasLimit}(call_);
            if (keccak256(reason) == starved) sawTheGuard = true;
        }
        assertTrue(sawTheGuard, "too little gas for the payout reverts InsufficientGasForPayout");
        assertTrue(refunded, "and enough gas refunds");

        // At the least gas that refunds, alice gets her stake back, and nothing waits in claimable.
        assertEq(usdg.balanceOf(users.alice), Defaults.STAKE, "her stake");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), 0, "nothing deferred");
    }

    modifier whenEveryPayoutHasTheGasItNeeds() {
        _;
    }

    function test_GivenTheTokenRefusesAPayout()
        external
        givenTheRefundIsSwitchedOn
        whenTheBatchHolds1To100Ids
        whenEveryIdWasOpened
        givenThePositionsAreOpen
        whenTheDelayHasPassedSinceTheExpiryOfEveryOpenPosition
        whenEveryPayoutHasTheGasItNeeds
    {
        // Paxos freezes alice.
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        vm.warp(end + Defaults.REFUND_DELAY);

        // it should keep the stake for the user to claim
        // it should refund the rest of the batch
        Ending[] memory endings = _expectRefunded(_ids(A, B), users.eve);
        assertTrue(endings[0].deferred, "alice's refund waits");
        assertEq(LayoutReader.claimable(address(flashOption), users.alice), Defaults.STAKE, "in her claimable balance");
        assertFalse(endings[1].deferred, "bob is paid");
        assertEq(usdg.balanceOf(users.bob), Defaults.STAKE, "his stake");
    }

    function test_GivenTheTokenPays()
        external
        givenTheRefundIsSwitchedOn
        whenTheBatchHolds1To100Ids
        whenEveryIdWasOpened
        givenThePositionsAreOpen
        whenTheDelayHasPassedSinceTheExpiryOfEveryOpenPosition
        whenEveryPayoutHasTheGasItNeeds
    {
        // Eve's bet on a second market, ETH, opened with the others, joins the batch: a refund needs no price.
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.ETH, Defaults.LEVERAGE, _enabledConfig());
        OpenOrder memory o = _order(users.eve, "eve's ETH call");
        o.marketId = Defaults.ETH;
        _betWith(o, _terms());
        vm.warp(end + Defaults.REFUND_DELAY);
        PoolState memory before = LayoutReader.pool(address(flashOption));

        // it should return each stake to its user, with no fee
        // it should release each position's hold on the pool and leave free money unchanged
        // it should close each position
        // it should emit {PositionRefunded} for each, before its payout
        // it should return the number refunded
        Ending[] memory endings = _expectRefunded(_ids(A, B, "eve's ETH call"), users.eve);
        PoolState memory pool = LayoutReader.pool(address(flashOption));
        assertEq(pool.total - pool.lockedMargin, before.total - before.lockedMargin, "free money unchanged");
        assertEq(pool.total, FREE, "only free money is left");
        assertEq(pool.lockedMargin + pool.openMaxProfit + pool.openPositions, 0, "no stake, exposure or open bet");
        assertEq(pool.feesPending, before.feesPending, "no fee");
        assertEq(pool.transferred, before.transferred + 3 * Defaults.STAKE, "three stakes paid");
        for (uint256 i; i < endings.length; ++i) {
            assertEq(uint8(endings[i].status), uint8(Status.Closed), "closed");
        }
        assertEq(usdg.balanceOf(users.alice), Defaults.STAKE, "alice's stake back");
        assertEq(usdg.balanceOf(users.eve), Defaults.STAKE, "eve's stake back");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Moves to a small pool ($20 of free money, no exposure gate) and opens six bets together, then ends five
    ///      of them five ways: "sold" (sold flat at once), "owed" (settled at the 4x cap: paid the $20 of free money
    ///      now and owed $10), "settled" (settled flat), "liquidated" (at its line, from an old tick) and "refunded"
    ///      (refunded alone, once the delay has passed). "open" is never ended. Returns the batch to refund: "open",
    ///      the five others, then "open" again.
    function _endEveryWay() private returns (bytes32[] memory batch) {
        _useSmallPool(20e6);
        _bet(users.bob, "sold", Side.Call);
        _bet(users.alice, "owed", Side.Call);
        _bet(users.alice, "settled", Side.Put);
        Position memory liquidated = _bet(users.eve, "liquidated", Side.Call);
        _bet(users.eve, "refunded", Side.Put);
        _bet(users.bob, "open", Side.Put);
        _expectSale("sold", Defaults.ENTRY_PRICE, Defaults.STAKE, Defaults.STAKE, Defaults.STAKE);
        uint48 expiry = _end(liquidated);
        vm.warp(expiry);
        _expectSettled(Examples.priceAt(300), expiry, _ids("owed"));
        _expectSettled(Defaults.ENTRY_PRICE, expiry, _ids("settled"));
        _expectLiquidated(liquidated.liqPrice, liquidated.startTime, _ids("liquidated"));
        vm.warp(expiry + Defaults.REFUND_DELAY);
        _expectRefunded(_ids("refunded"), users.eve);

        batch = new bytes32[](7);
        batch[0] = "open";
        batch[1] = "sold";
        batch[2] = "owed";
        batch[3] = "settled";
        batch[4] = "liquidated";
        batch[5] = "refunded";
        batch[6] = "open";
    }

    /// @dev `n` copies of `id`.
    function _repeat(bytes32 id, uint256 n) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = id;
        }
    }
}
