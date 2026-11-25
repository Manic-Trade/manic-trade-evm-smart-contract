// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vm} from "forge-std/Vm.sol";

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {InitParams} from "../../../src/types/ParamTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {ManicFlashOptionHarness} from "../../harnesses/ManicFlashOptionHarness.sol";
import {MockFalseToken} from "../../mocks/MockFalseToken.sol";
import {GasBurner, MockGasBurnerToken} from "../../mocks/MockGasBurnerToken.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Pay_Concrete_Test
/// @notice Every branch of `_pay`, the payout helper of settle, sell, repay and refund, from
///         test/concrete/pay/pay.tree (docs/ARCHITECTURE.md §8.8), called through `ManicFlashOptionHarness`.
/// @dev Refusals are tested three ways: a frozen recipient and a paused token (both USDG behaviours), and a token that
///      returns false. One has little gas, to show a quick refusal is never taken for running out of gas. A starved
///      payout is tested two ways: too little gas before the transfer, and a transfer that runs out of gas, wherever
///      it does: in the token, one call deeper, behind a proxy as USDG is, and behind a proxy one call deeper.
contract Pay_Concrete_Test is Base_Test {
    ManicFlashOptionHarness internal harness;
    bytes32 internal constant POSITION_ID = keccak256("a winner's position");

    function setUp() public override {
        super.setUp();
        harness = _deployHarness(_defaultInitParams());
        _mintUsdg(address(harness), 1000e6);
    }

    function test_WhenTheAmountIsZero() external {
        // it should do nothing: no transfer, no event, no claimable balance
        vm.recordLogs();
        harness.exposed_pay(users.alice, 0, POSITION_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event at all");
        assertEq(usdg.balanceOf(users.alice), 0, "nothing paid");
        assertEq(LayoutReader.claimable(address(harness), users.alice), 0, "nothing deferred");
    }

    modifier whenTheAmountIsNotZero() {
        _;
    }

    function test_RevertWhen_LessThanTheMinimumPayoutGasIsLeft() external whenTheAmountIsNotZero {
        // it should revert: a call starved below 60,000 gas can't push the payout into claimable
        vm.expectRevert(Errors.InsufficientGasForPayout.selector);
        harness.exposed_pay{gas: 50_000}(users.alice, 1e6, POSITION_ID);
        // With enough gas the same payout goes through.
        harness.exposed_pay{gas: 200_000}(users.alice, 1e6, POSITION_ID);
        assertEq(usdg.balanceOf(users.alice), 1e6, "paid with enough gas");
    }

    modifier whenAtLeastTheMinimumPayoutGasIsLeft() {
        _;
    }

    function test_WhenTheTransferSucceeds() external whenTheAmountIsNotZero whenAtLeastTheMinimumPayoutGasIsLeft {
        // it should pay the recipient, and defer nothing
        vm.recordLogs();
        harness.exposed_pay(users.alice, 25e6, POSITION_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(usdg.balanceOf(users.alice), 25e6, "alice is paid");
        assertEq(usdg.balanceOf(address(harness)), 975e6, "from the contract");
        assertEq(LayoutReader.claimable(address(harness), users.alice), 0, "nothing deferred");
        assertEq(LayoutReader.pool(address(harness)).totalClaimable, 0, "total claimable");
        assertEq(logs.length, 1, "only the token's Transfer event");
        assertEq(logs[0].emitter, address(usdg), "emitted by the token");
    }

    modifier whenTheTransferFails() {
        _;
    }

    function test_RevertWhen_TheTransferRanOutOfGas()
        external
        whenTheAmountIsNotZero
        whenAtLeastTheMinimumPayoutGasIsLeft
        whenTheTransferFails
    {
        // it should revert, however deep the transfer runs out of gas: in the token itself, one call deeper (a
        // compliance registry, say), behind a proxy as USDG is, and behind a proxy one call deeper; with little gas
        // and with plenty
        IERC20[4] memory tokens = [
            IERC20(address(new MockGasBurnerToken(GasBurner(address(0))))),
            IERC20(address(new MockGasBurnerToken(new GasBurner()))),
            _behindAProxy(new MockGasBurnerToken(GasBurner(address(0)))),
            _behindAProxy(new MockGasBurnerToken(new GasBurner()))
        ];
        uint256[2] memory gasLimits = [uint256(100_000), 10_000_000];
        InitParams memory p = _defaultInitParams();
        for (uint256 i; i < tokens.length; ++i) {
            p.token = tokens[i];
            ManicFlashOptionHarness starved = _deployHarness(p);
            for (uint256 j; j < gasLimits.length; ++j) {
                vm.expectRevert(Errors.InsufficientGasForPayout.selector);
                starved.exposed_pay{gas: gasLimits[j]}(users.alice, 1e6, POSITION_ID);
            }
        }
    }

    function test_WhenTheTokenRefusedIt()
        external
        whenTheAmountIsNotZero
        whenAtLeastTheMinimumPayoutGasIsLeft
        whenTheTransferFails
    {
        // A frozen recipient.
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        // it should emit {PayoutDeferred}
        vm.expectEmit(address(harness));
        emit Events.PayoutDeferred(POSITION_ID, users.alice, 30e6);
        harness.exposed_pay(users.alice, 30e6, POSITION_ID);
        // it should add the amount to the recipient's claimable balance
        // it should add it to the total claimable
        assertEq(LayoutReader.claimable(address(harness), users.alice), 30e6, "alice's payout waits");
        assertEq(LayoutReader.pool(address(harness)).totalClaimable, 30e6, "total claimable");
        assertEq(usdg.balanceOf(address(harness)), 1000e6, "nothing left the contract");
        // With little gas, a refusal is still a refusal: it is quick, so it leaves far more than 1/16 of the gas.
        harness.exposed_pay{gas: 100_000}(users.alice, 1e6, POSITION_ID);
        assertEq(LayoutReader.claimable(address(harness), users.alice), 31e6, "deferred with 100,000 gas too");

        // A paused token: every recipient is refused, and a second payout to alice adds up.
        vm.prank(usdgAdmin);
        usdg.pause();
        harness.exposed_pay(users.bob, 10e6, POSITION_ID);
        harness.exposed_pay(users.alice, 5e6, POSITION_ID);
        assertEq(LayoutReader.claimable(address(harness), users.bob), 10e6, "bob's payout waits");
        assertEq(LayoutReader.claimable(address(harness), users.alice), 36e6, "alice's payouts add up");
        assertEq(LayoutReader.pool(address(harness)).totalClaimable, 46e6, "total claimable");
        _assertBooksBalanced(address(harness));

        // A token that returns false instead of reverting.
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(new MockFalseToken()));
        ManicFlashOptionHarness falseToken = _deployHarness(p);
        falseToken.exposed_pay(users.alice, 7e6, POSITION_ID);
        assertEq(LayoutReader.claimable(address(falseToken), users.alice), 7e6, "a false return defers too");
    }

    /// @dev `token` behind an ERC-1967 proxy, as USDG is. OpenZeppelin's proxy must make a call when it is deployed;
    ///      the token has nothing to set up, so it reads `decimals()`.
    function _behindAProxy(MockGasBurnerToken token) private returns (IERC20) {
        return IERC20(address(new ERC1967Proxy(address(token), abi.encodeWithSignature("decimals()"))));
    }
}
