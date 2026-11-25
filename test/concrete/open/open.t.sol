// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ManicFlashOption} from "../../../src/ManicFlashOption.sol";
import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionEvents as Events} from "../../../src/interfaces/IManicFlashOptionEvents.sol";
import {LeverageMath} from "../../../src/libraries/LeverageMath.sol";
import {TradingModule} from "../../../src/modules/TradingModule.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {ConfigParams, InitParams} from "../../../src/types/ParamTypes.sol";
import {PoolState, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Base_Test} from "../../Base.t.sol";
import {MockReentrantToken} from "../../mocks/MockReentrantToken.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {UsdgSigner} from "../../utils/UsdgSigner.sol";

/// @title Open_Concrete_Test
/// @notice Every branch of `open`, from test/concrete/open/open.tree (docs/ARCHITECTURE.md §8.2): alice's order for a
///         $10 BTC call for 60 seconds, at $83,884, into a pool with $1,500 of free money.
/// @dev Each revert test breaks its own check and every later one (`_breakFrom`), so its own error also proves the
///      order: no later check can have run first. Where a check has a boundary, the test also shows the other side
///      passes it: the next check's error appears instead. The stake pull is broken by leaving alice without tokens,
///      so its error (`InsufficientFunds`) can't be mistaken for any check's.
contract Open_Concrete_Test is Base_Test {
    /// @dev The free money in the pool: enough for the open gate (a $10 bet at 4x can win $30).
    uint64 internal constant FREE = 1500e6;

    /// @dev One call to `open`: the order, its signature, the relayer's terms and the stake authorisation.
    struct Attempt {
        OpenOrder o;
        bytes signature;
        OpenTerms t;
        StakeAuth a;
    }

    uint256 internal aliceKey;
    uint256 internal bobKey;

    function setUp() public override {
        super.setUp();
        aliceKey = _keyOf("alice");
        bobKey = _keyOf("bob");
        _fund(users.bob, FREE);
    }

    function test_RevertWhen_TheCallerIsNotAnOpener() external {
        // it should revert: every user but the opener, with every check after the role broken
        Attempt memory x = _attempt(keccak256("alice's bet"));
        _breakFrom(x, 2);
        address[] memory callers = _everyoneBut(users.opener, users.opener);
        bytes32 openerRole = flashOption.OPENER_ROLE();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], openerRole)
            );
            vm.prank(callers[i]);
            flashOption.open(x.o, x.signature, x.t, x.a);
        }
    }

    modifier whenTheCallerIsAnOpener() {
        _;
    }

    function test_RevertGiven_TheContractIsHalted() external whenTheCallerIsAnOpener {
        // it should revert
        _expectOpenReverts(2, abi.encodeWithSelector(Errors.Halted.selector));
    }

    modifier givenTheContractIsNotHalted() {
        _;
    }

    function test_RevertWhen_TheOrderHasExpired() external whenTheCallerIsAnOpener givenTheContractIsNotHalted {
        // it should revert: one second past the deadline
        _expectOpenReverts(3, abi.encodeWithSelector(Errors.OrderExpired.selector));

        // At the deadline itself the order is still good: the next check, the market, fails instead.
        Attempt memory x = _attempt(keccak256("alice's other bet"));
        _breakFrom(x, 4);
        x.o.deadline = uint48(block.timestamp);
        x.signature = _signOrder(flashOption, bobKey, x.o);
        vm.expectRevert(Errors.UnknownMarket.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    modifier whenTheOrderHasNotExpired() {
        _;
    }

    function test_RevertWhen_TheMarketDoesNotExist()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
    {
        // it should revert: ETH was never created
        _expectOpenReverts(4, abi.encodeWithSelector(Errors.UnknownMarket.selector));
        // nor was BTC at 500x: the order's leverage picks the market, and BTC has only its 1000x one
        Attempt memory x = _attempt(keccak256("alice's bet"));
        _breakFrom(x, 5);
        x.o.leverage = 500;
        vm.expectRevert(Errors.UnknownMarket.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    modifier whenTheMarketExists() {
        _;
    }

    function test_RevertGiven_TheMarketIsDisabled()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
    {
        // it should revert
        _expectOpenReverts(5, abi.encodeWithSelector(Errors.LeverageDisabled.selector));
    }

    modifier givenTheMarketIsEnabled() {
        _;
    }

    function test_RevertGiven_TheMarketIsPaused()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
    {
        // it should revert
        _expectOpenReverts(6, abi.encodeWithSelector(Errors.LeveragePaused.selector));
    }

    modifier givenTheMarketIsNotPaused() {
        _;
    }

    function test_RevertGiven_TheBreakerHasTripped()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
    {
        // it should revert
        _expectOpenReverts(7, abi.encodeWithSelector(Errors.BreakerTripped.selector));
    }

    modifier givenTheBreakerHasNotTripped() {
        _;
    }

    function test_RevertWhen_ThePositionIdIsZeroOrUsed()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
    {
        // it should revert: an id already used, even by another user's open position
        bytes32 id = keccak256("bob's bet");
        _open(bobKey, _order(users.bob, id), _terms());
        Attempt memory x = _attempt(id);
        _breakFrom(x, 9);
        vm.expectRevert(Errors.PositionIdUsed.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);

        // And a zero id.
        _expectOpenReverts(8, abi.encodeWithSelector(Errors.PositionIdUsed.selector));
    }

    modifier whenThePositionIdIsNew() {
        _;
    }

    function test_RevertWhen_TheSignatureIsNotTheUsers()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
    {
        // it should revert: signed by bob for alice's order
        _expectOpenReverts(9, abi.encodeWithSelector(Errors.InvalidSignature.selector));

        // And alice's own signature, of the order before the relayer raised her stake: the relayer can't change a
        // signed field.
        Attempt memory x = _attempt(keccak256("alice's bet"));
        _breakFrom(x, 10);
        OpenOrder memory signed = _order(users.alice, x.o.positionId);
        x.signature = _signOrder(flashOption, aliceKey, signed);
        x.o = signed;
        x.o.stake = signed.stake + 1;
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);

        // Nor the leverage: her valid 1000x order, sent at 500x to a BTC 500x market that is open for bets.
        // Everything else is valid, terms and stake authorisation included, so only the contract's own signature check
        // can refuse it (USDG's bad-authorisation error shares the name `InvalidSignature`). Without the leverage in
        // the signed order, the relayer could pick the market for her.
        vm.prank(users.admin);
        flashOption.createMarket(Defaults.BTC, 500, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, 500, _enabledConfig());
        _fund(users.bob, 1000e6); // free money for the open gate
        Attempt memory y = _attempt(keccak256("alice's 1000x bet"));
        _mintUsdg(users.alice, y.o.stake);
        y.o.leverage = 500;
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(users.opener);
        flashOption.open(y.o, y.signature, y.t, y.a);
        // The same order at the leverage she signed opens: only the leverage was wrong.
        y.o.leverage = Defaults.LEVERAGE;
        vm.prank(users.opener);
        flashOption.open(y.o, y.signature, y.t, y.a);
        assertEq(
            uint8(LayoutReader.position(address(flashOption), y.o.positionId).status), uint8(Status.Open), "opened"
        );
    }

    modifier whenTheSignatureIsTheUsers() {
        _;
    }

    function test_RevertWhen_TheTermsAreOutsideTheMarketsBounds()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
    {
        // it should revert: a zero stake
        _expectOpenReverts(10, abi.encodeWithSelector(Errors.InvalidAmount.selector));

        // And each bound, one at a time, with every later check broken: the stake below the minimum and above the
        // maximum, a duration no rule allows, θ outside the one-minute rule, the floor, and a cap below the floor.
        ConfigParams memory c = _enabledConfig();
        _expectTermsRefused(1, c.minStake - 1, Defaults.DURATION, Defaults.THETA, Defaults.FLOOR_BPS, Defaults.CAP_BPS);
        _expectTermsRefused(2, c.maxStake + 1, Defaults.DURATION, Defaults.THETA, Defaults.FLOOR_BPS, Defaults.CAP_BPS);
        _expectTermsRefused(3, Defaults.STAKE, 90, Defaults.THETA, Defaults.FLOOR_BPS, Defaults.CAP_BPS);
        _expectTermsRefused(
            4, Defaults.STAKE, Defaults.DURATION, c.durations[0].thetaMaxE7 + 1, Defaults.FLOOR_BPS, Defaults.CAP_BPS
        );
        _expectTermsRefused(5, Defaults.STAKE, Defaults.DURATION, Defaults.THETA, c.floorMaxBps + 1, Defaults.CAP_BPS);
        _expectTermsRefused(6, Defaults.STAKE, Defaults.DURATION, Defaults.THETA, c.floorMaxBps, c.capMinBps - 1);
    }

    modifier whenTheTermsAreInsideTheMarketsBounds() {
        _;
    }

    function test_RevertWhen_TheEntryTickIsTooOldOrFromTheFuture()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
    {
        // it should revert: a tick with no time at all
        _expectOpenReverts(11, abi.encodeWithSelector(Errors.PriceTooOld.selector));

        // Each boundary, with every later check broken: one second past the maximum age is too old and the maximum
        // age passes; one second past the clock skew is from the future and the skew passes.
        // The skew is set to 2 s (the security checklist's limit, ORA-2) so it differs from the 5 s maximum age: a
        // check that swapped them would be caught.
        vm.warp(block.timestamp + 1000);
        ConfigParams memory c = _enabledConfig();
        c.clockSkewSecs = 2;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _expectTickTimeAt(1, uint48(block.timestamp - c.entryMaxAgeSecs - 1), Errors.PriceTooOld.selector);
        _expectTickTimeAt(2, uint48(block.timestamp - c.entryMaxAgeSecs), Errors.PriceBeforeOrder.selector);
        _expectTickTimeAt(3, uint48(block.timestamp + c.clockSkewSecs + 1), Errors.PriceFromFuture.selector);
        _expectTickTimeAt(4, uint48(block.timestamp + c.clockSkewSecs), Errors.PriceBeforeOrder.selector);
    }

    modifier whenTheEntryTickIsFresh() {
        _;
    }

    function test_RevertWhen_TheEntryTickIsBeforeTheOrder()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
        whenTheEntryTickIsFresh
    {
        // it should revert: the tick was published a second before alice signed, so she could have seen the price
        _expectOpenReverts(12, abi.encodeWithSelector(Errors.PriceBeforeOrder.selector));

        // A tick published at the second she signed passes: the next check, the price, fails instead.
        Attempt memory x = _attempt(keccak256("alice's other bet"));
        _breakFrom(x, 13);
        x.o.notBefore = x.t.entryPublishTime;
        x.signature = _signOrder(flashOption, aliceKey, x.o);
        vm.expectRevert(Errors.InvalidPrice.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    modifier whenTheEntryTickIsAtOrAfterTheOrder() {
        _;
    }

    function test_RevertWhen_TheEntryPriceIsNotPositive()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
        whenTheEntryTickIsFresh
        whenTheEntryTickIsAtOrAfterTheOrder
    {
        // it should revert: zero, and a negative price
        _expectOpenReverts(13, abi.encodeWithSelector(Errors.InvalidPrice.selector));
        Attempt memory x = _attempt(keccak256("alice's other bet"));
        _breakFrom(x, 13);
        x.t.entryPrice = -1;
        vm.expectRevert(Errors.InvalidPrice.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    modifier whenTheEntryPriceIsPositive() {
        _;
    }

    function test_RevertWhen_TheOpenGateBlocksTheBet()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
        whenTheEntryTickIsFresh
        whenTheEntryTickIsAtOrAfterTheOrder
        whenTheEntryPriceIsPositive
    {
        // it should revert: no free money left to cover the bet's $30 of max profit (the exposure gate is at 100%)
        _expectOpenReverts(14, abi.encodeWithSelector(Errors.OpenBlockedExposure.selector));

        // And too much owed: the operator lowers the owed limit to 0 while 1 base unit is owed.
        ConfigParams memory c = _enabledConfig();
        c.maxTotalOwed = 0;
        vm.prank(users.operator);
        flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        _writeLayout(address(flashOption), 3, 192, 64, 1); // pool.totalOwed
        Attempt memory x = _attempt(keccak256("alice's other bet"));
        _breakFrom(x, 15);
        vm.expectRevert(Errors.OpenBlockedTotalOwed.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    modifier whenTheOpenGateLetsItIn() {
        _;
    }

    function test_RevertWhen_LessThanTheStakeArrives()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
        whenTheEntryTickIsFresh
        whenTheEntryTickIsAtOrAfterTheOrder
        whenTheEntryPriceIsPositive
        whenTheOpenGateLetsItIn
    {
        // it should revert, and leave nothing behind, whatever stops the stake
        uint256 poolBalance = usdg.balanceOf(address(flashOption));
        uint256[4] memory books = _poolSlots();

        // Alice has no tokens.
        _expectPullRefused(_attempt(keccak256("bet 1")), abi.encodeWithSelector(MockUSDG.InsufficientFunds.selector));
        // She has them, but her authorisation can't be used: a silent no-op the balance check catches, or a refusal.
        _mintUsdg(users.alice, Defaults.STAKE);
        _expectTheSilentNoOpsCaught();
        _expectTheTokensRefusals();

        assertEq(usdg.balanceOf(address(flashOption)), poolBalance, "nothing arrived");
        uint256[4] memory booksAfter = _poolSlots();
        for (uint256 i; i < 4; ++i) {
            assertEq(booksAfter[i], books[i], "the pool's books, slots 3 to 6");
        }
    }

    function test_RevertWhen_MoreThanTheStakeArrives()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
        whenTheEntryTickIsFresh
        whenTheEntryTickIsAtOrAfterTheOrder
        whenTheEntryPriceIsPositive
        whenTheOpenGateLetsItIn
    {
        // it should revert: one base unit more than the stake arrived during the pull
        (MockReentrantToken token, ManicFlashOption proxy) = _proxyOnAReentrantToken();
        OpenOrder memory o = _order(users.alice, keccak256("alice's bet"));
        bytes memory signature = _signOrder(proxy, aliceKey, o);
        OpenTerms memory t = _terms();
        StakeAuth memory a; // the mock doesn't check the authorisation
        // Armed, the token mints one more base unit to the contract from inside the pull, before the stake moves.
        token.setCallback(address(token), abi.encodeCall(MockReentrantToken.mint, (address(proxy), 1)));
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferAmountMismatch.selector, o.stake, uint256(o.stake) + 1));
        vm.prank(users.opener);
        proxy.open(o, signature, t, a);
        assertEq(uint8(LayoutReader.position(address(proxy), o.positionId).status), uint8(Status.None), "not opened");
        assertEq(token.balanceOf(address(proxy)), FREE, "nothing arrived");

        // Disarmed, the same order opens: the refusal was the extra unit's.
        token.setCallback(address(0), "");
        vm.prank(users.opener);
        proxy.open(o, signature, t, a);
        assertEq(LayoutReader.pool(address(proxy)).total, uint256(FREE) + o.stake, "the total holds exactly the stake");
        assertEq(token.balanceOf(address(proxy)), uint256(FREE) + o.stake, "the balance rose by exactly the stake");
    }

    function test_WhenExactlyTheStakeArrives()
        external
        whenTheCallerIsAnOpener
        givenTheContractIsNotHalted
        whenTheOrderHasNotExpired
        whenTheMarketExists
        givenTheMarketIsEnabled
        givenTheMarketIsNotPaused
        givenTheBreakerHasNotTripped
        whenThePositionIdIsNew
        whenTheSignatureIsTheUsers
        whenTheTermsAreInsideTheMarketsBounds
        whenTheEntryTickIsFresh
        whenTheEntryTickIsAtOrAfterTheOrder
        whenTheEntryPriceIsPositive
        whenTheOpenGateLetsItIn
    {
        Attempt memory x = _attempt(keccak256("alice's bet"));
        _mintUsdg(users.alice, x.o.stake);
        PoolState memory before = LayoutReader.pool(address(flashOption));
        // The transaction lands 2 seconds after the tick (still fresh): the bet's clock must start at the tick.
        vm.warp(block.timestamp + 2);

        _assertNobodyElseCanSubmit(x);

        // it should emit {PositionOpened}
        (int64 liqPrice, int64 capPrice) =
            LeverageMath.lines(x.t.entryPrice, x.o.side, Defaults.LEVERAGE, x.t.thetaE7, x.t.capBps);
        _expectOpened(x, liqPrice, capPrice);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);

        // it should record the position
        _assertPositionRecorded(x, liqPrice);
        // it should hold the stake and its max profit in the books
        _assertBooksHoldTheStake(x, before);

        // it should take exactly the stake from the user
        assertEq(usdg.balanceOf(users.alice), 0, "alice paid her stake");
        assertEq(usdg.balanceOf(address(flashOption)), uint256(FREE) + x.o.stake, "the pool holds it");
        assertTrue(usdg.authorizationState(users.alice, x.o.positionId), "her authorisation is used up");
        assertEq(usdg.allowance(users.alice, address(flashOption)), 0, "and no allowance after");
        _assertBooksBalanced(address(flashOption));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Her authorisation's nonce (the position id) was already used, or she cancelled it: USDG does nothing and
    ///      doesn't revert, so only the balance check stops the open.
    function _expectTheSilentNoOpsCaught() private {
        Attempt memory x = _attempt(keccak256("bet 2"));
        _useNonce(x.o.positionId);
        _expectPullRefused(x, abi.encodeWithSelector(Errors.TransferAmountMismatch.selector, x.o.stake, 0));
        x = _attempt(keccak256("bet 3"));
        _cancelNonce(x.o.positionId);
        _expectPullRefused(x, abi.encodeWithSelector(Errors.TransferAmountMismatch.selector, x.o.stake, 0));
    }

    /// @dev The token refuses the pull, with its own error: the authorisation is bob's (USDG names this error
    ///      `InvalidSignature` too), it has expired or isn't valid yet, she is frozen, or the token is paused.
    /// @dev A second proxy, on a token that can call back from inside a pull (`MockReentrantToken`, disarmed), with the
    ///      same free money, the BTC market switched on, and alice holding her stake.
    function _proxyOnAReentrantToken() private returns (MockReentrantToken token, ManicFlashOption proxy) {
        token = new MockReentrantToken();
        InitParams memory p = _defaultInitParams();
        p.token = IERC20(address(token));
        proxy = ManicFlashOption(_deployProxy(p));
        token.mint(users.bob, FREE);
        vm.startPrank(users.bob);
        token.approve(address(proxy), FREE);
        proxy.fund(FREE);
        vm.stopPrank();
        vm.prank(users.admin);
        proxy.createMarket(Defaults.BTC, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        vm.prank(users.operator);
        proxy.setConfig(Defaults.BTC, Defaults.LEVERAGE, _enabledConfig());
        token.mint(users.alice, Defaults.STAKE);
    }

    function _expectTheTokensRefusals() private {
        Attempt memory x = _attempt(keccak256("bet 4"));
        x.a = _stakeAuth(flashOption, bobKey, x.o);
        _expectPullRefused(x, abi.encodeWithSelector(MockUSDG.InvalidSignature.selector));
        x = _attempt(keccak256("bet 5"));
        x.a.validBefore = block.timestamp;
        _expectPullRefused(x, abi.encodeWithSelector(MockUSDG.AuthorizationExpired.selector));
        x = _attempt(keccak256("bet 6"));
        x.a.validAfter = block.timestamp;
        _expectPullRefused(x, abi.encodeWithSelector(MockUSDG.AuthorizationInvalid.selector));
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        _expectPullRefused(_attempt(keccak256("bet 7")), abi.encodeWithSelector(MockUSDG.AddressFrozen.selector));
        vm.startPrank(usdgAdmin);
        usdg.unfreeze(users.alice);
        usdg.pause();
        vm.stopPrank();
        _expectPullRefused(_attempt(keccak256("bet 8")), abi.encodeWithSelector(MockUSDG.ContractPaused.selector));
    }

    /// @dev Nobody but the contract can submit alice's authorisation (it would fail, and stay unused), and she never
    ///      approves anything (security checklist SIG-7, SIG-8).
    function _assertNobodyElseCanSubmit(Attempt memory x) private {
        vm.expectRevert(MockUSDG.CallerMustBePayee.selector);
        vm.prank(users.eve);
        usdg.receiveWithAuthorization(
            users.alice, address(flashOption), x.o.stake, x.a.validAfter, x.a.validBefore, x.o.positionId, x.a.signature
        );
        assertFalse(usdg.authorizationState(users.alice, x.o.positionId), "still unused");
        assertEq(usdg.allowance(users.alice, address(flashOption)), 0, "no allowance before");
    }

    /// @dev Every field of the position, read from its raw slots, and its slot 2 still empty.
    function _assertPositionRecorded(Attempt memory x, int64 liqPrice) private view {
        Position memory p = LayoutReader.position(address(flashOption), x.o.positionId);
        assertEq(p.user, users.alice, "user");
        assertEq(p.marketIdx, 0, "BTC's index");
        assertEq(uint8(p.side), uint8(Side.Call), "side");
        assertEq(uint8(p.status), uint8(Status.Open), "status");
        assertEq(p.startTime, x.t.entryPublishTime, "starts at the entry tick");
        assertEq(p.durationSecs, x.o.durationSecs, "duration");
        assertEq(p.stake, x.o.stake, "stake");
        assertEq(p.entryPrice, x.t.entryPrice, "entry price");
        assertEq(p.liqPrice, liqPrice, "liquidation line");
        assertEq(p.floorBps, x.t.floorBps, "floor");
        assertEq(p.capBps, x.t.capBps, "cap");
        assertEq(p.leverage, x.o.leverage, "leverage: the market's, which the order names");
        assertEq(LayoutReader.positionWord(address(flashOption), x.o.positionId, 2), 0, "slot 2 untouched");
    }

    /// @dev The stake and its max profit are held in the books, and nothing else in them moved.
    function _assertBooksHoldTheStake(Attempt memory x, PoolState memory before) private view {
        uint64 maxProfit = x.o.stake * (x.t.capBps - 10_000) / 10_000; // $10 at 4x can win $30
        PoolState memory afterwards = LayoutReader.pool(address(flashOption));
        assertEq(afterwards.total, before.total + x.o.stake, "total");
        assertEq(afterwards.lockedMargin, before.lockedMargin + x.o.stake, "held margin");
        assertEq(afterwards.openMaxProfit, before.openMaxProfit + maxProfit, "open max profit");
        assertEq(afterwards.openPositions, before.openPositions + 1, "open positions");
        assertEq(afterwards.totalOwed, before.totalOwed, "owed untouched");
        assertEq(afterwards.feesPending, before.feesPending, "fees untouched");
        assertEq(afterwards.totalClaimable, before.totalClaimable, "claimable untouched");
    }

    /// @dev A valid attempt at alice's base bet with position id `id`: everything right except that alice holds no
    ///      tokens yet.
    function _attempt(bytes32 id) private view returns (Attempt memory x) {
        x.o = _order(users.alice, id);
        x.t = _terms();
        x.signature = _signOrder(flashOption, _aliceKey(), x.o);
        x.a = _stakeAuth(flashOption, _aliceKey(), x.o);
    }

    /// @dev Breaks check `from` (numbered as in docs/ARCHITECTURE.md §8.2, the role being 1) and every later one, then
    ///      signs the order: by bob when check 9 must fail, by alice otherwise. The stake pull, check 15, fails because
    ///      alice holds no tokens.
    function _breakFrom(Attempt memory x, uint256 from) private {
        if (from <= 2) {
            vm.prank(users.guardian);
            flashOption.setHalted(true);
        }
        if (from <= 3) x.o.deadline = uint48(block.timestamp) - 1;
        if (from <= 4) x.o.marketId = Defaults.ETH;
        if (from <= 5) {
            ConfigParams memory c = _enabledConfig();
            c.enabled = false;
            vm.prank(users.operator);
            flashOption.setConfig(Defaults.BTC, Defaults.LEVERAGE, c);
        }
        if (from <= 6) {
            vm.prank(users.guardian);
            flashOption.setPaused(Defaults.BTC, Defaults.LEVERAGE, true);
        }
        if (from <= 7) _writeLayout(address(flashOption), 7, 176, 8, 1); // breaker.tripped
        if (from <= 8) x.o.positionId = bytes32(0);
        if (from <= 10) x.o.stake = 0;
        if (from <= 11) x.t.entryPublishTime = 0;
        if (from <= 12) x.o.notBefore = x.t.entryPublishTime + 1;
        if (from <= 13) x.t.entryPrice = 0;
        if (from <= 14) _writeLayout(address(flashOption), 3, 64, 64, LayoutReader.pool(address(flashOption)).total);
        x.signature = _signOrder(flashOption, from <= 9 ? bobKey : aliceKey, x.o);
        x.a = _stakeAuth(flashOption, aliceKey, x.o);
    }

    /// @dev Breaks check `from` and every later one, and expects `open` to revert with `reason`.
    function _expectOpenReverts(uint256 from, bytes memory reason) private {
        Attempt memory x = _attempt(keccak256("alice's bet"));
        _breakFrom(x, from);
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    /// @dev Expects these terms to fail `validateOpen` with every later check broken.
    function _expectTermsRefused(
        uint256 n,
        uint64 stake,
        uint16 durationSecs,
        uint32 thetaE7,
        uint16 floorBps,
        uint16 capBps
    )
        private
    {
        Attempt memory x = _attempt(keccak256(abi.encode("terms", n)));
        _breakFrom(x, 11);
        x.o.stake = stake;
        x.o.durationSecs = durationSecs;
        x.t.thetaE7 = thetaE7;
        x.t.floorBps = floorBps;
        x.t.capBps = capBps;
        x.signature = _signOrder(flashOption, aliceKey, x.o);
        vm.expectRevert(n <= 2 ? Errors.InvalidAmount.selector : Errors.InvalidLeverageParams.selector);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    /// @dev Expects a tick published at `publishTime` to give `expected`, with every check after the tick's time broken
    ///      (the order is signed for a second after the tick).
    function _expectTickTimeAt(uint256 n, uint48 publishTime, bytes4 expected) private {
        Attempt memory x = _attempt(keccak256(abi.encode("tick", n)));
        _breakFrom(x, 12);
        x.t.entryPublishTime = publishTime;
        x.o.notBefore = publishTime + 1;
        x.signature = _signOrder(flashOption, aliceKey, x.o);
        vm.expectRevert(expected);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
    }

    /// @dev Expects the stake pull of the otherwise valid attempt `x` to fail with `reason`, and no position.
    function _expectPullRefused(Attempt memory x, bytes memory reason) private {
        vm.expectRevert(reason);
        vm.prank(users.opener);
        flashOption.open(x.o, x.signature, x.t, x.a);
        assertEq(uint8(LayoutReader.position(address(flashOption), x.o.positionId).status), 0, "no position");
    }

    /// @dev Uses alice's EIP-3009 nonce `nonce` for a 1-unit transfer to bob, before the contract can.
    function _useNonce(bytes32 nonce) private {
        UsdgSigner.Authorization memory a = UsdgSigner.Authorization({
            from: users.alice,
            to: users.bob,
            value: 1,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60,
            nonce: nonce
        });
        bytes memory signature = UsdgSigner.sign(aliceKey, UsdgSigner.authorizationDigest(address(usdg), a, false));
        usdg.transferWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, signature);
    }

    /// @dev Alice cancels her EIP-3009 nonce `nonce`.
    function _cancelNonce(bytes32 nonce) private {
        bytes memory signature = UsdgSigner.sign(aliceKey, UsdgSigner.cancelDigest(address(usdg), users.alice, nonce));
        usdg.cancelAuthorization(users.alice, nonce, signature);
    }

    /// @dev Expects {PositionOpened} for `x`, with these lines. Built in one memory struct and emitted from a helper:
    ///      inline, the event's 15 fields don't fit the stack (docs/CONVENTIONS.md §7).
    function _expectOpened(Attempt memory x, int64 liqPrice, int64 capPrice) private {
        TradingModule.Opened memory e;
        e.positionId = x.o.positionId;
        e.user = x.o.user;
        e.marketId = x.o.marketId;
        e.side = x.o.side;
        e.stake = x.o.stake;
        e.entryPrice = x.t.entryPrice;
        e.priceExponent = Defaults.PRICE_EXPONENT;
        e.liqPrice = liqPrice;
        e.capPrice = capPrice;
        e.thetaE7 = x.t.thetaE7;
        e.floorBps = x.t.floorBps;
        e.capBps = x.t.capBps;
        e.startTime = x.t.entryPublishTime;
        e.endTime = x.t.entryPublishTime + x.o.durationSecs;
        e.leverage = x.o.leverage; // the market's, which the order names
        vm.expectEmit(address(flashOption));
        _emitOpened(e);
    }

    function _emitOpened(TradingModule.Opened memory e) private {
        emit Events.PositionOpened(
            e.positionId,
            e.user,
            e.marketId,
            e.side,
            e.stake,
            e.entryPrice,
            e.priceExponent,
            e.liqPrice,
            e.capPrice,
            e.thetaE7,
            e.floorBps,
            e.capBps,
            e.startTime,
            e.endTime,
            e.leverage
        );
    }

    /// @dev Alice's key, for the view helpers (`_keyOf` is not view).
    function _aliceKey() private view returns (uint256) {
        return aliceKey;
    }

    /// @dev The pool's four slots, word for word.
    function _poolSlots() private view returns (uint256[4] memory words) {
        for (uint256 i; i < 4; ++i) {
            words[i] = LayoutReader.word(address(flashOption), 3 + i);
        }
    }
}
