#!/usr/bin/env python3
"""Writes the reference model's test vectors, test/fixtures/model/<function>.json, one file per function.

Each file holds:

- "cases": inputs the function accepts, each with the outputs the model gives (a check that passes has none);
- "reverts": inputs it refuses, each with "errorName", the error the model raises.

The inputs are the function's arguments, named as in the contract (`side` and `purpose` as numbers, a position id
as a number). A case may carry a "note" naming the edge it probes. Every file starts with the edge cases: the bounds,
zero, one unit past each limit, the rounding boundaries, every revert and the worked examples of docs/MATH.md §12.
Seeded random cases follow, over the whole input domain, at each leverage tier (1000x, 500x, 100x) and at any
leverage. The random numbers come from SplitMix64 with a fixed seed, so every run writes the same bytes.

Usage, from the repository root:

    python3 model/generate_vectors.py           # write the vectors
    python3 model/generate_vectors.py --check   # exit 1 if any file differs from what the model gives now

test/model/ModelVectors.t.sol replays every file against the contract.
"""

import hashlib
import json
import os
import sys

import flash_option_math as m

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "test", "fixtures", "model")
SEED = 0x4D414E49435F464F  # the base seed; each function draws from its own stream (`stream_seed`)

MASK64 = (1 << 64) - 1
UINT256_MAX = (1 << 256) - 1
TIERS = (1000, 500, 100)
SWEEP = (1, 2, 3, 4, 15, 100, 500, 1000, 2000, 10_000)
# Each tier's settings (docs/MATH.md §12, Examples 4, 5 and 8): (floors, caps, theta lines).
TIER_RANGES = {
    1000: ((11_000, 15_000), (15_000, 40_000), (2_250, 7_350)),
    500: ((10_250, 12_500), (15_000, 25_000), (2_490, 11_760)),
    100: ((10_050, 10_500), (15_000, 20_000), (2_601, 17_640)),
}
# Price scales: BTC $83,884, ETH $3,000 and SOL $150 at exponent -8, $1 at exponent -18 and at -5, and 1 unit.
PRICES = (m.ENTRY, 300_000_000_000, 15_000_000_000, 10**18, 100_000, 1)
DURATIONS = (60, 120, 180, 240, 300)
TOKEN6 = 10**6


