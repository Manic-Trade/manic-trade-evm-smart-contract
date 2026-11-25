// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {OpenOrder, OpenTerms} from "../../src/types/OrderTypes.sol";
import {ConfigParams} from "../../src/types/ParamTypes.sol";
import {Breaker, PoolState, Position, Status} from "../../src/types/StorageTypes.sol";
import {Base_Test} from "../Base.t.sol";
import {Calculations} from "../utils/Calculations.sol";
import {Defaults} from "../utils/Defaults.sol";
import {LayoutReader} from "../utils/LayoutReader.sol";
import {LeverageConfigs} from "../utils/LeverageConfigs.sol";
import {AdminHandler} from "./handlers/AdminHandler.sol";
import {BaseHandler, HandlerSetup} from "./handlers/BaseHandler.sol";
import {MarketHandler} from "./handlers/MarketHandler.sol";
import {PoolHandler} from "./handlers/PoolHandler.sol";
import {SettlementHandler} from "./handlers/SettlementHandler.sol";
import {TradingHandler} from "./handlers/TradingHandler.sol";
import {FlashOptionStore} from "./stores/FlashOptionStore.sol";

/// @title Leverage_Invariant_Test
/// @notice The stateful suite (docs/ARCHITECTURE.md §12, §13). Handlers drive random sequences of what can happen to
///         the contract, on BTC's three markets (1000x, 500x and 100x) sharing one pool: bets opened, sold,
///         liquidated, settled, refunded and repaid at a moving price while time passes, each batch on one market and
///         those that mix markets refused; the pool funded, withdrawn from, claimed from, swept and sent tokens it
///         must not count; and the rules changed under them: brakes put on and released, a market's settings and the
///         breaker changed, users and recipients frozen, and a stranger trying every role-gated function. After every
///         call, each invariant below must hold. Each `invariant_<NN>_` function is one invariant of §12, numbered as
///         there; 12 to 14 are the stateful suite's additions to the list.
/// @dev Set-up: BTC's markets at their planned settings (`LeverageConfigs.planned`): 1000x at the launch values
///      (Base_Test), 500x and 100x at the tier settings, each with the open gate at 100%. The refund delay at its
///      shortest, 1 hour, so refunds come within reach of a run, and $1,000 in the pool, $500 above the floor. Three
///      bettors (alice, bob and carol) sign their own orders. The handlers record what they know in
///      `FlashOptionStore`, and the checks they run during a call record any breach there; every invariant first
///      asserts that there is none.
///      `SmallPool_Invariant_Test` below runs the same suite on a pool too small to pay its winners.
contract Leverage_Invariant_Test is Base_Test {
    /// @dev The pool's money at the start: $1,000, $500 above the floor.
    uint64 internal constant SEED = 1000e6;

    /// @dev 2026-11-13, midnight UTC: a realistic clock, so a tick can be published seconds before "now".
    uint256 internal constant START = 1_794_528_000;

    /// @dev BTC's two markets besides the test market's 1000x.
    uint16 internal constant L500 = 500;
    uint16 internal constant L100 = 100;

    FlashOptionStore internal store;
    MarketHandler internal marketHandler;
    TradingHandler internal tradingHandler;
    SettlementHandler internal settlementHandler;
    PoolHandler internal poolHandler;
    AdminHandler internal adminHandler;

    address[] internal bettors;
    uint256[] internal bettorKeys;
    address internal stranger;
    address internal funder;
    /// @dev Every account the set-up or the handlers use, each once.
    address[] internal accounts;

    function setUp() public virtual override {
        super.setUp();
        string[3] memory names = ["alice", "bob", "carol"];
        for (uint256 i; i < names.length; ++i) {
            (address bettor, uint256 key) = makeAddrAndKey(names[i]);
            bettors.push(bettor);
            bettorKeys.push(key);
        }
        stranger = makeAddr("stranger");
        funder = makeAddr("funder");

        vm.warp(START);
        vm.prank(users.admin);
        flashOption.setRefundDelay(1 hours);
        _fund(funder, _seed());
        _useBtcAt(L500, LeverageConfigs.planned(L500));
        _useBtcAt(L100, LeverageConfigs.planned(L100));
        _prepareMarkets();

        store = new FlashOptionStore(Defaults.ENTRY_PRICE);
        HandlerSetup memory s = HandlerSetup({
            flashOption: flashOption,
            usdg: usdg,
            usdgAdmin: usdgAdmin,
            store: store,
            users: users,
            bettors: bettors,
            bettorKeys: bettorKeys,
            stranger: stranger,
            funder: funder
        });
        marketHandler = MarketHandler(_deploy("MarketHandler", s));
        tradingHandler = TradingHandler(_deploy("TradingHandler", s));
        settlementHandler = SettlementHandler(_deploy("SettlementHandler", s));
        poolHandler = PoolHandler(_deploy("PoolHandler", s));
        adminHandler = AdminHandler(_deploy("AdminHandler", s));
        _listAccounts();

        _targetHandlers();
    }

    /// @dev Names each handler and its actions as the fuzzer's only targets.
    function _targetHandlers() private {
        bytes4[] memory market = new bytes4[](2);
        market[0] = MarketHandler.movePrice.selector;
        market[1] = MarketHandler.warp.selector;
        _target(address(marketHandler), market);
        bytes4[] memory trading = new bytes4[](3);
        trading[0] = TradingHandler.open.selector;
        trading[1] = TradingHandler.openBurst.selector;
        trading[2] = TradingHandler.sell.selector;
        _target(address(tradingHandler), trading);
        bytes4[] memory settlement = new bytes4[](5);
        settlement[0] = SettlementHandler.liquidate.selector;
        settlement[1] = SettlementHandler.settle.selector;
        settlement[2] = SettlementHandler.refund.selector;
        settlement[3] = SettlementHandler.repay.selector;
        settlement[4] = SettlementHandler.mixedBatch.selector;
        _target(address(settlementHandler), settlement);
        _target(address(poolHandler), _poolActions());
        _target(address(adminHandler), _adminActions());
    }

    /// @dev The pool's money at the start.
    function _seed() internal pure virtual returns (uint64) {
        return SEED;
    }

    /// @dev Changes the markets' settings before the run, if a variant of the suite needs to. The planned settings
    ///      stay.
    function _prepareMarkets() internal virtual {}

    /// @dev BTC's three markets' leverages.
    function _leverages() internal pure returns (uint16[3] memory) {
        return [Defaults.LEVERAGE, L500, L100];
    }

    /// @dev The pool's actions the fuzzer calls.
    function _poolActions() internal pure virtual returns (bytes4[] memory pool) {
        pool = new bytes4[](5);
        pool[0] = PoolHandler.fund.selector;
        pool[1] = PoolHandler.withdraw.selector;
        pool[2] = PoolHandler.claim.selector;
        pool[3] = PoolHandler.sweepFees.selector;
        pool[4] = PoolHandler.donate.selector;
    }

    /// @dev The admin's actions the fuzzer calls.
    function _adminActions() internal pure virtual returns (bytes4[] memory admin) {
        admin = new bytes4[](5);
        admin[0] = AdminHandler.brake.selector;
        admin[1] = AdminHandler.configure.selector;
        admin[2] = AdminHandler.breaker.selector;
        admin[3] = AdminHandler.freeze.selector;
        admin[4] = AdminHandler.actAsStranger.selector;
    }

    /// @notice 1. The token balance covers the pool, the pending fees and every claimable balance. It covers them
    ///         exactly, plus the tokens sent straight to the contract, which the books never count.
    function invariant_01_TheBalanceHoldsTheBooks() external view {
        _assertNoBreach();
        PoolState memory pool = _pool();
        assertEq(
            usdg.balanceOf(address(flashOption)),
            uint256(pool.total) + pool.feesPending + pool.totalClaimable + store.donations(),
            "invariant 1: the balance is the pool, the pending fees, the claimable balances and the donations"
        );
    }

    /// @notice 2. The held margin, the open max profit and the open count are the sums over the open bets, of the
    ///         stakes and caps their orders and terms set; and each open bet still holds its stake and cap.
    function invariant_02_TheOpenBooksMatchTheOpenBets() external view {
        _assertNoBreach();
        uint256 stakes;
        uint256 maxProfits;
        uint256 count;
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = store.idAt(i);
            Position memory p = LayoutReader.position(address(flashOption), id);
            if (p.status != Status.Open) continue;
            FlashOptionStore.Bet memory b = store.bet(id);
            assertEq(p.stake, b.stake, "invariant 2: an open bet holds the stake its order signed");
            assertEq(p.capBps, b.capBps, "invariant 2: an open bet holds the cap its terms set");
            stakes += b.stake;
            maxProfits += Calculations.maxProfit(b.stake, b.capBps);
            ++count;
        }
        PoolState memory pool = _pool();
        assertEq(pool.lockedMargin, stakes, "invariant 2: the held margin is the sum of the open stakes");
        assertEq(pool.openMaxProfit, maxProfits, "invariant 2: the open max profit is the sum over the open bets");
        assertEq(pool.openPositions, count, "invariant 2: the open count is the number of open bets");
    }

    /// @notice 3. The IOU books are the sums over the IOUs, and the repay queue holds exactly them, in order. The total
    ///         owed and the IOU count match the owed bets; the head never passes the tail; and every place from the
    ///         head to the tail holds an IOU that knows its place, so the queue is as long as the IOU count.
    function invariant_03_TheIouBooksMatchTheQueue() external view {
        _assertNoBreach();
        PoolState memory pool = _pool();
        uint256 owed;
        uint256 count;
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = store.idAt(i);
            Position memory p = LayoutReader.position(address(flashOption), id);
            if (p.status != Status.Owed) continue;
            owed += p.owed;
            ++count;
            assertEq(LayoutReader.iouQueue(address(flashOption), p.queueSeq), id, "invariant 3: IOU keeps its place");
        }
        assertEq(pool.totalOwed, owed, "invariant 3: the total owed is the sum over the IOUs");
        assertEq(pool.owedPositions, count, "invariant 3: the IOU count is the number of IOUs");
        assertLe(pool.nextRepaySeq, pool.nextQueueSeq, "invariant 3: the head never passes the tail");
        for (uint64 seq = pool.nextRepaySeq; seq < pool.nextQueueSeq; ++seq) {
            Position memory p =
                LayoutReader.position(address(flashOption), LayoutReader.iouQueue(address(flashOption), seq));
            assertEq(uint256(p.status), uint256(Status.Owed), "invariant 3: every place in the queue holds an IOU");
            assertEq(p.queueSeq, seq, "invariant 3: every IOU in the queue knows its place");
        }
        assertEq(pool.nextQueueSeq - pool.nextRepaySeq, count, "invariant 3: the queue is as long as the IOU count");
    }

    /// @notice 4. Free money is never negative: the pool's total covers the stakes it holds.
    function invariant_04_FreeMoneyIsNeverNegative() external view {
        _assertNoBreach();
        PoolState memory pool = _pool();
        assertGe(pool.total, pool.lockedMargin, "invariant 4: the total covers the held margin");
    }

    /// @notice 5. While every bet was opened with the open gate at 10,000 bps or below, every winner is paid in full:
    ///         nobody is ever owed, and free money covers every open bet's max profit, after every open and at every
    ///         step. Withdrawals don't change this: a withdrawal must leave the open max profit covered above the
    ///         floor (§8.1). `validate` keeps the gate at 1 to 10,000 bps (ADR 0009), so this holds for the whole run;
    ///         only a campaign that switches the gate off in storage, as only an upgrade could, takes it out of play.
    function invariant_05_AtFullCoverNobodyIsOwed() external view {
        _assertNoBreach();
        if (store.openedBeyondFullCover()) {
            assertTrue(store.gateKeptOff(), "invariant 5: only a gate off in storage lets a bet in");
            return;
        }
        PoolState memory pool = _pool();
        assertEq(pool.totalOwed, 0, "invariant 5: nobody is owed while every open bet is covered");
        assertGe(pool.total - pool.lockedMargin, pool.openMaxProfit, "invariant 5: free money covers the open bets");
    }

    /// @notice 6. Seed recovery never passes 500 whole tokens in all, and no withdrawal leaves free money below the
    ///         floor plus every open bet's max profit: the handler checks each one that goes through, and every refused
    ///         one fails with the first check it breaks.
    function invariant_06_WithdrawalsKeepTheFloorAndTheCap() external view {
        _assertNoBreach();
        assertLe(_pool().seedRecovered, Defaults.SEED_RECOVERY_CAP, "invariant 6: seed recovery stays within its cap");
    }

    /// @notice 7. The total claimable is the sum of every account's claimable balance.
    function invariant_07_TheClaimableBooksMatchTheBalances() external view {
        _assertNoBreach();
        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            sum += LayoutReader.claimable(address(flashOption), accounts[i]);
        }
        assertEq(_pool().totalClaimable, sum, "invariant 7: the total claimable is the sum of the balances");
    }

    /// @notice 8. A status only moves forward, None → Open → (Owed →) Closed, so a closed id never opens
    ///         again: the handlers check every bet around every call. And no bet they opened ever loses its record.
    function invariant_08_AStatusOnlyMovesForward() external view {
        _assertNoBreach();
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            Status status = LayoutReader.position(address(flashOption), store.idAt(i)).status;
            assertTrue(status != Status.None, "invariant 8: an opened bet keeps its record");
        }
    }

    /// @notice 9. No bet pays its user more than stake × cap: what the user received for it, pushed or kept
    ///         claimable, never exceeds `stake × capBps / 10_000`. Fees only lower it.
    function invariant_09_NoBetPaysMoreThanItsCap() external view {
        _assertNoBreach();
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            FlashOptionStore.Bet memory b = store.bet(store.idAt(i));
            assertLe(b.received, (uint256(b.stake) * b.capBps) / 10_000, "invariant 9: a bet pays at most stake x cap");
        }
    }

    /// @notice 10. Only the relayers change bets, and money only goes to its owner. A stranger's call to any role-gated
    ///         function is refused for the role it lacks; the refund and repay, which anyone may call, come from any
    ///         account. Around every call, the handlers check that each known account's tokens plus claimable balance
    ///         changed by exactly what the contract's logs say it was paid, so a bet's payout reaches its own user and
    ///         nobody else gains. And every token in existence is held by the contract or a known account: none ever
    ///         leaked anywhere else.
    function invariant_10_MoneyOnlyGoesToItsOwner() external view {
        _assertNoBreach();
        uint256 held = usdg.balanceOf(address(flashOption));
        for (uint256 i; i < accounts.length; ++i) {
            held += usdg.balanceOf(accounts[i]);
        }
        assertEq(usdg.totalSupply(), held, "invariant 10: every token is held by the contract or a known account");
    }

    /// @notice 11. The payout circuit breaker holds. While it is tripped, nothing opens or sells; it trips only on
    ///         a call that counted profit past its limit; and an untripped breaker with a limit sits at or under it,
    ///         unless the limit was switched on or lowered since the last count. Settles and repays of bets already
    ///         open keep counting after a trip, by design (§8.11 step 4), so the window's net profit may then grow
    ///         past the limit: what the breaker stops is new risk.
    function invariant_11_TheBreakerHolds() external view {
        _assertNoBreach();
        Breaker memory b = LayoutReader.breaker(address(flashOption));
        if (b.maxNetProfit == 0 || b.tripped || store.limitTightened()) return;
        assertLe(b.profitOut, uint256(b.lossIn) + b.maxNetProfit, "invariant 11: an untripped breaker is within limit");
    }

    /// @notice 12. The contract never holds an allowance from anyone: stakes come in by EIP-3009, one authorisation
    ///         per order, and funding's allowance is spent in full (security checklist SIG-8).
    function invariant_12_NoAllowanceIsEverHeld() external view {
        _assertNoBreach();
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(usdg.allowance(accounts[i], address(flashOption)), 0, "invariant 12: no allowance stays behind");
        }
    }

    /// @notice 13. Every refusal a handler expects happens, with exactly the expected error, and everything else goes
    ///         through: the handlers record the first refusal that went otherwise, and a call they expect to go
    ///         through that the contract refuses fails the run (`fail_on_revert`).
    function invariant_13_EveryRefusalIsTheExpectedOne() external view {
        _assertNoBreach();
    }

    /// @notice 14. Every bet keeps its market's leverage. Each of BTC's three markets keeps the leverage of its key;
    ///         every bet stays on the market its order signed; and while the bet is open or owed it holds that
    ///         market's leverage, which its settle, sale and `getPosition` value it at (an IOU keeps it, though its
    ///         repayment is fixed), and once closed none.
    function invariant_14_EveryBetKeepsItsMarketsLeverage() external view {
        _assertNoBreach();
        uint16[3] memory leverages = _leverages();
        for (uint256 k; k < leverages.length; ++k) {
            assertEq(
                LayoutReader.market(address(flashOption), _indexOf(leverages[k])).leverage,
                leverages[k],
                "invariant 14: a market keeps its key's leverage"
            );
        }
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = store.idAt(i);
            Position memory p = LayoutReader.position(address(flashOption), id);
            uint16 signed = store.bet(id).leverage;
            assertEq(p.marketIdx, _indexOf(signed), "invariant 14: a bet stays on the market its order signed");
            assertEq(
                p.leverage,
                p.status == Status.Closed ? 0 : signed,
                "invariant 14: an open or owed bet holds its market's leverage, a closed one none"
            );
        }
    }

    /// @notice After every run, the pool winds down, and nobody's money is stuck, whatever the run did (security
    ///         checklist TEST-1, DOS-1). Every brake that stops an ending or a payment is released, every open bet
    ///         ended, every IOU repaid, every waiting payout claimed and the fees swept. The books must then hold
    ///         nothing but the free money: no bet open or owed, nothing claimable or pending, and the contract's
    ///         balance exactly the pool's total and the donations. Every bet is closed, none paid more than its cap.
    function afterInvariant() external {
        settlementHandler.windDown();
        _assertNoBreach();
        PoolState memory pool = _pool();
        assertEq(pool.openPositions, 0, "wind-down: no bet is open");
        assertEq(pool.lockedMargin, 0, "wind-down: no stake is held");
        assertEq(pool.openMaxProfit, 0, "wind-down: no max profit is open");
        assertEq(pool.totalOwed, 0, "wind-down: nobody is owed");
        assertEq(pool.owedPositions, 0, "wind-down: no IOU is left");
        assertEq(pool.nextRepaySeq, pool.nextQueueSeq, "wind-down: the queue is empty");
        assertEq(pool.totalClaimable, 0, "wind-down: nothing waits to be claimed");
        assertEq(pool.feesPending, 0, "wind-down: no fee is pending");
        assertEq(
            usdg.balanceOf(address(flashOption)),
            uint256(pool.total) + store.donations(),
            "wind-down: the balance is the pool's free money and the donations"
        );
        uint256 n = store.betCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = store.idAt(i);
            Status status = LayoutReader.position(address(flashOption), id).status;
            assertEq(uint256(status), uint256(Status.Closed), "wind-down: every bet is closed");
            FlashOptionStore.Bet memory b = store.bet(id);
            assertLe(b.received, (uint256(b.stake) * b.capBps) / 10_000, "wind-down: no bet paid more than its cap");
        }
    }

    /// @dev Every check a handler runs during a call records its first breach in the store; there must be none.
    function _assertNoBreach() internal view {
        assertEq(store.firstBreach(), "", "a check run during a call found a breach");
    }

    /// @dev Lists every account the set-up or the handlers use, each once: the role holders and recipients, the
    ///      bettors, the stranger and the funder.
    function _listAccounts() private {
        address[11] memory named = _everyone();
        for (uint256 i; i < named.length; ++i) {
            _listAccount(named[i]);
        }
        for (uint256 i; i < bettors.length; ++i) {
            _listAccount(bettors[i]);
        }
        _listAccount(stranger);
        _listAccount(funder);
    }

    function _listAccount(address account) private {
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == account) return;
        }
        accounts.push(account);
    }

    function _pool() internal view returns (PoolState memory) {
        return LayoutReader.pool(address(flashOption));
    }

    /// @dev The index of BTC's market at `marketLeverage`.
    function _indexOf(uint16 marketLeverage) internal view returns (uint16) {
        return LayoutReader.marketIndexPlusOne(address(flashOption), Defaults.BTC, marketLeverage) - 1;
    }

    /// @dev Deploys the handler `name` from its build artifact. `new` would copy each handler's creation code into this
    ///      contract, which already carries the contract's and the token's (Base_Test), and the whole would pass the
    ///      98,304-byte limit every deployment here must keep (foundry.toml `code_size_limit`).
    function _deploy(string memory name, HandlerSetup memory s) private returns (address) {
        return deployCode(string.concat(name, ".sol:", name), abi.encode(s));
    }

    /// @dev Makes `handler` a target of the fuzzer, with only `selectors` called. Naming the targets keeps the fuzzer
    ///      off every other contract the set-up deployed, the token and the contract itself included.
    function _target(address handler, bytes4[] memory selectors) private {
        targetContract(handler);
        targetSelector(FuzzSelector({addr: handler, selectors: selectors}));
    }
}

