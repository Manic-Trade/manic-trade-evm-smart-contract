#!/usr/bin/env python3
"""Derives every expected number of the scenario tests (test/scenarios/) from the reference model.

The scenario tests run bets end to end and assert their numbers to the base unit: lines, g, payouts, fees, the splits
of settlements, sales and repayments, and the pool's books. This file works each of those numbers out again from the
test's inputs (prices, stakes, settings and the pool's starting books). It uses only the functions of
flash_option_math.py and a small simulation of the pool's books, which moves them as docs/MATH.md §6 to §10 say.

- One class per test contract, named after it, holds one function per test, named after the test. Each function
  returns a `Derivation`: the numbers the test asserts, each with a label, and notes that show the working.
- Each step runs the model's checks in the contract's order. A refusal the test expects must be the model's refusal
  too, with the same error name, or the derivation stops with a `Disagreement`.

Usage, from the repository root:

    python3 model/scenarios.py            # print every derivation
    python3 model/scenarios.py NAME ...   # print the tests whose name contains NAME
    python3 model/scenarios.py --check    # exit 1 unless every derived number is a literal of its test

`--check` reads the test files. A test's body is its own code, the helpers of its file that it calls, and its
contract's setUp. Every derived number must appear there as an integer literal. Literals are compared by value: `_`
separators, `e` notation and a leading minus sign are read, and array subscripts are skipped. Every other integer
literal there must be listed by the test as an input, or as not derived with a reason. The check then prints the
coverage, file by file.

Python 3.9 or later, standard library only.
"""

import os
import re
import sys
import textwrap
from decimal import Decimal
from types import SimpleNamespace

import flash_option_math as m

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- The tests' inputs (test/utils/Examples.sol, test/utils/Defaults.sol, test/SettlementBase.t.sol) ---------------

P0 = 8_388_400_000_000  # $83,884 at exponent -8: the entry price of every bet
BP = 838_840_000  # 1 bp of P0, exactly
USD = 100_000_000  # $1 at exponent -8
TOKEN = 1_000_000  # one whole token (6 decimals)
STAKE = 10_000_000  # the base bet's stake, $10
POOL_FLOOR = 500_000_000  # the floor every pool starts with, $500
FREE = 1_500_000_000  # the free money the settlement tests' pool starts with, $1,500
START = 1_000  # the time of a test's first open; any value gives the same numbers
CALL, PUT = m.CALL, m.PUT

#: The base bet: $10 for 60 seconds, θ 3 bp, floor 1.3x, cap 4x.
BASE = {"stake": STAKE, "duration": 60, "theta": 3_000, "floor": 13_000, "cap": 40_000}
#: The tier example bet (`_example`, FlashOptionShared.sol): θ, floor and cap at 500x and at 100x.
EXAMPLE = {500: (5_250, 11_500, 25_000), 100: (6_600, 10_300, 20_000)}

#: The named constants above, as the test files declare them: `--check` reads each one and compares.
SOL_CONSTANTS = (
    ("test/utils/Examples.sol", "P0", P0),
    ("test/utils/Examples.sol", "BP", BP),
    ("test/utils/Examples.sol", "USD", USD),
    ("test/utils/Examples.sol", "STAKE", STAKE),
    ("test/utils/Defaults.sol", "STAKE", BASE["stake"]),
    ("test/utils/Defaults.sol", "DURATION", BASE["duration"]),
    ("test/utils/Defaults.sol", "THETA", BASE["theta"]),
    ("test/utils/Defaults.sol", "FLOOR_BPS", BASE["floor"]),
    ("test/utils/Defaults.sol", "CAP_BPS", BASE["cap"]),
    ("test/utils/Defaults.sol", "POOL_FLOOR", POOL_FLOOR),
    ("test/utils/Defaults.sol", "LEVERAGE", 1000),
    ("test/SettlementBase.t.sol", "FREE", FREE),
)


# --- Writing numbers --------------------------------------------------------------------------------------------------


def num(value):
    """An integer with thousands separators."""
    return "{:,}".format(value)


