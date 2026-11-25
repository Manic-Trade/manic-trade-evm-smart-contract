#!/usr/bin/env python3
"""A reference model of the Manic Flash Option's maths.

This is a second implementation of docs/MATH.md, in another language. It is written from that document; the
contract's code was read only where the document leaves a point open, and each docstring says what that settled.

- Exact integers only: Python's integers are unbounded, so nothing wraps, and every rounding and every narrowing to
  a Solidity type is written out.
- A refusal raises `Revert`. Its `name` is the contract's custom error ("MathOverflow", "InvalidLeverageParams", ...)
  or, for Solidity's built-in checked arithmetic, "Panic(0x11)" (overflow or underflow) or "Panic(0x12)" (division
  by zero). The checks run in the contract's order, so the first one that fails names the error.
- An input outside its Solidity type (a negative amount, a 17-bit leverage) cannot reach the contract through its
  ABI, so the model refuses it with `ValueError`: that is a bug in the caller, not a refusal by the contract.
- The records (`Lines`, `SettleSplit`, `SellSplit`, `RepaySplit`, `DurationRule`, `ConfigParams`) use the field
  names of the contract's structs, so they map one to one onto the contract's types and onto the test vectors.

Run it to check the model against the worked examples of docs/MATH.md §12:

    python3 model/flash_option_math.py

Python 3.9 or later, standard library only.
"""

from typing import NamedTuple, Tuple

# --- Constants (docs/MATH.md §3.3) -----------------------------------------------------------------------------------

MIN_LEVERAGE = 1
MAX_LEVERAGE = 10_000
BPS = 10_000  # basis points in 1x, or in 100%
E7 = 10_000_000  # the scale of theta: thetaE7 = theta x 10^7
MAX_LEVERAGE_CAP_BPS = 40_000  # 4x
WINNER_FEE_BPS = 200  # 2% of the profit paid
LOSER_FEE_BPS = 300  # 3% of the loss
SEED_RECOVERY_CAP_TOKENS = 500  # whole tokens, x 10^decimals
MAX_CLOCK_SKEW_SECS = 30

# `Side` and `WithdrawPurpose`, as the contract numbers them.
CALL = 0  # a long: wins when the price rises
PUT = 1  # a short: wins when the price falls
SEED_RECOVERY = 0
REWARDS = 1

# The integer types' ranges.
INT64_MIN = -(1 << 63)
INT64_MAX = (1 << 63) - 1
UINT64_MAX = (1 << 64) - 1
INT256_MIN = -(1 << 255)
INT256_MAX = (1 << 255) - 1


class Revert(Exception):
    """The contract refused: `name` is its custom error, or "Panic(0x11)" / "Panic(0x12)".

    `args` holds the error's arguments, if it has any (the position id of `InvalidLiquidationWindow` and
    `LiquidationPriceNotReached`).
    """

    def __init__(self, name, *args):
        super().__init__(name, *args)
        self.name = name
        self.args_ = args


# --- Records ----------------------------------------------------------------------------------------------------------


class Lines(NamedTuple):
    """The two lines of a bet (§4)."""

    liqPrice: int
    capPrice: int


class SettleSplit(NamedTuple):
    """How an expiry payout splits (§7.4)."""

    own: int
    paid: int
    owed: int
    winnerFee: int
    loserFee: int


class SellSplit(NamedTuple):
    """How an early sale splits (§8)."""

    toUser: int
    sellFee: int
    winnerFee: int
    loserFee: int


class RepaySplit(NamedTuple):
    """How one repayment of an IOU splits (§9)."""

    amount: int
    winnerFee: int
    toUser: int
    remaining: int


class DurationRule(NamedTuple):
    """A duration and the range of theta a bet of that length may have (§2, §3.1)."""

    durationSecs: int
    thetaMinE7: int
    thetaMaxE7: int
    enabled: bool


class ConfigParams(NamedTuple):
    """A market's settings (§3.1), in the field order of the contract's `ConfigParams`."""

    enabled: bool
    entryMaxAgeSecs: int
    clockSkewSecs: int
    floorMinBps: int
    floorMaxBps: int
    capMinBps: int
    capMaxBps: int
    maxSellFeeBps: int
    sellMinDelaySecs: int
    sellCutoffSecs: int
    maxExposureBps: int
    minStake: int
    maxStake: int
    maxTotalOwed: int
    durations: Tuple[DurationRule, DurationRule, DurationRule, DurationRule, DurationRule]


# --- Types and narrowing (§1, §11) ----------------------------------------------------------------------------------


def _uint(value, bits):
    """`value` as a `uint<bits>` argument; anything else could not reach the contract (ValueError)."""
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < (1 << bits):
        raise ValueError("not a uint%d: %r" % (bits, value))
    return value


def _int(value, bits):
    """`value` as an `int<bits>` argument (ValueError otherwise)."""
    half = 1 << (bits - 1)
    if isinstance(value, bool) or not isinstance(value, int) or not -half <= value < half:
        raise ValueError("not an int%d: %r" % (bits, value))
    return value


def _bool(value):
    """`value` as a `bool` argument (ValueError otherwise)."""
    if not isinstance(value, bool):
        raise ValueError("not a bool: %r" % (value,))
    return value


def _side(side):
    """`side` as a `Side` argument: CALL (0) or PUT (1)."""
    if side not in (CALL, PUT) or isinstance(side, bool):
        raise ValueError("not a side: %r" % (side,))
    return side


def _to_int64(value):
    """Narrows a result to `int64` (§11): a value that does not fit is refused with `MathOverflow`."""
    if not INT64_MIN <= value <= INT64_MAX:
        raise Revert("MathOverflow")
    return value


def _to_uint64(value):
    """Narrows a result to `uint64` (§11): a value that does not fit is refused with `MathOverflow`."""
    if not 0 <= value <= UINT64_MAX:
        raise Revert("MathOverflow")
    return value