/// @title SmallPool_Invariant_Test
/// @notice The same suite on a pool that can't pay its winners (docs/ARCHITECTURE.md §8.5, §8.7): $20 of free money,
///         below the floor, with the open gate off on every market and kept off. Winners the pool can't pay become
///         IOUs, of every leverage in one queue; a sale waits until nobody is owed, on any market; withdrawals stay
///         refused, no loser fee is taken below the floor, and repayments walk the queue as losers' money and top-ups
///         come in.
/// @dev Every invariant of `Leverage_Invariant_Test` runs here too, in a campaign of its own. Two actions are left out:
///      `fund`, whose top-ups would soon make the pool deep enough to pay everyone, so only losers' money comes in; and
///      `configure`, which could switch the gate back on and close the pool to new bets.
contract SmallPool_Invariant_Test is Leverage_Invariant_Test {
    /// @dev Every run starts with a crowd of winners about to expire: six $50 calls for a minute, two on each market at
    ///      its highest cap (4x, 2.5x and 2x), then a 40 bp jump: past the caps at 1000x and 500x, and 1.4x at 100x.
    ///      Settled, they win $150, $75 and $20 each against $20 of free money, so the first settle queues IOUs, and
    ///      the run explores from there: repayments, part payments, sales held back by the queue, and IOUs of three
    ///      leverages in one queue.
    function setUp() public override {
        super.setUp();
        // `_prepareMarkets` switched every gate off before the store existed; `configure` keeps them off.
        store.setGateKeptOff();
        uint16[3] memory leverages = _leverages();
        for (uint256 i; i < 6; ++i) {
            ConfigParams memory c = LeverageConfigs.planned(leverages[i / 2]);
            OpenOrder memory o = _order(bettors[i % bettors.length], store.newId());
            o.leverage = leverages[i / 2];
            o.stake = 50e6;
            OpenTerms memory t = _terms();
            t.floorBps = c.floorMinBps;
            t.capBps = c.capMaxBps;
            _open(bettorKeys[i % bettorKeys.length], o, t);
            store.addBet(o.positionId, o.user, o.stake, t.capBps, o.leverage, t.entryPublishTime + o.durationSecs);
        }
        // The crowd's max profit is far beyond free money, so invariant 5 is out of play here.
        store.setOpenedBeyondFullCover();
        int64 price = store.price();
        store.setPrice(price + (price * 40) / 10_000);
    }

    /// @notice No action is dead code (security checklist TEST-1): driven in a fixed order, 40 rounds of every action,
    ///         each one does its work at least once, and the stranger and every mixed batch are refused every time.
    ///         Each market opens bets, ends bets and owes IOUs. The IOUs form and are repaid, and the wind-down then
    ///         finds nothing stuck. A handler path that quietly stopped working, such as a filter that never finds a
    ///         bet to settle, fails here even when every invariant still holds.
    function test_EveryActionDoesItsWork() external {
        for (uint256 round; round < 40; ++round) {
            uint256 r = uint256(keccak256(abi.encode("every action", round)));
            marketHandler.movePrice(int256(r % 80_001) - 40_000, uint8(r >> 8));
            marketHandler.warp(r >> 16);
            tradingHandler.open(r >> 24, r >> 32);
            tradingHandler.openBurst(r >> 40);
            tradingHandler.sell(r >> 48, r >> 56);
            settlementHandler.liquidate(r >> 64);
            settlementHandler.settle(r >> 72);
            settlementHandler.refund(r >> 80);
            settlementHandler.repay(r >> 88);
            settlementHandler.mixedBatch(r >> 184);
            poolHandler.fund(r >> 96);
            poolHandler.withdraw(r >> 104, r >> 112);
            poolHandler.claim(r >> 120);
            poolHandler.sweepFees(r >> 128);
            poolHandler.donate(r >> 136);
            adminHandler.brake(r >> 144);
            adminHandler.configure(r >> 152);
            adminHandler.breaker(r >> 160);
            adminHandler.freeze(r >> 168);
            adminHandler.actAsStranger(r >> 176);
        }
        _assertDid(marketHandler, "movePrice");
        _assertDid(marketHandler, "warp");
        _assertDid(tradingHandler, "open");
        _assertDid(tradingHandler, "openBurst");
        _assertDid(tradingHandler, "sell");
        _assertDid(settlementHandler, "liquidate");
        _assertDid(settlementHandler, "settle");
        _assertDid(settlementHandler, "refund");
        _assertDid(settlementHandler, "repay");
        _assertDid(poolHandler, "fund");
        _assertDid(poolHandler, "withdraw");
        _assertDid(poolHandler, "claim");
        _assertDid(poolHandler, "sweepFees");
        _assertDid(poolHandler, "donate");
        _assertDid(adminHandler, "brake");
        _assertDid(adminHandler, "configure");
        _assertDid(adminHandler, "breaker");
        _assertDid(adminHandler, "freeze");
        assertEq(adminHandler.calls("actAsStranger"), adminHandler.refused("actAsStranger"), "the stranger is refused");
        _assertEveryMarketDidItsWork();
        this.afterInvariant();
    }

    /// @dev Every mixed batch was refused, and each of BTC's three markets opened bets beyond the crowd's two, ended
    ///      some and owed IOUs.
    function _assertEveryMarketDidItsWork() private view {
        assertGt(settlementHandler.refused("mixedBatch"), 0, "mixed batches were sent");
        assertEq(settlementHandler.calls("mixedBatch"), settlementHandler.refused("mixedBatch"), "a mix is refused");
        uint16[3] memory leverages = _leverages();
        for (uint256 k; k < leverages.length; ++k) {
            string memory market = string.concat(" at ", vm.toString(leverages[k]), "x");
            assertGt(store.openedAt(leverages[k]), 2, string.concat("bets opened beyond the crowd", market));
            assertGt(store.endedAt(leverages[k]), 0, string.concat("bets ended", market));
            assertGt(store.owedAt(leverages[k]), 0, string.concat("IOUs formed", market));
        }
    }

    /// @dev `handler`'s `action` did its work at least once.
    function _assertDid(BaseHandler handler, string memory action) private view {
        assertGt(handler.done(action), 0, string.concat(action, " never did its work"));
    }

    /// @dev $20: below the floor, and too little to pay the winners.
    function _seed() internal pure override returns (uint64) {
        return 20e6;
    }

    /// @dev The open gate off on every market, and kept off: bets may promise more than the pool holds. `validate`
    ///      refuses the gate off (ADR 0009), so each market is set at its planned values and its gate switched off
    ///      in storage, as only an upgrade could do now; `configure` switches it off again after each change.
    function _prepareMarkets() internal override {
        uint16[3] memory leverages = _leverages();
        for (uint256 k; k < leverages.length; ++k) {
            ConfigParams memory c = LeverageConfigs.planned(leverages[k]);
            c.enabled = true;
            vm.prank(users.operator);
            flashOption.setConfig(Defaults.BTC, leverages[k], c);
            _switchOffOpenGate(address(flashOption), Defaults.BTC, leverages[k]);
        }
    }

    function _poolActions() internal pure override returns (bytes4[] memory pool) {
        pool = new bytes4[](4);
        pool[0] = PoolHandler.withdraw.selector;
        pool[1] = PoolHandler.claim.selector;
        pool[2] = PoolHandler.sweepFees.selector;
        pool[3] = PoolHandler.donate.selector;
    }

    function _adminActions() internal pure override returns (bytes4[] memory admin) {
        admin = new bytes4[](4);
        admin[0] = AdminHandler.brake.selector;
        admin[1] = AdminHandler.breaker.selector;
        admin[2] = AdminHandler.freeze.selector;
        admin[3] = AdminHandler.actAsStranger.selector;
    }
}