def move(price):
    """`price` as a move from P0: in whole dollars or whole bps where it is one, else in price units."""
    diff = price - P0
    if diff == 0:
        return "P0"
    sign = "+" if diff > 0 else "-"
    size = abs(diff)
    if size % USD == 0:
        return "P0 %s $%s" % (sign, num(size // USD))
    if size % BP == 0:
        return "P0 %s %d bp" % (sign, size // BP)
    return "P0 %s %s" % (sign, num(size))


def at(price):
    """A price, with its move from P0."""
    return "%s (%s)" % (num(price), move(price))


def up(bps):
    """`_up`: `bps` whole bps above P0."""
    return P0 + bps * BP


def down(bps):
    """`_down`: `bps` whole bps below P0."""
    return P0 - bps * BP


def favour(side, bps):
    """`_favour`: `bps` whole bps from P0 in the bet's favour (against it when negative)."""
    return up(bps) if side == CALL else down(bps)


def dollars(amount):
    """`Examples.priceAt`: `amount` whole dollars from P0."""
    return P0 + amount * USD


SIDE = {CALL: "long", PUT: "short"}


# --- What a test derives ------------------------------------------------------------------------------------------


class Disagreement(Exception):
    """The model and a scenario test disagree on a refusal: the test expects one the model does not make, or another
    error."""


class Derivation:
    """What one scenario test derives: the numbers it asserts, each with a label, and notes that show the working."""

    def __init__(self):
        self.lines = []  # ("note", text) and ("number", label, value), in order

    def note(self, text):
        """A line of the working."""
        self.lines.append(("note", text))

    def number(self, label, value):
        """A number the test asserts. `--check` requires it as a literal of the test."""
        self.lines.append(("number", label, value))
        return value

    def numbers(self):
        """The derived numbers, as (label, value) pairs."""
        return [(line[1], line[2]) for line in self.lines if line[0] == "number"]

    def refused(self, what, error, step, *args, **kwargs):
        """`step(*args, **kwargs)` must be refused with `error`, as the test expects. A refused step changes
        nothing."""
        refusal(what, error, step, *args, **kwargs)
        self.note("%s: refused, %s" % (what, error))


def refusal(what, error, step, *args, **kwargs):
    """`step(*args, **kwargs)` must be refused with `error`, as the test expects; a `Disagreement` otherwise."""
    try:
        step(*args, **kwargs)
    except m.Revert as e:
        if e.name != error:
            raise Disagreement("%s: the test expects %s, the model gives %s" % (what, error, e.name))
        return
    raise Disagreement("%s: the test expects %s, the model accepts it" % (what, error))


def scenario(literals=None):
    """Marks a test's derivation. `literals` maps each integer literal of the test's own body that is not derived to
    what it is: an input, or "not derived: " and the reason."""

    def mark(fn):
        fn.literals = literals or {}
        return staticmethod(fn)

    return mark


# --- The markets' settings (docs/MATH.md §3) --------------------------------------------------------------------------


def rule(duration, theta_min, theta_max):
    """An enabled duration rule."""
    return m.DurationRule(duration, theta_min, theta_max, True)


def launch_rule(duration, theta):
    """`Examples.rule`: a θ range of ±25% around `theta`, rounded down."""
    return rule(duration, theta * 3 // 4, theta * 5 // 4)


def launch_config(gate):
    """The launch settings (`Examples.launchConfig`), switched on, with the open gate at `gate` bps (0: off).
    `Defaults.marketConfig()` is the same with the gate at 100%."""
    return m.ConfigParams(
        enabled=True, entryMaxAgeSecs=5, clockSkewSecs=5, floorMinBps=11_000, floorMaxBps=15_000, capMinBps=15_000,
        capMaxBps=40_000, maxSellFeeBps=600, sellMinDelaySecs=0, sellCutoffSecs=2, maxExposureBps=gate,
        minStake=TOKEN, maxStake=50 * TOKEN, maxTotalOwed=m.UINT64_MAX,
        durations=(launch_rule(60, 3_000), launch_rule(120, 4_190), launch_rule(180, 4_930), launch_rule(240, 5_470),
                   launch_rule(300, 5_880)),
    )


def with_rule(c, index, new_rule):
    """`c` with duration rule `index` replaced."""
    durations = list(c.durations)
    durations[index] = new_rule
    return c._replace(durations=tuple(durations))


def tier_bounds(leverage):
    """`LeverageConfigs.tierBounds`: the launch settings, gate at 100%, with the tier's floors and caps."""
    floor_min, floor_max, cap_min, cap_max = {500: (10_250, 12_500, 15_000, 25_000),
                                              100: (10_050, 10_500, 15_000, 20_000)}[leverage]
    return launch_config(10_000)._replace(floorMinBps=floor_min, floorMaxBps=floor_max, capMinBps=cap_min,
                                          capMaxBps=cap_max)


#: The tier lines per duration (`LeverageConfigs.tierConfig`).
TIER_RULES = {
    500: (rule(60, 2_490, 6_750), rule(120, 3_476, 9_430), rule(180, 4_097, 11_090), rule(240, 4_547, 10_940),
          rule(300, 4_887, 11_760)),
    100: (rule(60, 2_601, 9_000), rule(120, 3_629, 12_570), rule(180, 4_275, 14_790), rule(240, 4_743, 16_410),
          rule(300, 5_100, 17_640)),
}


def tier_config(leverage, gate=0):
    """The tier settings (`LeverageConfigs.tierConfig`), with the open gate as `_tierConfig` stores it: off."""
    return tier_bounds(leverage)._replace(durations=TIER_RULES[leverage], maxExposureBps=gate)


def widest_line(leverage):
    """The widest line `leverage` allows: the largest θ with θ × L < 10^7 (docs/MATH.md §3.1), which the model's
    `theta_within_limit` confirms."""
    widest = (m.E7 - 1) // leverage
    assert m.theta_within_limit(widest, leverage) and not m.theta_within_limit(widest + 1, leverage)
    return widest


def five_second_tier_config(leverage):
    """`_tierConfigWithFiveSeconds`: the tier settings, gate off, with a 5-second rule up to the widest line in the
    4-minute slot."""
    return with_rule(tier_config(leverage), 3, rule(5, 1_000, widest_line(leverage)))


def options_config(leverage):
    """`_options` (FlashOptionShared.sol): the tier floors and caps, the gate off, its own lines per duration, and a
    5-second rule (θ 0.1 to 0.5 bp) in the 4-minute slot."""
    if leverage == 500:
        durations = (rule(60, 2_490, 11_760), rule(120, 2_490, 11_760), rule(180, 2_490, 11_760), rule(5, 1_000, 5_000),
                     rule(300, 2_490, 11_760))
    else:
        durations = (rule(60, 2_601, 9_000), rule(120, 3_629, 12_570), rule(180, 4_275, 14_790), rule(5, 1_000, 5_000),
                     rule(300, 5_100, 17_640))
    return tier_bounds(leverage)._replace(durations=durations, maxExposureBps=0)


def sent(c):
    """`c` as `createMarket` and `setConfig` receive it: a gate that is off goes in at 100% (`validate` refuses 0)."""
    return c if c.maxExposureBps else c._replace(maxExposureBps=10_000)


def example(leverage, **changes):
    """The tier example bet's terms at `leverage` (`_example`), with any term changed."""
    theta, floor, cap = EXAMPLE[leverage]
    terms = dict(BASE, theta=theta, floor=floor, cap=cap)
    terms.update(changes)
    return terms


# --- The pool's books (docs/MATH.md §6 to §10) -----------------------------------------------------------------------


def payout_at(bet, price):
    """What `bet` would pay at `price` (§5): the payout at g there. It bounds a sale's valuation (§8)."""
    return m.payout(bet.stake, m.g_bps(P0, price, bet.side, bet.leverage, bet.floor, bet.cap))


class Bet:
    """One bet: its market's leverage, its terms, its lines (§4), its maximum profit (§5) and its status."""

    count = 0

    def __init__(self, name, leverage, side, start, stake, duration, theta, floor, cap):
        Bet.count += 1
        self.number = Bet.count  # its position id in the model's checks
        self.name, self.leverage, self.side, self.start, self.end = name, leverage, side, start, start + duration
        self.stake, self.duration, self.theta, self.floor, self.cap = stake, duration, theta, floor, cap
        self.liq, self.cap_price = m.lines(P0, side, leverage, theta, cap)
        self.max_profit = m.max_profit(stake, cap)
        self.status = "open"
        self.owed = 0
        self.queue_seq = None


def check_batch_size(count):
    """A batch holds 1 to 100 ids (§3.3)."""
    if count == 0:
        raise m.Revert("EmptyBatch")
    if count > 100:
        raise m.Revert("BatchSizeTooLarge")


class Pool:
    """A pool's books (`PoolState`, §1) and the bets on it, moved the way §6 to §10 say.

    Each action runs the model's checks first, in the contract's order. A refused action changes nothing, as a
    reverted call: the books, the bets and the notes go back to what they were.
    """

    def __init__(self, out, markets, seed, label):
        self.out = out  # where the steps are written; None while a test's loop runs silently
        self.markets = {}  # leverage -> the market's stored settings (m.ConfigParams)
        for leverage, c in markets.items():
            self.set_config(leverage, c, quiet=True)
        self.total = self.locked = self.open_max_profit = self.total_owed = self.fees = 0
        self.floor = POOL_FLOOR
        self.queue = []  # the IOUs, head first
        self.next_queue_seq = self.next_repay_seq = self.open_positions = self.owed_positions = 0
        self.now = START
        self.batch = 1000  # the market of the next liquidate or settle (the tests' `batchLeverage`)
        self.bets = []
        self.say("%s; floor %s" % (label, num(self.floor)))
        if seed:
            self.fund(seed)

    @property
    def free(self):
        """Free money: `total - lockedMargin` (§1)."""
        return self.total - self.locked

    def books(self):
        """The books, in one line."""
        return "total %s, locked %s, free %s, open max profit %s, owed %s" % (
            num(self.total), num(self.locked), num(self.free), num(self.open_max_profit), num(self.total_owed))

    def say(self, text):
        """Writes a step to the derivation, unless the pool is silent."""
        if self.out is not None:
            self.out.note(text)

    def atomic(self, step):
        """Runs `step`. If the model refuses, puts the books, the bets and the notes back as they were."""
        saved = dict(self.__dict__), list(self.queue), [(bet, dict(bet.__dict__)) for bet in self.bets]
        written = len(self.out.lines) if self.out is not None else 0
        try:
            return step()
        except m.Revert:
            pool, queue, bets = saved
            self.__dict__.clear()
            self.__dict__.update(pool)
            self.queue = queue
            for bet, state in bets:
                bet.__dict__.clear()
                bet.__dict__.update(state)
            if self.out is not None:
                del self.out.lines[written:]
            raise

    def set_config(self, leverage, c, quiet=False):
        """`createMarket` or `setConfig`: `validate` (§3.1) passes on the settings as sent, then they are stored as
        `c` (a gate of 0 is switched off in storage after)."""
        m.validate(sent(c), leverage)
        self.markets[leverage] = c
        if not quiet:
            self.say("settings of the %dx market: valid; open gate %s, owed limit %s" % (
                leverage, "off" if c.maxExposureBps == 0 else "%s bps" % num(c.maxExposureBps),
                "none" if c.maxTotalOwed == m.UINT64_MAX else num(c.maxTotalOwed)))

    def warp(self, time):
        """Moves the clock to `time`."""
        assert time >= self.now
        self.now = time

    def fund(self, amount):
        """`fund` (§10): `total += amount`."""
        self.total += amount
        self.say("fund %s: %s" % (num(amount), self.books()))

    def set_floor(self, pool_floor):
        """`setPoolFloor`: at least $500."""
        assert pool_floor >= POOL_FLOOR
        self.floor = pool_floor
        self.say("pool floor set to %s" % num(pool_floor))

    def open(self, name, leverage, side, **terms):
        """`open` (§6): the bet's terms against its market's settings (§3.2), its lines (§4), then the open gate.
        The stake joins `total` and `lockedMargin`, so free money does not change."""
        t = dict(BASE)
        t.update(terms)
        c = self.markets[leverage]
        m.validate_open(c, t["stake"], t["duration"], t["theta"], t["floor"], t["cap"])
        bet = Bet(name, leverage, side, self.now, **t)
        m.open_gate(self.total_owed, c.maxTotalOwed, self.open_max_profit, bet.max_profit, self.free,
                    c.maxExposureBps)
        self.total += bet.stake
        self.locked += bet.stake
        self.open_max_profit += bet.max_profit
        self.open_positions += 1
        self.bets.append(bet)
        self.say("open %s: %s %s at %dx, θ %s, floor %s, cap %s, %d s; line %s, cap line %s, max profit %s" % (
            bet.name, SIDE[side], num(bet.stake), leverage, num(bet.theta), num(bet.floor), num(bet.cap),
            bet.duration, at(bet.liq), at(bet.cap_price), num(bet.max_profit)))
        return bet

    def release(self, bet):
        """An ending releases the bet's hold (§7): its stake, its maximum profit and its count."""
        self.locked -= bet.stake
        self.open_max_profit -= bet.max_profit
        self.open_positions -= 1

    def same_market(self, bet):
        """A batch holds the bets of one market (ADR 0008)."""
        if bet.leverage != self.batch:
            raise m.Revert("ConfigMismatch", bet.number)

    def liquidate(self, bets, price, publish=None):
        """`liquidate` (§7.1): one tick on a batch, each open bet in order, free money measured before each. Returns
        each bet's loser fee (None for a bet the batch skips)."""
        publish = self.now if publish is None else publish

        def step():
            check_batch_size(len(bets))
            skew = self.markets[self.batch].clockSkewSecs
            fees = []
            for bet in bets:
                self.same_market(bet)
                if bet.status != "open":
                    self.say("liquidate %s: skipped, it is %s" % (bet.name, bet.status))
                    fees.append(None)
                    continue
                m.check_liquidation(bet.number, bet.start, bet.end, bet.liq, bet.side, price, publish, self.now, skew)
                free_before = self.free
                fee = m.loser_fee(bet.stake, free_before, self.floor)
                self.release(bet)
                self.total -= fee
                self.fees += fee
                bet.status = "closed"
                self.say("liquidate %s at %s: free before %s, loser fee %s; %s" % (
                    bet.name, at(price), num(free_before), num(fee), self.books()))
                fees.append(fee)
            return fees

        return self.atomic(step)

    def settle(self, bets, price, publish=None):
        """`settle` (§7.2, §7.4): one tick on a batch, each open bet in order; each payout splits with free money and
        the owed total as the bets before it left them. Returns each bet's ending (None for a bet the batch skips)."""
        publish = bets[0].end if publish is None else publish

        def step():
            check_batch_size(len(bets))
            if price <= 0:
                raise m.Revert("InvalidPrice")
            if publish > self.now + self.markets[self.batch].clockSkewSecs:
                raise m.Revert("NotExpired")
            endings = []
            for bet in bets:
                self.same_market(bet)
                if bet.status != "open":
                    self.say("settle %s: skipped, it is %s" % (bet.name, bet.status))
                    endings.append(None)
                    continue
                if bet.end != publish:
                    raise m.Revert("InvalidPriceTimestamp", bet.number)
                if m.touched(price, bet.liq, bet.side):
                    raise m.Revert("LiquidateInstead", bet.number)
                g = m.g_bps(P0, price, bet.side, bet.leverage, bet.floor, bet.cap)
                payout = m.payout(bet.stake, g)
                free_before, owed_before = self.free, self.total_owed
                s = m.settle_split(payout, bet.stake, free_before, owed_before, self.floor)
                e = SimpleNamespace(g=g, payout=payout, toUser=m.settle_to_user(s), queueSeq=None, **s._asdict())
                self.release(bet)
                self.total -= m.settle_out_of_pool(s)
                self.fees += s.winnerFee + s.loserFee
                bet.status = "closed"
                if s.owed:
                    bet.status, bet.owed, bet.queue_seq = "owed", s.owed, self.next_queue_seq
                    e.queueSeq = self.next_queue_seq
                    self.next_queue_seq += 1
                    self.total_owed += s.owed
                    self.owed_positions += 1
                    self.queue.append(bet)
                self.say("settle %s at %s: g %s, payout %s; free before %s, owed before %s -> own %s, paid %s, "
                         "owed %s, winner fee %s, loser fee %s, to the user %s%s; %s" % (
                             bet.name, at(price), num(g), num(payout), num(free_before), num(owed_before), num(s.own),
                             num(s.paid), num(s.owed), num(s.winnerFee), num(s.loserFee), num(e.toUser),
                             "" if e.queueSeq is None else ", queue place %d" % e.queueSeq, self.books()))
                endings.append(e)
            return endings

        return self.atomic(step)

    def sell(self, bet, price, valuation, amount, minimum, publish=None):
        """`sell` (§8): the checks in the contract's order, then the sale split. Returns the sale."""
        publish = self.now if publish is None else publish

        def step():
            c = self.markets[bet.leverage]  # a sale names no market: the bet's own applies
            if bet.status != "open":
                raise m.Revert("PositionNotOpen")
            m.check_sell_window(bet.start, bet.end, publish, c.sellMinDelaySecs, c.sellCutoffSecs)
            if self.now >= bet.end:
                raise m.Revert("SellWindowClosed")
            m.check_entry_time(self.now, publish, c.entryMaxAgeSecs, c.clockSkewSecs)
            if price <= 0:
                raise m.Revert("InvalidPrice")
            if m.touched(price, bet.liq, bet.side):
                raise m.Revert("LiquidateInstead", bet.number)
            g = m.g_bps(P0, price, bet.side, bet.leverage, bet.floor, bet.cap)
            free_before = self.free
            m.check_sell(bet.stake, g, valuation, amount, minimum, c.maxSellFeeBps, self.total_owed, free_before)
            s = m.sell_split(bet.stake, valuation, amount, free_before, self.floor)
            self.release(bet)
            self.total -= m.sell_out_of_pool(s)
            self.fees += m.sell_fees(s)
            bet.status = "closed"
            self.say("sell %s at %s: g %s, so at most payout %s; valuation %s, sale amount %s; free before %s -> to "
                     "the user %s, sell fee %s, winner fee %s, loser fee %s; %s" % (
                         bet.name, at(price), num(g), num(m.payout(bet.stake, g)), num(valuation), num(amount),
                         num(free_before), num(s.toUser), num(s.sellFee), num(s.winnerFee), num(s.loserFee),
                         self.books()))
            return SimpleNamespace(gNow=g, **s._asdict())

        return self.atomic(step)

    def repay(self, max_count):
        """`repay(maxCount)` (§9): the queue from its head, oldest first, from free money only. It stops when free
        money is 0, after an IOU it pays only in part, or after `maxCount` IOUs. Returns (bet, split) per IOU paid."""
        if not 1 <= max_count <= 50:
            raise m.Revert("InvalidMaxCount")
        paid = []
        while self.queue and len(paid) < max_count and self.free > 0:
            bet = self.queue[0]
            r = m.repay_split(bet.owed, self.free)
            self.total -= r.amount
            self.total_owed -= r.amount
            self.fees += r.winnerFee
            bet.owed = r.remaining
            paid.append((bet, r))
            self.say("repay %s: owed %s, free %s -> amount %s, winner fee %s, to the owner %s, still owed %s; %s" % (
                bet.name, num(r.amount + r.remaining), num(self.free + r.amount), num(r.amount), num(r.winnerFee),
                num(r.toUser), num(r.remaining), self.books()))
            if r.remaining:
                break
            self.queue.pop(0)
            self.next_repay_seq += 1
            self.owed_positions -= 1
            bet.status = "closed"
        if not paid:
            self.say("repay: no free money, nothing paid")
        return paid


def base_pool(out, markets=None):
    """The settlement tests' pool (`Settlement_Base_Test`): $1,500 of free money, the $500 floor, and BTC at 1000x
    on the launch settings with the open gate at 100%."""
    return Pool(out, markets or {1000: launch_config(10_000)}, FREE, "the settlement tests' pool")


def small_pool(out, seed):
    """`_useSmallPool(seed)`: a new pool holding only `seed`, with BTC's open gate off at 1000x."""
    return Pool(out, {1000: launch_config(0)}, seed, "a small pool, the open gate off")


def empty_pool(out):
    """`_useEmptyPool`: a second, empty pool. BTC at 1000x on the launch settings with a 5-second rule in its
    5-minute slot, and at 500x and 100x on the tier settings with a 5-second rule up to the widest line. Every gate
    is off."""
    markets = {1000: with_rule(launch_config(0), 4, rule(5, 1_000, 5_000)), 500: five_second_tier_config(500),
               100: five_second_tier_config(100)}
    return Pool(out, markets, 0, "a second, empty pool, every gate off")


# --- LiquidateScenarios.t.sol -----------------------------------------------------------------------------------------


class Liquidate_Scenario_Test:
    """Liquidations on the settlement tests' pool ($1,500 free, the $500 floor): base bets at 1000x."""

    FILE = "test/scenarios/LiquidateScenarios.t.sol"
    HELPERS = {}

    @scenario({1: "one price unit inside the line"})
    def test_ALongAtItsLineButNotOneUnitInside():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        out.refused("a tick one unit inside the line", "LiquidationPriceNotReached", pool.liquidate, [bet], bet.liq + 1,
                    bet.start)
        (fee,) = pool.liquidate([bet], bet.liq, bet.start)
        out.number("loser fee: 3% of the $10 stake, free money above the floor", fee)
        return out

    @scenario({1: "one price unit inside the line"})
    def test_AShortAtItsLineButNotOneUnitInside():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("short", 1000, PUT)
        out.refused("a tick one unit inside the line", "LiquidationPriceNotReached", pool.liquidate, [bet], bet.liq - 1,
                    bet.start)
        pool.liquidate([bet], bet.liq, bet.start)
        return out

    @scenario({500: "a price move: $500 past each line"})
    def test_ALongAndAShortBeyondTheirLines():
        out = Derivation()
        pool = base_pool(out)
        long_bet = pool.open("long", 1000, CALL)
        short_bet = pool.open("short", 1000, PUT)
        pool.liquidate([long_bet], long_bet.liq - 500 * USD, long_bet.start)
        pool.liquidate([short_bet], short_bet.liq + 500 * USD, short_bet.start)
        return out

    @scenario({1: "a time: one second outside the bet's life",
               30: "a time: a tick 30 s ahead of the clock, past its 5 s skew"})
    def test_ATickInsideThePositionsLifeAndNotFromTheFuture():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        out.refused("a tick one second before the start", "InvalidLiquidationWindow", pool.liquidate, [bet], bet.liq,
                    bet.start - 1)
        out.refused("a tick one second after the end", "InvalidLiquidationWindow", pool.liquidate, [bet], bet.liq,
                    bet.end + 1)
        out.refused("a tick 30 s ahead of the clock", "PriceFromFuture", pool.liquidate, [bet], bet.liq, pool.now + 30)
        pool.liquidate([bet], bet.liq, bet.start)
        second = pool.open("second long", 1000, CALL)
        pool.warp(second.end)
        out.refused("at the end, a tick one second after it", "InvalidLiquidationWindow", pool.liquidate, [second],
                    second.liq, second.end + 1)
        pool.liquidate([second], second.liq, second.end)
        return out

    @scenario({0: "a price: zero", -1: "a price: negative"})
    def test_RevertWhen_ThePriceIsZeroOrNegative():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        out.refused("a zero price", "InvalidPrice", pool.liquidate, [bet], 0, bet.start)
        out.refused("a negative price", "InvalidPrice", pool.liquidate, [bet], -1, bet.start)
        pool.liquidate([bet], bet.liq, bet.start)
        return out

    @scenario({1: "a setting: a floor one unit above free money"})
    def test_TheLoserFeeAtTheFloorButNotOneUnitBelow():
        out = Derivation()
        pool = base_pool(out)
        a = pool.open("a", 1000, CALL)
        b = pool.open("b", 1000, CALL)
        pool.set_floor(pool.free)
        (fee,) = pool.liquidate([a], a.liq, a.start)
        out.number("a's loser fee: 3% of $10, free money exactly at the floor", fee)
        pool.set_floor(pool.free + 1)
        (fee,) = pool.liquidate([b], b.liq, b.start)
        out.number("b's loser fee: none, free money one unit below the floor", fee)
        return out

    @scenario()
    def test_FreeMoneyIsMeasuredPerPositionInBatchOrder():
        out = Derivation()
        pool = base_pool(out)
        c = pool.open("c", 1000, CALL)
        d = pool.open("d", 1000, CALL)
        pool.set_floor(pool.free + c.stake)
        fees = pool.liquidate([c, d], c.liq, c.start)
        out.number("c's loser fee: free money is one $10 stake short of the floor", fees[0])
        out.number("d's loser fee: c's released stake lifts free money to the floor", fees[1])
        return out

    @scenario({1_600_000_000: "a top-up: $1,600, so the open gate lets in all 101 bets",
               101: "a count: 101 bets", 100: "a count: the batch limit, 100 ids"})
    def test_OneHundredPositionsInOneBatchThenTheHundredAndFirstAlone():
        out = Derivation()
        probe = base_pool(None)
        for i in range(50):
            probe.open("bet %d" % i, 1000, CALL)
        out.refused("without the top-up, the 51st bet ($1,530 of maximum profit against $1,500 free)",
                    "OpenBlockedExposure", probe.open, "bet 50", 1000, CALL)
        pool = base_pool(out)
        pool.fund(1_600 * TOKEN)
        pool.out = None
        bets = [pool.open("bet %d" % i, 1000, CALL) for i in range(101)]
        pool.out = out
        out.note("101 longs open: %s" % pool.books())
        last = bets[-1]
        out.refused("101 ids in one batch", "BatchSizeTooLarge", pool.liquidate, bets, last.liq, last.start)
        pool.out = None
        fees = pool.liquidate(bets[:100], last.liq, last.start) + pool.liquidate(bets[100:], last.liq, last.start)
        pool.out = out
        out.note("100 liquidated in one batch, then the 101st, each with a loser fee of %s: %s" % (
            " or ".join(sorted({num(f) for f in fees})), pool.books()))
        out.number("open bets after both batches", pool.open_positions)
        return out


# --- SettleScenarios.t.sol --------------------------------------------------------------------------------------------


def expect_winner(out, pool, side, amount, what):
    """`_expectWinner`: the base bet on `side`, settled at its expiry second `amount` dollars from P0."""
    where = "%s$%d" % ("+" if amount > 0 else "-", abs(amount))
    bet = pool.open("%s at %s" % (SIDE[side], where), 1000, side)
    pool.warp(bet.end)
    (e,) = pool.settle([bet], dollars(amount))
    out.number("%s at %s: g, %s" % (SIDE[side], where, what), e.g)
    out.number("%s at %s: paid to the user" % (SIDE[side], where), e.toUser)
    out.number("%s at %s: winner fee, 2%% of the profit paid" % (SIDE[side], where), e.winnerFee)


def iou(out, name, e):
    """`_assertIou`: what a settled winner was paid now, what it is owed, what its user got, and its queue place."""
    out.number("%s: profit paid now" % name, e.paid)
    out.number("%s: owed" % name, e.owed)
    out.number("%s: to the user now" % name, e.toUser)
    out.number("%s: its queue place" % name, e.queueSeq)


def gate_on_total_owed(out, pool):
    """`_expectTheGateOnTotalOwed`: an owed limit one unit below the owed total stops a new bet, and one at it lets the
    same order in, which then settles. `_setMaxTotalOwed` stores the launch settings with the gate off."""
    owed = out.number("total owed: $10 + $30 + $3", pool.total_owed)
    pool.set_config(1000, launch_config(0)._replace(maxTotalOwed=owed - 1))
    out.refused("open e with the owed limit one unit below the owed total", "OpenBlockedTotalOwed", pool.open, "e",
                1000, CALL)
    pool.set_config(1000, launch_config(0)._replace(maxTotalOwed=owed))
    e = pool.open("e", 1000, CALL)
    pool.warp(e.end)
    pool.settle([e], dollars(-8))


class Settle_Scenario_Test:
    """Settlements on the settlement tests' pool ($1,500 free, the $500 floor), and the IOU queue on a $20 pool:
    base bets at 1000x."""

    FILE = "test/scenarios/SettleScenarios.t.sol"
    HELPERS = {"_expectTheGateOnTotalOwed": {1: "one unit below the owed total", -8: "a price move: -$8"}}

    @scenario({8: "a price move: +$8", 84: "a price move: +$84", 300: "a price move: +$300, past the cap line"})
    def test_ALongWinnerAtTheFloorMidRangeAndTheCap():
        out = Derivation()
        pool = base_pool(out)
        for amount, what in ((8, "a small win pays the 1.3x floor"), (84, "mid-range"), (300, "the 4x cap")):
            expect_winner(out, pool, CALL, amount, what)
        return out

    @scenario({-8: "a price move: -$8", -84: "a price move: -$84", -300: "a price move: -$300, past the cap line"})
    def test_AShortWinnerAtTheFloorMidRangeAndTheCap():
        out = Derivation()
        pool = base_pool(out)
        for amount, what in ((-8, "a small win pays the 1.3x floor"), (-84, "mid-range"), (-300, "the 4x cap")):
            expect_winner(out, pool, PUT, amount, what)
        return out

    @scenario()
    def test_AFlatExpiryReturnsExactlyTheStake():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("flat", 1000, CALL)
        pool.warp(bet.end)
        (e,) = pool.settle([bet], P0)
        out.number("to the user: the stake back", e.toUser)
        out.number("fees: winner fee + loser fee", e.winnerFee + e.loserFee)
        return out

    @scenario({-8: "a price move: -$8", 8: "a price move: +$8"})
    def test_ALongAndAShortLoser():
        out = Derivation()
        pool = base_pool(out)
        long_bet = pool.open("long", 1000, CALL)
        pool.warp(long_bet.end)
        (e,) = pool.settle([long_bet], dollars(-8))
        out.number("the long at -$8: to the user", e.toUser)
        out.number("the long at -$8: loser fee, 3% of the $0.954 loss", e.loserFee)
        short_bet = pool.open("short", 1000, PUT)
        pool.warp(short_bet.end)
        (e,) = pool.settle([short_bet], dollars(8))
        out.number("the short at +$8: loser fee, the same loss on the other side", e.loserFee)
        return out

    @scenario({1: "a setting: a floor one unit above free money", -8: "a price move: -$8"})
    def test_NoLoserFeeOneUnitBelowTheFloor():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        pool.set_floor(pool.free + 1)
        pool.warp(bet.end)
        (e,) = pool.settle([bet], dollars(-8))
        out.number("loser fee: none, free money one unit below the floor", e.loserFee)
        return out

    @scenario({1: "one price unit"})
    def test_OneUnitInsideTheLineSettles():
        out = Derivation()
        pool = base_pool(out)
        long_bet = pool.open("long", 1000, CALL)
        short_bet = pool.open("short", 1000, PUT)
        pool.warp(long_bet.end)
        out.refused("settling the long on its line", "LiquidateInstead", pool.settle, [long_bet], long_bet.liq)
        out.refused("settling the long one unit beyond it", "LiquidateInstead", pool.settle, [long_bet],
                    long_bet.liq - 1)
        (e,) = pool.settle([long_bet], long_bet.liq + 1)
        out.number("g one unit inside the long's line: -3.0 bp at 1000x leaves 0.7x", e.g)
        out.refused("settling the short on its line", "LiquidateInstead", pool.settle, [short_bet], short_bet.liq)
        out.refused("settling the short one unit beyond it", "LiquidateInstead", pool.settle, [short_bet],
                    short_bet.liq + 1)
        pool.settle([short_bet], short_bet.liq - 1)
        return out

    @scenario({11_000: "a setting: a 1.1x floor", 15_000: "a setting: a 1.5x cap", 8: "a price move: +$8"})
    def test_SeveralUsersInOneBatch():
        out = Derivation()
        pool = base_pool(out)
        a = pool.open("a long at the 1.3x floor", 1000, CALL)
        b = pool.open("a losing short", 1000, PUT)
        c = pool.open("a long at the 1.1x floor", 1000, CALL, floor=11_000, cap=15_000)
        pool.warp(c.end)
        endings = pool.settle([a, b, c], dollars(8))
        for bet, e in zip((a, b, c), endings):
            out.number("%s: to the user" % bet.name, e.toUser)
        return out

    @scenario({8: "a price move: +$8", 10: "a time: 10 s after the expiry second"})
    def test_LongAfterTheExpirySecond():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("late", 1000, CALL)
        out.refused("the expiry second's tick before the clock is there", "NotExpired", pool.settle, [bet], dollars(8),
                    bet.end)
        pool.warp(bet.end + 10)
        pool.settle([bet], dollars(8), bet.end)
        return out

    @scenario({1_600_000_000: "a top-up: $1,600, so the open gate lets in all 101 bets", 101: "a count: 101 bets",
               2: "a count: bets alternate long and short", 0: "a count: the even bets are longs",
               8: "a price move: +$8", 100: "a count: the batch limit, 100 ids"})
    def test_OneHundredPositionsInOneBatchThenTheHundredAndFirstAlone():
        out = Derivation()
        pool = base_pool(out)
        pool.fund(1_600 * TOKEN)
        pool.out = None
        bets = [pool.open("bet %d" % i, 1000, CALL if i % 2 == 0 else PUT) for i in range(101)]
        pool.out = out
        out.note("101 bets open, even ones long and odd ones short: %s" % pool.books())
        pool.warp(bets[-1].end)
        price = dollars(8)
        out.refused("101 ids in one batch", "BatchSizeTooLarge", pool.settle, bets, price)
        pool.out = None
        endings = pool.settle(bets[:100], price) + pool.settle(bets[100:], price)
        pool.out = out
        paid = {CALL: set(), PUT: set()}
        for bet, e in zip(bets, endings):
            paid[bet.side].add(e.toUser)
        assert len(paid[CALL]) == len(paid[PUT]) == 1
        longs = sum(1 for bet in bets if bet.side == CALL)
        out.number("longs among the 101 bets", longs)
        out.number("a long's pay at +$8: the 1.3x floor less 2% of the $3 profit", paid[CALL].pop())
        out.number("shorts among them", len(bets) - longs)
        out.number("a short's pay at +$8: a $0.954 loss, no fee to the user", paid[PUT].pop())
        out.note("alice's balance: the sum, %s" % num(sum(e.toUser for e in endings)))
        return out

    @scenario({300: "a price move: +$300", -8: "a price move: -$8", 8: "a price move: +$8"})
    def test_TheIouQueue():
        out = Derivation()
        pool = small_pool(out, 20 * TOKEN)
        a = pool.open("a", 1000, CALL)
        b = pool.open("b", 1000, CALL)
        pool.warp(b.end)
        ending_a, ending_b = pool.settle([a, b], dollars(300))
        iou(out, "a, $30 profit with $20 free", ending_a)
        iou(out, "b, with nothing free and a queued", ending_b)
        c = pool.open("c", 1000, CALL)
        pool.warp(c.end)
        (e,) = pool.settle([c], dollars(-8))
        out.number("c's loser fee: free money is below the $500 floor", e.loserFee)
        out.note("free money after c's loss: %s, above 0" % num(pool.free))
        d = pool.open("d", 1000, CALL)
        pool.warp(d.end)
        (e,) = pool.settle([d], dollars(8))
        iou(out, "d, queued behind a and b although money is free", e)
        pool.settle([a], P0, a.end)
        pool.liquidate([a], a.liq, a.end)
        gate_on_total_owed(out, pool)
        return out


# --- RepayScenarios.t.sol ---------------------------------------------------------------------------------------------


def repay_setup(out):
    """`Repay_Scenario_Test.setUp`: on a $20 pool, two winners at +$300 in one batch, then one at a time a loser at
    -$8, a winner at +$8, a loser at -$8 and a winner at +$8. It leaves four IOUs, $10, $30, $3 and $3, and two
    losses' $0.954 each of free money."""
    pool = small_pool(out, 20 * TOKEN)
    a = pool.open("a", 1000, CALL)
    b = pool.open("b", 1000, CALL)
    pool.warp(b.end)
    pool.settle([a, b], dollars(300))
    for name, amount in (("c", -8), ("d", 8), ("e", -8), ("p", 8)):
        bet = pool.open(name, 1000, CALL)
        pool.warp(bet.end)
        pool.settle([bet], dollars(amount))
    out.number("set-up: IOUs in the queue", pool.next_queue_seq - pool.next_repay_seq)
    out.number("set-up: IOUs repaid so far (nextRepaySeq)", pool.next_repay_seq)
    out.number("set-up: total owed, $10 + $30 + $3 + $3", pool.total_owed)
    out.number("set-up: free money, two losses' $0.954 each", pool.free)
    return pool


def repay_part_of_the_head(out, pool):
    """`_repayPartOfTheHead`: x opens, and a stranger repays the head from all the free money there is."""
    x = pool.open("x", 1000, CALL)
    paid = pool.repay(50)
    out.number("repayments", len(paid))
    head, r = paid[0]
    out.number("repaid to %s: all of the free money, none of x's stake" % head.name, r.amount)
    out.number("its winner fee: 2% of it", r.winnerFee)
    out.number("to %s's owner" % head.name, r.toUser)
    out.number("still owed to %s, the head" % head.name, r.remaining)
    out.note("no free money left, and locked %s is x's stake: total %s" % (num(pool.locked), num(pool.total)))
    return x


class Repay_Scenario_Test:
    """Repaying the IOU queue that the set-up leaves on a $20 pool."""

    FILE = "test/scenarios/RepayScenarios.t.sol"
    HELPERS = {
        "setUp": {20_000_000: "a seed: the small pool's $20", 300: "a price move: +$300", -8: "a price move: -$8",
                  8: "a price move: +$8"},
        "_repayPartOfTheHead": {50: "a count: up to 50 IOUs"},
    }

    @scenario()
    def test_AnyoneRepaysPartOfTheHeadAndAnOpenStakeStaysUntouched():
        out = Derivation()
        pool = repay_setup(out)
        repay_part_of_the_head(out, pool)
        return out

    @scenario({50: "a count: up to 50 IOUs"})
    def test_WithNoFreeMoneyNothingIsPaid():
        out = Derivation()
        pool = repay_setup(out)
        repay_part_of_the_head(out, pool)
        paid = pool.repay(50)
        out.number("repayments with no free money", len(paid))
        out.number("repayment events", len(paid))
        return out

    @scenario({1: "one price unit inside the line", 37_000_000: "a top-up: $37", 3: "a count: up to 3 IOUs",
               5_000_000: "a top-up: $5", 50: "a count: up to 50 IOUs"})
    def test_ALossAndATopUpRepayTheQueueInOrder():
        out = Derivation()
        pool = repay_setup(out)
        x = repay_part_of_the_head(out, pool)
        pool.warp(x.end)
        pool.settle([x], x.liq + 1)
        pool.fund(37 * TOKEN)
        paid = pool.repay(3)
        out.number("repayments", len(paid))
        out.number("repaid to a: the rest of it, in full", paid[0][1].amount)
        out.number("repaid to b, in full", paid[1][1].amount)
        out.number("repaid to d: what is left", paid[2][1].amount)
        out.number("still owed to d, which stays the head", paid[2][1].remaining)
        out.number("the head's place (nextRepaySeq): d's", pool.next_repay_seq)
        pool.fund(5 * TOKEN)
        paid = pool.repay(50)
        out.number("repayments: d and p", len(paid))
        p = next(bet for bet in pool.bets if bet.name == "p")
        assert pool.next_repay_seq == pool.next_queue_seq and p.status == "closed"
        out.note("the queue is empty: nextRepaySeq = nextQueueSeq = %d, and p is closed" % pool.next_queue_seq)
        out.number("total owed", pool.total_owed)
        return out


# --- SellScenarios.t.sol ----------------------------------------------------------------------------------------------


def flat_valuation(out, bet):
    """The valuation of `_expectFlatSale`: the payout at the entry, where g is 1x, so the stake back. The test values
    and sells a flat bet for exactly that, and sets it as the user's minimum."""
    return out.number("a flat sale: the payout at the entry, g 1x, so the stake back", payout_at(bet, P0))


class Sell_Scenario_Test:
    """Sales on the settlement tests' pool ($1,500 free, the $500 floor, a 6% sell-fee cap), on a $20 pool with a
    queue, and on a $5 pool: base bets at 1000x."""

    FILE = "test/scenarios/SellScenarios.t.sol"
    HELPERS = {}

    @scenario({12_500_000: "a quote: the valuation, $12.50", 12_000_000: "a quote: the sale amount, $12",
               11_640_000: "a quote: the user's minimum, $11.64"})
    def test_ALongAtAProfit():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        s = pool.sell(bet, dollars(8), 12_500_000, 12_000_000, 11_640_000)
        out.number("g at +$8: the 1.3x floor", s.gNow)
        out.number("to the user: $12 less 2% of the $2 profit", s.toUser)
        out.number("sell fee: the valuation less the sale amount", s.sellFee)
        out.number("winner fee: 2% of the $2 profit", s.winnerFee)
        out.number("loser fee: none on a profit", s.loserFee)
        return out

    @scenario({-8: "a price move: -$8", 12_500_000: "a quote: the valuation, $12.50",
               12_000_000: "a quote: the sale amount and the user's minimum, $12"})
    def test_AShortAtAProfit():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("short", 1000, PUT)
        s = pool.sell(bet, dollars(-8), 12_500_000, 12_000_000, 12_000_000)
        out.number("to the user: $12 less 2% of the $2 profit", s.toUser)
        return out

    @scenario({-8: "a price move: -$8", 9_000_000: "a quote: the valuation, $9",
               1: "a setting: a floor one unit above free money"})
    def test_ALossAndNoLoserFeeBelowTheFloor():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        s = pool.sell(bet, dollars(-8), 9_000_000, 8_600_000, 8_600_000)
        out.number("to the user: the sale amount; no winner fee on a loss", s.toUser)
        out.number("sell fee: the valuation less the sale amount", s.sellFee)
        out.number("loser fee: 3% of the $1 loss in the valuation", s.loserFee)
        second = pool.open("second long", 1000, CALL)
        pool.set_floor(pool.free + 1)
        s = pool.sell(second, dollars(-8), 9_000_000, 8_600_000, 8_600_000)
        out.number("loser fee one unit below the floor: none", s.loserFee)
        return out

    @scenario({300: "a price move: +$300, past the cap line"})
    def test_TheCappedRegionWithNoSellFee():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        price = dollars(300)
        most = out.number("the payout past the cap line, the valuation sold at", payout_at(bet, price))
        s = pool.sell(bet, price, most, most, most)
        out.number("g: the 4x cap", s.gNow)
        out.number("to the user: $40 less 2% of the $30 profit", s.toUser)
        out.number("sell fee: none", s.sellFee)
        out.number("winner fee: 2% of the $30 profit", s.winnerFee)
        return out

    @scenario({12_500_000: "a quote: a valuation of $12.50", 12_000_000: "a quote: a valuation of $12"})
    def test_EachBoundAtItsEdge():
        out = Derivation()
        pool = base_pool(out)
        price = dollars(8)
        a = pool.open("a", 1000, CALL)
        most = out.number("the payout at +$8 (the 1.3x floor): the highest valuation", payout_at(a, price))
        over = out.number("one unit above it", most + 1)
        out.refused("a valuation one unit above the payout", "ValuationAboveCurrentPayout", pool.sell, a, price, over,
                    most, most)
        pool.sell(a, price, most, most, most)
        b = pool.open("b", 1000, CALL)
        valuation = 12_500_000
        cap = m.fee(valuation, pool.markets[1000].maxSellFeeBps)
        lowest = out.number("the lowest sale amount on $12.50: the valuation less the 6%% fee cap, %s" % num(cap),
                            valuation - cap)
        under = out.number("one unit below it", lowest - 1)
        out.refused("a sale amount one unit below it", "SellFeeTooHigh", pool.sell, b, price, valuation, under, under)
        pool.sell(b, price, valuation, lowest, lowest)
        c = pool.open("c", 1000, CALL)
        valuation = 12_000_000
        above = out.number("a sale amount one unit above the $12 valuation", valuation + 1)
        out.refused("a sale amount one unit above the valuation", "SellAmountExceedsValuation", pool.sell, c, price,
                    valuation, above, above)
        out.number("a user's minimum one unit above the $12 sale amount", valuation + 1)
        out.refused("a minimum one unit above the sale amount", "SellAmountBelowMin", pool.sell, c, price, valuation,
                    valuation, valuation + 1)
        pool.sell(c, price, valuation, valuation, valuation)
        return out

    @scenario({5: "a setting: 5-second bets", 1_000: "a setting: θ from 0.1 bp", 5_000: "a setting: θ up to 0.5 bp"})
    def test_TheSellWindowsEdges():
        out = Derivation()
        c = with_rule(launch_config(10_000), 4, rule(5, 1_000, 5_000))._replace(sellMinDelaySecs=1)
        pool = base_pool(out, {1000: c})
        a = pool.open("a", 1000, CALL, duration=5)
        b = pool.open("b", 1000, CALL, duration=5)
        opens = out.number("the window opens this many seconds after the start: sellMinDelaySecs", c.sellMinDelaySecs)
        closes = out.number("it closes this many seconds after it: the duration less sellCutoffSecs",
                            a.duration - c.sellCutoffSecs)
        last = out.number("its last open second, after the start", closes - 1)
        value = flat_valuation(out, a)
        pool.warp(a.start + opens)
        out.refused("a tick at the start", "SellWindowClosed", pool.sell, a, P0, value, value, value, a.start)
        out.refused("a tick at start + %d" % closes, "SellWindowClosed", pool.sell, a, P0, value, value, value,
                    a.start + closes)
        pool.sell(a, P0, value, value, value, a.start + opens)
        pool.warp(a.start + last)
        pool.sell(b, P0, value, value, value, b.start + last)
        return out

    @scenario({30: "a time: a tick 30 s ahead of the clock, past its 5 s skew"})
    def test_AStaleTickAndAFutureOne():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        value = flat_valuation(out, bet)
        out.refused("a tick 30 s ahead of the clock", "PriceFromFuture", pool.sell, bet, P0, value, value, value,
                    pool.now + 30)
        stale = out.number("seconds until the open's own tick is too old: entryMaxAgeSecs + 1",
                           pool.markets[1000].entryMaxAgeSecs + 1)
        pool.warp(bet.start + stale)
        out.refused("the open's own tick, %d s old" % stale, "PriceTooOld", pool.sell, bet, P0, value, value, value,
                    bet.start)
        pool.sell(bet, P0, value, value, value, pool.now)
        return out

    @scenario({1_000_000: "a quote: $1, which a refused price never reaches", 1: "one price unit",
               0: "a price: zero"})
    def test_APriceOnOrBeyondTheLineAndAZeroPrice():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        out.refused("a price on the line", "LiquidateInstead", pool.sell, bet, bet.liq, TOKEN, TOKEN, TOKEN)
        out.refused("a price one unit beyond it", "LiquidateInstead", pool.sell, bet, bet.liq - 1, TOKEN, TOKEN, TOKEN)
        out.refused("a zero price", "InvalidPrice", pool.sell, bet, 0, TOKEN, TOKEN, TOKEN)
        inside = bet.liq + 1
        most = out.number("the payout one unit inside the line, the valuation sold at", payout_at(bet, inside))
        s = pool.sell(bet, inside, most, most, most)
        out.number("g one unit inside the line: 0.7x", s.gNow)
        return out

    @scenario()
    def test_ADisabledOrPausedMarket():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        value = flat_valuation(out, bet)
        out.note("a disabled or a paused market refuses the sale (LeverageDisabled, LeveragePaused) before any maths")
        pool.sell(bet, P0, value, value, value)
        return out

    @scenario()
    def test_TheWrongRelayerAndAnotherUsersSignature():
        out = Derivation()
        pool = base_pool(out)
        bet = pool.open("long", 1000, CALL)
        value = flat_valuation(out, bet)
        out.note("the sender's role and the signer are checked before any maths")
        pool.sell(bet, P0, value, value, value)
        return out

    @scenario({20_000_000: "a seed: the small pool's $20", 300: "a price move: +$300",
               0: "not derived: the bound of an inequality (someone is owed: the owed total is above 0)",
               12_000_000: "a quote: a $12 sale, inside the $13 payout"})
    def test_AQueueStopsEverySaleAndAnOwedPositionCantBeSold():
        out = Derivation()
        pool = small_pool(out, 20 * TOKEN)
        a = pool.open("a", 1000, CALL)
        b = pool.open("b", 1000, CALL)
        pool.warp(b.end)
        pool.settle([a, b], dollars(300))
        p = pool.open("p", 1000, CALL)
        price = dollars(8)
        out.refused("a $12 sale while anyone is owed", "QueueNotEmpty", pool.sell, p, price, 12_000_000, 12_000_000,
                    12_000_000)
        pool.warp(p.end)
        (e,) = pool.settle([p], price)
        out.number("p at expiry: its whole $3 profit joins the queue", e.owed)
        out.refused("selling the owed p", "PositionNotOpen", pool.sell, p, price, 12_000_000, 12_000_000, 12_000_000)
        return out

    @scenario({5_000_000: "a seed: the small pool's $5", 300: "a price move: +$300, past the cap line"})
    def test_ASaleThePoolCantPayInFull():
        out = Derivation()
        pool = small_pool(out, 5 * TOKEN)
        bet = pool.open("long", 1000, CALL)
        price = dollars(300)
        out.note("the payout at +$300 would be %s" % num(payout_at(bet, price)))
        most = out.number("the most the pool can pay: free money plus the bet's stake", pool.free + bet.stake)
        over = out.number("one unit more", most + 1)
        out.refused("a valuation one unit above it", "SellNotPayable", pool.sell, bet, price, over, over, over)
        s = pool.sell(bet, price, most, most, most)
        out.number("to the user: $15 less 2% of the $5 profit", s.toUser)
        out.note("the pool is empty: total %s, locked %s" % (num(pool.total), num(pool.locked)))
        return out


# --- FlashOptionScenarios.t.sol ---------------------------------------------------------------------------------------


def flash_option_pool(out):
    """`FlashOption_Scenario_Test.setUp`: the settlement tests' pool, with BTC at 500x and 100x on `_options` (gate
    off) beside 1000x."""
    return base_pool(out, {1000: launch_config(10_000), 500: options_config(500), 100: options_config(100)})


def with_line(c, theta_max):
    """`c` with the first duration rule's widest line set to `theta_max`."""
    return with_rule(c, 0, c.durations[0]._replace(thetaMaxE7=theta_max))


def highest_cap(leverage):
    """The highest cap a short can reach at `leverage` (§3.1 rule 6), capped at 4x: the largest `capBps` the model's
    `cap_reachable` accepts."""
    cap = min((leverage + 1) * m.BPS - 1, m.MAX_LEVERAGE_CAP_BPS)
    assert m.cap_reachable(cap, leverage) and (cap == m.MAX_LEVERAGE_CAP_BPS or not m.cap_reachable(cap + 1, leverage))
    return cap


class FlashOption_Scenario_Test:
    """Markets at 1000x, 500x and 100x on one pool: their settings, and a 500x and a 100x bet."""

    FILE = "test/scenarios/FlashOptionScenarios.t.sol"
    HELPERS = {
        "_expectCreateRejected": {0: "a marker: a gate of 0 is off, and an index plus one of 0 is no market",
                                  10_000: "a setting: the open gate at 100%"},
        "_expectUpdateRejected": {0: "a marker: a gate of 0 is off", 10_000: "a setting: the open gate at 100%"},
    }

    @scenario({3: "a count: three markets", 1: "an index offset: a market's index plus one"})
    def test_CreatesBtc500xAnd100xNextTo1000x():
        out = Derivation()
        flash_option_pool(out)
        out.note("each market's settings pass validate at its own leverage; the test checks the keys, no amount")
        return out

    @scenario({0: "a leverage: 0x, below the range", 250: "a leverage: 250x", 2: "a leverage: 2x"})
    def test_RejectsALeverageOutsideTheRangeALineAtOneOverLeverageAndACapAShortCantReach():
        out = Derivation()
        launch = launch_config(10_000)
        out.refused("the launch settings at 0x", "InvalidLeverageParams", m.validate, launch, 0)
        over = out.number("one above the highest leverage", m.MAX_LEVERAGE + 1)
        out.refused("the launch settings at %sx" % num(over), "InvalidLeverageParams", m.validate, launch, over)
        line = out.number("the line at 1/250: θ x 250 = 10^7", m.E7 // 250)
        out.refused("a %s line at 250x" % num(line), "InvalidLeverageParams", m.validate, with_line(launch, line), 250)
        widest = out.number("the widest line at 250x: (10^7 - 1) // 250", widest_line(250))
        m.validate(with_line(launch, widest), 250)
        out.note("a %s line at 250x: valid" % num(widest))
        highest = out.number("the highest cap a short can reach at 2x: below 3x", highest_cap(2))
        cap = out.number("one bp above it: 1x + 2 x 100%", highest + 1)
        out.refused("a %s cap at 2x" % num(cap), "InvalidLeverageParams", m.validate, launch._replace(capMaxBps=cap), 2)
        m.validate(launch._replace(capMaxBps=highest), 2)
        out.note("a %s cap at 2x: valid" % num(highest))
        return out

    @scenario({3: "a count: three markets"})
    def test_CannotBeCreatedTwiceForTheSameLeverage():
        out = Derivation()
        flash_option_pool(out)
        out.note("a second market for one feed and leverage is refused (MarketExists) before its settings are read")
        return out

    @scenario({3: "a count: three markets", 1: "one unit past the widest line",
               11_760: "a setting: the 500x tier's widest line, 11.76 bp", 2: "a leverage: 2x"})
    def test_ChecksEachUpdateAgainstTheMarketsOwnLeverage():
        out = Derivation()
        pool = flash_option_pool(out)
        for leverage in (1000, 500, 100):
            c = pool.markets[leverage]
            widest = out.number("the widest line at %dx: (10^7 - 1) // %d" % (leverage, leverage),
                                widest_line(leverage))
            out.refused("a %s line at %dx" % (num(widest + 1), leverage), "InvalidLeverageParams", pool.set_config,
                        leverage, with_line(c, widest + 1))
            pool.set_config(leverage, with_line(c, widest))
            pool.set_config(leverage, c)
        out.refused("the 500x tier's widest line, 11,760, at 1000x", "InvalidLeverageParams", pool.set_config, 1000,
                    with_line(pool.markets[1000], 11_760))
        highest = out.number("the highest cap a short can reach at 2x", highest_cap(2))
        pool.set_config(2, launch_config(10_000)._replace(capMaxBps=highest))
        out.number("one bp above it", highest + 1)
        out.refused("an update to a %s cap at 2x" % num(highest + 1), "InvalidLeverageParams", pool.set_config, 2,
                    launch_config(10_000)._replace(capMaxBps=highest + 1))
        return out

    @scenario({40_000_000: "a setting: a $40 maximum stake", 12_000: "a setting: a 1.2x floor",
               25_000: "a setting: a 2.5x cap"})
    def test_UpdateAndPauseChangeOneLeverageOnly():
        out = Derivation()
        pool = flash_option_pool(out)
        pool.set_config(500, options_config(500)._replace(maxStake=40 * TOKEN))
        pool.set_config(500, options_config(500))
        out.note("paused at 500x, its opens stop (LeveragePaused) before any maths")
        bet = pool.open("alice at 1000x", 1000, CALL)
        value = out.number("the payout at the entry, g 1x: the valuation sold at", payout_at(bet, P0))
        s = pool.sell(bet, P0, value, 9_500_000, 9_500_000)
        out.number("g at the entry: 1x", s.gNow)
        out.number("to the user: the $9.50 sale amount, no winner fee", s.toUser)
        out.number("sell fee: $10 less $9.50", s.sellFee)
        return out

    @scenario({11_760: "a setting: θ 11.76 bp", 12_500: "a setting: a 1.25x floor", 25_000: "a setting: a 2.5x cap",
               8: "a price move: +8 bp", 13_500_000: "a quote: the sale amount, $13.50"})
    def test_A500xBetTheLinesAndTheSaleAt500x():
        out = Derivation()
        pool = flash_option_pool(out)
        bet = pool.open("alice at 500x", 500, CALL, theta=11_760, floor=12_500, cap=25_000)
        out.number("the line: 11.76 bp below the entry", bet.liq)
        out.number("the cap line: 2.5x is a 0.3% move at 500x", bet.cap_price)
        price = up(8)
        most = out.number("the payout at +8 bp at 500x, 1.4x: the highest valuation", payout_at(bet, price))
        out.note("at 1000x the same move would give g %s" % num(m.g_bps(P0, price, CALL, 1000, 12_500, 25_000)))
        over = out.number("one unit above it", most + 1)
        out.refused("a valuation one unit above it", "ValuationAboveCurrentPayout", pool.sell, bet, price, over, over,
                    over)
        s = pool.sell(bet, price, most, 13_500_000, 13_500_000)
        out.number("g at +8 bp: 1.4x", s.gNow)
        out.number("to the user: $13.50 less 2% of the $3.50 profit", s.toUser)
        out.number("sell fee: $14 less $13.50", s.sellFee)
        out.number("winner fee: 2% of the $3.50 profit", s.winnerFee)
        return out

    @scenario({5: "a setting: a 5-second bet", 3_000: "a setting: θ 3 bp", 10_250: "a setting: a 1.025x floor",
               15_000: "a setting: a 1.5x cap", 6: "a price move: +6 bp"})
    def test_A500xBetSettlesAt500xAndOnlyInItsOwnMarketsBatches():
        out = Derivation()
        pool = flash_option_pool(out)
        bet = pool.open("alice at 500x", 500, CALL, duration=5, theta=3_000, floor=10_250, cap=15_000)
        out.refused("its line in the 1000x market's batch", "ConfigMismatch", pool.liquidate, [bet], bet.liq)
        pool.warp(bet.end)
        out.refused("settling it in the 1000x market's batch", "ConfigMismatch", pool.settle, [bet], up(6))
        pool.batch = 500
        (e,) = pool.settle([bet], up(6))
        out.number("g at +6 bp at 500x: 1.3x", e.g)
        out.number("payout: $13", e.payout)
        out.note("at 1000x the same move would give g %s" % num(m.g_bps(P0, up(6), CALL, 1000, 10_250, 15_000)))
        return out

    @scenario({300: "a setting: a 5-minute bet", 17_640: "a setting: θ 17.64 bp", 10_500: "a setting: a 1.05x floor",
               20_000: "a setting: a 2x cap", 8: "a price move: +8 bp",
               10_700_000: "a quote: the sale amount, $10.70", 5: "a setting: a 5-second bet",
               3_000: "a setting: θ 3 bp", 10_050: "a setting: a 1.005x floor", 15_000: "a setting: a 1.5x cap",
               6: "a price move: 6 bp down, in the short's favour"})
    def test_A100xBetTheLinesTheSaleAndTheSettlementAt100x():
        out = Derivation()
        pool = flash_option_pool(out)
        bet = pool.open("alice at 100x", 100, CALL, duration=300, theta=17_640, floor=10_500, cap=20_000)
        out.number("the line: 17.64 bp below the entry", bet.liq)
        out.number("the cap line: 2x is a 1% move at 100x", bet.cap_price)
        price = up(8)
        most = out.number("the payout at +8 bp at 100x, 1.08x: the highest valuation", payout_at(bet, price))
        over = out.number("one unit above it", most + 1)
        out.refused("a valuation one unit above it", "ValuationAboveCurrentPayout", pool.sell, bet, price, over, over,
                    over)
        s = pool.sell(bet, price, most, 10_700_000, 10_700_000)
        out.number("g at +8 bp: 1.08x, above the 1.05x floor", s.gNow)
        short_bet = pool.open("alice's 100x short", 100, PUT, duration=5, theta=3_000, floor=10_050, cap=15_000)
        out.note("the short's line is above the entry and its cap line below: %s, %s" % (
            at(short_bet.liq), at(short_bet.cap_price)))
        pool.warp(short_bet.end)
        pool.batch = 500
        out.refused("settling it in the 500x market's batch", "ConfigMismatch", pool.settle, [short_bet], down(6))
        pool.batch = 100
        (e,) = pool.settle([short_bet], down(6))
        out.number("g at 6 bp down, for the short: 1.06x", e.g)
        out.number("payout: $10.60", e.payout)
        return out

    @scenario({12_000: "a setting: a 1.2x floor", 25_000: "a setting: a 2.5x cap", 10_500: "a setting: a 1.05x floor",
               20_000: "a setting: a 2x cap", 3: "a count: three bets", 0: "an index: the first bet"})
    def test_EachBetRecordsItsLeverageAndEachLeverageLiquidatesInItsOwnBatch():
        out = Derivation()
        pool = flash_option_pool(out)
        bets = [pool.open("alice at 1000x", 1000, CALL),
                pool.open("alice at 500x", 500, CALL, floor=12_000, cap=25_000),
                pool.open("alice at 100x", 100, CALL, floor=10_500, cap=20_000)]
        line = bets[0].liq
        assert all(bet.liq == line for bet in bets)
        out.note("θ is a price distance, so the three lines are one price: %s" % at(line))
        for bet, what in zip(bets, ("4x at 1000x, +0.3%", "2.5x at 500x, +0.3%", "2x at 100x, +1%")):
            out.number("the cap line, %s" % what, bet.cap_price)
        out.refused("the 1000x and the 500x bet in one batch", "ConfigMismatch", pool.liquidate, bets[:2], line)
        for bet in bets:
            pool.batch = bet.leverage
            pool.liquidate([bet], line)
        return out


# --- LeverageTradingScenarios.t.sol -----------------------------------------------------------------------------------


def trading_pool(out):
    """`LeverageTrading_Scenario_Test.setUp`: the settlement tests' pool, with BTC at 500x and 100x on the tier
    settings (gate off) beside 1000x."""
    return base_pool(out, {1000: launch_config(10_000), 500: tier_config(500), 100: tier_config(100)})


def use_five_second_rules(pool):
    """`_useFiveSecondRules`: at 500x and 100x a 5-second rule up to the widest line in the 4-minute slot, and at
    1000x one with θ 0.1 to 0.5 bp in the 5-minute slot."""
    pool.set_config(500, five_second_tier_config(500))
    pool.set_config(100, five_second_tier_config(100))
    pool.set_config(1000, with_rule(launch_config(10_000), 4, rule(5, 1_000, 5_000)))


def expect_winners(out, pool, leverage, moves):
    """`_expectWinners`: the example bet at `leverage`, long and short, settled at each move in its favour."""
    pool.batch = leverage
    for bps in moves:
        for side in (CALL, PUT):
            name = "%dx %s winner at +%d bp" % (leverage, SIDE[side], bps)
            bet = pool.open(name, leverage, side, **example(leverage))
            pool.warp(bet.end)
            (e,) = pool.settle([bet], favour(side, bps))
            out.number("%dx %s at +%d bp: g" % (leverage, SIDE[side], bps), e.g)
            out.number("%dx %s at +%d bp: paid to the user" % (leverage, SIDE[side], bps), e.toUser)


def expect_flat_losers_and_inside(out, pool, leverage):
    """`_expectFlatLosersAndInside`: at `leverage`, a flat expiry, a loser at -2 bp on each side, and a bet one unit
    inside its line on each side; on the line, and beyond it, a settle is LiquidateInstead."""
    pool.batch = leverage
    flat = pool.open("%dx flat" % leverage, leverage, CALL, **example(leverage))
    pool.warp(flat.end)
    (e,) = pool.settle([flat], P0)
    out.number("%dx flat: the stake back" % leverage, e.toUser)
    out.number("%dx flat: winner fee + loser fee" % leverage, e.winnerFee + e.loserFee)
    for side in (CALL, PUT):
        loser = pool.open("%dx %s loser" % (leverage, SIDE[side]), leverage, side, **example(leverage))
        pool.warp(loser.end)
        (e,) = pool.settle([loser], favour(side, -2))
        out.number("%dx %s at -2 bp: g" % (leverage, SIDE[side]), e.g)
        out.number("%dx %s at -2 bp: paid to the user" % (leverage, SIDE[side]), e.toUser)
        out.number("%dx %s at -2 bp: loser fee, 3%% of the loss" % (leverage, SIDE[side]), e.loserFee)
    for side in (CALL, PUT):
        bet = pool.open("%dx %s inside" % (leverage, SIDE[side]), leverage, side, **example(leverage))
        pool.warp(bet.end)
        inward = 1 if side == CALL else -1
        out.refused("%s on its line" % bet.name, "LiquidateInstead", pool.settle, [bet], bet.liq)
        out.refused("%s one unit beyond it" % bet.name, "LiquidateInstead", pool.settle, [bet], bet.liq - inward)
        (e,) = pool.settle([bet], bet.liq + inward)
        out.number("%dx %s one unit inside the line: g" % (leverage, SIDE[side]), e.g)


def expect_sale_case(out, pool, leverage, side, bps, amount):
    """`_expectSaleCase`: the example bet at `leverage` on `side`, sold at once `bps` in its favour, valued at the
    payout there and sold for `amount`, which is also the user's minimum."""
    bet = pool.open("%dx %s sale at %+d bp" % (leverage, SIDE[side], bps), leverage, side, **example(leverage))
    price = favour(side, bps)
    what = "%dx %s at %+d bp" % (leverage, SIDE[side], bps)
    value = out.number("%s: the payout there, the valuation sold at" % what, payout_at(bet, price))
    s = pool.sell(bet, price, value, amount, amount)
    out.number("%s: g" % what, s.gNow)
    out.number("%s: to the user" % what, s.toUser)
    out.number("%s: sell fee" % what, s.sellFee)
    out.number("%s: winner fee" % what, s.winnerFee)
    out.number("%s: loser fee" % what, s.loserFee)


def expect_payout_bound(out, pool, leverage):
    """`_expectPayoutBound`: at `leverage`, long and short at +4 bp, a valuation one unit above the payout is refused,
    and the bet sells at the payout."""
    for side in (CALL, PUT):
        bet = pool.open("%dx %s bound" % (leverage, SIDE[side]), leverage, side, **example(leverage))
        price = favour(side, 4)
        most = out.number("%dx %s at +4 bp: the payout, the highest valuation" % (leverage, SIDE[side]),
                          payout_at(bet, price))
        out.refused("a valuation one unit above it", "ValuationAboveCurrentPayout", pool.sell, bet, price, most + 1,
                    most, most)
        s = pool.sell(bet, price, most, most, most)
        out.number("%dx %s at +4 bp: g" % (leverage, SIDE[side]), s.gNow)


def limit_for(pool, terms):
    """`_limitFor`: the smallest open-gate rate, in bps of free money, under which a bet with `terms` opens now:
    exposure x 10,000 / free, rounded up, with the open bets' maximum profit counted (`limit`) and alone (`alone`)."""
    mine = m.max_profit(terms["stake"], terms["cap"])
    limit = -(-(pool.open_max_profit + mine) * m.BPS // pool.free)
    alone = -(-mine * m.BPS // pool.free)
    return limit, alone, mine


def queue_three_ious(out, pool):
    """`_queueThreeIous`: on the empty pool, a 500x, a 100x and a 1000x 5-second winner at +10 bp (1.5x, 1.1x and 2x),
    settled in that order. With no free money, each gets its stake back and is owed its whole profit, queued in
    settle order."""
    bets = [pool.open("the 500x IOU", 500, CALL, **example(500, duration=5)),
            pool.open("the 100x IOU", 100, CALL, **example(100, duration=5)),
            pool.open("the 1000x IOU", 1000, CALL, duration=5)]
    first = pool.next_queue_seq
    pool.warp(bets[-1].end)
    for i, bet in enumerate(bets):
        pool.batch = bet.leverage
        (e,) = pool.settle([bet], up(10))
        out.number("%s at +10 bp: profit paid now" % bet.name, e.paid)
        out.number("%s at +10 bp: to the user, the stake back" % bet.name, e.toUser)
        out.number("%s at +10 bp: owed, the whole profit" % bet.name, e.owed)
        assert e.queueSeq == first + i
    return bets


def open_waiting_bets(pool):
    """`_openWaitingBets`: 3-minute bets at 1000x, 500x and 100x, θ 5 bp, which fits each one's 3-minute range."""
    return [pool.open("waiting at 1000x", 1000, CALL, duration=180, theta=5_000),
            pool.open("waiting at 500x", 500, CALL, **example(500, duration=180, theta=5_000)),
            pool.open("waiting at 100x", 100, CALL, **example(100, duration=180, theta=5_000))]


class LeverageTrading_Scenario_Test:
    """The 500x and 100x tiers beside 1000x on one pool, and IOUs of the three leverages on a second, empty pool."""

    FILE = "test/scenarios/LeverageTradingScenarios.t.sol"
    HELPERS = {
        "_useFiveSecondRules": {5: "a setting: a 5-second rule", 1_000: "a setting: θ from 0.1 bp",
                                5_000: "a setting: θ up to 0.5 bp"},
        "_expectWinners": {3: "a count: three cases", 2: "a count: two sides"},
        "_expectFlatLosersAndInside": {2: "a count: two sides", -2: "a price move: -2 bp", 1: "one price unit"},
        "_expectPayoutBound": {2: "a count: two sides", 4: "a price move: +4 bp", 1: "one unit above the payout"},
        "_limitFor": {10_000: "a constant: 10,000 bps in 100%", 1: "a constant: the -1 of a division rounded up"},
        "_queueThreeIous": {3: "a count: three bets", 5: "a setting: 5-second bets", 10: "a price move: +10 bp"},
        "_openWaitingBets": {3: "a count: three bets", 180: "a setting: 3-minute bets", 5_000: "a setting: θ 5 bp"},
    }

    @scenario({2: "a count: two tiers", 5: "a count: five duration rules",
               10_000_000: "a constant: 10^7 (E7), the line limit"})
    def test_PutsTheTierLinesOnThe500xAnd100xMarkets():
        out = Derivation()
        pool = trading_pool(out)
        for leverage in (500, 100):
            pool.set_config(leverage, tier_config(leverage))
            widest = max(r.thetaMaxE7 for r in tier_config(leverage).durations)
            assert all(m.theta_within_limit(r.thetaMaxE7, leverage) for r in tier_config(leverage).durations)
            out.note("%dx: every line under 1/%d, the widest %s x %d = %s < 10^7" % (
                leverage, leverage, num(widest), leverage, num(widest * leverage)))
        return out

    @scenario({2_000_000_000: "a top-up: $2,000",
               1_000_000_000: "not derived: the margin of an inequality (free money at least the floor plus $1,000)"})
    def test_TopsThePoolUpBy2000():
        out = Derivation()
        pool = trading_pool(out)
        pool.fund(2_000 * TOKEN)
        assert pool.free >= pool.floor + 1_000 * TOKEN
        out.note("free money %s is at least the floor plus $1,000, %s" % (num(pool.free),
                                                                         num(pool.floor + 1_000 * TOKEN)))
        return out

    @scenario()
    def test_OpensTheTierExampleBetLongAndShortWithTheLinesAtItsLeverage():
        out = Derivation()
        pool = trading_pool(out)
        for leverage, side in ((500, CALL), (500, PUT), (100, CALL), (100, PUT)):
            bet = pool.open("%dx %s" % (leverage, SIDE[side]), leverage, side, **example(leverage))
            out.number("%dx %s: the line, θ %s" % (leverage, SIDE[side], num(bet.theta)), bet.liq)
            out.number("%dx %s: the cap line" % (leverage, SIDE[side]), bet.cap_price)
        return out

    @scenario({2: "a count: two tiers; index arithmetic", 10: "a count: ten bets", 5: "a count: five duration rules",
               4: "index arithmetic: the longest duration first", 1: "one unit past a range; index arithmetic",
               20: "a price move: 20 bp down"})
    def test_OpensEveryDurationAtItsLowestAndHighestLine():
        out = Derivation()
        pool = trading_pool(out)
        for leverage in (500, 100):
            bets = []
            for r in reversed(tier_config(leverage).durations):
                for theta in (r.thetaMinE7 - 1, r.thetaMaxE7 + 1):
                    refusal("θ %s at %dx for %d s" % (num(theta), leverage, r.durationSecs), "InvalidLeverageParams",
                            pool.open, "", leverage, CALL, **example(leverage, duration=r.durationSecs, theta=theta))
                pool.out = None
                for end, theta in (("lowest", r.thetaMinE7), ("highest", r.thetaMaxE7)):
                    bets.append(pool.open("%dx %d s %s" % (leverage, r.durationSecs, end), leverage, CALL,
                                          **example(leverage, duration=r.durationSecs, theta=theta)))
                pool.out = out
                out.note("%dx, %d s: θ %s and %s open, %s and %s are refused (InvalidLeverageParams)" % (
                    leverage, r.durationSecs, num(r.thetaMinE7), num(r.thetaMaxE7), num(r.thetaMinE7 - 1),
                    num(r.thetaMaxE7 + 1)))
            pool.batch = leverage
            pool.out = None
            fees = pool.liquidate(bets, down(20))
            pool.out = out
            assert len(set(fees)) == 1
            out.note("one tick 20 bp down liquidates all ten: %s" % pool.books())
            out.number("%dx: each of the ten bets' loser fee, 3%% of $10" % leverage, fees[0])
        return out

    @scenario({2: "a count: two tiers", 1: "one unit past a bound"})
    def test_OpensStakeFloorAndCapAtEachOfTheirBounds():
        out = Derivation()
        pool = trading_pool(out)
        for leverage in (500, 100):
            c = tier_config(leverage)
            low = example(leverage, stake=c.minStake, floor=c.floorMinBps, cap=c.capMinBps)
            high = example(leverage, stake=c.maxStake, floor=c.floorMaxBps, cap=c.capMaxBps)
            for terms, change, error in ((low, {"stake": c.minStake - 1}, "InvalidAmount"),
                                         (high, {"stake": c.maxStake + 1}, "InvalidAmount"),
                                         (low, {"floor": c.floorMinBps - 1}, "InvalidLeverageParams"),
                                         (high, {"floor": c.floorMaxBps + 1}, "InvalidLeverageParams"),
                                         (low, {"cap": c.capMinBps - 1}, "InvalidLeverageParams"),
                                         (high, {"cap": c.capMaxBps + 1}, "InvalidLeverageParams")):
                (name, value), = change.items()
                out.refused("%dx: %s %s" % (leverage, name, num(value)), error, pool.open, "", leverage, CALL,
                            **dict(terms, **change))
            a = pool.open("%dx low" % leverage, leverage, CALL, **low)
            b = pool.open("%dx high" % leverage, leverage, CALL, **high)
            pool.batch = leverage
            fees = pool.liquidate([a, b], a.liq)
            out.number("%dx: the $1 bet's loser fee, 3%% of $1" % leverage, fees[0])
            out.number("%dx: the $50 bet's loser fee, 3%% of $50" % leverage, fees[1])
        return out

    @scenario()
    def test_TurnsTheFourMinuteLineIntoAFiveSecondOneUpToTheWidestLine():
        out = Derivation()
        pool = trading_pool(out)
        out.number("the widest line at 500x: (10^7 - 1) // 500", widest_line(500))
        out.number("the widest line at 100x: (10^7 - 1) // 100", widest_line(100))
        use_five_second_rules(pool)
        return out

    @scenario({2: "a count: two tiers", 5: "a setting: 5-second bets", 1: "one price unit"})
    def test_AtTheWidestLineABetOpensPaysZeroOneUnitInsideItsLineAndIsLiquidatedOnIt():
        out = Derivation()
        pool = trading_pool(out)
        use_five_second_rules(pool)
        for leverage in (500, 100):
            widest = widest_line(leverage)
            long_bet = pool.open("%dx widest long" % leverage, leverage, CALL,
                                 **example(leverage, duration=5, theta=widest))
            short_bet = pool.open("%dx widest short" % leverage, leverage, PUT,
                                  **example(leverage, duration=5, theta=widest))
            out.number("%dx: the long's line at θ %s" % (leverage, num(widest)), long_bet.liq)
            out.note("g reaches 0 at %s, past the line" % at(P0 - P0 // leverage))
            pool.warp(long_bet.end)
            pool.batch = leverage
            (e,) = pool.settle([long_bet], long_bet.liq + 1)
            out.number("%dx: g one unit inside the line" % leverage, e.g)
            out.number("%dx: payout + to the user" % leverage, e.payout + e.toUser)
            out.number("%dx: loser fee, 3%% of the stake" % leverage, e.loserFee)
            out.refused("the short one unit inside its line", "LiquidationPriceNotReached", pool.liquidate,
                        [short_bet], short_bet.liq - 1, short_bet.start)
            pool.liquidate([short_bet], short_bet.liq, short_bet.start)
        return out

    @scenario({2: "a count: two tiers", 10: "a time: 10 s later", 1: "one price unit"})
    def test_LiquidatesTheTierExampleBetsOnTheirLinesNotOneUnitInside():
        out = Derivation()
        pool = trading_pool(out)
        for leverage in (500, 100):
            long_bet = pool.open("%dx long" % leverage, leverage, CALL, **example(leverage))
            short_bet = pool.open("%dx short" % leverage, leverage, PUT, **example(leverage))
            pool.warp(pool.now + 10)
            pool.batch = leverage
            out.refused("the long one unit inside its line", "LiquidationPriceNotReached", pool.liquidate, [long_bet],
                        long_bet.liq + 1, long_bet.start)
            out.refused("the short one unit inside its line", "LiquidationPriceNotReached", pool.liquidate,
                        [short_bet], short_bet.liq - 1, short_bet.start)
            (fee,) = pool.liquidate([long_bet], long_bet.liq, long_bet.start)
            out.number("%dx: the long's loser fee, 3%% of $10" % leverage, fee)
            (fee,) = pool.liquidate([short_bet], short_bet.liq, short_bet.start)
            out.number("%dx: the short's loser fee, 3%% of $10" % leverage, fee)
        return out

    @scenario({5_250: "a setting: θ 5.25 bp, the 500x bets' line, inside the 100x range"})
    def test_RejectsALiquidationBatchThatMixesLeverages():
        out = Derivation()
        pool = trading_pool(out)
        a = pool.open("500x a", 500, CALL, **example(500))
        b = pool.open("500x b", 500, CALL, **example(500))
        c = pool.open("100x c", 100, CALL, **example(100, theta=5_250))
        assert a.liq == b.liq == c.liq
        out.note("one line for all three: %s" % at(a.liq))
        pool.batch = 500
        out.refused("a, b and c in the 500x batch", "ConfigMismatch", pool.liquidate, [a, b, c], a.liq)
        out.refused("c and a in the 500x batch", "ConfigMismatch", pool.liquidate, [c, a], a.liq)
        pool.batch = 100
        out.refused("c and a in the 100x batch", "ConfigMismatch", pool.liquidate, [c, a], a.liq)
        pool.batch = 500
        pool.liquidate([a, b], a.liq)
        pool.batch = 100
        pool.liquidate([c], a.liq)
        return out

    @scenario({2: "a price move: +2 bp", 10: "a price move: +10 bp", 40: "a price move: +40 bp, past the cap line",
               50: "a price move: +50 bp", 150: "a price move: +150 bp, past the cap line"})
    def test_PaysWinnersAtTheFloorMidRangeAndTheCap():
        out = Derivation()
        pool = trading_pool(out)
        expect_winners(out, pool, 500, (2, 10, 40))
        expect_winners(out, pool, 100, (2, 50, 150))
        return out

    @scenario()
    def test_FlatExpiryLosersAndOneUnitInsideTheLine():
        out = Derivation()
        pool = trading_pool(out)
        expect_flat_losers_and_inside(out, pool, 500)
        expect_flat_losers_and_inside(out, pool, 100)
        return out

    @scenario({6: "a price move: +6 bp"})
    def test_SettlesBetsOfThreeLeveragesExpiringInTheSameSecond():
        out = Derivation()
        pool = trading_pool(out)
        x1000 = pool.open("1000x", 1000, CALL)
        x500 = pool.open("500x", 500, CALL, **example(500))
        x500b = pool.open("500x, another user", 500, CALL, **example(500))
        x100 = pool.open("100x", 100, CALL, **example(100))
        end = x1000.end
        assert x500.end == x500b.end == x100.end == end
        pool.warp(end)
        tick = up(6)
        pool.batch = 500
        out.refused("both 500x bets and the 100x bet in the 500x batch", "ConfigMismatch", pool.settle,
                    [x500, x500b, x100], tick)
        pool.batch = 1000
        out.refused("the 1000x and a 500x bet in the 1000x batch", "ConfigMismatch", pool.settle, [x1000, x500], tick)
        (e,) = pool.settle([x1000], tick)
        out.number("1000x at +6 bp: g 1.6x", e.g)
        pool.batch = 500
        e1, e2 = pool.settle([x500, x500b], tick)
        out.number("500x at +6 bp: g 1.3x", e1.g)
        out.number("500x, another user: g 1.3x", e2.g)
        pool.batch = 100
        (e,) = pool.settle([x100], tick)
        out.number("100x at +6 bp: g 1.06x", e.g)
        return out

    @scenario({6: "a price move: +6 bp", -2: "a price move: -2 bp", 40: "a price move: +40 bp, past the cap line",
               20: "a price move: +20 bp", 150: "a price move: +150 bp, past the cap line",
               12_500_000: "a quote: the sale amount, $12.50", 11_500_000: "a quote: the sale amount, $11.50"})
    def test_SellsLongAndShortAtAProfitAtALossAndCapped():
        out = Derivation()
        pool = trading_pool(out)
        for leverage, side, bps, amount in ((500, CALL, 6, 12_500_000), (500, PUT, 6, 12_500_000),
                                            (500, CALL, -2, 8_600_000), (500, CALL, 40, 25_000_000),
                                            (100, CALL, 20, 11_500_000), (100, PUT, 20, 11_500_000),
                                            (100, CALL, -2, 9_400_000), (100, PUT, 150, 20_000_000)):
            expect_sale_case(out, pool, leverage, side, bps, amount)
        return out

    @scenario()
    def test_BoundsASalesValuationByThePayoutAtTheBetsOwnLeverage():
        out = Derivation()
        pool = trading_pool(out)
        expect_payout_bound(out, pool, 500)
        expect_payout_bound(out, pool, 100)
        return out

    @scenario({1: "one bp below the limit", 10: "a price move: 10 bp down"})
    def test_AMarketsExposureGateCountsEveryLeveragesBets():
        out = Derivation()
        pool = trading_pool(out)
        x1000 = pool.open("1000x", 1000, CALL)
        x100 = pool.open("100x", 100, CALL, **example(100))
        terms = example(500)
        limit, alone, mine = limit_for(pool, terms)
        out.note("the 500x bet's maximum profit %s; with the open bets' %s and %s free: the limit is %s bps, %s bps on "
                 "its own" % (num(mine), num(pool.open_max_profit), num(pool.free), num(limit), num(alone)))
        assert alone < limit - 1
        pool.set_config(500, tier_config(500, gate=limit - 1))
        out.refused("the 500x bet with the gate one bp below the limit", "OpenBlockedExposure", pool.open, "500x", 500,
                    CALL, **terms)
        x100b = pool.open("100x, the second", 100, CALL, **example(100))
        limit, _, _ = limit_for(pool, terms)
        out.note("after the second 100x bet the limit is %s bps" % num(limit))
        refusal("the gate one bp below the new limit", "OpenBlockedExposure", m.open_gate, pool.total_owed,
                m.UINT64_MAX, pool.open_max_profit, mine, pool.free, limit - 1)
        pool.set_config(500, tier_config(500, gate=limit))
        bet = pool.open("500x", 500, CALL, **terms)
        pool.set_config(500, tier_config(500))
        pool.liquidate([x1000], down(10))
        pool.batch = 100
        pool.liquidate([x100, x100b], down(10))
        pool.batch = 500
        pool.liquidate([bet], down(10))
        return out

    @scenario({3: "a count: three markets"})
    def test_CreatesThe500xAnd100xMarketsOfAnEmptyPool():
        out = Derivation()
        pool = empty_pool(out)
        out.number("the empty pool's total + locked + owed + open bets + IOUs",
                   pool.total + pool.locked + pool.total_owed + pool.open_positions + pool.owed_positions)
        return out

    @scenario()
    def test_WinnersTheEmptyPoolCantPayJoinOneQueueInSettleOrder():
        out = Derivation()
        pool = empty_pool(out)
        queue_three_ious(out, pool)
        return out

    @scenario({3: "a count: three bets", 9_500_000: "a quote: the sale amount and the user's minimum, $9.50",
               1: "one unit below the owed total", 5: "a setting: 5-second bets"})
    def test_WhileAnyoneIsOwedNoLeverageCanSellAndEachOwedGateStopsOnlyItsOwnOpens():
        out = Derivation()
        pool = empty_pool(out)
        queue_three_ious(out, pool)
        waiting = open_waiting_bets(pool)
        value = out.number("a flat valuation: the payout at the entry, the stake", payout_at(waiting[0], P0))
        for bet in waiting:
            out.refused("selling %s for $9.50 while anyone is owed" % bet.name, "QueueNotEmpty", pool.sell, bet, P0,
                        value, 9_500_000, 9_500_000)
        owed = out.number("total owed: $5 + $1 + $10", pool.total_owed)
        pool.set_config(500, five_second_tier_config(500)._replace(maxTotalOwed=owed - 1))
        y500 = example(500, duration=5)
        out.refused("y at 500x, its owed limit one unit below", "OpenBlockedTotalOwed", pool.open, "y at 500x", 500,
                    CALL, **y500)
        y100 = pool.open("y at 100x", 100, CALL, **example(100, duration=5))
        pool.set_config(500, five_second_tier_config(500)._replace(maxTotalOwed=owed))
        y = pool.open("y at 500x", 500, CALL, **y500)
        pool.set_config(500, five_second_tier_config(500))
        pool.warp(y100.end)
        pool.batch = 100
        (e,) = pool.settle([y100], P0)
        out.number("100x flat: owed", e.owed)
        pool.batch = 500
        (e,) = pool.settle([y], P0)
        out.number("500x flat: owed", e.owed)
        return out

    @scenario({3: "a count: three IOUs", 5_500_000: "a top-up: $5.50, the 500x IOU and half of the 100x one"})
    def test_RepaysTheQueueInOrderAcrossLeverages():
        out = Derivation()
        pool = empty_pool(out)
        queue_three_ious(out, pool)
        out.note("the queue, head first: %s" % ", ".join(bet.name for bet in pool.queue))
        pool.fund(5_500_000)
        paid = pool.repay(3)
        out.number("repayments: the 1000x IOU waits", len(paid))
        out.number("the 500x IOU: repaid in full", paid[0][1].amount)
        out.number("the 500x IOU: still owed", paid[0][1].remaining)
        out.number("the 100x IOU: repaid, half of it", paid[1][1].amount)
        out.number("the 100x IOU: still owed", paid[1][1].remaining)
        rest = out.number("owed in all now, which the second top-up repays exactly", pool.total_owed)
        pool.fund(rest)
        paid = pool.repay(3)
        out.number("repayments: the 100x IOU's rest and the 1000x IOU", len(paid))
        out.number("still owed on both", sum(r.remaining for _, r in paid))
        out.number("total owed", pool.total_owed)
        out.number("IOUs", pool.owed_positions)
        assert pool.next_repay_seq == pool.next_queue_seq
        return out

    @scenario({3: "a count: up to three IOUs; three bets"})
    def test_WithTheQueueEmptyTheBetsOfAllThreeLeveragesSellAgain():
        out = Derivation()
        pool = empty_pool(out)
        queue_three_ious(out, pool)
        waiting = open_waiting_bets(pool)
        owed = out.number("the top-up: all that is owed, $5 + $1 + $10", pool.total_owed)
        pool.fund(owed)
        pool.repay(3)
        for bet in waiting:
            value = out.number("%s: a flat valuation, the payout at the entry" % bet.name, payout_at(bet, P0))
            s = pool.sell(bet, P0, value, 9_500_000, 9_500_000)
            out.number("%s: g 1x" % bet.name, s.gNow)
            out.number("%s: to the user, $9.50" % bet.name, s.toUser)
            out.number("%s: sell fee" % bet.name, s.sellFee)
            out.number("%s: winner fee + loser fee" % bet.name, s.winnerFee + s.loserFee)
        out.number("stake held", pool.locked)
        out.number("total owed", pool.total_owed)
        out.number("open bets", pool.open_positions)
        out.number("IOUs", pool.owed_positions)
        return out


CLASSES = (Liquidate_Scenario_Test, Settle_Scenario_Test, Sell_Scenario_Test, Repay_Scenario_Test,
           FlashOption_Scenario_Test, LeverageTrading_Scenario_Test)


def tests_of(cls):
    """The names of `cls`'s derivations, in the order the file declares them."""
    return [name for name in vars(cls) if name.startswith("test")]


# --- Reading the test files -------------------------------------------------------------------------------------------

#: An integer literal: decimal with `_` separators, a decimal point and `e` notation (`12.5e6`), or hexadecimal.
NUMBER = re.compile(r"(?<![\w.$])(0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE]\d+)?)(?![\w.])")
FUNCTION = re.compile(r"\bfunction\s+(\w+)\s*\(")
CALL_SITE = re.compile(r"\b(\w+)\s*\(")
#: The characters after which a `-` is a sign, not a subtraction.
SIGN_AFTER = set("(,[{=?:;+-*/%<>!&|^~")


class Literal(SimpleNamespace):
    """An integer literal of a test file: `line`, `token` as written, `value`, and `offset` in the file."""


class Function(SimpleNamespace):
    """A function of a test file: `name`, its body's `literals`, and the `calls` it makes to the file's functions."""


def blank(source):
    """`source` with its comments and string literals blanked out, keeping every offset and line break."""
    out = list(source)
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif source[i] in "\"'":
            j = i + 1
            while j < n and source[j] != source[i]:
                j += 2 if source[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j + 1
            continue
        else:
            i += 1
            continue
        for k in range(i, j):
            if out[k] != "\n":
                out[k] = " "
        i = j
    return "".join(out)


def literal_value(token):
    """The integer a literal stands for (`12.5e6` is 12,500,000), or None for one that is not a whole number."""
    text = token.replace("_", "")
    if text[:2] in ("0x", "0X"):
        return int(text, 16)
    value = Decimal(text)
    return int(value) if value == value.to_integral_value() else None


def before(text, i):
    """The index of the last character before `i` that is not white space (-1 at the start)."""
    i -= 1
    while i >= 0 and text[i].isspace():
        i -= 1
    return i


def after(text, i):
    """The index of the first character at or after `i` that is not white space."""
    while i < len(text) and text[i].isspace():
        i += 1
    return i


def literals_in(text, start, end):
    """The integer literals of `text[start:end]`, with a leading minus sign read as part of the literal. An array
    subscript (`endings[0]`) or a fixed array length (`Bet[3]`) is skipped: it names a place, not a number."""
    found = []
    for match in NUMBER.finditer(text, start, end):
        value = literal_value(match.group(1))
        if value is None:
            continue
        left, right = before(text, match.start()), after(text, match.end())
        if left >= 0 and text[left] == "[" and right < len(text) and text[right] == "]":
            owner = before(text, left)
            if owner >= 0 and (text[owner].isalnum() or text[owner] in "_)]"):
                continue
        offset = match.start()
        if left >= 0 and text[left] == "-":
            sign = before(text, left)
            if sign < 0 or text[sign] in SIGN_AFTER or text[max(sign - 5, 0):sign + 1] == "return":
                value, offset = -value, left
        found.append(Literal(line=text.count("\n", 0, match.start()) + 1, token=match.group(1), value=value,
                             offset=offset))
    return found


def read_functions(path):
    """The functions of a Solidity file with a body, by name, in order."""
    with open(path) as f:
        text = blank(f.read())
    functions = []
    for match in FUNCTION.finditer(text):
        i, depth = match.end(), 1
        while depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        while text[i] not in "{;":
            i += 1
        if text[i] == ";":
            continue
        start, depth = i, 0
        while True:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
            if depth == 0:
                break
        functions.append(Function(name=match.group(1), literals=literals_in(text, start, i), body=text[start:i]))
    names = {f.name for f in functions}
    for f in functions:
        f.calls = {c for c in CALL_SITE.findall(f.body) if c in names and c != f.name}
    return {f.name: f for f in functions}


def scope_of(test, functions):
    """A test's body: the test itself, the helpers of its file it calls (and the ones they call), and its contract's
    setUp with its helpers."""
    seen, todo = [], [test.name] + (["setUp"] if "setUp" in functions else [])
    while todo:
        name = todo.pop(0)
        if name in seen:
            continue
        seen.append(name)
        todo.extend(sorted(functions[name].calls))
    return [functions[name] for name in seen]


def read_constant(rel, name):
    """The literal value of `name`'s `constant` declaration in the file `rel`, or None."""
    with open(os.path.join(ROOT, rel)) as f:
        text = blank(f.read())
    match = re.search(r"\bconstant\s+%s\s*=\s*([^;]+);" % name, text)
    token = match.group(1).strip() if match else ""
    return literal_value(token) if NUMBER.fullmatch(token) else None


# --- The check ------------------------------------------------------------------------------------------------------


def check():
    """Every derived number is a literal of its test, every other literal is listed, and the inputs are the test
    files' own. Prints the coverage, test by test and file by file; returns 1 on any failure."""
    failures = []
    for rel, name, value in SOL_CONSTANTS:
        found = read_constant(rel, name)
        if found != value:
            failures.append("%s: %s is %s in the file, %s here" % (rel, name, found, num(value)))
    rows = []
    for cls in CLASSES:
        functions = read_functions(os.path.join(ROOT, cls.FILE))
        tests = [f for f in functions.values() if f.name.startswith("test")]
        derivations = tests_of(cls)
        for name in sorted(set(derivations) - {f.name for f in tests}):
            failures.append("%s: %s derives a test the file does not have" % (cls.FILE, name))
        print(os.path.basename(cls.FILE))
        kinds = {}  # (function, offset) -> "derived", "input" or "not derived": each literal of the file once
        for test in tests:
            if test.name not in derivations:
                failures.append("%s: %s has no derivation" % (cls.FILE, test.name))
                continue
            derive = getattr(cls, test.name)
            try:
                numbers = derive().numbers()
            except Disagreement as e:
                failures.append("%s: %s: %s" % (cls.FILE, test.name, e))
                continue
            derived = {value for _, value in numbers}
            scope = scope_of(test, functions)
            values = {lit.value for f in scope for lit in f.literals}
            for label, value in numbers:
                if value not in values:
                    failures.append("%s: %s: derived %s (%s) is not a literal of the test" % (
                        cls.FILE, test.name, num(value), label))
            tally = {"derived": 0, "input": 0, "not derived": 0}
            notes = []
            for f in scope:
                table = derive.literals if f is test else cls.HELPERS.get(f.name, {})
                for lit in f.literals:
                    key = (f.name, lit.offset)
                    if lit.value in derived:
                        kind = "derived"
                    else:
                        tag = table.get(lit.value)
                        if tag is None:
                            failures.append("%s:%d: %s: the literal %s is neither derived nor listed" % (
                                cls.FILE, lit.line, test.name, lit.token))
                            continue
                        kind = "not derived" if tag.startswith("not derived") else "input"
                        notes.append("      line %d: %s%s  %s%s" % (lit.line, "-" if lit.value < 0 else "", lit.token,
                                                                    tag, "" if f is test else " (%s)" % f.name))
                    tally[kind] += 1
                    if kinds.get(key) != "derived":
                        kinds[key] = kind
            print("  %s: derives %s; %s: %d derived, %d input, %d not derived" % (
                test.name, count(len(numbers), "number"), count(sum(tally.values()), "literal"), tally["derived"],
                tally["input"], tally["not derived"]))
            for line in notes:
                print(line)
        counts = tuple(sum(1 for k in kinds.values() if k == kind) for kind in ("derived", "input", "not derived"))
        rows.append((os.path.basename(cls.FILE), len(tests), len(kinds)) + counts)
    print()
    print("Each literal once per file (a helper's literals count once):")
    print("%-34s %5s %8s %7s %6s %11s" % ("", "tests", "literals", "derived", "inputs", "not derived"))
    for row in rows:
        print("%-34s %5d %8d %7d %6d %11d" % row)
    total = tuple(sum(row[i] for row in rows) for i in range(1, 6))
    print("%-34s %5d %8d %7d %6d %11d" % (("total",) + total))
    if failures:
        print()
        print("FAILED:")
        for failure in failures:
            print("  " + failure)
        return 1
    print("OK: every derived number is a literal of its test; every other literal is an input or not derived.")
    return 0


# --- Printing the derivations ---------------------------------------------------------------------------------------


def count(n, noun):
    """`n` and `noun`, plural unless `n` is 1."""
    return "%d %s%s" % (n, noun, "" if n == 1 else "s")


def show(cls, name):
    """Prints one test's derivation; returns 1 if the model disagrees with the test."""
    print("%s  %s" % (os.path.basename(cls.FILE), name))
    try:
        d = getattr(cls, name)()
    except Disagreement as e:
        print("  DISAGREEMENT: %s" % e)
        print()
        return 1
    for line in d.lines:
        if line[0] == "note":
            print(textwrap.fill(line[1], 118, initial_indent="    ", subsequent_indent="        "))
        else:
            print("  = %-17s %s" % (num(line[2]), line[1]))
    print()
    return 0


def main(argv):
    m.check_worked_examples()  # never derive from a model that disagrees with docs/MATH.md §12
    if "--check" in argv:
        return check()
    wanted = [a for a in argv if not a.startswith("-")]
    status = 0
    for cls in CLASSES:
        for name in tests_of(cls):
            if not wanted or any(w in name for w in wanted):
                status |= show(cls, name)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