def _checked_uint64(value):
    """Plain `uint64` arithmetic (a sum or a difference of two amounts). It is not one of the narrowings of §11, so
    Solidity's checked arithmetic refuses a result outside the type with Panic(0x11)."""
    if not 0 <= value <= UINT64_MAX:
        raise Revert("Panic(0x11)")
    return value


# --- floorDiv (§11) --------------------------------------------------------------------------------------------------


def floor_div(a, b):
    """`floorDiv(a, b)` (docs/MATH.md §11): `a / b` rounded toward minus infinity.

    Python's `//` is exactly this floor: `floor_div(-7, 2) == -4`, where Solidity's `/` gives -3. Settled by the
    code, since the document only uses a positive divisor: the operands and the result are `int256`, a zero divisor
    panics (Panic(0x12)), and the one quotient that does not fit, the smallest `int256` divided by -1, panics too
    (Panic(0x11)).
    """
    _int(a, 256)
    _int(b, 256)
    if b == 0:
        raise Revert("Panic(0x12)")
    q = a // b
    if q > INT256_MAX:
        raise Revert("Panic(0x11)")
    return q


# --- The leverage checks (§3.1, §3.3, §4) --------------------------------------------------------------------------


def leverage_allowed(leverage):
    """`leverageAllowed(L)` (§3.1 rule 1, §3.3): L is a whole number from 1 to 10,000."""
    _uint(leverage, 16)
    return MIN_LEVERAGE <= leverage <= MAX_LEVERAGE


def theta_within_limit(theta_e7, leverage):
    """`thetaWithinLimit(thetaE7, L)` (§3.1, a duration rule; §4): the line comes before a move of 1/L, that is
    `thetaE7 x L < 10^7`. The widest line a leverage allows is therefore `(10^7 - 1) // L`."""
    _uint(theta_e7, 32)
    _uint(leverage, 16)
    return theta_e7 * leverage < E7


def cap_reachable(cap_bps, leverage):
    """`capReachable(capBps, L)` (§3.1 rule 6): a short can reach the cap, `capBps - 10,000 < L x 10,000`.

    The document states the rule for caps above 1x. Settled by the code: a cap at or below 1x counts as a gain of 0,
    so it is reachable at every leverage from 1 up, and at L = 0 nothing is.
    """
    _uint(cap_bps, 16)
    _uint(leverage, 16)
    gain = max(cap_bps - BPS, 0)
    return gain < leverage * BPS


# --- The lines (§4) --------------------------------------------------------------------------------------------------


def _line_params_valid(leverage, theta_e7, cap_bps):
    """The parameter checks of `lines` (§4): 1 <= L <= 10,000, thetaE7 > 0, thetaE7 x L < 10^7, 10,000 < capBps <=
    40,000 and capBps - 10,000 < L x 10,000. `theta_e7=None` skips the two theta checks, as `capLine` does."""
    if not leverage_allowed(leverage):
        return False
    if theta_e7 is not None and (theta_e7 == 0 or not theta_within_limit(theta_e7, leverage)):
        return False
    if not BPS < cap_bps <= MAX_LEVERAGE_CAP_BPS:
        return False
    return cap_bps - BPS < leverage * BPS


def _cap_offset(entry, leverage, cap_bps):
    """`capOffset = floor(entry x (capBps - 10,000) / (L x 10,000))` (§4): positive operands, so it rounds down."""
    return entry * (cap_bps - BPS) // (leverage * BPS)


def lines(entry, side, leverage, theta_e7, cap_bps):
    """`lines(entry, side, L, thetaE7, capBps)` (§4): the liquidation line and the cap line of a bet.

    liqOffset = floor(entry x thetaE7 / 10^7)
    capOffset = floor(entry x (capBps - 10,000) / (L x 10,000))
    Call: liqPrice = entry - liqOffset, capPrice = entry + capOffset
    Put:  liqPrice = entry + liqOffset, capPrice = entry - capOffset

    Checks, in order: `entry > 0` (InvalidPrice); then the leverage, theta and the cap (InvalidLeverageParams); and a
    line that does not fit `int64` is MathOverflow.
    """
    _int(entry, 64)
    _side(side)
    _uint(leverage, 16)
    _uint(theta_e7, 32)
    _uint(cap_bps, 16)
    if entry <= 0:
        raise Revert("InvalidPrice")
    if not _line_params_valid(leverage, theta_e7, cap_bps):
        raise Revert("InvalidLeverageParams")
    liq_offset = entry * theta_e7 // E7
    cap_offset = _cap_offset(entry, leverage, cap_bps)
    if side == CALL:
        return Lines(_to_int64(entry - liq_offset), _to_int64(entry + cap_offset))
    return Lines(_to_int64(entry + liq_offset), _to_int64(entry - cap_offset))


def cap_line(entry, side, leverage, cap_bps):
    """`capLine(entry, side, L, capBps)` (§4): the cap line alone, with the same checks as `lines` except theta."""
    _int(entry, 64)
    _side(side)
    _uint(leverage, 16)
    _uint(cap_bps, 16)
    if entry <= 0:
        raise Revert("InvalidPrice")
    if not _line_params_valid(leverage, None, cap_bps):
        raise Revert("InvalidLeverageParams")
    cap_offset = _cap_offset(entry, leverage, cap_bps)
    return _to_int64(entry + cap_offset if side == CALL else entry - cap_offset)


def touched(price, liq_price, side):
    """`touched(price, liqPrice, side)` (§4): a long is touched at or below its line, a short at or above it."""
    _int(price, 64)
    _int(liq_price, 64)
    _side(side)
    return price <= liq_price if side == CALL else price >= liq_price


# --- The payout curve (§5) -------------------------------------------------------------------------------------------


