// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IManicFlashOptionErrors as Errors} from "../../../src/interfaces/IManicFlashOptionErrors.sol";
import {IManicFlashOptionTrading} from "../../../src/interfaces/IManicFlashOptionTrading.sol";
import {OpenOrder, OpenTerms, SellOrder, SellTerms, StakeAuth} from "../../../src/types/OrderTypes.sol";
import {DurationRule, Market, PoolState, Position, Side, Status} from "../../../src/types/StorageTypes.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {Calculations} from "../../utils/Calculations.sol";
import {Defaults} from "../../utils/Defaults.sol";
import {LayoutReader} from "../../utils/LayoutReader.sol";
import {OrderSigner} from "../../utils/OrderSigner.sol";
import {UsdgSigner} from "../../utils/UsdgSigner.sol";
import {BaseHandler, HandlerSetup} from "./BaseHandler.sol";

/// @title TradingHandler
/// @notice The opener relayer's side of the contract: a bettor opens a bet on one of BTC's three markets (1000x, 500x
///         or 100x), or sells one early, signed as the backend signs it.
/// @dev Each order draws its market, and its terms inside that market's bounds, and prices at the current tick, so the
///      checks a relayer can't fail (signature, bounds, tick time, `notBefore`, the sale's window and amounts) pass,
///      and the call must go through. A sale is quoted with its bet's own market's settings, and valued at the bet's
///      own leverage. The exceptions are the refusals the handler predicts from the state, in the contract's check
///      order (docs/ARCHITECTURE.md §8.2, §8.3): the halt, the market switched off or paused, a tripped breaker, then
///      for an open the gate (which counts every market's bets, on the one pool) and the token's pause or the bettor's
///      freeze at the stake pull, and for a sale anyone still owed. Each must be refused with exactly its error.
contract TradingHandler is BaseHandler {
    /// @dev Which side a bet takes: drawn from its seed, or set.
    uint256 internal constant ANY_SIDE = 0;
    uint256 internal constant CALL = 1;
    uint256 internal constant PUT = 2;

    constructor(HandlerSetup memory s) BaseHandler(s) {}

    /// @notice A random bettor opens a bet on one of the three markets: any duration, side, θ, floor and cap that
    ///         market allows, at a tick up to its maximum age, for any stake the open gate lets in.
    /// @param seed Picks the market and the bettor, and draws the terms.
    /// @param stake The stake to try, bounded to the market's range, then shrunk to what the gate lets in.
    function open(uint256 seed, uint256 stake) external instrumented("open") {
        Market memory m = _market(_pickLeverage(_pick(seed, 12, 0, 2)));
        _finish(_openOne(m, seed, stake, _pick(seed, 1, 0, 4), _pick(seed, 2, 0, m.entryMaxAgeSecs), ANY_SIDE));
    }

    /// @notice Two to five bets arrive in the same second on one of the three markets, from any bettors, priced at the
    ///         same tick and with the same duration. So they also expire together and settle as one batch, the way
    ///         bets queue up behind a busy relayer. Half the bursts are a crowd on one side, which wins or loses
    ///         together. Bursts on different markets in the same second expire together too, and settle in a batch per
    ///         market.
    /// @param seed Draws the burst's market, size, duration, tick and side, and each bet's bettor, terms and stake.
    function openBurst(uint256 seed) external instrumented("openBurst") {
        Market memory m = _market(_pickLeverage(_pick(seed, 5, 0, 2)));
        uint256 rule = _pick(seed, 1, 0, 4);
        uint256 age = _pick(seed, 2, 0, m.entryMaxAgeSecs);
        uint256 count = _pick(seed, 3, 2, 5);
        uint256 side = _pick(seed, 4, 0, 3); // ANY_SIDE, CALL or PUT; 3 is ANY_SIDE too
        if (side == 3) side = ANY_SIDE;
        Outcome result = Outcome.Skipped;
        for (uint256 i; i < count; ++i) {
            uint256 betSeed = uint256(keccak256(abi.encode(seed, "burst", i)));
            Outcome one = _openOne(m, betSeed, betSeed >> 128, rule, age, side);
            // The burst is done if any bet opened, refused if every bet that tried was refused.
            if (one == Outcome.Done || result == Outcome.Skipped) result = one;
        }
        _finish(result);
    }

    /// @dev Opens one bet on the market `m`, or checks its refusal: a random bettor, with `m`'s duration rule
    ///      `ruleIndex`, at the tick `age` seconds old, on `side` (`ANY_SIDE`: drawn), terms drawn from `seed`, and
    ///      `stake` bounded to the market and fitted to the gate.
    function _openOne(
        Market memory m,
        uint256 seed,
        uint256 stake,
        uint256 ruleIndex,
        uint256 age,
        uint256 side
    )
        private
        returns (Outcome)
    {
        DurationRule memory rule = m.durations[ruleIndex];
        if (!rule.enabled) return Outcome.Skipped;
        uint256 bettor = seed % bettors.length;
        (OpenOrder memory o, OpenTerms memory t) = _draft(m, rule, bettor, seed, stake, age);
        if (side != ANY_SIDE) o.side = side == CALL ? Side.Call : Side.Put;
        bool fits = _fitToGate(m, o, t);

        // Signed before the prank: hashing the order calls the contract (docs/CONVENTIONS.md §9).
        bytes memory signature = OrderSigner.sign(bettorKeys[bettor], flashOption.hashOpenOrder(o));
        StakeAuth memory a = _stakeAuth(bettorKeys[bettor], o);
        bytes memory refusal = _openRefusal(m, o.user, fits);
        if (refusal.length > 0) {
            (bool ok, bytes memory reason) =
                _attempt("open", users.opener, abi.encodeCall(IManicFlashOptionTrading.open, (o, signature, t, a)));
            // A tripped breaker stopping an open is invariant 11's; every other refusal is invariant 13's.
            _checkRefusal(bytes4(refusal) == Errors.BreakerTripped.selector ? 11 : 13, "open", ok, reason, refusal);
            return Outcome.Refused;
        }

        _mint(o.user, o.stake);
        vm.prank(users.opener);
        flashOption.open(o, signature, t, a);
        store.addBet(o.positionId, o.user, o.stake, t.capBps, o.leverage, t.entryPublishTime + o.durationSecs);
        _checkFullCover(m);
        return Outcome.Done;
    }

    /// @notice A bettor sells an open bet of any market early, at the current price, for amounts the relayer may
    ///         quote: a valuation up to what the bet pays at this price, at its own leverage, and what the pool can
    ///         pay, an early-sell fee up to its market's cap, and a minimum up to the sale amount.
    /// @param seed Picks the bet, the tick's age and the fee.
    /// @param valuation The valuation to try, bounded to what the bet pays now and the pool can pay.
    function sell(uint256 seed, uint256 valuation) external instrumented("sell") {
        int64 price = store.price();
        (bytes32 id, uint48 publishTime) = _sellable(price, seed);
        if (id == bytes32(0)) {
            _skip();
            return;
        }
        Position memory p = LayoutReader.position(address(flashOption), id);
        Market memory m = _marketOf(p);
        SellTerms memory t = _quote(m, p, price, publishTime, seed, valuation);
        SellOrder memory s = SellOrder({
            positionId: id,
            minAmount: uint64(_pick(seed, 10, 0, t.sellAmount)),
            notBefore: publishTime - uint48(_pick(seed, 11, 0, 10)),
            deadline: uint48(block.timestamp) + Defaults.ORDER_LIFETIME
        });

        // Signed before the prank: hashing the order calls the contract (docs/CONVENTIONS.md §9).
        bytes memory signature = OrderSigner.sign(_keyOf(p.user), flashOption.hashSellOrder(s));
        bytes memory refusal = _sellRefusal(m);
        if (refusal.length > 0) {
            (bool ok, bytes memory reason) =
                _attempt("sell", users.opener, abi.encodeCall(IManicFlashOptionTrading.sell, (s, signature, t)));
            _checkRefusal(bytes4(refusal) == Errors.BreakerTripped.selector ? 11 : 13, "sell", ok, reason, refusal);
            _refuse();
            return;
        }
        vm.prank(users.opener);
        flashOption.sell(s, signature, t);
        _done();
    }

    /// @dev The order and the terms of a bet by `bettor` with `rule`'s duration, at the current price and a tick `age`
    ///      seconds old, every other field drawn from `seed` inside the market's bounds.
    function _draft(
        Market memory m,
        DurationRule memory rule,
        uint256 bettor,
        uint256 seed,
        uint256 stake,
        uint256 age
    )
        private
        returns (OpenOrder memory o, OpenTerms memory t)
    {
        t.entryPrice = store.price();
        t.entryPublishTime = uint48(block.timestamp - age);
        t.thetaE7 = uint32(_pick(seed, 3, rule.thetaMinE7, rule.thetaMaxE7));
        t.floorBps = uint16(_pick(seed, 4, m.floorMinBps, m.floorMaxBps));
        t.capBps = uint16(_pick(seed, 5, t.floorBps > m.capMinBps ? t.floorBps : m.capMinBps, m.capMaxBps));

        o.positionId = store.newId();
        o.user = bettors[bettor];
        o.marketId = Defaults.BTC;
        o.leverage = m.leverage;
        o.side = _pick(seed, 6, 0, 1) == 0 ? Side.Call : Side.Put;
        o.stake = uint64(_bound(stake, m.minStake, m.maxStake));
        o.durationSecs = rule.durationSecs;
        // The order is signed first and priced after: the tick is at or after `notBefore`, the edge included.
        o.notBefore = t.entryPublishTime - uint48(_pick(seed, 7, 0, 10));
        o.deadline = uint48(block.timestamp) + Defaults.ORDER_LIFETIME;
    }

    /// @dev Shrinks the stake to the largest the open gate lets in, if the gate is on. Returns false when even the
    ///      market's smallest stake doesn't fit, which leaves the stake at that smallest one.
    function _fitToGate(Market memory m, OpenOrder memory o, OpenTerms memory t) private view returns (bool) {
        if (m.maxExposureBps == 0) return true;
        PoolState memory pool = _pool();
        uint256 limit = (uint256(pool.total - pool.lockedMargin) * m.maxExposureBps) / 10_000;
        uint256 room = limit > pool.openMaxProfit ? limit - pool.openMaxProfit : 0;
        // The largest stake whose max profit, stake × (cap − 1) rounded down, fits in the room.
        uint256 widest = (room * 10_000) / (t.capBps - 10_000);
        if (o.stake <= widest) return true;
        if (widest < m.minStake) {
            o.stake = m.minStake;
            return false;
        }
        o.stake = uint64(widest);
        assert(Calculations.maxProfit(o.stake, t.capBps) <= room);
        return true;
    }

    /// @dev The error the contract must refuse the open with, in its check order, or "" if it must go through.
    function _openRefusal(Market memory m, address user, bool fits) private view returns (bytes memory) {
        if (LayoutReader.halted(address(flashOption))) return abi.encodeWithSelector(Errors.Halted.selector);
        if (!m.enabled) return abi.encodeWithSelector(Errors.LeverageDisabled.selector);
        if (m.paused) return abi.encodeWithSelector(Errors.LeveragePaused.selector);
        if (LayoutReader.breaker(address(flashOption)).tripped) {
            return abi.encodeWithSelector(Errors.BreakerTripped.selector);
        }
        PoolState memory pool = _pool();
        if (pool.totalOwed > m.maxTotalOwed) return abi.encodeWithSelector(Errors.OpenBlockedTotalOwed.selector);
        if (!fits) return abi.encodeWithSelector(Errors.OpenBlockedExposure.selector);
        // The stake pull, after the books are written: the token refuses it while paused, or while the bettor is
        // frozen, and the whole open reverts with the token's error.
        if (usdg.paused()) return abi.encodeWithSelector(MockUSDG.ContractPaused.selector);
        if (usdg.isFrozen(user)) return abi.encodeWithSelector(MockUSDG.AddressFrozen.selector);
        return "";
    }

    /// @dev §12 #5: an open the gate let in at up to 10,000 bps leaves free money covering every open bet's max
    ///      profit. One let in beyond that, with the gate off or above 10,000, takes #5 out of play for the rest of the
    ///      run. `validate` keeps the gate at 1 to 10,000 bps (ADR 0009), so only a campaign that switches it off in
    ///      storage (`FlashOptionStore.gateKeptOff`) gets here.
    function _checkFullCover(Market memory m) private {
        if (m.maxExposureBps == 0 || m.maxExposureBps > 10_000) {
            store.setOpenedBeyondFullCover();
            return;
        }
        PoolState memory pool = _pool();
        if (pool.total - pool.lockedMargin < pool.openMaxProfit) {
            store.recordBreach(5, "open: after a gated open, free money doesn't cover the open max profit");
        }
    }

    /// @dev A random open bet, of any market, that can be sold now at `price`, and a tick time the sale may use; a zero
    ///      id if none.
    function _sellable(int64 price, uint256 seed) private view returns (bytes32 id, uint48 tick) {
        uint256 n = store.betCount();
        bytes32[] memory ids = new bytes32[](n);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            bytes32 candidate = store.idAt(i);
            Position memory p = LayoutReader.position(address(flashOption), candidate);
            if (p.status != Status.Open || _touched(price, p)) continue;
            (uint256 lo, uint256 hi) = _saleTicks(_marketOf(p), p);
            if (lo <= hi) ids[count++] = candidate;
        }
        if (count == 0) return (bytes32(0), 0);
        id = ids[seed % count];
        Position memory chosen = LayoutReader.position(address(flashOption), id);
        (uint256 first, uint256 last) = _saleTicks(_marketOf(chosen), chosen);
        tick = uint48(_pick(seed, 8, first, last));
    }

    /// @dev The tick times a sale of `p` may use now, by its market `m`'s settings: inside its sell window, from
    ///      `sellMinDelaySecs` after its start to more than `sellCutoffSecs` before its end, no older than the market
    ///      allows, not after now, and only while the bet hasn't ended. Empty when `lo > hi`.
    function _saleTicks(Market memory m, Position memory p) private view returns (uint256 lo, uint256 hi) {
        uint256 end = uint256(p.startTime) + p.durationSecs;
        if (block.timestamp >= end || end <= m.sellCutoffSecs) return (1, 0);
        lo = uint256(p.startTime) + m.sellMinDelaySecs;
        if (block.timestamp > m.entryMaxAgeSecs && block.timestamp - m.entryMaxAgeSecs > lo) {
            lo = block.timestamp - m.entryMaxAgeSecs;
        }
        hi = end - m.sellCutoffSecs - 1;
        if (block.timestamp < hi) hi = block.timestamp;
    }

    /// @dev A sale's terms at `price`: a valuation up to what `p` pays at this price and what the pool can pay it (its
    ///      free money plus the bet's own stake), and a sale amount below it by at most its market `m`'s fee cap.
    function _quote(
        Market memory m,
        Position memory p,
        int64 price,
        uint48 publishTime,
        uint256 seed,
        uint256 valuation
    )
        private
        view
        returns (SellTerms memory t)
    {
        uint256 most = _worth(p, price);
        PoolState memory pool = _pool();
        uint256 payable_ = uint256(pool.total - pool.lockedMargin) + p.stake;
        if (payable_ < most) most = payable_;
        t.price = price;
        t.publishTime = publishTime;
        t.valuation = uint64(_bound(valuation, 0, most));
        t.sellAmount = t.valuation - uint64(_pick(seed, 9, 0, (uint256(t.valuation) * m.maxSellFeeBps) / 10_000));
    }

    /// @dev What `p` pays at `price`: its stake × g at its own leverage, rounded down, from `Calculations` (never
    ///      `LeverageMath`).
    function _worth(Position memory p, int64 price) private pure returns (uint256) {
        return
            (uint256(p.stake) * Calculations.gBps(p.entryPrice, price, p.side, p.leverage, p.floorBps, p.capBps))
                / 10_000;
    }

    /// @dev Whether `price` touches `p`'s liquidation line, equality included.
    function _touched(int64 price, Position memory p) private pure returns (bool) {
        return p.side == Side.Call ? price <= p.liqPrice : price >= p.liqPrice;
    }

    /// @dev The error the contract must refuse a sale with, in its check order, or "" if it must go through. The
    ///      handler only quotes sales that pass every check on the order and its amounts, so what's left is the brakes
    ///      (the halt, and those of the bet's own market `m`) and the IOU queue: no sale while anyone is owed, on any
    ///      market.
    function _sellRefusal(Market memory m) private view returns (bytes memory) {
        if (LayoutReader.halted(address(flashOption))) return abi.encodeWithSelector(Errors.Halted.selector);
        if (!m.enabled) return abi.encodeWithSelector(Errors.LeverageDisabled.selector);
        if (m.paused) return abi.encodeWithSelector(Errors.LeveragePaused.selector);
        if (LayoutReader.breaker(address(flashOption)).tripped) {
            return abi.encodeWithSelector(Errors.BreakerTripped.selector);
        }
        if (_pool().totalOwed != 0) return abi.encodeWithSelector(Errors.QueueNotEmpty.selector);
        return "";
    }

    /// @dev The signing key of a bettor.
    function _keyOf(address bettor) private view returns (uint256) {
        for (uint256 i; i < bettors.length; ++i) {
            if (bettors[i] == bettor) return bettorKeys[i];
        }
        revert("not a bettor");
    }

    /// @dev The bettor's EIP-3009 authorisation for the contract to receive exactly the stake, with the position id as
    ///      its nonce, as `Base_Test._stakeAuth` builds it.
    function _stakeAuth(uint256 key, OpenOrder memory o) private view returns (StakeAuth memory a) {
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + Defaults.AUTH_LIFETIME;
        UsdgSigner.Authorization memory auth = UsdgSigner.Authorization({
            from: o.user,
            to: address(flashOption),
            value: o.stake,
            validAfter: a.validAfter,
            validBefore: a.validBefore,
            nonce: o.positionId
        });
        a.signature = UsdgSigner.sign(key, UsdgSigner.authorizationDigest(address(usdg), auth, true));
    }
}
