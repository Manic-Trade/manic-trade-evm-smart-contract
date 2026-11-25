// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {OpenOrder} from "../../../src/types/OrderTypes.sol";
import {Breaker, Market, PoolState, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {Settlement_Base_Test} from "../../SettlementBase.t.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {Examples} from "../../utils/Examples.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";

/// @title Getters_Concrete_Test
/// @notice The getters (docs/ARCHITECTURE.md §8.9): each returns exactly what storage holds, read slot by slot with
///         `LayoutReader`, for open, owed, closed and never-used positions, the markets, the pool, the repay queue,
///         the circuit breaker and the settings. Their guard against read-only reentrancy is tested in
///         test/concrete/reentrancy/.
/// @dev Whole structs are compared through `abi.encode`, which is equal only if every field is. The cap price is
///      compared with the one `PositionOpened` reported, decoded from the open's own log.
contract Getters_Concrete_Test is Settlement_Base_Test {
    function test_GetPositionOfAnOpenBet() external {
        for (uint256 i; i < 2; ++i) {
            Side side = i == 0 ? Side.Call : Side.Put;
            bytes32 id = keccak256(abi.encode("open bet", side));
            OpenedData memory opened = _betRecorded(users.alice, id, side);

            (Position memory p, uint48 endTime, int64 capPrice) = flashOption.getPosition(id);
            _assertStored(id, p);
            assertEq(uint8(p.status), uint8(Status.Open), "open");
            assertEq(p.leverage, Defaults.LEVERAGE, "its leverage, 1000x");
            assertEq(opened.leverage, Defaults.LEVERAGE, "the leverage PositionOpened reported");
            assertEq(endTime, opened.endTime, "the expiry PositionOpened reported");
            assertEq(capPrice, opened.capPrice, "the cap price PositionOpened reported");
        }
    }

    function test_GetPositionOfAnIouThenOfItsClosedRecord() external {
        _useSmallPool(20e6);
        OpenedData memory a = _betRecorded(users.alice, "a", Side.Call);
        Position memory b = _bet(users.alice, "b", Side.Call);
        vm.warp(_end(b));
        _expectSettled(Examples.priceAt(300), _end(b), _ids("a", "b"));

        // An IOU keeps its terms, so it still has a cap price, and reads what it is owed and its place.
        (Position memory p, uint48 endTime, int64 capPrice) = flashOption.getPosition("a");
        _assertStored("a", p);
        assertEq(uint8(p.status), uint8(Status.Owed), "owed");
        assertEq(p.owed, 10_000_000, "$10 owed");
        assertEq(p.queueSeq, 0, "first in the queue");
        assertEq(p.leverage, Defaults.LEVERAGE, "its leverage, with its other terms");
        assertEq(capPrice, a.capPrice, "its cap price");
        assertEq(endTime, a.endTime, "its expiry");

        // Repaid in full, it closes: only its first slot stays.
        _fund(users.bob, 100e6);
        _expectRepaid(1, users.eve);
        (p, endTime, capPrice) = flashOption.getPosition("a");
        _assertStored("a", p);
        assertEq(uint8(p.status), uint8(Status.Closed), "closed");
        assertEq(p.stake, 0, "its terms are cleared");
        assertEq(p.leverage, 0, "its leverage with them");
        assertEq(p.owed, 0, "and it is owed nothing");
        assertEq(capPrice, 0, "so it has no cap price");
        assertEq(endTime, a.endTime, "its expiry is still there");
    }

    function test_GetPositionOfAnUnusedId() external view {
        (Position memory p, uint48 endTime, int64 capPrice) = flashOption.getPosition("never used");
        assertEq(
            abi.encode(p), abi.encode(Position(address(0), 0, Side.Call, Status.None, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        );
        assertEq(endTime, 0, "no expiry");
        assertEq(capPrice, 0, "no cap price");
    }

    function test_GetMarketAndTheMarketList() external {
        assertEq(
            abi.encode(flashOption.getMarket(Defaults.BTC, Defaults.LEVERAGE)),
            abi.encode(LayoutReader.market(address(flashOption), 0))
        );
        assertEq(flashOption.marketCount(), 1, "one market");
        (bytes32 first, uint16 firstLeverage) = flashOption.marketIdAt(0);
        assertEq(first, Defaults.BTC, "BTC first");
        assertEq(firstLeverage, Defaults.LEVERAGE, "at 1000x");
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.marketIdAt(1);
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.getMarket(Defaults.ETH, Defaults.LEVERAGE);
        vm.expectRevert(Errors.UnknownMarket.selector);
        flashOption.getMarket(Defaults.BTC, 500); // a feed's market is per leverage

        vm.prank(users.admin);
        flashOption.createMarket(Defaults.ETH, Defaults.LEVERAGE, Defaults.PRICE_EXPONENT, Defaults.marketConfig());
        assertEq(flashOption.marketCount(), 2, "two markets");
        (bytes32 second, uint16 secondLeverage) = flashOption.marketIdAt(1);
        assertEq(second, Defaults.ETH, "ETH second");
        assertEq(secondLeverage, Defaults.LEVERAGE, "at 1000x too");
        Market memory eth = flashOption.getMarket(Defaults.ETH, Defaults.LEVERAGE);
        assertEq(abi.encode(eth), abi.encode(LayoutReader.market(address(flashOption), 1)), "ETH as stored");
        assertFalse(eth.enabled, "created switched off");
    }

    function test_GetPoolFreeMoneyAndClaimable() external {
        _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.bob, "b", Side.Put);
        // While the two bets are open, their stakes are held: free money is the $1,500 the pool was funded with.
        assertEq(flashOption.getPool().lockedMargin, 2 * Defaults.STAKE, "both stakes held");
        assertEq(flashOption.freeMoney(), FREE, "free money leaves the held stakes out");
        vm.warp(_end(b));
        vm.prank(usdgAdmin);
        usdg.freeze(users.alice);
        _expectSettled(Examples.priceAt(8), _end(b), _ids("a", "b"));

        PoolState memory pool = flashOption.getPool();
        assertEq(abi.encode(pool), abi.encode(LayoutReader.pool(address(flashOption))), "every field as stored");
        assertEq(flashOption.freeMoney(), pool.total - pool.lockedMargin, "free money");
        assertEq(flashOption.claimableOf(users.alice), 12_940_000, "alice's payout waits");
        assertEq(
            flashOption.claimableOf(users.alice), LayoutReader.claimable(address(flashOption), users.alice), "stored"
        );
        assertEq(flashOption.claimableOf(users.bob), 0, "bob was paid");
    }

    function test_QueueHeadFollowsTheQueue() external {
        _useSmallPool(20e6);
        _assertHead(0, 0, 0); // empty
        _bet(users.alice, "a", Side.Call);
        Position memory b = _bet(users.bob, "b", Side.Call);
        vm.warp(_end(b));
        _expectSettled(Examples.priceAt(300), _end(b), _ids("a", "b"));
        _assertHead(0, "a", 10_000_000);

        _fund(users.bob, 4e6);
        _expectRepaid(50, users.eve);
        _assertHead(0, "a", 6_000_000); // part-paid, still the head

        _fund(users.bob, 6e6);
        _expectRepaid(1, users.eve);
        _assertHead(1, "b", 30_000_000);

        _fund(users.bob, 30e6);
        _expectRepaid(1, users.eve);
        _assertHead(2, 0, 0); // empty again
    }

    function test_TheSettingsGetters() external {
        Breaker memory breaker = flashOption.getBreaker();
        assertEq(abi.encode(breaker), abi.encode(LayoutReader.breaker(address(flashOption))), "the breaker as stored");
        assertEq(breaker.maxNetProfit, Defaults.BREAKER_MAX_NET_PROFIT, "its limit");
        assertEq(address(flashOption.token()), address(usdg), "USDG");
        assertEq(flashOption.refundDelaySecs(), Defaults.REFUND_DELAY, "24 hours");
        (address fees, address rewards) = flashOption.recipients();
        assertEq(fees, users.feeRecipient, "the fee recipient");
        assertEq(rewards, users.rewardsRecipient, "the rewards recipient");

        assertFalse(flashOption.halted(), "not halted");
        vm.prank(users.guardian);
        flashOption.setHalted(true);
        assertTrue(flashOption.halted(), "halted");
        vm.prank(users.admin);
        flashOption.setRecipients(users.eve, users.bob);
        (fees, rewards) = flashOption.recipients();
        assertEq(fees, users.eve, "the new fee recipient");
        assertEq(rewards, users.bob, "the new rewards recipient");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Opens `user`'s base bet on `side` and returns what its {PositionOpened} reported.
    function _betRecorded(address user, bytes32 id, Side side) private returns (OpenedData memory) {
        OpenOrder memory o = _order(user, id);
        o.side = side;
        return _betRecorded(o, _terms());
    }

    /// @dev `p`, returned by `getPosition`, is exactly what storage holds for `id`.
    function _assertStored(bytes32 id, Position memory p) private view {
        assertEq(abi.encode(p), abi.encode(LayoutReader.position(address(flashOption), id)), "the position as stored");
    }

    /// @dev `queueHead()` returns these.
    function _assertHead(uint64 queueSeq, bytes32 positionId, uint64 owed) private view {
        (uint64 seq, bytes32 id, uint64 amount) = flashOption.queueHead();
        assertEq(seq, queueSeq, "the head's place");
        assertEq(id, positionId, "the head");
        assertEq(amount, owed, "what it is owed");
    }
}