def g_bps(entry, price, side, leverage, floor_bps, cap_bps):
    """`gBps(entry, price, side, L, floorBps, capBps)` (§5): the payout multiple g, in bps of the stake.

    move = price - entry (Call) or entry - price (Put)
    R    = floor(move x L x 10,000 / entry), toward minus infinity (Python's //)
    g    = 10,000 + R, raised to the floor on a win (R > 0), then clamped to the cap, then to 0.

    Checks, in order: `entry > 0` and `price > 0` (InvalidPrice), then 1 <= L <= 10,000 (InvalidLeverageParams).
    """
    _int(entry, 64)
    _int(price, 64)
    _side(side)
    _uint(leverage, 16)
    _uint(floor_bps, 16)
    _uint(cap_bps, 16)
    if entry <= 0 or price <= 0:
        raise Revert("InvalidPrice")
    if not leverage_allowed(leverage):
        raise Revert("InvalidLeverageParams")
    move = price - entry if side == CALL else entry - price
    r = move * leverage * BPS // entry
    g = BPS + r
    if r > 0 and g < floor_bps:
        g = floor_bps
    if g > cap_bps:
        g = cap_bps
    if g < 0:
        g = 0
    return g


def payout(stake, multiple_bps):
    """`payout(stake, g)` (§5): `floor(stake x g / 10,000)`, which must fit `uint64` (MathOverflow)."""
    _uint(stake, 64)
    _uint(multiple_bps, 16)
    return _to_uint64(stake * multiple_bps // BPS)


def max_profit(stake, cap_bps):
    """`maxProfit(stake, capBps)` (§5): `floor(stake x (capBps - 10,000) / 10,000)`, the most a bet can win above
    its stake. It needs `capBps >= 10,000` (InvalidLeverageParams), and the result must fit `uint64` (MathOverflow)."""
    _uint(stake, 64)
    _uint(cap_bps, 16)
    if cap_bps < BPS:
        raise Revert("InvalidLeverageParams")
    return _to_uint64(stake * (cap_bps - BPS) // BPS)


# --- The time checks (§6, §7.1) -------------------------------------------------------------------------------------


def check_liquidation(position_id, start_time, end_time, liq_price, side, price, publish_time, current_time,
                      clock_skew_secs):
    """`checkLiquidation(...)` (§7.1): a price tick liquidates a bet. Checks, in order:

    price <= 0                                        InvalidPrice
    publishTime < startTime or publishTime > endTime  InvalidLiquidationWindow(positionId)
    publishTime > now + clockSkewSecs                 PriceFromFuture
    not touched(price)                                LiquidationPriceNotReached(positionId)

    Both ends of the bet's life count, and there is no age limit. The times are `uint256`, the skew a `uint8`.
    """
    _uint(position_id, 256)
    for t in (start_time, end_time, publish_time, current_time):
        _uint(t, 256)
    _int(liq_price, 64)
    _side(side)
    _int(price, 64)
    _uint(clock_skew_secs, 8)
    if price <= 0:
        raise Revert("InvalidPrice")
    if publish_time < start_time or publish_time > end_time:
        raise Revert("InvalidLiquidationWindow", position_id)
    if publish_time > current_time + clock_skew_secs:
        raise Revert("PriceFromFuture")
    if not touched(price, liq_price, side):
        raise Revert("LiquidationPriceNotReached", position_id)


def check_entry_time(current_time, publish_time, max_age_secs, clock_skew_secs):
    """`checkEntryTime(now, publishTime, maxAgeSecs, clockSkewSecs)` (§6): the age and skew of the tick of an open or
    a sale. Checks, in order:

    publishTime == 0                    PriceTooOld
    publishTime > now + clockSkewSecs   PriceFromFuture
    publishTime < now - entryMaxAgeSecs PriceTooOld

    A tick is accepted when `now - entryMaxAgeSecs <= publishTime <= now + clockSkewSecs`.
    """
    _uint(current_time, 256)
    _uint(publish_time, 256)
    _uint(max_age_secs, 8)
    _uint(clock_skew_secs, 8)
    if publish_time == 0:
        raise Revert("PriceTooOld")
    if publish_time > current_time + clock_skew_secs:
        raise Revert("PriceFromFuture")
    if publish_time < current_time - max_age_secs:
        raise Revert("PriceTooOld")


# --- The open gate (§6) ----------------------------------------------------------------------------------------------


def open_gate(total_owed, max_total_owed, open_max_profit, new_max_profit, free, max_exposure_bps):
    """`openGate(...)` (§6): whether a new bet may open. Checks, in order:

    totalOwed > maxTotalOwed                                              OpenBlockedTotalOwed
    openMaxProfit + newMaxProfit > floor(free x maxExposureBps / 10,000)  OpenBlockedExposure

    A rate of 0 switches the exposure test off. The new bet's maximum profit is given as a value (`maxProfit`).
    """
    for v in (total_owed, max_total_owed, open_max_profit, new_max_profit, free):
        _uint(v, 64)
    _uint(max_exposure_bps, 32)
    if total_owed > max_total_owed:
        raise Revert("OpenBlockedTotalOwed")
    if max_exposure_bps > 0 and open_max_profit + new_max_profit > free * max_exposure_bps // BPS:
        raise Revert("OpenBlockedExposure")


# --- The fees (§7.3) -------------------------------------------------------------------------------------------------


def fee(amount, fee_bps):
    """`fee(amount, rate)` (§7.3): `floor(amount x min(rate, 10,000) / 10,000)`, so a fee never exceeds its
    amount."""
    _uint(amount, 64)
    _uint(fee_bps, 16)
    return amount * min(fee_bps, BPS) // BPS


def winner_fee(profit_paid):
    """`winnerFee(profit)` (§7.3): 2% of the profit actually paid, rounded down."""
    return fee(profit_paid, WINNER_FEE_BPS)


def loser_fee(loss, free_before, pool_floor):
    """`loserFee(loss, freeBefore, poolFloor)` (§7.3): 3% of the loss while free money (measured with the bet's own
    stake still held) is at or above the pool floor, else 0."""
    _uint(loss, 64)
    _uint(free_before, 64)
    _uint(pool_floor, 64)
    return fee(loss, LOSER_FEE_BPS) if free_before >= pool_floor else 0


# --- The settlement split (§7.4) -------------------------------------------------------------------------------------


def settle_split(payout_amount, stake, free_before, total_owed, pool_floor):
    """`settleSplit(payout, stake, freeBefore, totalOwed, poolFloor)` (§7.4):

    own       = min(payout, stake)
    profit    = payout - own
    paid      = totalOwed == 0 ? min(profit, freeBefore) : 0
    owed      = profit - paid
    winnerFee = fee(paid, 200)
    loserFee  = freeBefore >= poolFloor ? fee(stake - own, 300) : 0
    """
    for v in (payout_amount, stake, free_before, total_owed, pool_floor):
        _uint(v, 64)
    own = min(payout_amount, stake)
    profit = payout_amount - own
    paid = min(profit, free_before) if total_owed == 0 else 0
    owed = profit - paid
    return SettleSplit(own, paid, owed, winner_fee(paid), loser_fee(stake - own, free_before, pool_floor))


def settle_to_user(split):
    """`toUser(split)` (§7.4): what the user receives now, `own + paid - winnerFee`."""
    return _checked_uint64(_checked_uint64(split.own + split.paid) - split.winnerFee)


def settle_out_of_pool(split):
    """`outOfPool(split)` (§7.4): what leaves `total`, `own + paid + loserFee`."""
    return _checked_uint64(_checked_uint64(split.own + split.paid) + split.loserFee)


# --- The early sale (§8) ---------------------------------------------------------------------------------------------


def check_sell_window(start_time, end_time, publish_time, min_delay_secs, cutoff_secs):
    """`checkSellWindow(startTime, endTime, publishTime, sellMinDelaySecs, sellCutoffSecs)` (§8): a sale's tick is
    accepted when `startTime + sellMinDelaySecs <= publishTime < endTime - sellCutoffSecs`, and every tick is refused
    when `endTime <= sellCutoffSecs`. Every refusal is SellWindowClosed."""
    for t in (start_time, end_time, publish_time):
        _uint(t, 256)
    _uint(min_delay_secs, 16)
    _uint(cutoff_secs, 16)
    too_early = publish_time < start_time + min_delay_secs
    too_late = end_time <= cutoff_secs or publish_time >= end_time - cutoff_secs
    if too_early or too_late:
        raise Revert("SellWindowClosed")


def check_sell(stake, g_now_bps, valuation, sell_amount, min_amount, max_sell_fee_bps, total_owed, free_before):
    """`checkSell(...)` (§8): bounds the relayer's quote. Checks, in order:

    valuation > payout(stake, gNow)                                     ValuationAboveCurrentPayout
    sellAmount > valuation                                              SellAmountExceedsValuation
    valuation - sellAmount > floor(valuation x maxSellFeeBps / 10,000)  SellFeeTooHigh
    sellAmount < minAmount                                              SellAmountBelowMin
    totalOwed != 0                                                      QueueNotEmpty
    valuation > freeBefore + stake                                      SellNotPayable

    `payout` itself comes first, so a payout that does not fit `uint64` is MathOverflow (§5). The fee cap is the
    document's formula; above a rate of 100% it cannot refuse anything, since the fee is at most the valuation, so the
    contract's clamp of the rate at 100% (`fee`, §7.3) gives the same answers.
    """
    for v in (stake, valuation, sell_amount, min_amount, total_owed, free_before):
        _uint(v, 64)
    _uint(g_now_bps, 16)
    _uint(max_sell_fee_bps, 16)
    if valuation > payout(stake, g_now_bps):
        raise Revert("ValuationAboveCurrentPayout")
    if sell_amount > valuation:
        raise Revert("SellAmountExceedsValuation")
    if valuation - sell_amount > valuation * max_sell_fee_bps // BPS:
        raise Revert("SellFeeTooHigh")
    if sell_amount < min_amount:
        raise Revert("SellAmountBelowMin")
    if total_owed != 0:
        raise Revert("QueueNotEmpty")
    if valuation > free_before + stake:
        raise Revert("SellNotPayable")


def sell_split(stake, valuation, sell_amount, free_before, pool_floor):
    """`sellSplit(stake, valuation, sellAmount, freeBefore, poolFloor)` (§8):

    winnerFee = fee(max(sellAmount - stake, 0), 200)
    toUser    = sellAmount - winnerFee
    sellFee   = valuation - sellAmount
    loserFee  = freeBefore >= poolFloor ? fee(max(stake - valuation, 0), 300) : 0

    The split needs `sellAmount <= valuation`, which `checkSell` guarantees. Settled by the code: otherwise the early
    sell fee is a negative `uint64`, which Solidity's checked arithmetic refuses with Panic(0x11).
    """
    for v in (stake, valuation, sell_amount, free_before, pool_floor):
        _uint(v, 64)
    w_fee = winner_fee(max(sell_amount - stake, 0))
    to_user = _checked_uint64(sell_amount - w_fee)
    sell_fee = _checked_uint64(valuation - sell_amount)
    l_fee = loser_fee(max(stake - valuation, 0), free_before, pool_floor)
    return SellSplit(to_user, sell_fee, w_fee, l_fee)


def sell_fees(split):
    """`fees(split)` (§8): what goes to `feesPending` on a sale, `sellFee + winnerFee + loserFee`."""
    return _checked_uint64(_checked_uint64(split.sellFee + split.winnerFee) + split.loserFee)


def sell_out_of_pool(split):
    """`outOfPool(split)` (§8): what leaves `total` on a sale, `toUser + fees`, which is `valuation + loserFee`."""
    return _checked_uint64(split.toUser + sell_fees(split))


# --- The IOU queue (§9) ----------------------------------------------------------------------------------------------


def repay_split(owed, free):
    """`repaySplit(owed, free)` (§9): one repayment from free money.

    amount = min(owed, free), winnerFee = fee(amount, 200), toUser = amount - winnerFee, remaining = owed - amount.
    """
    _uint(owed, 64)
    _uint(free, 64)
    amount = min(owed, free)
    w_fee = winner_fee(amount)
    return RepaySplit(amount, w_fee, amount - w_fee, owed - amount)


# --- Withdrawals (§10) -----------------------------------------------------------------------------------------------


def check_withdraw(purpose, amount, free, total_owed, pool_floor, open_max_profit, seed_recovered, decimals):
    """`checkWithdraw(purpose, amount, free, totalOwed, poolFloor, openMaxProfit, seedRecovered, decimals)` (§10).
    Checks, in order:

    amount == 0                                                     InvalidAmount
    totalOwed != 0                                                  OwedOutstanding
    free < amount + poolFloor                                       BelowPoolFloor
    free - amount - poolFloor < openMaxProfit                       OpenExposureNotCovered
    seed recovery only: seedRecovered + amount > 500 x 10^decimals  SeedRecoveryExceeded

    The cap `500 x 10^decimals` must fit `uint64` (MathOverflow); it is only worked out for seed recovery.
    """
    if purpose not in (SEED_RECOVERY, REWARDS) or isinstance(purpose, bool):
        raise ValueError("not a withdrawal purpose: %r" % (purpose,))
    for v in (amount, free, total_owed, pool_floor, open_max_profit, seed_recovered):
        _uint(v, 64)
    _uint(decimals, 8)
    if amount == 0:
        raise Revert("InvalidAmount")
    if total_owed != 0:
        raise Revert("OwedOutstanding")
    if free < amount + pool_floor:
        raise Revert("BelowPoolFloor")
    if free - amount - pool_floor < open_max_profit:
        raise Revert("OpenExposureNotCovered")
    if purpose == SEED_RECOVERY:
        cap = _to_uint64(SEED_RECOVERY_CAP_TOKENS * 10**decimals)
        if seed_recovered + amount > cap:
            raise Revert("SeedRecoveryExceeded")


# --- A market's settings and a bet's terms (§3) ----------------------------------------------------------------------


def _check_config_types(p):
    """Every field of `p` in its Solidity type (ValueError otherwise)."""
    _bool(p.enabled)
    _uint(p.entryMaxAgeSecs, 8)
    _uint(p.clockSkewSecs, 8)
    for v in (p.floorMinBps, p.floorMaxBps, p.capMinBps, p.capMaxBps, p.maxSellFeeBps, p.sellMinDelaySecs,
              p.sellCutoffSecs):
        _uint(v, 16)
    _uint(p.maxExposureBps, 32)
    for v in (p.minStake, p.maxStake, p.maxTotalOwed):
        _uint(v, 64)
    if len(p.durations) != 5:
        raise ValueError("a market holds exactly five duration rules")
    for rule in p.durations:
        _uint(rule.durationSecs, 16)
        _uint(rule.thetaMinE7, 32)
        _uint(rule.thetaMaxE7, 32)
        _bool(rule.enabled)


def _rule_valid(rules, i, leverage):
    """Whether duration rule `i` is valid at leverage L (§3.1): unused, with every field zero and `enabled` false, or
    `0 < thetaMinE7 <= thetaMaxE7`, `thetaMaxE7 x L < 10^7` and a duration no earlier rule has.

    Settled by the code: a zero duration is what marks a rule unused, so a rule with a zero duration and any other
    field set is invalid (rather than a used rule whose duration happens to be 0).
    """
    rule = rules[i]
    if rule.durationSecs == 0:
        return rule.thetaMinE7 == 0 and rule.thetaMaxE7 == 0 and not rule.enabled
    if rule.thetaMinE7 == 0 or rule.thetaMinE7 > rule.thetaMaxE7:
        return False
    if not theta_within_limit(rule.thetaMaxE7, leverage):
        return False
    return all(rules[j].durationSecs != rule.durationSecs for j in range(i))


def config_failures(p, leverage):
    """The numbers of the rules of §3.1 that `p` breaks at leverage L, in the table's order (rule 8 is a duration
    rule). Empty when `p` is valid."""
    _check_config_types(p)
    _uint(leverage, 16)
    failed = []
    if not leverage_allowed(leverage):
        failed.append(1)
    if not 0 < p.minStake <= p.maxStake:
        failed.append(2)
    if not BPS < p.floorMinBps <= p.floorMaxBps:
        failed.append(3)
    if not BPS < p.capMinBps <= p.capMaxBps <= MAX_LEVERAGE_CAP_BPS:
        failed.append(4)
    if not p.floorMaxBps <= p.capMaxBps:
        failed.append(5)
    if not p.capMaxBps - BPS < leverage * BPS:
        failed.append(6)
    if not p.maxSellFeeBps <= BPS:
        failed.append(7)
    if not all(_rule_valid(p.durations, i, leverage) for i in range(len(p.durations))):
        failed.append(8)
    if not p.entryMaxAgeSecs > 0:
        failed.append(9)
    if not 0 < p.maxExposureBps <= BPS:
        failed.append(10)
    if not p.clockSkewSecs <= MAX_CLOCK_SKEW_SECS:
        failed.append(11)
    return failed


def validate(p, leverage):
    """`validate(p, L)` (§3.1): a market's settings at its leverage. Every refusal is InvalidLeverageParams, so the
    order of the eleven rules does not change the answer.

    The sell window, the owed limit (`maxTotalOwed`) and `enabled` are left unbounded. Rule 6, for a cap at or below
    1x, follows `cap_reachable`; such a cap already breaks rule 4.
    """
    if config_failures(p, leverage):
        raise Revert("InvalidLeverageParams")


def validate_open(m, stake, duration_secs, theta_e7, floor_bps, cap_bps):
    """`validateOpen(market, stake, durationSecs, thetaE7, floorBps, capBps)` (§3.2): a bet's terms against the
    stored settings `m`. Checks, in order:

    minStake <= stake <= maxStake                        InvalidAmount
    durationSecs is the duration of an enabled rule      InvalidLeverageParams
    thetaMinE7 <= thetaE7 <= thetaMaxE7, from that rule  InvalidLeverageParams
    floorMinBps <= floorBps <= floorMaxBps               InvalidLeverageParams
    max(capMinBps, floorBps) <= capBps <= capMaxBps      InvalidLeverageParams

    Settled by the code, for stored settings `validate` never let through: the first enabled rule with the duration
    is the one used, and an enabled rule with a zero duration matches a zero duration. (`validate` allows neither
    two rules with one duration nor an enabled rule with a zero duration, so neither case arises in a market.)
    """
    _check_config_types(m)
    _uint(stake, 64)
    _uint(duration_secs, 16)
    _uint(theta_e7, 32)
    _uint(floor_bps, 16)
    _uint(cap_bps, 16)
    if stake < m.minStake or stake > m.maxStake:
        raise Revert("InvalidAmount")
    rule = next((r for r in m.durations if r.enabled and r.durationSecs == duration_secs), None)
    if rule is None:
        raise Revert("InvalidLeverageParams")
    if not rule.thetaMinE7 <= theta_e7 <= rule.thetaMaxE7:
        raise Revert("InvalidLeverageParams")
    if not m.floorMinBps <= floor_bps <= m.floorMaxBps:
        raise Revert("InvalidLeverageParams")
    if not max(m.capMinBps, floor_bps) <= cap_bps <= m.capMaxBps:
        raise Revert("InvalidLeverageParams")


# --- The worked examples (§12) ---------------------------------------------------------------------------------------

#: The reference bet of §12: BTC at exponent -8, entry $83,884, a $10 stake, 1000x, theta 2.627 bp, a 1.3x floor, a 4x
#: cap and a $500 pool floor. One basis point of the entry is `ONE_BP`.
ENTRY = 8_388_400_000_000
ONE_BP = 838_840_000
STAKE = 10_000_000
POOL_FLOOR = 500_000_000
USD = 100_000_000  # $1 at exponent -8
TOKEN = 1_000_000  # one whole 6-decimal token


def rule(duration_secs, theta_e7):
    """A duration rule whose theta range is +-25% around `theta_e7`, rounded down (§12, Example 8)."""
    return DurationRule(duration_secs, theta_e7 * 3 // 4, theta_e7 * 5 // 4, True)


def launch_config():
    """The example market at 1000x (§12, Example 8): stakes of $1 to $50, floors 1.1x to 1.5x, caps 1.5x to 4x, a 6%
    early-sell fee cap, a 5-second price age and clock skew, a sell window from the start to 2 seconds before the
    end, the open gate at 100%, and five theta ranges of +-25% around a line."""
    return ConfigParams(
        enabled=False, entryMaxAgeSecs=5, clockSkewSecs=5, floorMinBps=11_000, floorMaxBps=15_000, capMinBps=15_000,
        capMaxBps=40_000, maxSellFeeBps=600, sellMinDelaySecs=0, sellCutoffSecs=2, maxExposureBps=10_000,
        minStake=TOKEN, maxStake=50 * TOKEN, maxTotalOwed=UINT64_MAX,
        durations=(rule(60, 3_000), rule(120, 4_190), rule(180, 4_930), rule(240, 5_470), rule(300, 5_880)),
    )


def _raises(name, fn, *args):
    """Whether `fn(*args)` is refused with error `name`."""
    try:
        fn(*args)
    except Revert as e:
        return e.name == name
    return False


def check_worked_examples():
    """Checks the model against every number of the worked examples in docs/MATH.md §12 (AssertionError if one
    differs)."""
    t = 2_627
    # Example 1: the lines at 1000x.
    assert lines(ENTRY, CALL, 1000, t, 40_000) == (8_386_196_367_320, 8_413_565_200_000)
    assert lines(ENTRY, PUT, 1000, t, 40_000) == (8_390_603_632_680, 8_363_234_800_000)
    assert touched(8_386_196_367_320, 8_386_196_367_320, CALL) and not touched(8_386_196_367_321, 8_386_196_367_320,
                                                                                  CALL)
    assert touched(8_390_603_632_680, 8_390_603_632_680, PUT) and not touched(8_390_603_632_679, 8_390_603_632_680,
                                                                                 PUT)
    # Example 2: the payout curve at 1000x.
    for dollars, g in ((84, 20_013), (252, 40_000), (8, 13_000), (0, 10_000), (-8, 9_046)):
        assert g_bps(ENTRY, ENTRY + dollars * USD, CALL, 1000, 13_000, 40_000) == g
        assert payout(STAKE, g) == g * 1_000
    assert floor_div(-8 * USD * 1000 * BPS, ENTRY) == -954
    for floor, paid in ((11_000, 11), (14_000, 14), (15_000, 15)):
        assert payout(STAKE, g_bps(ENTRY, ENTRY + 8 * USD, CALL, 1000, floor, 40_000)) == paid * TOKEN
    assert g_bps(ENTRY, ENTRY - 8 * USD, PUT, 1000, 14_000, 40_000) == 14_000
    assert g_bps(ENTRY, ENTRY + 8 * USD, PUT, 1000, 14_000, 40_000) == 9_046
    assert max_profit(STAKE, 40_000) == 30_000_000
    # Example 3: settlement and its fees, with $10,000 free and nobody owed.
    free = 10_000 * TOKEN
    s = settle_split(20_013_000, STAKE, free, 0, POOL_FLOOR)
    assert s == (STAKE, 10_013_000, 0, 200_260, 0) and settle_to_user(s) == 19_812_740
    s = settle_split(40_000_000, STAKE, free, 0, POOL_FLOOR)
    assert s == (STAKE, 30_000_000, 0, 600_000, 0) and settle_to_user(s) == 39_400_000
    s = settle_split(9_046_000, STAKE, free, 0, POOL_FLOOR)
    assert s == (9_046_000, 0, 0, 0, 28_620) and settle_to_user(s) == 9_046_000
    assert settle_out_of_pool(s) == 9_074_620
    assert settle_split(9_046_000, STAKE, POOL_FLOOR - 1, 0, POOL_FLOOR).loserFee == 0
    s = settle_split(40_000_000, STAKE, 12 * TOKEN, 0, POOL_FLOOR)
    assert s == (STAKE, 12 * TOKEN, 18 * TOKEN, 240_000, 0) and settle_to_user(s) == 21_760_000
    assert settle_split(40_000_000, STAKE, 1_000 * TOKEN, 1, POOL_FLOOR)[:3] == (STAKE, 0, 30 * TOKEN)
    # Example 4: the 500x tier.
    liq, cap = lines(ENTRY, CALL, 500, 11_760, 25_000)
    assert (liq, cap) == (8_378_535_241_600, 8_413_565_200_000)
    assert ENTRY - liq == 9_864_758_400
    assert g_bps(ENTRY, liq, CALL, 500, 10_250, 25_000) == 4_120
    assert g_bps(ENTRY, cap, CALL, 500, 10_250, 25_000) == 25_000
    assert g_bps(ENTRY, cap - 1, CALL, 500, 10_250, 25_000) == 24_999
    # Example 5: the 100x tier.
    assert lines(ENTRY, CALL, 100, 17_640, 20_000) == (8_373_602_862_400, 8_472_284_000_000)
    assert lines(ENTRY, PUT, 100, 17_640, 20_000) == (8_403_197_137_600, 8_304_516_000_000)
    for side, (liq, cap) in ((CALL, (8_373_602_862_400, 8_472_284_000_000)),
                             (PUT, (8_403_197_137_600, 8_304_516_000_000))):
        assert g_bps(ENTRY, liq, side, 100, 10_050, 20_000) == 8_236
        assert g_bps(ENTRY, cap, side, 100, 10_050, 20_000) == 20_000
        assert g_bps(ENTRY, cap - 1 if side == CALL else cap + 1, side, 100, 10_050, 20_000) == 19_999
    for move, g in ((ONE_BP // 10, 10_050), (ONE_BP, 10_100), (99 * ONE_BP, 19_900), (100 * ONE_BP, 20_000),
                    (150 * ONE_BP, 20_000)):
        assert g_bps(ENTRY, ENTRY + move, CALL, 100, 10_050, 20_000) == g
    assert g_bps(ENTRY, ENTRY + ONE_BP, CALL, 500, 10_250, 25_000) == 10_500
    assert g_bps(ENTRY, ENTRY + 30 * ONE_BP, CALL, 500, 10_250, 25_000) == 25_000
    # Example 6: half a basis point.
    half = ONE_BP // 2
    assert half == 419_420_000
    for leverage, up, down in ((15, 10_007, 9_992), (1, 10_000, 9_999)):
        assert g_bps(ENTRY, ENTRY + half, CALL, leverage, BPS, 40_000) == up
        assert g_bps(ENTRY, ENTRY - half, CALL, leverage, BPS, 40_000) == down
    assert g_bps(ENTRY, ENTRY + half, CALL, 1, 10_050, 40_000) == 10_000
    for leverage in (1, 4, 15, 100, 500, 1000, 2000, 10_000):
        for bps in range(-3, 4):
            assert g_bps(ENTRY, ENTRY + bps * ONE_BP, CALL, leverage, BPS, 40_000) == max(0, BPS + bps * leverage)
    # Example 7: the widest line and the highest cap per leverage.
    for leverage, widest in ((1, 9_999_999), (4, 2_499_999), (15, 666_666), (100, 99_999), (500, 19_999),
                             (1000, 9_999), (2000, 4_999), (10_000, 999)):
        assert (E7 - 1) // leverage == widest
        assert theta_within_limit(widest, leverage) and not theta_within_limit(widest + 1, leverage)
    assert theta_within_limit(11_760, 500) and not theta_within_limit(11_760, 1000)
    for leverage, highest in ((1, 19_999), (2, 29_999), (3, 39_999), (4, 40_000)):
        assert cap_reachable(highest, leverage)
        assert highest == 40_000 or not cap_reachable(highest + 1, leverage)
    assert cap_line(ENTRY, PUT, 1, 19_999) == ONE_BP
    # Example 8: a market's settings.
    c = launch_config()
    validate(c, 1000)
    assert [r.thetaMinE7 for r in c.durations] == [2_250, 3_142, 3_697, 4_102, 4_410]
    assert [r.thetaMaxE7 for r in c.durations] == [3_750, 5_237, 6_162, 6_837, 7_350]
    validate_open(c, STAKE, 60, 2_250, 13_000, 40_000)
    validate_open(c, STAKE, 60, 3_750, 13_000, 40_000)
    assert _raises("InvalidLeverageParams", validate_open, c, STAKE, 60, 2_249, 13_000, 40_000)
    assert _raises("InvalidLeverageParams", validate_open, c, STAKE, 60, 3_751, 13_000, 40_000)
    assert _raises("InvalidLeverageParams", validate_open, c, STAKE, 60, 5_880, 13_000, 40_000)
    low_cap = c._replace(capMinBps=12_000)
    validate_open(low_cap, STAKE, 60, 3_000, 13_000, 13_000)
    assert _raises("InvalidLeverageParams", validate_open, low_cap, STAKE, 60, 3_000, 13_000, 12_999)
    # Example 9: the open gate and withdrawals ($1,500 free, a $500 floor, a 6-decimal token).
    open_gate(0, 0, 970 * TOKEN, 30 * TOKEN, 1_000 * TOKEN, 10_000)
    assert _raises("OpenBlockedExposure", open_gate, 0, 0, 970 * TOKEN, 30 * TOKEN + 1, 1_000 * TOKEN, 10_000)
    open_gate(0, 0, 0, 1, 1, 15_000)
    assert _raises("OpenBlockedExposure", open_gate, 0, 0, 0, 2, 1, 15_000)
    open_gate(100, 100, 0, 0, 0, 10_000)
    assert _raises("OpenBlockedTotalOwed", open_gate, 101, 100, 0, 0, 0, 10_000)
    f, fl = 1_500 * TOKEN, 500 * TOKEN
    check_withdraw(REWARDS, 1_000 * TOKEN, f, 0, fl, 0, 0, 6)
    assert _raises("BelowPoolFloor", check_withdraw, REWARDS, 1_000 * TOKEN + 1, f, 0, fl, 0, 0, 6)
    check_withdraw(REWARDS, 700 * TOKEN, f, 0, fl, 300 * TOKEN, 0, 6)
    assert _raises("OpenExposureNotCovered", check_withdraw, REWARDS, 700 * TOKEN + 1, f, 0, fl, 300 * TOKEN, 0, 6)
    check_withdraw(SEED_RECOVERY, 500 * TOKEN, f, 0, fl, 0, 0, 6)
    check_withdraw(SEED_RECOVERY, 200 * TOKEN, f, 0, fl, 0, 300 * TOKEN, 6)
    assert _raises("SeedRecoveryExceeded", check_withdraw, SEED_RECOVERY, 200 * TOKEN + 1, f, 0, fl, 0, 300 * TOKEN, 6)
    check_withdraw(SEED_RECOVERY, 400 * TOKEN, 900 * TOKEN, 0, fl, 0, 0, 6)
    assert _raises("BelowPoolFloor", check_withdraw, SEED_RECOVERY, 400 * TOKEN + 1, 900 * TOKEN, 0, fl, 0, 0, 6)
    check_withdraw(SEED_RECOVERY, 500_000_000_000, 10**12, 0, 0, 0, 0, 9)
    assert _raises("MathOverflow", check_withdraw, SEED_RECOVERY, 1, 10**12, 0, 0, 0, 0, 17)
    # Example 10: early sales.
    assert payout(STAKE, 13_000) == 13_000_000
    assert _raises("ValuationAboveCurrentPayout", check_sell, STAKE, 13_000, 13_000_001, 0, 0, 600, 0, 10**12)
    check_sell(STAKE, 13_000, 12_500_000, 11_750_000, 0, 600, 0, 10**12)
    assert _raises("SellFeeTooHigh", check_sell, STAKE, 13_000, 12_500_000, 11_749_999, 0, 600, 0, 10**12)
    check_sell(STAKE, 13_000, 12 * TOKEN, 12 * TOKEN, 0, 600, 0, 2 * TOKEN)
    assert _raises("SellNotPayable", check_sell, STAKE, 13_000, 12 * TOKEN, 12 * TOKEN, 0, 600, 0, 2 * TOKEN - 1)
    for valuation, amount, sell_fee, w_fee, l_fee, to_user, out in (
            (12_500_000, 12_000_000, 500_000, 40_000, 0, 11_960_000, 12_500_000),
            (9_000_000, 8_600_000, 400_000, 0, 30_000, 8_600_000, 9_030_000),
            (40_000_000, 40_000_000, 0, 600_000, 0, 39_400_000, 40_000_000),
            (10_200_000, 9_900_000, 300_000, 0, 0, 9_900_000, 10_200_000)):
        s = sell_split(STAKE, valuation, amount, POOL_FLOOR, POOL_FLOOR)
        assert s == (to_user, sell_fee, w_fee, l_fee) and sell_out_of_pool(s) == out
    assert sell_split(STAKE, 9_000_000, 8_600_000, POOL_FLOOR - 1, POOL_FLOOR).loserFee == 0
    # Example 11: the IOU queue in a small pool ($20 free, below the $500 floor).
    assert loser_fee(STAKE, 20 * TOKEN, POOL_FLOOR) == 0
    s = settle_split(40 * TOKEN, STAKE, 30 * TOKEN, 0, POOL_FLOOR)
    assert s == (STAKE, 30 * TOKEN, 0, 600_000, 0) and settle_to_user(s) == 39_400_000
    assert settle_out_of_pool(s) == 40 * TOKEN
    s = settle_split(40 * TOKEN, STAKE, 0, 0, POOL_FLOOR)
    assert s == (STAKE, 0, 30 * TOKEN, 0, 0) and settle_to_user(s) == STAKE
    assert repay_split(30 * TOKEN, 10 * TOKEN) == (10 * TOKEN, 200_000, 9_800_000, 20 * TOKEN)
    # Example 12: times.
    now = 10_000
    for publish in (now - 5, now + 5):
        check_entry_time(now, publish, 5, 5)
    assert _raises("PriceTooOld", check_entry_time, now, now - 6, 5, 5)
    assert _raises("PriceFromFuture", check_entry_time, now, now + 6, 5, 5)
    assert _raises("PriceTooOld", check_entry_time, now, 0, 5, 5)
    for publish in (1_000, 1_057):
        check_sell_window(1_000, 1_060, publish, 0, 2)
    for publish in (999, 1_058, 1_060):
        assert _raises("SellWindowClosed", check_sell_window, 1_000, 1_060, publish, 0, 2)
    assert _raises("SellWindowClosed", check_sell_window, 1_000, 1_060, 1_009, 10, 2)
    check_sell_window(1_000, 1_060, 1_010, 10, 2)
    liq = ENTRY - ONE_BP
    for publish in (1_000, 1_060):
        check_liquidation(1, 1_000, 1_060, liq, CALL, liq, publish, 2_000, 5)
    for publish in (999, 1_061):
        assert _raises("InvalidLiquidationWindow", check_liquidation, 1, 1_000, 1_060, liq, CALL, liq, publish, 2_000,
                       5)
    check_liquidation(1, 1_000, 1_060, liq, CALL, liq, 1_015, 1_010, 5)
    assert _raises("PriceFromFuture", check_liquidation, 1, 1_000, 1_060, liq, CALL, liq, 1_016, 1_010, 5)
    # The fee examples of §7.3.
    assert winner_fee(49) == 0 and winner_fee(50) == 1
    assert fee(1_000, 20_000) == 1_000


if __name__ == "__main__":
    check_worked_examples()
    print("The model reproduces every worked example of docs/MATH.md section 12.")
