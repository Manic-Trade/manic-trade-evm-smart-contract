// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManicFlashOptionErrors as Errors} from "../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Position} from "../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../SettlementBase.t.sol";
import {Defaults} from "../utils/Defaults.sol";
import {Examples} from "../utils/Examples.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";

/// @title FakePriceLoop_Test
/// @notice The fake-price loop with one stolen relayer key (docs/ARCHITECTURE.md §8.11, security checklist AC-2).
///         Ostium (Arbitrum, Jul 2026, ~$18M) lost its pool to a stolen price key that opened at fake prices and
///         closed at real ones. The breaker's own test (`test/concrete/breaker/`) runs it with both relayer keys on
///         one market.
///         Here each key runs it alone, the loop spreads over the three planned markets, and a revoked key tries to
///         start it again.
/// @dev The breaker starts with the test default: a $1,000 limit on net profit per 1-hour window. The attacker bets
///      from wallets of their own (eve), $50 calls at a minute, and the pool has $10,000 of free money.
contract FakePriceLoop_Test is Settlement_Base_Test {
    /// @dev The attacker's stake per bet: the launch config's largest.
    uint64 internal constant STAKE = 50e6;

    /// @dev What a $50 bet at the 4x cap is worth.
    uint64 internal constant AT_THE_CAP = 200e6;

    /// @dev A second opener key, which the backend keeps ready (docs/runbooks/relayer-keys.md: at least two of each).
    address internal secondOpener;

    function setUp() public override {
        super.setUp();
        _fund(users.bob, 8500e6);
        secondOpener = makeAddr("secondOpener");
        bytes32 openerRole = flashOption.OPENER_ROLE();
        vm.prank(users.admin);
        flashOption.grantRole(openerRole, secondOpener);
    }

    /// @dev The opener key alone, with no settler: it opens eve's bets at a fake entry $300 below the real price,
    ///      then sells each at once at the real price, at the 4x cap: $150 of profit a sale. The seventh sale takes
    ///      the window's profit to $1,050, over the limit, and trips the breaker; the eighth sale and any new bet are
    ///      refused. With the breaker off, all eight go through.
    function test_TheOpenerAloneIsStoppedWhenItSellsAtTheRealPrice() external {
        for (uint256 i; i < 8; ++i) {
            _openAtAFakeEntry(_id("bet", i));
        }
        uint256 before = vm.snapshotState();
        vm.prank(users.admin);
        flashOption.setBreaker(0, Defaults.BREAKER_WINDOW);
        for (uint256 i; i < 8; ++i) {
            _sellAtTheRealPrice(_id("bet", i));
        }
        vm.revertToStateAndDelete(before);

        for (uint256 i; i < 7; ++i) {
            assertFalse(LayoutReader.breaker(address(flashOption)).tripped, "not tripped before the seventh sale");
            _sellAtTheRealPrice(_id("bet", i));
        }
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "tripped by the seventh sale");
        assertEq(LayoutReader.breaker(address(flashOption)).profitOut, 1050e6, "$1,050 of profit out");
        _expectSellReverts(
            _sellOrder(_id("bet", 7), AT_THE_CAP),
            _sellTerms(Examples.P0, AT_THE_CAP, AT_THE_CAP),
            abi.encodeWithSelector(Errors.BreakerTripped.selector)
        );
        _expectOpenRefused(users.opener, abi.encodeWithSelector(Errors.BreakerTripped.selector));
    }

    /// @dev The settler key alone, with the opener honest: eve's bets open at the real price on BTC's three planned
    ///      markets, 1000x at the launch values and 500x and 100x at the tier settings, and the key settles them at a
    ///      fake price 2% up, past every cap. A round of two bets per market takes $550 ($150, $75 and $50 a bet at
    ///      caps of 4x, 2.5x and 2x). The markets share one breaker: in the second round, the 1000x batch takes the
    ///      total to $850, the 500x batch to exactly $1,000, which is allowed, and the 100x batch to $1,100, which
    ///      trips it. Then no market opens a bet.
    function test_TheSettlerAloneIsStoppedAcrossThreeLeveragesSharingOneBreaker() external {
        uint16[3] memory leverages = [uint16(1000), 500, 100];
        _useBtcAt(500, LeverageConfigs.planned(500));
        _useBtcAt(100, LeverageConfigs.planned(100));

        _settlerRound(leverages, 0);
        assertEq(LayoutReader.breaker(address(flashOption)).profitOut, 550e6, "the first round's profit");
        assertFalse(LayoutReader.breaker(address(flashOption)).tripped, "under the limit");
        _settlerRound(leverages, 1);
        assertEq(LayoutReader.breaker(address(flashOption)).profitOut, 1100e6, "both rounds' profit");
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "tripped by the 100x batch");

        for (uint256 i; i < leverages.length; ++i) {
            OpenOrder memory o = _attackersOrder(_id("after the trip", i), leverages[i]);
            _expectOpenRefusedFor(
                users.opener, o, _realTerms(leverages[i]), abi.encodeWithSelector(Errors.BreakerTripped.selector)
            );
        }
    }

    /// @dev After the opener key trips the breaker, the guardian revokes it at once and the operator resets the
    ///      breaker. The revoked key can't open or sell again, and the guardian can't grant it back: only the
    ///      timelocked admin grants a key. The backend carries on with its second opener key.
    function test_ARevokedKeyCantRestartTheLoop() external {
        for (uint256 i; i < 8; ++i) {
            _openAtAFakeEntry(_id("bet", i));
        }
        for (uint256 i; i < 7; ++i) {
            _sellAtTheRealPrice(_id("bet", i));
        }
        assertTrue(LayoutReader.breaker(address(flashOption)).tripped, "tripped by the seventh sale");
        bytes32 openerRole = flashOption.OPENER_ROLE();
        vm.prank(users.guardian);
        flashOption.revokeRelayer(openerRole, users.opener);
        vm.prank(users.operator);
        flashOption.resetBreaker();

        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, users.opener, openerRole);
        _expectSellReverts(
            _sellOrder(_id("bet", 7), AT_THE_CAP), _sellTerms(Examples.P0, AT_THE_CAP, AT_THE_CAP), unauthorized
        );
        _expectOpenRefused(users.opener, unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                users.guardian,
                flashOption.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(users.guardian);
        flashOption.grantRole(openerRole, users.opener);

        OpenOrder memory o = _order(users.alice, "alice's call");
        _mintUsdg(users.alice, o.stake);
        bytes memory signature = _signOrder(flashOption, aliceKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, aliceKey, o);
        vm.prank(secondOpener);
        flashOption.open(o, signature, _terms(), a);
        assertEq(LayoutReader.position(address(flashOption), "alice's call").user, users.alice, "the 2nd key opened");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Opens eve's $50 BTC call at 1000x at a fake entry, $300 below the real price.
    function _openAtAFakeEntry(bytes32 id) private {
        OpenOrder memory o = _attackersOrder(id, Defaults.LEVERAGE);
        OpenTerms memory t = _terms();
        t.entryPrice = Examples.priceAt(-300);
        _betWith(o, t);
    }

    /// @dev Sells eve's bet `id` now at the real price, past its 4x cap, for its whole value: no early-sell fee, which
    ///      the opener picks.
    function _sellAtTheRealPrice(bytes32 id) private {
        _expectSale(id, Examples.P0, AT_THE_CAP, AT_THE_CAP, AT_THE_CAP);
    }

    /// @dev One round of the settler's loop: two of eve's bets per market, opened honestly at the real price, then
    ///      settled at their expiry, a batch per market, at a fake price 2% up.
    function _settlerRound(uint16[3] memory leverages, uint256 round) private {
        bytes32[2][3] memory ids;
        uint48 end;
        for (uint256 i; i < leverages.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                ids[i][j] = keccak256(abi.encode("round", round, i, j));
                Position memory p = _betWith(_attackersOrder(ids[i][j], leverages[i]), _realTerms(leverages[i]));
                end = _end(p);
            }
        }
        vm.warp(end);
        for (uint256 i; i < leverages.length; ++i) {
            batchLeverage = leverages[i];
            _expectSettled(Examples.P0 + Examples.P0 / 50, end, _ids(ids[i][0], ids[i][1]));
        }
        batchLeverage = Defaults.LEVERAGE;
    }

    /// @dev Eve's order for a $50 BTC call at `marketLeverage`.
    function _attackersOrder(bytes32 id, uint16 marketLeverage) private view returns (OpenOrder memory o) {
        o = _order(users.eve, id);
        o.leverage = marketLeverage;
        o.stake = STAKE;
    }

    /// @dev Terms at the real price that the market at `marketLeverage` accepts: the one-minute rule's widest line,
    ///      the lowest floor and the highest cap of its planned settings.
    function _realTerms(uint16 marketLeverage) private view returns (OpenTerms memory t) {
        ConfigParams memory c = LeverageConfigs.planned(marketLeverage);
        assertEq(c.durations[0].durationSecs, Defaults.DURATION, "the first rule is the one-minute one");
        t = _terms();
        t.thetaE7 = c.durations[0].thetaMaxE7;
        t.floorBps = c.floorMinBps;
        t.capBps = c.capMaxBps;
    }

    /// @dev Expects a new fake-entry bet of eve's, opened by `relayer`, to be refused with `reason`.
    function _expectOpenRefused(address relayer, bytes memory reason) private {
        OpenTerms memory t = _terms();
        t.entryPrice = Examples.priceAt(-300);
        _expectOpenRefusedFor(relayer, _attackersOrder("refused", Defaults.LEVERAGE), t, reason);
    }

    /// @dev Expects `relayer`'s open of eve's order `o` with `t` to be refused with `reason`.
    function _expectOpenRefusedFor(
        address relayer,
        OpenOrder memory o,
        OpenTerms memory t,
        bytes memory reason
    )
        private
    {
        _mintUsdg(o.user, o.stake);
        bytes memory signature = _signOrder(flashOption, eveKey, o);
        StakeAuth memory a = _stakeAuth(flashOption, eveKey, o);
        vm.expectRevert(reason);
        vm.prank(relayer);
        flashOption.open(o, signature, t, a);
    }

    /// @dev A position id from a tag and a number.
    function _id(string memory tag, uint256 i) private pure returns (bytes32) {
        return keccak256(abi.encode(tag, i));
    }
}