class Rng:
    """SplitMix64: a small, fully specified generator, so the vectors never depend on Python's `random`."""

    def __init__(self, seed):
        self.state = seed & MASK64

    def next64(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def bits(self, n):
        """A uniform n-bit number."""
        value, have = 0, 0
        while have < n:
            value = (value << 64) | self.next64()
            have += 64
        return value >> (have - n)

    def below(self, n):
        """Uniform in [0, n), by rejection."""
        if n <= 1:
            return 0
        k = (n - 1).bit_length()
        while True:
            v = self.bits(k)
            if v < n:
                return v

    def between(self, lo, hi):
        """Uniform in [lo, hi]."""
        return lo + self.below(hi - lo + 1)

    def pick(self, seq):
        return seq[self.below(len(seq))]

    def chance(self, percent):
        return self.below(100) < percent

    def log_uniform(self, lo, hi):
        """A value in [lo, hi] whose bit length is uniform, so small, middling and huge values all come up."""
        b = self.between(lo.bit_length(), hi.bit_length())
        a = max(lo, (1 << (b - 1)) if b else 0)
        z = min(hi, (1 << b) - 1)
        return self.between(a, z)

    def uint(self, bits):
        """Any uint<bits>: a special value, a log-uniform one or a uniform one."""
        top = (1 << bits) - 1
        r = self.below(10)
        if r == 0:
            return self.pick((0, 1, 2, top - 1, top, 1 << (bits - 1), (1 << (bits - 1)) - 1))
        if r < 6:
            return self.log_uniform(0, top)
        return self.below(top + 1)

    def int_(self, bits):
        """Any int<bits>, either sign."""
        half = 1 << (bits - 1)
        r = self.below(10)
        if r == 0:
            return self.pick((0, 1, -1, half - 1, -half, half - 2, -half + 1))
        if r < 6:
            v = self.log_uniform(0, half - 1)
            return -v - self.below(2) if self.chance(50) else v
        return self.between(-half, half - 1)

    def near(self, value, spread, lo, hi):
        """`value` moved by at most `spread` either way, kept in [lo, hi]."""
        return min(hi, max(lo, value + self.between(-spread, spread)))


def stream_seed(name):
    """The seed of `name`'s random stream: adding cases to one function never shifts another's."""
    digest = hashlib.sha256(("%d/%s" % (SEED, name)).encode()).digest()
    return int.from_bytes(digest[:8], "big")


class Vectors:
    """The cases of one function: runs the model on each input and files it under "cases" or "reverts"."""

    def __init__(self, name, library, spec, run):
        self.name, self.library, self.spec, self.run = name, library, spec, run
        self.cases, self.reverts, self.seen = [], [], set()
        self.extra = None  # optional (key, list) written before the cases, e.g. validateOpen's markets
        self.rng = Rng(stream_seed(name))

    def add(self, note=None, **inputs):
        """Adds one case (a duplicate of an earlier one is dropped)."""
        key = json.dumps(inputs, sort_keys=True, default=_plain)
        if key in self.seen:
            return
        self.seen.add(key)
        record = dict(inputs)
        try:
            outputs = self.run(**inputs)
        except m.Revert as e:
            record["errorName"] = e.name
            target = self.reverts
        else:
            record.update(outputs)
            target = self.cases
        if note:
            record["note"] = note
        target.append(record)

    def render(self):
        """The file's text: a header line, then one case per line."""
        header = {
            "function": self.name, "library": self.library, "spec": self.spec,
            "generator": "model/generate_vectors.py", "seed": "0x%016x" % stream_seed(self.name),
            "caseCount": len(self.cases), "revertCount": len(self.reverts),
        }
        parts = [_dumps(header)[:-1] + ",\n"]
        lists = [("cases", self.cases), ("reverts", self.reverts)]
        if self.extra:
            lists.insert(0, self.extra)
        for n, (key, items) in enumerate(lists):
            body = "\n" + ",\n".join(_dumps(x) for x in items) + "\n" if items else ""
            parts.append('"%s":[%s]%s' % (key, body, ",\n" if n < len(lists) - 1 else "}\n"))
        return "".join(parts)


def _plain(value):
    """JSON form of the model's records (a NamedTuple becomes an object with the struct's field names)."""
    if hasattr(value, "_asdict"):
        return {k: _plain(v) for k, v in value._asdict().items()}
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    return value


def _dumps(value):
    return json.dumps(_plain(value), separators=(",", ":"), ensure_ascii=True)


# --- Shared draws -----------------------------------------------------------------------------------------------------


def widest(leverage):
    """The widest line a leverage allows (§3.1): the largest thetaE7 with thetaE7 x L < 10^7."""
    return (m.E7 - 1) // leverage


def highest_cap(leverage):
    """The highest cap a short can reach at L (§3.1 rules 4 and 6)."""
    return min(m.MAX_LEVERAGE_CAP_BPS, m.BPS + leverage * m.BPS - 1)


def largest(ok, lo, hi):
    """The largest x in [lo, hi] with ok(x), for ok true up to a point and false after it."""
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if ok(mid):
            lo = mid
        else:
            hi = mid - 1
    return lo


def any_leverage(rng):
    """A leverage from 1x to 10,000x: one of the swept ones, or any, with small ones as likely as large."""
    r = rng.below(3)
    if r == 0:
        return rng.pick(SWEEP)
    if r == 1:
        return rng.log_uniform(1, m.MAX_LEVERAGE)
    return rng.between(1, m.MAX_LEVERAGE)


def bad_leverage(rng):
    """A leverage outside 1x to 10,000x."""
    return rng.pick((0, 10_001, 65_535)) if rng.chance(50) else rng.between(10_001, 65_535)


def price(rng):
    """A positive price: near a real one, or anywhere up to the int64 maximum."""
    r = rng.below(10)
    if r < 4:
        base = rng.pick(PRICES[:4])
        return max(1, base * rng.between(5_000, 20_000) // 10_000 + rng.between(-1_000, 1_000))
    if r < 8:
        return rng.log_uniform(1, m.INT64_MAX)
    return rng.between(1, m.INT64_MAX)


def theta(rng, leverage):
    """A theta inside the leverage's limit: a tier's own lines, or anywhere from 1 to the widest."""
    top = widest(leverage)
    if leverage in TIER_RANGES and rng.chance(50):
        lo, hi = TIER_RANGES[leverage][2]
        return rng.between(min(lo, top), min(hi, top))
    return rng.log_uniform(1, top) if rng.chance(50) else rng.between(1, top)


def cap(rng, leverage):
    """A cap the leverage can reach: a tier's own caps, or anywhere above 1x."""
    top = highest_cap(leverage)
    if leverage in TIER_RANGES and rng.chance(50):
        lo, hi = TIER_RANGES[leverage][1]
        return rng.between(lo, hi)
    return rng.between(m.BPS + 1, top)


def floor_for(rng, leverage, cap_bps):
    """A floor at or below `cap_bps`: a tier's own floors, or anywhere above 1x."""
    if leverage in TIER_RANGES and rng.chance(50):
        lo, hi = TIER_RANGES[leverage][0]
        return min(rng.between(lo, hi), cap_bps)
    return rng.between(m.BPS + 1, cap_bps) if cap_bps > m.BPS else cap_bps


def stake(rng):
    """A stake: $1 to $50 of a 6-decimal token (the example market), any small one, or any uint64."""
    r = rng.below(10)
    if r < 5:
        return rng.between(TOKEN6, 50 * TOKEN6)
    if r < 8:
        return rng.log_uniform(1, 10**15)
    return rng.uint(64)


def amount(rng):
    """Any uint64 amount, small ones as likely as large."""
    return rng.uint(64)


def tier_bet(rng, leverage):
    """A random bet at a leverage: (entry, price, side, floor, cap, g), with g from the model."""
    entry = price(rng)
    side = rng.below(2)
    cap_bps = cap(rng, leverage)
    floor_bps = floor_for(rng, leverage, cap_bps)
    target = rng.between(-12_000, 45_000)  # the R to aim at, in bps of the stake
    move = target * entry // (leverage * m.BPS) + rng.between(-2, 2)
    p = entry + move if side == m.CALL else entry - move
    p = min(m.INT64_MAX, max(1, p))
    return entry, p, side, floor_bps, cap_bps, m.g_bps(entry, p, side, leverage, floor_bps, cap_bps)


def bet_leverage(rng, i):
    """The leverage of the i-th random bet: each tier in turn, then any leverage."""
    return TIERS[i % 4] if i % 4 < 3 else any_leverage(rng)


# --- floorDiv (§11) --------------------------------------------------------------------------------------------------


def gen_floor_div():
    v = Vectors("floorDiv", "LeverageMath", "docs/MATH.md section 11", lambda a, b: {"q": m.floor_div(a, b)})
    lo, hi = m.INT256_MIN, m.INT256_MAX
    for a, b, note in ((7, 2, "section 11"), (-7, 2, "section 11: Solidity's / gives -3"), (7, -2, "section 11"),
                       (-7, -2, "section 11"), (6, 3, "exact"), (-6, 3, "exact"), (6, -3, "exact"), (-6, -3, "exact"),
                       (0, 5, "zero dividend"), (0, -5, "zero dividend"), (1, 2, "rounds down to 0"),
                       (-1, 2, "rounds down to -1"), (1, -2, "rounds down to -1"), (-1, -2, "rounds down to 0"),
                       (1, 1, None), (-1, 1, None), (1, -1, None), (-1, -1, None),
                       (-8 * m.USD * 1000 * m.BPS, m.ENTRY, "Example 2: -$8 at 1000x is -954"),
                       (hi, 1, "int256 max"), (lo, 1, "int256 min"), (hi, -1, "int256 max / -1"),
                       (lo, -1, "int256 min / -1 does not fit"), (lo, 2, None), (lo, -2, None), (hi, 2, None),
                       (hi, -2, None), (lo, hi, None), (hi, lo, None), (lo, lo, None), (hi, hi, None),
                       (lo + 1, -1, "int256 min + 1 / -1 fits"), (0, lo, None), (0, hi, None), (-1, hi, None),
                       (1, lo, None), (-1, lo, None)):
        v.add(note=note, a=a, b=b)
    for a in (0, 1, -1, hi, lo):
        v.add(note="a zero divisor", a=a, b=0)
    rng = v.rng
    for b in (2, 3, 7, 10_000, m.ENTRY, -3, -10_000, -m.ENTRY):  # one unit either side of a multiple
        for k in (5, -5, 123_456_789):
            for d in (-1, 0, 1):
                v.add(note="a multiple of b, and one unit either side", a=k * b + d, b=b)
    for i in range(700):
        r = i % 4
        if r == 0:  # gBps's own division: a move x L x 10,000 over a positive entry
            leverage = any_leverage(rng)
            entry = price(rng)
            v.add(a=rng.between(-entry, 4 * entry) * leverage * m.BPS, b=entry)
        elif r == 1:
            v.add(a=rng.int_(256), b=rng.int_(256) or 1)
        elif r == 2:
            v.add(a=rng.int_(128), b=rng.int_(64) or -1)
        else:
            b = rng.int_(64) or 1
            v.add(a=b * rng.int_(128) + rng.between(-2, 2), b=b)
    return v


# --- The leverage checks (§3.1) --------------------------------------------------------------------------------------


def gen_leverage_allowed():
    v = Vectors("leverageAllowed", "LeverageMath", "docs/MATH.md sections 3.1 and 3.3",
                lambda leverage: {"allowed": m.leverage_allowed(leverage)})
    for leverage in (0, 1, 2, 4, 15, 99, 100, 101, 499, 500, 501, 999, 1000, 1001, 2000, 9_999, 10_000, 10_001,
                     32_767, 32_768, 65_534, 65_535):
        v.add(note="a bound or a tier" if leverage in (0, 1, 10_000, 10_001, 100, 500, 1000) else None,
              leverage=leverage)
    rng = v.rng
    for i in range(600):
        v.add(leverage=rng.between(0, 12_000) if i % 2 else rng.uint(16))
    return v


def gen_theta_within_limit():
    v = Vectors("thetaWithinLimit", "LeverageMath", "docs/MATH.md sections 3.1 and 4",
                lambda thetaE7, leverage: {"within": m.theta_within_limit(thetaE7, leverage)})
    for leverage in SWEEP:
        top = widest(leverage)
        v.add(note="Example 7: the widest line", thetaE7=top, leverage=leverage)
        v.add(note="Example 7: one unit wider", thetaE7=top + 1, leverage=leverage)
    v.add(note="Example 7: 666,667 x 15 is not below 10^7", thetaE7=666_667, leverage=15)
    v.add(note="Example 7: the 500x tier's widest line fits 500x", thetaE7=11_760, leverage=500)
    v.add(note="Example 7: but not 1000x", thetaE7=11_760, leverage=1000)
    for theta_e7, leverage, note in ((0, 0, "zero"), (0, 65_535, "zero theta"), (4_294_967_295, 0, "zero leverage"),
                                     (4_294_967_295, 65_535, "the largest product, in 256 bits"),
                                     (9_999_999, 1, None), (10_000_000, 1, None), (1, 65_535, None),
                                     (152, 65_535, None), (153, 65_535, None)):
        if leverage < 65_536:
            v.add(note=note, thetaE7=theta_e7, leverage=leverage)
    rng = v.rng
    for i in range(900):
        r = i % 3
        leverage = TIERS[i % 3] if r == 0 else (any_leverage(rng) if r == 1 else rng.uint(16))
        if leverage and rng.chance(50):
            theta_e7 = max(0, min(4_294_967_295, widest(leverage) + rng.between(-3, 3)))
        else:
            theta_e7 = rng.uint(32) if rng.chance(30) else rng.log_uniform(0, 20_000_000)
        v.add(thetaE7=theta_e7, leverage=leverage)
    return v


def gen_cap_reachable():
    v = Vectors("capReachable", "LeverageMath", "docs/MATH.md section 3.1, rule 6",
                lambda capBps, leverage: {"reachable": m.cap_reachable(capBps, leverage)})
    for leverage, top in ((1, 19_999), (2, 29_999), (3, 39_999)):
        v.add(note="Example 7: the highest cap at %dx" % leverage, capBps=top, leverage=leverage)
        v.add(note="Example 7: one bp higher", capBps=top + 1, leverage=leverage)
    v.add(note="Example 7: from 4x up, the 4x ceiling", capBps=40_000, leverage=4)
    for cap_bps, leverage, note in ((65_535, 6, "the largest cap, gain 55,535 < 60,000"),
                                    (65_535, 5, "the largest cap, gain 55,535 >= 50,000"),
                                    (10_000, 0, "a 1x cap counts as no gain; at 0x nothing is reachable"),
                                    (10_000, 1, "a 1x cap counts as no gain"), (5_000, 1, "a cap below 1x"),
                                    (0, 0, None), (0, 1, None), (10_001, 0, None), (10_001, 1, None),
                                    (40_000, 3, None), (40_000, 1000, None), (65_535, 65_535, None)):
        v.add(note=note, capBps=cap_bps, leverage=leverage)
    rng = v.rng
    for i in range(900):
        r = i % 4
        if r == 0:
            leverage = rng.between(0, 7)
            cap_bps = rng.near(m.BPS + leverage * m.BPS, 3, 0, 65_535) if rng.chance(60) else rng.uint(16)
        elif r == 1:
            leverage, cap_bps = TIERS[i % 3], rng.uint(16)
        else:
            leverage, cap_bps = (any_leverage(rng) if r == 2 else rng.uint(16)), rng.uint(16)
        v.add(capBps=cap_bps, leverage=leverage)
    return v


# --- The lines (§4) --------------------------------------------------------------------------------------------------


def _lines_out(entry, side, leverage, thetaE7, capBps):
    liq, cap_price = m.lines(entry, side, leverage, thetaE7, capBps)
    return {"liqPrice": liq, "capPrice": cap_price}


def gen_lines():
    v = Vectors("lines", "LeverageMath", "docs/MATH.md section 4", _lines_out)
    e = m.ENTRY
    for side in (m.CALL, m.PUT):
        v.add(note="Example 1: 1000x", entry=e, side=side, leverage=1000, thetaE7=2_627, capBps=40_000)
        v.add(note="Example 4: 500x", entry=e, side=side, leverage=500, thetaE7=11_760, capBps=25_000)
        v.add(note="Example 5: 100x", entry=e, side=side, leverage=100, thetaE7=17_640, capBps=20_000)
        v.add(note="Example 7: a 1.9999x cap at 1x", entry=e, side=side, leverage=1, thetaE7=1, capBps=19_999)
        v.add(note="the smallest entry", entry=1, side=side, leverage=1000, thetaE7=9_999, capBps=40_000)
        for leverage in SWEEP:
            v.add(note="the widest line and the highest cap", entry=e, side=side, leverage=leverage,
                  thetaE7=widest(leverage), capBps=highest_cap(leverage))
    errors = (
        (0, 0, 1000, 2_627, 40_000, "a zero entry"), (-1, 1, 1000, 2_627, 40_000, "a negative entry"),
        (m.INT64_MIN, 0, 0, 0, 0, "the price is checked before the parameters"),
        (e, 0, 0, 2_627, 40_000, "leverage 0"), (e, 1, 10_001, 999, 40_000, "leverage 10,001"),
        (e, 0, 1000, 0, 40_000, "theta 0"), (e, 1, 1000, 10_000, 40_000, "theta x L = 10^7"),
        (e, 0, 15, 666_667, 40_000, "Example 7: one unit wider at 15x"),
        (e, 0, 1000, 2_627, 10_000, "a 1x cap"), (e, 1, 1000, 2_627, 40_001, "a cap above 4x"),
        (e, 1, 1, 1, 20_000, "a 2x cap a short cannot reach at 1x"),
        (e, 0, 3, 1, 40_000, "a 4x cap a short cannot reach at 3x"),
        (e, 0, 1000, 2_627, 65_535, None), (e, 1, 65_535, 1, 15_000, None),
    )
    for entry, side, leverage, theta_e7, cap_bps, note in errors:
        v.add(note=note, entry=entry, side=side, leverage=leverage, thetaE7=theta_e7, capBps=cap_bps)
    # Where each line stops fitting int64: a long's cap line and a short's liquidation line.
    for leverage, theta_e7, cap_bps in ((1000, 2_627, 40_000), (500, 11_760, 25_000), (100, 17_640, 20_000),
                                        (1, 9_999_999, 19_999), (10_000, 1, 10_001)):
        top = largest(lambda x: x + m._cap_offset(x, leverage, cap_bps) <= m.INT64_MAX, 1, m.INT64_MAX)
        v.add(note="the largest entry whose cap line fits", entry=top, side=m.CALL, leverage=leverage,
              thetaE7=theta_e7, capBps=cap_bps)
        if top < m.INT64_MAX:
            v.add(note="one unit more: MathOverflow", entry=top + 1, side=m.CALL, leverage=leverage,
                  thetaE7=theta_e7, capBps=cap_bps)
        top = largest(lambda x: x + x * theta_e7 // m.E7 <= m.INT64_MAX, 1, m.INT64_MAX)
        v.add(note="the largest entry whose short line fits", entry=top, side=m.PUT, leverage=leverage,
              thetaE7=theta_e7, capBps=cap_bps)
        if top < m.INT64_MAX:
            v.add(note="one unit more: MathOverflow", entry=top + 1, side=m.PUT, leverage=leverage,
                  thetaE7=theta_e7, capBps=cap_bps)
        for side in (m.CALL, m.PUT):
            v.add(note="the int64 maximum", entry=m.INT64_MAX, side=side, leverage=leverage, thetaE7=theta_e7,
                  capBps=cap_bps)
    # Rounding: an entry whose offsets divide exactly, and one unit either side.
    for leverage, theta_e7, cap_bps in ((1000, 2_627, 40_000), (500, 11_760, 25_000), (100, 17_640, 20_000)):
        step = m.E7 * leverage * m.BPS  # a multiple of both divisors' needs
        for k in (1, 7, 1_234):
            for d in (-1, 0, 1):
                v.add(note="offsets exact, or one unit off", entry=k * step + d, side=k % 2, leverage=leverage,
                      thetaE7=theta_e7, capBps=cap_bps)
    rng = v.rng
    for i in range(1300):
        r = i % 10
        leverage = TIERS[r % 3] if r < 6 else any_leverage(rng)
        entry, side = price(rng), rng.below(2)
        theta_e7, cap_bps = theta(rng, leverage), cap(rng, leverage)
        if r == 7:  # near the int64 maximum, where the outer line may not fit
            entry = m.INT64_MAX - rng.log_uniform(0, m.INT64_MAX // 2)
        elif r == 8:  # one input moved past (or onto) its bound
            k = rng.below(6)
            if k == 0:
                entry = rng.pick((0, -1, m.INT64_MIN, -rng.log_uniform(1, m.INT64_MAX)))
            elif k == 1:
                leverage = bad_leverage(rng)
            elif k == 2:
                theta_e7 = rng.pick((0, widest(leverage), widest(leverage) + 1, widest(leverage) + rng.between(2, 99)))
            elif k == 3:
                cap_bps = rng.pick((m.BPS, m.BPS + 1, 40_000, 40_001, rng.between(0, m.BPS), rng.between(40_001,
                                                                                                         65_535)))
            elif k == 4:
                cap_bps = min(65_535, highest_cap(leverage) + rng.between(0, 2))
            else:
                theta_e7 = rng.uint(32)
        elif r == 9:  # every input anywhere in its type
            entry, leverage, theta_e7, cap_bps = rng.int_(64), rng.uint(16), rng.uint(32), rng.uint(16)
        v.add(entry=entry, side=side, leverage=leverage, thetaE7=theta_e7, capBps=cap_bps)
    return v


def gen_cap_line():
    v = Vectors("capLine", "LeverageMath", "docs/MATH.md section 4",
                lambda entry, side, leverage, capBps: {"capPrice": m.cap_line(entry, side, leverage, capBps)})
    e = m.ENTRY
    for side in (m.CALL, m.PUT):
        v.add(note="Example 1: 1000x", entry=e, side=side, leverage=1000, capBps=40_000)
        v.add(note="Example 4: 500x", entry=e, side=side, leverage=500, capBps=25_000)
        v.add(note="Example 5: 100x", entry=e, side=side, leverage=100, capBps=20_000)
        v.add(note="the smallest entry", entry=1, side=side, leverage=1, capBps=19_999)
        for leverage in SWEEP:
            v.add(note="the highest cap", entry=e, side=side, leverage=leverage, capBps=highest_cap(leverage))
    v.add(note="Example 7: one bp of the entry above 0", entry=e, side=m.PUT, leverage=1, capBps=19_999)
    for entry, side, leverage, cap_bps, note in (
            (0, 0, 1000, 40_000, "a zero entry"), (-1, 1, 1000, 10_000, "the price is checked first"),
            (e, 0, 0, 40_000, "leverage 0"), (e, 0, 10_001, 40_000, "leverage 10,001"),
            (e, 0, 1000, 10_000, "a 1x cap"), (e, 0, 1000, 40_001, "a cap above 4x"),
            (e, 1, 1, 20_000, "a cap a short cannot reach at 1x"), (e, 1, 2, 30_000, "nor at 2x"),
            (m.INT64_MAX, 0, 1000, 40_000, "a long's cap line above int64"),
            (m.INT64_MAX, 1, 1000, 40_000, "a short's cap line stays positive")):
        v.add(note=note, entry=entry, side=side, leverage=leverage, capBps=cap_bps)
    for leverage, cap_bps in ((1000, 40_000), (500, 25_000), (100, 20_000), (1, 19_999), (10_000, 10_001)):
        top = largest(lambda x: x + m._cap_offset(x, leverage, cap_bps) <= m.INT64_MAX, 1, m.INT64_MAX)
        v.add(note="the largest entry whose cap line fits", entry=top, side=m.CALL, leverage=leverage, capBps=cap_bps)
        if top < m.INT64_MAX:
            v.add(note="one unit more: MathOverflow", entry=top + 1, side=m.CALL, leverage=leverage, capBps=cap_bps)
    rng = v.rng
    for i in range(800):
        r = i % 10
        leverage = TIERS[r % 3] if r < 6 else any_leverage(rng)
        entry, side, cap_bps = price(rng), rng.below(2), cap(rng, leverage)
        if r == 7:
            entry = m.INT64_MAX - rng.log_uniform(0, m.INT64_MAX // 2)
        elif r == 8:
            k = rng.below(3)
            if k == 0:
                entry = rng.pick((0, -1, m.INT64_MIN, -rng.log_uniform(1, m.INT64_MAX)))
            elif k == 1:
                leverage = bad_leverage(rng)
            else:
                cap_bps = rng.pick((m.BPS, 40_001, rng.between(0, m.BPS), min(65_535, highest_cap(leverage) + 1)))
        elif r == 9:
            entry, leverage, cap_bps = rng.int_(64), rng.uint(16), rng.uint(16)
        v.add(entry=entry, side=side, leverage=leverage, capBps=cap_bps)
    return v


def gen_touched():
    v = Vectors("touched", "LeverageMath", "docs/MATH.md section 4",
                lambda price, liqPrice, side: {"touched": m.touched(price, liqPrice, side)})
    for p, note in ((8_386_196_367_320, "Example 1: a long's line, touched"),
                    (8_386_196_367_321, "Example 1: one unit above it, not")):
        v.add(note=note, price=p, liqPrice=8_386_196_367_320, side=m.CALL)
    for p, note in ((8_390_603_632_680, "Example 1: a short's line, touched"),
                    (8_390_603_632_679, "Example 1: one unit below it, not")):
        v.add(note=note, price=p, liqPrice=8_390_603_632_680, side=m.PUT)
    for p, liq in ((m.INT64_MIN, m.INT64_MIN), (m.INT64_MAX, m.INT64_MAX), (m.INT64_MIN, m.INT64_MAX),
                   (m.INT64_MAX, m.INT64_MIN), (0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)):
        for side in (m.CALL, m.PUT):
            v.add(note="the int64 range", price=p, liqPrice=liq, side=side)
    rng = v.rng
    for i in range(700):
        side = rng.below(2)
        if i % 3 == 2:
            v.add(price=rng.int_(64), liqPrice=rng.int_(64), side=side)
        else:
            liq = price(rng)
            v.add(price=rng.near(liq, 3 if i % 3 == 0 else 10**6, m.INT64_MIN, m.INT64_MAX), liqPrice=liq, side=side)
    return v


# --- The payout curve (§5) -------------------------------------------------------------------------------------------


def gen_g_bps():
    v = Vectors("gBps", "LeverageMath", "docs/MATH.md section 5",
                lambda entry, price, side, leverage, floorBps, capBps: {
                    "g": m.g_bps(entry, price, side, leverage, floorBps, capBps)})
    e, usd, bp = m.ENTRY, m.USD, m.ONE_BP

    def add(note, entry, price_, side, leverage, floor_bps, cap_bps):
        v.add(note=note, entry=entry, price=price_, side=side, leverage=leverage, floorBps=floor_bps, capBps=cap_bps)

    for dollars, note in ((84, "Example 2: +$84"), (252, "Example 2: +$252, capped"), (8, "Example 2: +$8, the floor"),
                          (0, "Example 2: the entry"), (-8, "Example 2: -$8, rounded to the larger loss")):
        add(note, e, e + dollars * usd, m.CALL, 1000, 13_000, 40_000)
    for floor_bps in (11_000, 14_000, 15_000):
        add("Example 2: +$8 with another floor", e, e + 8 * usd, m.CALL, 1000, floor_bps, 40_000)
    add("Example 2: a short mirrors it", e, e - 8 * usd, m.PUT, 1000, 14_000, 40_000)
    add("Example 2: a short mirrors it", e, e + 8 * usd, m.PUT, 1000, 14_000, 40_000)
    add("Example 4: 500x at the line", e, 8_378_535_241_600, m.CALL, 500, 10_250, 25_000)
    add("Example 4: 500x at the cap line", e, 8_413_565_200_000, m.CALL, 500, 10_250, 25_000)
    add("Example 4: one unit short of it", e, 8_413_565_199_999, m.CALL, 500, 10_250, 25_000)
    for p, side, note in ((8_373_602_862_400, m.CALL, "Example 5: 100x at the line"),
                          (8_403_197_137_600, m.PUT, "Example 5: 100x at the line"),
                          (8_472_284_000_000, m.CALL, "Example 5: at the cap line"),
                          (8_304_516_000_000, m.PUT, "Example 5: at the cap line"),
                          (8_472_283_999_999, m.CALL, "Example 5: one unit short"),
                          (8_304_516_000_001, m.PUT, "Example 5: one unit short")):
        add(note, e, p, side, 100, 10_050, 20_000)
    for move, note in ((bp // 10, "Example 5: +0.1 bp, raised to the floor"), (bp, "Example 5: +1 bp"),
                       (99 * bp, "Example 5: +99 bp"), (100 * bp, "Example 5: +100 bp, the cap"),
                       (150 * bp, "Example 5: +150 bp, capped")):
        add(note, e, e + move, m.CALL, 100, 10_050, 20_000)
    add("Example 5: 500x, +1 bp", e, e + bp, m.CALL, 500, 10_250, 25_000)
    add("Example 5: 500x, +30 bp reaches the cap", e, e + 30 * bp, m.CALL, 500, 10_250, 25_000)
    for leverage in (15, 1):
        for sign in (1, -1):
            add("Example 6: half a bp", e, e + sign * bp // 2, m.CALL, leverage, m.BPS, 40_000)
    add("Example 6: R = 0 is not a win, so no floor", e, e + bp // 2, m.CALL, 1, 10_050, 40_000)
    for leverage in SWEEP:
        for bps in (-1, 1):
            add("Example 6: one whole bp moves g by L", e, e + bps * bp, m.CALL, leverage, m.BPS, 40_000)
    add("Example 6: a move too small to count", e, e + 1, m.CALL, 1000, 13_000, 40_000)
    add("a loss of every bp of the stake: g clamps at 0", e, 1, m.CALL, 1000, 13_000, 40_000)
    add("a short at the int64 maximum: g clamps at 0", e, m.INT64_MAX, m.PUT, 10_000, 13_000, 40_000)
    add("the largest move up: g clamps at the cap", 1, m.INT64_MAX, m.CALL, 10_000, 13_000, 40_000)
    add("a floor above the cap: the cap wins", e, e + 8 * usd, m.CALL, 1000, 50_000, 40_000)
    add("a cap below 1x: no move pays more", e, e, m.CALL, 1000, 0, 5_000)
    add("a zero cap", e, e + 84 * usd, m.CALL, 1000, 13_000, 0)
    for entry, p, side, leverage, note in ((0, e, 0, 1000, "a zero entry"), (e, 0, 1, 1000, "a zero price"),
                                           (-1, e, 0, 1000, "a negative entry"), (e, -1, 0, 1000, "a negative price"),
                                           (0, 0, 0, 0, "the prices are checked before the leverage"),
                                           (e, e, 0, 0, "leverage 0"), (e, e, 1, 10_001, "leverage 10,001"),
                                           (e, e, 0, 65_535, "the largest uint16")):
        add(note, entry, p, side, leverage, 13_000, 40_000)
    rng = v.rng
    for i in range(1500):
        r = i % 12
        leverage = TIERS[r % 3] if r < 7 else any_leverage(rng)
        entry, p, side, floor_bps, cap_bps, _ = tier_bet(rng, leverage)
        if r == 9:  # the exact price where R steps from one value to the next, and one unit before it
            target = rng.between(-11_000, 31_000)
            lo = -(-target * entry // (leverage * m.BPS))  # the smallest move with R >= target
            for move in (lo - 1, lo):
                q = entry + move if side == m.CALL else entry - move
                if 0 < q <= m.INT64_MAX:
                    v.add(entry=entry, price=q, side=side, leverage=leverage, floorBps=floor_bps, capBps=cap_bps)
            continue
        if r == 10:  # one input anywhere in its type
            k = rng.below(4)
            if k == 0:
                entry, p = rng.int_(64), rng.int_(64)
            elif k == 1:
                leverage = rng.uint(16)
            else:
                floor_bps, cap_bps = rng.uint(16), rng.uint(16)
        elif r == 11:
            entry, p, leverage, floor_bps, cap_bps = (rng.int_(64), rng.int_(64), rng.uint(16), rng.uint(16),
                                                      rng.uint(16))
        v.add(entry=entry, price=p, side=side, leverage=leverage, floorBps=floor_bps, capBps=cap_bps)
    return v


def gen_payout():
    v = Vectors("payout", "LeverageMath", "docs/MATH.md section 5",
                lambda stake, multipleBps: {"amount": m.payout(stake, multipleBps)})
    for g, note in ((20_013, "Example 2: +$84"), (40_000, "Example 2: the cap"), (13_000, "Example 2: the floor"),
                    (10_000, "Example 2: the entry"), (9_046, "Example 2: -$8"), (0, "a zero multiple"),
                    (65_535, "the largest multiple"), (1, None), (9_999, None)):
        v.add(note=note, stake=m.STAKE, multipleBps=g)
    for s, g, note in ((0, 40_000, "a zero stake"), (1, 9_999, "rounds down to 0"), (1, 10_000, None),
                       (9_999, 1, "rounds down to 0"), (10_000, 1, None), (m.UINT64_MAX, 10_000, "the uint64 maximum"),
                       (m.UINT64_MAX, 9_999, None), (m.UINT64_MAX, 10_001, "MathOverflow"),
                       (m.UINT64_MAX, 65_535, "MathOverflow"), (m.UINT64_MAX, 0, None)):
        v.add(note=note, stake=s, multipleBps=g)
    for g in (10_001, 13_000, 20_000, 25_000, 40_000, 65_535):  # the largest stake that still fits
        top = ((m.UINT64_MAX + 1) * m.BPS - 1) // g
        v.add(note="the largest stake whose payout fits", stake=top, multipleBps=g)
        v.add(note="one unit more: MathOverflow", stake=top + 1, multipleBps=g)
    rng = v.rng
    for i in range(900):
        r = i % 6
        if r < 3:
            leverage = bet_leverage(rng, i)
            v.add(stake=stake(rng), multipleBps=tier_bet(rng, leverage)[5])
        elif r == 3:
            g = rng.between(10_001, 65_535)
            top = ((m.UINT64_MAX + 1) * m.BPS - 1) // g
            v.add(stake=rng.near(top, 2, 0, m.UINT64_MAX), multipleBps=g)
        else:
            v.add(stake=amount(rng), multipleBps=rng.uint(16))
    return v


def gen_max_profit():
    v = Vectors("maxProfit", "LeverageMath", "docs/MATH.md section 5",
                lambda stake, capBps: {"amount": m.max_profit(stake, capBps)})
    for s, c, note in ((m.STAKE, 40_000, "Example 2: $30"), (m.STAKE, 25_000, "the 500x tier's cap"),
                       (m.STAKE, 20_000, "the 100x tier's cap"), (m.STAKE, 10_000, "a 1x cap: no profit"),
                       (m.STAKE, 9_999, "a cap below 1x"), (m.STAKE, 0, "a zero cap"), (0, 40_000, "a zero stake"),
                       (1, 10_001, "rounds down to 0"), (9_999, 10_001, None), (10_000, 10_001, None),
                       (m.UINT64_MAX, 20_000, "the uint64 maximum at 2x"), (m.UINT64_MAX, 20_001, "MathOverflow"),
                       (m.UINT64_MAX, 65_535, "MathOverflow"), (m.UINT64_MAX, 9_999, "the cap is checked first"),
                       (0, 0, "the cap is checked first")):
        v.add(note=note, stake=s, capBps=c)
    for c in (20_001, 25_000, 40_000, 65_535):
        top = ((m.UINT64_MAX + 1) * m.BPS - 1) // (c - m.BPS)
        v.add(note="the largest stake whose maximum profit fits", stake=top, capBps=c)
        v.add(note="one unit more: MathOverflow", stake=top + 1, capBps=c)
    rng = v.rng
    for i in range(800):
        r = i % 6
        if r < 3:
            v.add(stake=stake(rng), capBps=cap(rng, bet_leverage(rng, i)))
        elif r == 3:
            c = rng.between(20_001, 65_535)
            top = ((m.UINT64_MAX + 1) * m.BPS - 1) // (c - m.BPS)
            v.add(stake=rng.near(top, 2, 0, m.UINT64_MAX), capBps=c)
        else:
            v.add(stake=amount(rng), capBps=rng.uint(16))
    return v


# --- The time checks (§6, §7.1) -------------------------------------------------------------------------------------


def _check_liquidation(positionId, startTime, endTime, liqPrice, side, price, publishTime, currentTime, clockSkewSecs):
    m.check_liquidation(positionId, startTime, endTime, liqPrice, side, price, publishTime, currentTime,
                        clockSkewSecs)
    return {}


def gen_check_liquidation():
    v = Vectors("checkLiquidation", "LeverageMath", "docs/MATH.md section 7.1", _check_liquidation)
    liq = m.ENTRY - m.ONE_BP

    def add(note, start, end, publish, now, skew, p=liq, side=m.CALL, liq_price=liq, pid=1):
        v.add(note=note, positionId=pid, startTime=start, endTime=end, liqPrice=liq_price, side=side, price=p,
              publishTime=publish, currentTime=now, clockSkewSecs=skew)

    add("Example 12: the start", 1_000, 1_060, 1_000, 2_000, 5)
    add("Example 12: the end", 1_000, 1_060, 1_060, 2_000, 5)
    add("Example 12: before the start", 1_000, 1_060, 999, 2_000, 5)
    add("Example 12: after the end", 1_000, 1_060, 1_061, 2_000, 5)
    add("Example 12: 5 seconds ahead", 1_000, 1_060, 1_015, 1_010, 5)
    add("Example 12: 6 seconds ahead", 1_000, 1_060, 1_016, 1_010, 5)
    add("a long one unit above its line", 1_000, 1_060, 1_030, 1_030, 5, p=liq + 1, pid=7)
    add("a short at its line", 1_000, 1_060, 1_030, 1_030, 5, p=liq, side=m.PUT)
    add("a short one unit below its line", 1_000, 1_060, 1_030, 1_030, 5, p=liq - 1, side=m.PUT, pid=8)
    add("a zero price", 1_000, 1_060, 1_030, 1_030, 5, p=0)
    add("a negative price, checked before the window", 1_000, 1_060, 0, 0, 0, p=-1)
    add("the window before the clock", 1_000, 1_060, 999, 0, 0, p=liq + 1, pid=9)
    add("the clock before the line", 1_000, 1_060, 1_060, 0, 0, p=liq + 1)
    add("an old tick still liquidates", 1_000, 1_060, 1_000, 10**12, 0)
    add("no skew: the tick at the clock", 1_000, 1_060, 1_030, 1_030, 0)
    add("no skew: one second ahead", 1_000, 1_060, 1_031, 1_030, 0)
    add("the largest skew", 1_000, 1_060, 1_060, 805, 255)
    add("the largest skew, one second more", 1_000, 1_060, 1_060, 804, 255)
    top = UINT256_MAX
    add("the uint256 maximum", 0, top, top, top - 5, 5)
    add("the uint256 maximum, one second further", 0, top, top, top - 6, 5)
    add("a window of one second", top, top, top, 0, 255, pid=top)
    add("the int64 range", 1, 2, 1, 1, 0, p=m.INT64_MAX, liq_price=m.INT64_MAX)
    add("the int64 range", 1, 2, 1, 1, 0, p=1, side=m.PUT, liq_price=m.INT64_MIN)
    rng = v.rng
    for i in range(700):
        if i % 6 == 5:  # anywhere in the types
            start, end, publish, now = (rng.uint(256) if rng.chance(30) else rng.uint(48) for _ in range(4))
            skew, liq_price, side, p = rng.uint(8), rng.int_(64), rng.below(2), rng.int_(64)
        else:  # a bet a few minutes long, a tick inside its life that touches the line, or one check broken
            start = rng.between(1_600_000_000, 1_900_000_000) if rng.chance(90) else rng.between(0, 1_000)
            end = start + (rng.pick(DURATIONS) if rng.chance(80) else rng.uint(16))
            skew = rng.between(0, 30) if rng.chance(80) else rng.uint(8)
            publish = rng.pick((start, end, rng.between(start, end)))
            now = max(0, publish + rng.pick((-skew, rng.between(-skew, 0), rng.between(0, 10**5))))
            liq_price, side = price(rng), rng.below(2)
            beyond = rng.between(0, 3)  # how far past the line, toward the loss
            p = max(m.INT64_MIN, min(m.INT64_MAX, liq_price - beyond if side == m.CALL else liq_price + beyond))
            fault = rng.below(10)
            if fault == 0:
                p = rng.pick((0, -1, m.INT64_MIN, -rng.log_uniform(1, m.INT64_MAX)))
            elif fault == 1:
                publish = max(0, start - rng.between(1, 3)) if rng.chance(50) else end + rng.between(1, 3)
            elif fault == 2:
                now = max(0, publish - skew - rng.between(1, 3))
            elif fault == 3:
                gap = rng.pick((1, rng.between(1, 10**6)))
                p = max(m.INT64_MIN, min(m.INT64_MAX, liq_price + gap if side == m.CALL else liq_price - gap))
        v.add(positionId=rng.uint(32), startTime=start, endTime=end, liqPrice=liq_price, side=side, price=p,
              publishTime=publish, currentTime=now, clockSkewSecs=skew)
    return v


def _check_entry_time(currentTime, publishTime, maxAgeSecs, clockSkewSecs):
    m.check_entry_time(currentTime, publishTime, maxAgeSecs, clockSkewSecs)
    return {}


def gen_check_entry_time():
    v = Vectors("checkEntryTime", "LeverageMath", "docs/MATH.md section 6", _check_entry_time)

    def add(note, now, publish, age, skew):
        v.add(note=note, currentTime=now, publishTime=publish, maxAgeSecs=age, clockSkewSecs=skew)

    now = 1_700_000_000
    add("Example 12: 5 seconds old", now, now - 5, 5, 5)
    add("Example 12: 5 seconds ahead", now, now + 5, 5, 5)
    add("Example 12: 6 seconds old", now, now - 6, 5, 5)
    add("Example 12: 6 seconds ahead", now, now + 6, 5, 5)
    add("Example 12: a time of 0", now, 0, 5, 5)
    add("a time of 0 is too old even at clock 0", 0, 0, 255, 255)
    add("clock 0: the skew's edge", 0, 5, 0, 5)
    add("clock 0: one second past it", 0, 6, 0, 5)
    add("no age, no skew: the clock itself", now, now, 0, 0)
    add("no age: one second old", now, now - 1, 0, 0)
    add("no skew: one second ahead", now, now + 1, 0, 0)
    add("the largest age", now, now - 255, 255, 0)
    add("the largest age, one second more", now, now - 256, 255, 0)
    add("the largest skew", now, now + 255, 0, 255)
    add("the largest skew, one second more", now, now + 256, 0, 255)
    add("the uint256 maximum", UINT256_MAX, UINT256_MAX, 0, 0)
    add("the uint256 maximum, the oldest tick", UINT256_MAX, UINT256_MAX - 255, 255, 0)
    add("the uint256 maximum, one second older", UINT256_MAX, UINT256_MAX - 256, 255, 0)
    add("a tick at the uint256 maximum, from the future", 0, UINT256_MAX, 255, 255)
    add("an old clock and a tick of 1", 256, 1, 255, 0)
    add("a tick both old and of time 0", now, 0, 0, 0)
    rng = v.rng
    for i in range(800):
        if i % 6 == 5:  # anywhere in the types
            current, publish = (rng.uint(256) if rng.chance(30) else rng.uint(40) for _ in range(2))
            age, skew = rng.uint(8), rng.uint(8)
        else:  # a tick inside the window, on its edge, or one second past it
            current = rng.between(1_600_000_000, 1_900_000_000) if rng.chance(85) else rng.between(0, 300)
            age = rng.between(0, 30) if rng.chance(75) else rng.uint(8)
            skew = rng.between(0, 30) if rng.chance(75) else rng.uint(8)
            fault = rng.below(20)
            if fault == 0:
                publish = 0
            elif fault < 4:
                publish = current + skew + rng.between(1, 3)
            elif fault < 7:
                publish = max(0, current - age - rng.between(1, 3))
            elif fault < 12:
                publish = max(0, current + rng.pick((-age, skew)))
            else:
                publish = max(0, current + rng.between(-age, skew))
        add(None, current, publish, age, skew)
    return v


# --- The open gate (§6) ----------------------------------------------------------------------------------------------


def _open_gate(totalOwed, maxTotalOwed, openMaxProfit, newMaxProfit, free, maxExposureBps):
    m.open_gate(totalOwed, maxTotalOwed, openMaxProfit, newMaxProfit, free, maxExposureBps)
    return {}


def gen_open_gate():
    v = Vectors("openGate", "LeverageMath", "docs/MATH.md section 6", _open_gate)
    t = m.TOKEN

    def add(note, owed, owed_max, open_mp, new_mp, free, rate):
        v.add(note=note, totalOwed=owed, maxTotalOwed=owed_max, openMaxProfit=open_mp, newMaxProfit=new_mp, free=free,
              maxExposureBps=rate)

    add("Example 9: 970 + 30 <= 1,000", 0, 0, 970 * t, 30 * t, 1_000 * t, 10_000)
    add("Example 9: one unit more", 0, 0, 970 * t, 30 * t + 1, 1_000 * t, 10_000)
    add("Example 9: 1 unit free at 1.5x allows 1", 0, 0, 0, 1, 1, 15_000)
    add("Example 9: but not 2 (rounded down)", 0, 0, 0, 2, 1, 15_000)
    add("Example 9: owed 100, limit 100", 100, 100, 0, 0, 0, 10_000)
    add("Example 9: owed 101, limit 100", 101, 100, 0, 0, 0, 10_000)
    add("the owed check comes first", 101, 100, m.UINT64_MAX, m.UINT64_MAX, 0, 10_000)
    add("a rate of 0 switches the exposure test off", 0, 0, m.UINT64_MAX, m.UINT64_MAX, 0, 0)
    add("a rate of 1 bp", 0, 0, 0, 1, 10_000, 1)
    add("a rate of 1 bp, one unit more", 0, 0, 0, 2, 10_000, 1)
    add("nothing free, nothing asked", 0, 0, 0, 0, 0, 10_000)
    add("nothing free", 0, 0, 0, 1, 0, 10_000)
    add("the sum of two uint64 maxima, in 256 bits", 0, m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX,
        2**32 - 1)
    add("the largest limit", m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX,
        m.UINT64_MAX, 20_000)
    add("the largest limit, one unit short", 0, 0, m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX - 1, 20_000)
    add("100% of everything", 0, 0, m.UINT64_MAX, 0, m.UINT64_MAX, 10_000)
    add("100% of everything, one unit more", 0, 0, m.UINT64_MAX, 1, m.UINT64_MAX, 10_000)
    rng = v.rng
    for i in range(900):
        r = i % 3
        if r < 2:
            free = rng.between(0, 10**13) if rng.chance(70) else amount(rng)
            rate = rng.pick((10_000, 10_000, 5_000, 1, rng.between(1, 10_000), 0, rng.uint(32)))
            limit = free * rate // m.BPS
            new_mp = rng.between(0, 30 * 10**6) if rng.chance(70) else amount(rng)
            target = min(m.UINT64_MAX, max(0, limit - new_mp + rng.between(-2, 2)))
            open_mp = target if rng.chance(60) else rng.between(0, target)
            owed_max = rng.pick((m.UINT64_MAX, 0, rng.between(0, 10**9)))
            owed = 0 if rng.chance(60) else rng.near(owed_max, 2, 0, m.UINT64_MAX)
        else:
            owed, owed_max, open_mp, new_mp, free = (amount(rng) for _ in range(5))
            rate = rng.uint(32)
        add(None, owed, owed_max, open_mp, new_mp, free, rate)
    return v


# --- The fees (§7.3) -------------------------------------------------------------------------------------------------


def gen_fee():
    v = Vectors("fee", "LeverageMath", "docs/MATH.md section 7.3",
                lambda amount, feeBps: {"fee": m.fee(amount, feeBps)})
    for a, f, note in ((49, 200, "section 7.3: 2% of 49 is 0"), (50, 200, "section 7.3: 2% of 50 is 1"),
                       (99, 200, None), (100, 200, None), (954_000, 300, "Example 3: the loser fee"),
                       (10_013_000, 200, "Example 3: the winner fee"),
                       (12_500_000, 600, "Example 10: the sell fee cap"),
                       (1_000, 10_000, "100%"), (1_000, 10_001, "above 100% counts as 100%"),
                       (1_000, 65_535, "the largest rate counts as 100%"), (1_000, 0, "a zero rate"),
                       (0, 10_000, "a zero amount"), (m.UINT64_MAX, 10_000, "the uint64 maximum"),
                       (m.UINT64_MAX, 65_535, None), (m.UINT64_MAX, 9_999, None), (m.UINT64_MAX, 1, None),
                       (9_999, 1, "rounds down to 0"), (10_000, 1, None)):
        v.add(note=note, amount=a, feeBps=f)
    rng = v.rng
    for i in range(800):
        r = i % 4
        rate = rng.pick((200, 300, 600, 10_000, rng.between(0, 10_000))) if r < 2 else rng.uint(16)
        a = amount(rng) if r != 1 else rng.near(rng.between(1, 10**9) * m.BPS, 1, 0, m.UINT64_MAX)
        v.add(amount=a, feeBps=rate)
    return v


def gen_winner_fee():
    v = Vectors("winnerFee", "LeverageMath", "docs/MATH.md section 7.3",
                lambda profitPaid: {"fee": m.winner_fee(profitPaid)})
    for p, note in ((0, None), (49, "2% of 49 is 0"), (50, "2% of 50 is 1"), (99, None), (100, None),
                    (10_013_000, "Example 3: +$84"), (30_000_000, "Example 3: +$252"), (12_000_000, "Example 3"),
                    (2_000_000, "Example 10: a sale's profit"), (10_000_000, "Example 11: a repayment"),
                    (m.UINT64_MAX, "the uint64 maximum"), (m.UINT64_MAX - 1, None)):
        v.add(note=note, profitPaid=p)
    rng = v.rng
    for i in range(600):
        v.add(profitPaid=amount(rng) if i % 2 else rng.near(rng.between(0, 10**12) * 50, 1, 0, m.UINT64_MAX))
    return v


def gen_loser_fee():
    v = Vectors("loserFee", "LeverageMath", "docs/MATH.md section 7.3",
                lambda loss, freeBefore, poolFloor: {"fee": m.loser_fee(loss, freeBefore, poolFloor)})
    fl = m.POOL_FLOOR
    for loss, free, floor, note in ((954_000, 10_000 * m.TOKEN, fl, "Example 3: -$8"),
                                    (954_000, fl - 1, fl, "Example 3: one unit below the floor"),
                                    (954_000, fl, fl, "free money at the floor"),
                                    (m.STAKE, 20 * m.TOKEN, fl, "Example 11: a small pool"),
                                    (1_000_000, fl, fl, "Example 10: a loss of $1"),
                                    (33, fl, fl, "3% of 33 is 0"), (34, fl, fl, "3% of 34 is 1"),
                                    (0, fl, fl, "no loss"), (m.UINT64_MAX, 0, 0, "a zero floor"),
                                    (m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, None),
                                    (m.UINT64_MAX, m.UINT64_MAX - 1, m.UINT64_MAX, None)):
        v.add(note=note, loss=loss, freeBefore=free, poolFloor=floor)
    rng = v.rng
    for i in range(700):
        floor = rng.pick((fl, 500 * 10**9, rng.between(0, 10**12))) if i % 3 else amount(rng)
        free = rng.near(floor, 2, 0, m.UINT64_MAX) if rng.chance(50) else amount(rng)
        loss = stake(rng) if i % 2 else amount(rng)
        v.add(loss=loss, freeBefore=free, poolFloor=floor)
    return v


# --- The settlement split (§7.4) -------------------------------------------------------------------------------------


def _settle_split(payoutAmount, stake, freeBefore, totalOwed, poolFloor):
    s = m.settle_split(payoutAmount, stake, freeBefore, totalOwed, poolFloor)
    return dict(s._asdict(), toUser=m.settle_to_user(s), outOfPool=m.settle_out_of_pool(s))


def gen_settle_split():
    v = Vectors("settleSplit", "LeverageMath", "docs/MATH.md section 7.4", _settle_split)
    t, s, fl = m.TOKEN, m.STAKE, m.POOL_FLOOR

    def add(note, pay, stake_, free, owed, floor=fl):
        v.add(note=note, payoutAmount=pay, stake=stake_, freeBefore=free, totalOwed=owed, poolFloor=floor)

    add("Example 3: +$84", 20_013_000, s, 10_000 * t, 0)
    add("Example 3: +$252", 40_000_000, s, 10_000 * t, 0)
    add("Example 3: -$8", 9_046_000, s, 10_000 * t, 0)
    add("Example 3: -$8, free one unit below the floor", 9_046_000, s, fl - 1, 0)
    add("Example 3: a short pool, $12 free", 40_000_000, s, 12 * t, 0)
    add("Example 3: a queue ahead", 40_000_000, s, 1_000 * t, 1)
    add("Example 11: A settles", 40 * t, s, 30 * t, 0)
    add("Example 11: B settles", 40 * t, s, 0, 0)
    add("the stake back exactly", s, s, fl, 0)
    add("one unit of profit", s + 1, s, fl, 0)
    add("one unit of loss", s - 1, s, fl, 0)
    add("a total loss", 0, s, fl, 0)
    add("profit equal to free money", 20 * t, s, 10 * t, 0)
    add("profit one unit above free money", 20 * t + 1, s, 10 * t, 0)
    add("profit one unit below free money", 20 * t - 1, s, 10 * t, 0)
    add("free money exactly at the floor", 5 * t, s, fl, 0)
    add("a loss with someone owed: the fee still counts", 5 * t, s, fl, 7)
    add("nothing at all", 0, 0, 0, 0)
    add("the uint64 maximum", m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, 0, m.UINT64_MAX)
    add("all profit, all paid", m.UINT64_MAX, 0, m.UINT64_MAX, 0, 0)
    add("all loss", 0, m.UINT64_MAX, m.UINT64_MAX, 0, 0)
    rng = v.rng
    for i in range(800):
        r = i % 3
        if r < 2:
            leverage = bet_leverage(rng, i)
            stake_ = stake(rng)
            pay = m.payout(stake_, tier_bet(rng, leverage)[5]) if stake_ <= 10**15 else rng.uint(64)
            floor = rng.pick((fl, 500 * 10**9, rng.between(0, 10**12)))
            profit = max(0, pay - stake_)
            free = rng.pick((rng.near(profit, 2, 0, m.UINT64_MAX), rng.near(floor, 2, 0, m.UINT64_MAX),
                             rng.between(0, 10**13), amount(rng)))
            owed = 0 if rng.chance(75) else rng.pick((1, amount(rng)))
        else:
            pay, stake_, free, owed, floor = (amount(rng) for _ in range(5))
            if rng.chance(50):
                owed = 0
        add(None, pay, stake_, free, owed, floor)
    return v


# --- The early sale (§8) ---------------------------------------------------------------------------------------------


def _check_sell_window(startTime, endTime, publishTime, minDelaySecs, cutoffSecs):
    m.check_sell_window(startTime, endTime, publishTime, minDelaySecs, cutoffSecs)
    return {}


def gen_check_sell_window():
    v = Vectors("checkSellWindow", "LeverageMath", "docs/MATH.md section 8", _check_sell_window)

    def add(note, start, end, publish, delay, cutoff):
        v.add(note=note, startTime=start, endTime=end, publishTime=publish, minDelaySecs=delay, cutoffSecs=cutoff)

    for publish, note in ((1_000, "Example 12: the start"), (1_057, "Example 12: the last second"),
                          (999, "Example 12: before the start"), (1_058, "Example 12: inside the cutoff"),
                          (1_060, "Example 12: the end"), (1_061, "after the end")):
        add(note, 1_000, 1_060, publish, 0, 2)
    add("Example 12: inside a 10-second delay", 1_000, 1_060, 1_009, 10, 2)
    add("Example 12: the delay's end", 1_000, 1_060, 1_010, 10, 2)
    add("an end at the cutoff closes the window", 0, 2, 0, 0, 2)
    add("an end one second past it opens it", 0, 3, 0, 0, 2)
    add("no cutoff: the last second before the end", 1_000, 1_060, 1_059, 0, 0)
    add("a delay as long as the bet", 1_000, 1_060, 1_059, 60, 0)
    add("a delay and a cutoff that meet", 1_000, 1_060, 1_030, 30, 30)
    add("a delay and a cutoff that leave one second", 1_000, 1_060, 1_029, 29, 30)
    add("the largest delay and cutoff", 0, 2 * 65_535 + 1, 65_535, 65_535, 65_535)
    add("the largest cutoff closes a short bet", 0, 65_535, 0, 0, 65_535)
    add("a zero bet", 0, 0, 0, 0, 0)
    add("the uint256 maximum", 0, UINT256_MAX, UINT256_MAX - 1, 0, 0)
    add("the uint256 maximum, at the end", 0, UINT256_MAX, UINT256_MAX, 0, 0)
    add("a start at the uint256 maximum", UINT256_MAX, UINT256_MAX, UINT256_MAX, 0, 0)
    add("a start at the uint256 maximum, with a delay", UINT256_MAX - 1, UINT256_MAX, UINT256_MAX - 2, 1, 0)
    rng = v.rng
    for i in range(800):
        if i % 6 == 5:  # anywhere in the types
            start, end, publish = (rng.uint(256) if rng.chance(30) else rng.uint(40) for _ in range(3))
            delay, cutoff = rng.uint(16), rng.uint(16)
        else:  # a bet a few minutes long; a tick inside its sell window, on an edge, or one to three seconds out
            start = rng.between(1_600_000_000, 1_900_000_000) if rng.chance(85) else rng.between(0, 100)
            end = start + (rng.pick(DURATIONS) if rng.chance(80) else rng.uint(16))
            delay = rng.pick((0, 0, 5, 10, rng.between(0, 30), rng.uint(16) if rng.chance(30) else 0))
            cutoff = rng.pick((0, 2, 2, 5, rng.between(0, 30), rng.uint(16) if rng.chance(30) else 2))
            lo, hi = start + delay, end - cutoff - 1  # the window, both ends included
            fault = rng.below(10)
            if lo <= hi and fault < 6:
                publish = rng.pick((lo, hi, rng.between(lo, hi)))
            elif fault < 8:
                publish = lo - rng.between(1, 3)
            else:
                publish = hi + rng.between(1, 3)
            publish = max(0, publish)
        add(None, start, end, publish, delay, cutoff)
    return v


def _check_sell(stake, gNowBps, valuation, sellAmount, minAmount, maxSellFeeBps, totalOwed, freeBefore):
    m.check_sell(stake, gNowBps, valuation, sellAmount, minAmount, maxSellFeeBps, totalOwed, freeBefore)
    return {}


def gen_check_sell():
    v = Vectors("checkSell", "LeverageMath", "docs/MATH.md section 8", _check_sell)
    s, t, big = m.STAKE, m.TOKEN, 10**12

    def add(note, g, val, amt, min_amt, rate, owed, free, stake_=s):
        v.add(note=note, stake=stake_, gNowBps=g, valuation=val, sellAmount=amt, minAmount=min_amt,
              maxSellFeeBps=rate, totalOwed=owed, freeBefore=free)

    add("Example 10: at most the payout", 13_000, 13_000_000, 13_000_000, 0, 600, 0, big)
    add("Example 10: one unit above it", 13_000, 13_000_001, 13_000_001, 0, 600, 0, big)
    add("Example 10: a 6% fee at its cap", 13_000, 12_500_000, 11_750_000, 0, 600, 0, big)
    add("Example 10: one unit over the cap", 13_000, 12_500_000, 11_749_999, 0, 600, 0, big)
    add("Example 10: payable with $2 free", 13_000, 12 * t, 12 * t, 0, 600, 0, 2 * t)
    add("Example 10: one unit less free", 13_000, 12 * t, 12 * t, 0, 600, 0, 2 * t - 1)
    add("a sale amount above the valuation", 13_000, 12 * t, 12 * t + 1, 0, 600, 0, big)
    add("the user's minimum", 13_000, 12 * t, 12 * t, 12 * t, 600, 0, big)
    add("one unit below the user's minimum", 13_000, 12 * t, 12 * t, 12 * t + 1, 600, 0, big)
    add("someone owed", 13_000, 12 * t, 12 * t, 0, 600, 1, big)
    add("a zero fee cap, no fee", 13_000, 12 * t, 12 * t, 0, 0, 0, big)
    add("a zero fee cap, a fee of 1", 13_000, 12 * t, 12 * t - 1, 0, 0, 0, big)
    add("a 100% fee cap: the whole valuation", 13_000, 12 * t, 0, 0, 10_000, 0, big)
    add("a fee cap above 100% refuses nothing", 13_000, 12 * t, 0, 0, 10_001, 0, big)
    add("the largest fee cap", 13_000, 12 * t, 0, 0, 65_535, 0, big)
    add("a loss sold at its payout", 9_046, 9_046_000, 9_046_000, 0, 600, 0, 0)
    add("a liquidated multiple values at 0", 0, 0, 0, 0, 600, 0, 0)
    add("a payout too large for uint64", 10_001, 0, 0, 0, 600, 0, 0, m.UINT64_MAX)
    add("the payout is checked first", 65_535, m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, 0, 1, 0, m.UINT64_MAX)
    add("valuation, then sale amount", 13_000, 13_000_001, 13_000_002, 0, 600, 1, 0)
    add("sale amount, then fee", 13_000, 12 * t, 12 * t + 1, 13 * t, 0, 1, 0)
    add("fee, then minimum", 13_000, 12 * t, 11 * t, 12 * t, 600, 1, 0)
    add("minimum, then queue", 13_000, 12 * t, 12 * t, 12 * t + 1, 600, 1, 0)
    add("queue, then payable", 13_000, 12 * t, 12 * t, 0, 600, 1, 0)
    add("the uint64 maximum, payable", 10_000, m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, 0, 0, 0, m.UINT64_MAX)
    add("free money plus the stake, in 256 bits", 20_000, m.UINT64_MAX, m.UINT64_MAX, 0, 0, 0, m.UINT64_MAX,
        m.UINT64_MAX // 2 + 1)
    rng = v.rng
    for i in range(1000):
        if i % 8 == 7:  # anywhere in the types
            stake_, val, amt, min_amt, owed, free = (amount(rng) for _ in range(6))
            g, rate = rng.uint(16), rng.uint(16)
            add(None, g, val, amt, min_amt, rate, owed, free, stake_)
            continue
        # A sale of a bet at a tier, quoted within every bound, or with one check broken at its bound.
        leverage = bet_leverage(rng, i)
        stake_ = stake(rng) if rng.chance(90) else rng.log_uniform(1, 10**17)
        g = tier_bet(rng, leverage)[5]
        try:
            pay = m.payout(stake_, g)
        except m.Revert:  # too large for uint64: the first check refuses it
            pay = m.UINT64_MAX
        val = pay if rng.chance(40) else rng.between(0, pay)
        rate = rng.pick((600, 600, 0, 10_000, rng.between(0, 10_000), rng.uint(16)))
        fee_cap = val * min(rate, m.BPS) // m.BPS
        amt = val - fee_cap if rng.chance(40) else val - rng.between(0, fee_cap)
        min_amt = amt if rng.chance(40) else rng.between(0, amt)
        owed = 0
        need = max(0, val - stake_)
        free = need if rng.chance(30) else min(m.UINT64_MAX, need + rng.log_uniform(0, 10**12))
        fault = rng.below(12)
        if fault == 0 and pay < m.UINT64_MAX:
            val = pay + 1
        elif fault == 1 and val < m.UINT64_MAX:
            amt = val + 1
        elif fault == 2 and val - fee_cap >= 1:
            amt = val - fee_cap - 1
        elif fault == 3 and amt < m.UINT64_MAX:
            min_amt = amt + 1
        elif fault == 4:
            owed = rng.pick((1, amount(rng)))
        elif fault == 5 and need >= 1:
            free = need - 1
        add(None, g, val, amt, min_amt, rate, owed, free, stake_)
    return v


def _sell_split(stake, valuation, sellAmount, freeBefore, poolFloor):
    s = m.sell_split(stake, valuation, sellAmount, freeBefore, poolFloor)
    return dict(s._asdict(), fees=m.sell_fees(s), outOfPool=m.sell_out_of_pool(s))


def gen_sell_split():
    v = Vectors("sellSplit", "LeverageMath", "docs/MATH.md section 8", _sell_split)
    s, fl = m.STAKE, m.POOL_FLOOR

    def add(note, val, amt, free=fl, floor=fl, stake_=s):
        v.add(note=note, stake=stake_, valuation=val, sellAmount=amt, freeBefore=free, poolFloor=floor)

    add("Example 10: profit", 12_500_000, 12_000_000)
    add("Example 10: loss", 9_000_000, 8_600_000)
    add("Example 10: loss, free one unit below the floor", 9_000_000, 8_600_000, fl - 1)
    add("Example 10: at the cap", 40_000_000, 40_000_000)
    add("Example 10: in between", 10_200_000, 9_900_000)
    add("a sale amount at the stake", 12_000_000, s)
    add("one unit above the stake", 12_000_000, s + 1)
    add("a valuation at the stake", s, 9_000_000)
    add("one unit below the stake", s - 1, 9_000_000)
    add("nothing at all", 0, 0)
    add("a sale amount above the valuation: Panic(0x11)", 9_000_000, 9_000_001)
    add("the uint64 maximum", m.UINT64_MAX, m.UINT64_MAX, m.UINT64_MAX, 0, 0)
    add("all loss", 0, 0, m.UINT64_MAX, 0, m.UINT64_MAX)
    add("all fee", m.UINT64_MAX, 0, 0, 0, m.UINT64_MAX)
    add("the uint64 maximum above a zero valuation: Panic(0x11)", 0, m.UINT64_MAX, 0, 0, 0)
    rng = v.rng
    for i in range(800):
        r = i % 3
        if r < 2:
            stake_ = stake(rng)
            val = rng.pick((stake_, stake_ - 1, stake_ + 1, rng.between(0, 4 * stake_),
                            rng.log_uniform(0, m.UINT64_MAX)))
            val = min(m.UINT64_MAX, max(0, val))
            amt = rng.pick((val, val - val * 600 // m.BPS, rng.between(0, val), min(val, stake_), min(val, stake_ + 1)))
            if rng.chance(3):
                amt = val + 1  # refused: Panic(0x11)
            amt = min(m.UINT64_MAX, max(0, amt))
            floor = rng.pick((fl, 500 * 10**9, rng.between(0, 10**12)))
            free = rng.near(floor, 2, 0, m.UINT64_MAX) if rng.chance(40) else amount(rng)
        else:
            stake_, val, amt, free, floor = (amount(rng) for _ in range(5))
            if rng.chance(95) and amt > val:
                val, amt = amt, val
        add(None, val, amt, free, floor, stake_)
    return v


# --- The IOU queue (§9) ----------------------------------------------------------------------------------------------


def gen_repay_split():
    v = Vectors("repaySplit", "LeverageMath", "docs/MATH.md section 9",
                lambda owed, free: dict(m.repay_split(owed, free)._asdict()))
    t = m.TOKEN
    for owed, free, note in ((30 * t, 10 * t, "Example 11: $10 of $30"), (30 * t, 30 * t, "paid in full"),
                             (30 * t, 30 * t - 1, "one unit short"), (30 * t, 30 * t + 1, "one unit to spare"),
                             (0, 0, "nothing"), (0, 10 * t, "nothing owed"), (10 * t, 0, "nothing free"),
                             (49, 49, "2% of 49 is 0"), (50, 50, "2% of 50 is 1"),
                             (m.UINT64_MAX, m.UINT64_MAX, "the uint64 maximum"), (m.UINT64_MAX, 0, None),
                             (0, m.UINT64_MAX, None), (m.UINT64_MAX, 1, None)):
        v.add(note=note, owed=owed, free=free)
    rng = v.rng
    for i in range(700):
        owed = stake(rng) if i % 3 == 0 else amount(rng)
        free = rng.near(owed, 2, 0, m.UINT64_MAX) if i % 3 == 1 else amount(rng)
        v.add(owed=owed, free=free)
    return v


# --- Withdrawals (§10) -----------------------------------------------------------------------------------------------


def _check_withdraw(purpose, amount, free, totalOwed, poolFloor, openMaxProfit, seedRecovered, decimals):
    m.check_withdraw(purpose, amount, free, totalOwed, poolFloor, openMaxProfit, seedRecovered, decimals)
    return {}


def gen_check_withdraw():
    v = Vectors("checkWithdraw", "LeverageMath", "docs/MATH.md section 10", _check_withdraw)
    t = m.TOKEN
    seed, rewards = m.SEED_RECOVERY, m.REWARDS

    def add(note, purpose, amt, free, owed=0, floor=500 * t, open_mp=0, recovered=0, decimals=6):
        v.add(note=note, purpose=purpose, amount=amt, free=free, totalOwed=owed, poolFloor=floor,
              openMaxProfit=open_mp, seedRecovered=recovered, decimals=decimals)

    add("Example 9: rewards up to $1,000", rewards, 1_000 * t, 1_500 * t)
    add("Example 9: one unit more", rewards, 1_000 * t + 1, 1_500 * t)
    add("Example 9: $700 with $300 of exposure", rewards, 700 * t, 1_500 * t, open_mp=300 * t)
    add("Example 9: one unit more", rewards, 700 * t + 1, 1_500 * t, open_mp=300 * t)
    add("Example 9: $500 of seed in one go", seed, 500 * t, 1_500 * t)
    add("Example 9: $200 after $300", seed, 200 * t, 1_500 * t, recovered=300 * t)
    add("Example 9: one unit more", seed, 200 * t + 1, 1_500 * t, recovered=300 * t)
    add("Example 9: $400 with $900 free", seed, 400 * t, 900 * t)
    add("Example 9: one unit more, the floor binds first", seed, 400 * t + 1, 900 * t)
    add("Example 9: the cap at 9 decimals", seed, 500 * 10**9, 10**13, floor=0, decimals=9)
    add("Example 9: one unit over it", seed, 500 * 10**9 + 1, 10**13, floor=0, decimals=9)
    add("Example 9: 17 decimals do not fit uint64", seed, 1, 10**13, floor=0, decimals=17)
    add("16 decimals still fit", seed, 500 * 10**16, m.UINT64_MAX, floor=0, decimals=16)
    add("rewards ignore the decimals", rewards, 1, 10**13, floor=0, decimals=255)
    for d in (18, 19, 20, 77, 78, 255):
        add("seed recovery at %d decimals" % d, seed, 1, 10**13, floor=0, decimals=d)
    add("a zero amount comes first", seed, 0, 0, owed=1, decimals=255)
    add("someone owed", rewards, 1, 1_500 * t, owed=1)
    add("someone owed, before the floor", rewards, m.UINT64_MAX, 0, owed=m.UINT64_MAX)
    add("nothing free", rewards, 1, 0, floor=0)
    add("the floor, before the exposure", rewards, 1, 500 * t, open_mp=m.UINT64_MAX)
    add("amount plus floor in 256 bits", rewards, m.UINT64_MAX, m.UINT64_MAX, floor=m.UINT64_MAX)
    add("everything free, no floor", rewards, m.UINT64_MAX, m.UINT64_MAX, floor=0)
    add("seed recovered already at the cap", seed, 1, 1_500 * t, recovered=500 * t)
    add("seed recovered at the uint64 maximum", seed, 1, 1_500 * t, recovered=m.UINT64_MAX)
    add("the exposure, before the seed cap", seed, 1, 1_500 * t, open_mp=1_000 * t, recovered=m.UINT64_MAX)
    rng = v.rng
    for i in range(900):
        if i % 8 == 7:  # anywhere in the types
            amt, free, owed, floor, open_mp, recovered = (amount(rng) for _ in range(6))
            decimals = rng.uint(8)
            if rng.chance(60):
                owed = 0
            add(None, rng.below(2), amt, free, owed, floor, open_mp, recovered, decimals)
            continue
        # A withdrawal within every bound, or with one check broken at its bound.
        decimals = rng.between(6, 9) if rng.chance(85) else rng.between(0, 16)
        unit = 10**decimals
        cap_ = 500 * unit
        floor = 500 * unit if rng.chance(70) else rng.between(0, 10**3 * unit)
        free = min(m.UINT64_MAX, floor + (rng.log_uniform(0, 10**6 * unit) if rng.chance(85) else amount(rng)))
        room = free - floor
        open_mp = rng.pick((0, rng.between(0, room - 1), room - 1)) if room >= 1 else 0
        most = room - open_mp  # the most that may leave
        purpose = rng.below(2)
        amt = most if rng.chance(30) else rng.between(min(1, most), most)  # 0 only when nothing may leave
        if purpose == m.SEED_RECOVERY:
            amt = min(amt, cap_)
        recovered = 0 if purpose == m.REWARDS or rng.chance(30) else rng.between(0, cap_ - amt)
        owed = 0
        fault = rng.below(14)
        if fault == 0:
            amt = 0
        elif fault == 1:
            owed = rng.pick((1, amount(rng)))
        elif fault == 2 and room < m.UINT64_MAX:
            amt = room + 1
        elif fault == 3 and open_mp >= 1:
            amt = most + 1
        elif fault == 4 and amt >= 1:
            amt = min(amt, cap_)
            purpose, recovered = m.SEED_RECOVERY, cap_ - amt + 1
        elif fault == 5 and amt >= 1:
            purpose, decimals = m.SEED_RECOVERY, rng.between(17, 255)
        add(None, purpose, amt, free, owed, floor, open_mp, recovered, decimals)
    return v


# --- A market's settings and a bet's terms (§3) ----------------------------------------------------------------------


def tier_config(leverage):
    """The example market's settings fitted to a tier (§12, Example 8): the 1000x launch config, or the 500x and 100x
    tier settings (each duration's lowest line 15% below the tier's)."""
    c = m.launch_config()
    if leverage == 500:
        rules = tuple(m.DurationRule(60 * (i + 1), 2_490, 11_760, True) for i in range(5))
        return c._replace(floorMinBps=10_250, floorMaxBps=12_500, capMinBps=15_000, capMaxBps=25_000, durations=rules)
    if leverage == 100:
        rules = (m.DurationRule(60, 2_601, 9_000, True), m.DurationRule(120, 3_629, 12_570, True),
                 m.DurationRule(180, 4_275, 14_790, True), m.DurationRule(240, 4_743, 16_410, True),
                 m.DurationRule(300, 5_100, 17_640, True))
        return c._replace(floorMinBps=10_050, floorMaxBps=10_500, capMinBps=15_000, capMaxBps=20_000, durations=rules)
    return c


EMPTY_RULE = m.DurationRule(0, 0, 0, False)


def with_rule(c, i, r):
    """`c` with duration rule `i` replaced by `r`."""
    rules = list(c.durations)
    rules[i] = r
    return c._replace(durations=tuple(rules))


def random_rules(rng, leverage):
    """Five duration rules valid at `leverage`: 0 to 5 used ones, with distinct durations, in any slots."""
    used = rng.between(0, 5)
    durations = []
    while len(durations) < used:
        d = rng.pick(DURATIONS) if rng.chance(60) else rng.between(1, 65_535)
        if d not in durations:
            durations.append(d)
    top = widest(leverage)
    rules = []
    for d in durations:
        hi = theta(rng, leverage)
        rules.append(m.DurationRule(d, rng.between(1, hi), hi if rng.chance(70) else rng.between(hi, top),
                                    rng.chance(80)))
    rules += [EMPTY_RULE] * (5 - used)
    for i in range(4, 0, -1):  # shuffle the slots
        j = rng.below(i + 1)
        rules[i], rules[j] = rules[j], rules[i]
    return tuple(rules)


def random_config(rng, leverage):
    """Settings `validate` accepts at `leverage`."""
    top = highest_cap(leverage)
    cap_max = rng.between(m.BPS + 1, top) if rng.chance(50) else min(top, rng.pick((20_000, 25_000, 40_000)))
    floor_max = rng.between(m.BPS + 1, cap_max)
    min_stake = rng.between(1, 10 * TOKEN6) if rng.chance(70) else rng.log_uniform(1, m.UINT64_MAX)
    return m.ConfigParams(
        enabled=rng.chance(50), entryMaxAgeSecs=rng.between(1, 255) if rng.chance(30) else rng.between(1, 10),
        clockSkewSecs=rng.between(0, 30), floorMinBps=rng.between(m.BPS + 1, floor_max), floorMaxBps=floor_max,
        capMinBps=rng.between(m.BPS + 1, cap_max), capMaxBps=cap_max, maxSellFeeBps=rng.between(0, m.BPS),
        sellMinDelaySecs=rng.uint(16) if rng.chance(20) else rng.between(0, 10),
        sellCutoffSecs=rng.uint(16) if rng.chance(20) else rng.between(0, 10),
        maxExposureBps=rng.between(1, m.BPS) if rng.chance(50) else m.BPS,
        minStake=min_stake, maxStake=rng.between(min_stake, m.UINT64_MAX) if rng.chance(30) else
        min(m.UINT64_MAX, min_stake + rng.log_uniform(0, 10**12)),
        maxTotalOwed=rng.uint(64), durations=random_rules(rng, leverage),
    )


def any_config(rng):
    """Settings with every field anywhere in its type."""
    rules = tuple(m.DurationRule(rng.uint(16) if rng.chance(70) else 0, rng.uint(32), rng.uint(32), rng.chance(50))
                  for _ in range(5))
    return m.ConfigParams(rng.chance(50), rng.uint(8), rng.uint(8), rng.uint(16), rng.uint(16), rng.uint(16),
                          rng.uint(16), rng.uint(16), rng.uint(16), rng.uint(16), rng.uint(32), rng.uint(64),
                          rng.uint(64), rng.uint(64), rules)


def nudge(rng, c, leverage):
    """`c` with one setting moved onto its bound or one unit past it (§3.1, every rule)."""
    used = [i for i, r in enumerate(c.durations) if r.durationSecs]
    unused = [i for i, r in enumerate(c.durations) if not r.durationSecs]
    k = rng.below(19)
    if k == 0:
        return c._replace(minStake=0)
    if k == 1:
        return c._replace(minStake=c.maxStake + rng.below(2)) if c.maxStake < m.UINT64_MAX else c
    if k == 2:
        return c._replace(floorMinBps=m.BPS + rng.below(2))
    if k == 3:
        return c._replace(floorMinBps=min(65_535, c.floorMaxBps + rng.below(2)))
    if k == 4:
        return c._replace(capMinBps=m.BPS + rng.below(2))
    if k == 5:
        return c._replace(capMinBps=min(65_535, c.capMaxBps + rng.below(2)))
    if k == 6:
        return c._replace(capMaxBps=40_000 + rng.below(2), capMinBps=min(c.capMinBps, 40_000))
    if k == 7:
        return c._replace(floorMaxBps=min(65_535, c.capMaxBps + rng.below(2)))
    if k == 8:
        return c._replace(capMaxBps=min(65_535, highest_cap(leverage) + rng.below(2)), capMinBps=m.BPS + 1)
    if k == 9:
        return c._replace(maxSellFeeBps=m.BPS + rng.below(2))
    if k == 10 and used:
        i = rng.pick(used)
        r = c.durations[i]
        return with_rule(c, i, r._replace(thetaMaxE7=widest(leverage) + rng.below(2), enabled=rng.chance(50)))
    if k == 11 and used:
        i = rng.pick(used)
        return with_rule(c, i, c.durations[i]._replace(thetaMinE7=rng.below(2)))
    if k == 12 and used:
        i = rng.pick(used)
        r = c.durations[i]
        return with_rule(c, i, r._replace(thetaMinE7=min(2**32 - 1, r.thetaMaxE7 + rng.below(2))))
    if k == 13 and len(used) >= 2:
        i, j = sorted((used[0], rng.pick(used[1:])))
        return with_rule(c, j, c.durations[j]._replace(durationSecs=c.durations[i].durationSecs))
    if k == 14 and unused:
        i = rng.pick(unused)
        return with_rule(c, i, rng.pick((EMPTY_RULE._replace(thetaMinE7=1), EMPTY_RULE._replace(thetaMaxE7=1),
                                         EMPTY_RULE._replace(enabled=True))))
    if k == 15:
        return c._replace(entryMaxAgeSecs=rng.below(2))
    if k == 16:
        return c._replace(maxExposureBps=rng.pick((0, 1, m.BPS, m.BPS + 1, 2**32 - 1)))
    if k == 17:
        return c._replace(clockSkewSecs=rng.pick((30, 31, 255)))
    return c._replace(sellMinDelaySecs=65_535, sellCutoffSecs=65_535, maxTotalOwed=rng.pick((0, m.UINT64_MAX)))


def _validate(p, leverage):
    m.validate(p, leverage)
    return {}


def gen_validate():
    v = Vectors("validate", "ConfigLib", "docs/MATH.md section 3.1", _validate)

    def add(note, c, leverage=1000):
        v.add(note=note, p=c, leverage=leverage)

    c = m.launch_config()
    add("Example 8: the example market at 1000x", c)
    for note, changes in (
            ("rule 2: a zero minimum stake", dict(minStake=0)),
            ("rule 2: a minimum above the maximum", dict(minStake=c.maxStake + 1)),
            ("rule 2: minimum = maximum", dict(minStake=c.maxStake)),
            ("rule 3: a floor of exactly 1x", dict(floorMinBps=10_000)),
            ("rule 3: a floor just above 1x", dict(floorMinBps=10_001)),
            ("rule 3: a lowest floor above the highest", dict(floorMinBps=15_001)),
            ("rule 3: lowest floor = highest", dict(floorMinBps=15_000)),
            ("rule 4: a cap of exactly 1x", dict(capMinBps=10_000)),
            ("rule 4: a lowest cap above the highest", dict(capMinBps=40_001, capMaxBps=40_000)),
            ("rule 4: lowest cap = highest", dict(capMinBps=40_000)),
            ("rule 4: a cap above 4x", dict(capMaxBps=40_001)),
            ("rule 5: the highest floor above the highest cap", dict(capMinBps=12_000, capMaxBps=14_000)),
            ("rule 5: the highest floor at the highest cap",
             dict(capMinBps=12_000, capMaxBps=14_000, floorMaxBps=14_000, floorMinBps=11_000)),
            ("rule 7: a sell fee above 100%", dict(maxSellFeeBps=10_001)),
            ("rule 7: a sell fee of 100%", dict(maxSellFeeBps=10_000)),
            ("rule 9: no price age", dict(entryMaxAgeSecs=0)),
            ("rule 9: one second", dict(entryMaxAgeSecs=1)),
            ("rule 10: the gate off", dict(maxExposureBps=0)),
            ("rule 10: 1 bp", dict(maxExposureBps=1)),
            ("rule 10: just over 100%", dict(maxExposureBps=10_001)),
            ("rule 10: the largest", dict(maxExposureBps=2**32 - 1)),
            ("rule 11: no skew", dict(clockSkewSecs=0)),
            ("rule 11: 30 seconds", dict(clockSkewSecs=30)),
            ("rule 11: 31 seconds", dict(clockSkewSecs=31)),
            ("rule 11: 255 seconds", dict(clockSkewSecs=255)),
            ("unbounded: the sell window, the owed limit and enabled",
             dict(sellMinDelaySecs=65_535, sellCutoffSecs=65_535, maxTotalOwed=0, enabled=True))):
        add(note, c._replace(**changes))
    first = c.durations[0]
    for note, i, r in (("rule 8: a zero theta minimum", 0, first._replace(thetaMinE7=0)),
                       ("rule 8: a theta maximum of 10 bp", 0, first._replace(thetaMaxE7=10_000)),
                       ("rule 8: a theta maximum just under 10 bp", 0, first._replace(thetaMaxE7=9_999)),
                       ("rule 8: a 10x units mistake", 0, first._replace(thetaMaxE7=30_000)),
                       ("rule 8: a theta minimum above the maximum", 0, first._replace(thetaMinE7=3_751)),
                       ("rule 8: a duplicate duration", 1, c.durations[1]._replace(durationSecs=60)),
                       ("rule 8: a disabled rule is still checked", 2,
                        c.durations[2]._replace(enabled=False, thetaMinE7=0)),
                       ("rule 8: an empty unused slot", 4, EMPTY_RULE),
                       ("rule 8: an unused slot switched on", 4, EMPTY_RULE._replace(enabled=True)),
                       ("rule 8: an unused slot with a theta", 4, EMPTY_RULE._replace(thetaMaxE7=1)),
                       ("rule 8: an unused slot with a theta minimum", 4, EMPTY_RULE._replace(thetaMinE7=1)),
                       ("rule 8: a zero duration with a full theta range", 0,
                        m.DurationRule(0, 2_250, 3_750, True))):
        add(note, with_rule(c, i, r))
    # The leverage, its widest line and its highest cap (Example 7).
    for leverage in SWEEP:
        top = widest(leverage)
        base = c._replace(capMaxBps=min(19_999, highest_cap(leverage)), durations=tuple(
            r._replace(thetaMinE7=1, thetaMaxE7=top) for r in c.durations))
        add("rule 8: the widest line at %dx" % leverage, base, leverage)
        add("rule 8: one unit wider", with_rule(base, 3, base.durations[3]._replace(thetaMaxE7=top + 1)), leverage)
        add("rule 8: one disabled rule one unit wider",
            with_rule(base, 3, base.durations[3]._replace(thetaMaxE7=top + 1, enabled=False)), leverage)
        add("rule 6: the highest cap at %dx" % leverage, base._replace(capMaxBps=highest_cap(leverage)), leverage)
        if leverage <= 3:
            add("rule 6: one bp higher", base._replace(capMaxBps=highest_cap(leverage) + 1), leverage)
    wide = c._replace(capMaxBps=19_999, durations=tuple(r._replace(thetaMinE7=1, thetaMaxE7=999) for r in c.durations))
    for leverage, note in ((0, "rule 1: leverage 0"), (1, "rule 1: 1x"), (10_000, "rule 1: 10,000x"),
                           (10_001, "rule 1: leverage 10,001"), (65_535, "rule 1: the largest uint16")):
        add(note, wide, leverage)
    for leverage in TIERS:
        add("Example 8: the %dx tier settings" % leverage, tier_config(leverage), leverage)
    add("Example 8: the 500x settings at 1000x", tier_config(500), 1000)
    add("Example 8: the 100x settings at 500x", tier_config(100), 500)
    add("no duration rules at all", c._replace(durations=(EMPTY_RULE,) * 5))
    rng = v.rng
    for i in range(420):
        leverage = bet_leverage(rng, i)
        k = i % 20
        if k < 7:
            cfg = random_config(rng, leverage)
        elif k < 15:
            cfg = nudge(rng, random_config(rng, leverage), leverage)
        elif k < 17:
            cfg = nudge(rng, nudge(rng, tier_config(rng.pick(TIERS)), leverage), leverage)
        elif k < 19:
            cfg = any_config(rng)
        else:
            cfg, leverage = random_config(rng, leverage), bad_leverage(rng)
        add(None, cfg, leverage)
    return v


def _validate_open(markets):
    def run(market, stake, durationSecs, thetaE7, floorBps, capBps):
        m.validate_open(markets[market], stake, durationSecs, thetaE7, floorBps, capBps)
        return {}

    return run


def gen_validate_open():
    rng = Rng(stream_seed("validateOpen/markets"))
    c = m.launch_config()
    markets = [
        ("Example 8: the example market at 1000x", c),
        ("Example 8: a 1.2x cap minimum, below the floors", c._replace(capMinBps=12_000)),
        ("a disabled five-minute rule", with_rule(c, 4, c.durations[4]._replace(enabled=False))),
        ("an unused fifth slot", with_rule(c, 4, EMPTY_RULE)),
        ("the 500x tier settings", tier_config(500)),
        ("the 100x tier settings", tier_config(100)),
        ("one stake only", c._replace(minStake=m.STAKE, maxStake=m.STAKE)),
        ("stored without validate: two enabled rules for 60 s; the first is used",
         with_rule(c, 2, m.DurationRule(60, 4_000, 9_000, True))),
        ("stored without validate: an enabled rule with a zero duration",
         with_rule(c, 4, m.DurationRule(0, 1, 9_999, True))),
        ("the widest stakes", c._replace(minStake=0, maxStake=m.UINT64_MAX)),
    ]
    hand_made = len(markets)  # these get every edge; the random markets below get random terms
    for i in range(24):
        markets.append((None, random_config(rng, bet_leverage(rng, i))))
    for _ in range(4):
        markets.append(("stored without validate", any_config(rng)))
    v = Vectors("validateOpen", "ConfigLib", "docs/MATH.md section 3.2", _validate_open([mk for _, mk in markets]))
    v.extra = ("markets", [mk for _, mk in markets])
    rng = v.rng
    for index, (label, mk) in enumerate(markets):
        enabled = [r for r in mk.durations if r.enabled]
        rule = enabled[0] if enabled else mk.durations[0]
        base = dict(market=index, stake=mk.minStake, durationSecs=rule.durationSecs,
                    thetaE7=(rule.thetaMinE7 + rule.thetaMaxE7) // 2, floorBps=mk.floorMinBps,
                    capBps=max(mk.capMinBps, mk.floorMinBps))

        def add(note, **changes):
            terms = dict(base, **changes)
            for key, bits in (("stake", 64), ("durationSecs", 16), ("thetaE7", 32), ("floorBps", 16),
                              ("capBps", 16)):
                if not 0 <= terms[key] < (1 << bits):
                    return
            v.add(note=note, **terms)

        add(label or "the base terms")
        for s, note in ((mk.minStake, "the smallest stake"), (mk.maxStake, "the largest stake"),
                        (mk.minStake - 1, "one unit below it"), (mk.maxStake + 1, "one unit above it"),
                        (0, "a zero stake")):
            add(note, stake=s)
        if index >= hand_made:
            draws = 22
        else:
            draws = 10
            add_edges(add, mk, rule, base)
        for _ in range(draws):  # terms that fit, or one term one unit outside its range
            terms = dict(base)
            matched = [r for r in mk.durations if r.enabled]
            if matched:
                r = rng.pick(matched)
                r = next(x for x in mk.durations if x.enabled and x.durationSecs == r.durationSecs)  # the first match
                f_lo, f_hi = mk.floorMinBps, mk.floorMaxBps
                floor_bps = rng.between(f_lo, f_hi) if f_lo <= f_hi else f_lo
                c_lo, c_hi = max(mk.capMinBps, floor_bps), mk.capMaxBps
                terms.update(durationSecs=r.durationSecs,
                             thetaE7=rng.between(r.thetaMinE7, r.thetaMaxE7) if r.thetaMinE7 <= r.thetaMaxE7 else 0,
                             floorBps=floor_bps, capBps=rng.between(c_lo, c_hi) if c_lo <= c_hi else c_lo)
                terms["stake"] = (rng.between(mk.minStake, mk.maxStake) if mk.minStake <= mk.maxStake
                                  else mk.minStake)
                fault = rng.below(12)
                if fault == 0:
                    terms["stake"] = rng.pick((mk.minStake - 1, mk.maxStake + 1))
                elif fault == 1:
                    terms["durationSecs"] = rng.uint(16)
                elif fault == 2:
                    terms["thetaE7"] = rng.pick((r.thetaMinE7 - 1, r.thetaMaxE7 + 1))
                elif fault == 3:
                    terms["floorBps"] = rng.pick((f_lo - 1, f_hi + 1))
                elif fault == 4:
                    terms["capBps"] = rng.pick((c_lo - 1, c_hi + 1))
            else:
                terms.update(stake=rng.uint(64), durationSecs=rng.uint(16), thetaE7=rng.uint(32),
                             floorBps=rng.uint(16), capBps=rng.uint(16))
            add(None, **{k: terms[k] for k in ("stake", "durationSecs", "thetaE7", "floorBps", "capBps")})
    return v


def add_edges(add, mk, rule, base):
    """validateOpen's edge cases on market `mk`: every term on its bound and one unit past it, and the check order."""
    for r in mk.durations:
        for t, note in ((r.thetaMinE7, "the narrowest line"), (r.thetaMaxE7, "the widest line"),
                        (r.thetaMinE7 - 1, "one unit narrower"), (r.thetaMaxE7 + 1, "one unit wider")):
            add(note if r.enabled else "a rule that is not enabled", durationSecs=r.durationSecs, thetaE7=t)
    for d, note in ((0, "a zero duration"), (90, "a duration with no rule"), (65_535, None)):
        add(note, durationSecs=d)
    for f, note in ((mk.floorMinBps, "the lowest floor"), (mk.floorMaxBps, "the highest floor"),
                    (mk.floorMinBps - 1, "one bp below it"), (mk.floorMaxBps + 1, "one bp above it")):
        add(note, floorBps=f, capBps=max(mk.capMinBps, f))
    low = max(mk.capMinBps, base["floorBps"])
    for cp, note in ((low, "the lowest cap"), (mk.capMaxBps, "the highest cap"), (low - 1, "one bp below it"),
                     (mk.capMaxBps + 1, "one bp above it")):
        add(note, capBps=cp)
    if mk.floorMaxBps > mk.capMinBps:
        add("a floor above the cap minimum: the floor is the lowest cap", floorBps=mk.floorMaxBps,
            capBps=mk.floorMaxBps - 1)
    add("stake first", stake=mk.maxStake + 1, durationSecs=90, thetaE7=0, floorBps=0, capBps=0)
    add("duration before theta", durationSecs=90, thetaE7=rule.thetaMaxE7 + 1, floorBps=0)
    add("theta before floor", thetaE7=rule.thetaMaxE7 + 1, floorBps=0, capBps=0)
    add("floor before cap", floorBps=mk.floorMaxBps + 1, capBps=0)


# --- Writing ----------------------------------------------------------------------------------------------------------

GENERATORS = (
    gen_floor_div, gen_leverage_allowed, gen_theta_within_limit, gen_cap_reachable, gen_lines, gen_cap_line,
    gen_g_bps, gen_payout, gen_max_profit, gen_touched, gen_check_liquidation, gen_check_entry_time, gen_open_gate,
    gen_fee, gen_winner_fee, gen_loser_fee, gen_settle_split, gen_check_sell_window, gen_check_sell, gen_sell_split,
    gen_repay_split, gen_check_withdraw, gen_validate, gen_validate_open,
)


def main(argv):
    check = "--check" in argv
    m.check_worked_examples()  # never write vectors from a model that disagrees with docs/MATH.md §12
    if not check:
        os.makedirs(OUT_DIR, exist_ok=True)
    stale = []
    total_cases = total_bytes = 0
    for gen in GENERATORS:
        v = gen()
        text = v.render()
        path = os.path.join(OUT_DIR, v.name + ".json")
        data = text.encode("ascii")
        total_cases += len(v.cases) + len(v.reverts)
        total_bytes += len(data)
        if check:
            try:
                with open(path, "rb") as f:
                    same = f.read() == data
            except OSError:
                same = False
            if not same:
                stale.append(path)
        else:
            with open(path, "wb") as f:
                f.write(data)
        print("%-18s %5d cases %5d reverts %9d bytes" % (v.name, len(v.cases), len(v.reverts), len(data)))
    print("%-18s %17d in all %9d bytes" % ("total", total_cases, total_bytes))
    if stale:
        print("out of date: " + ", ".join(os.path.relpath(p, ROOT) for p in stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
