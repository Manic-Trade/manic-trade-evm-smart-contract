# Manic Flash Option: the maths

This document specifies every number the contract computes for a bet: its lines, its payout, its fees, how the pool's
money moves when the bet ends, and the rules that refuse a bet, a sale or a withdrawal. It is written from the code:

- `src/libraries/LeverageMath.sol`: the maths, as pure functions;
- `src/libraries/ConfigLib.sol`: the validity rules for a market's settings and for a bet's terms;
- `src/types/MathTypes.sol` and `src/types/StorageTypes.sol`: the fields;
- `src/modules/TradingModule.sol`, `src/modules/SettlementModule.sol`, `src/modules/PoolModule.sol` and
  `src/base/FlashOptionBase.sol`: where the results are used.

Where this document and the code differ, the code is right. Each worked example (§12) names the unit test file that
checks its values.

A second implementation of this document, in Python, is in [`model/`](../model/README.md). It recomputes every worked
example (`python3 model/flash_option_math.py`), and `test/model/ModelVectors.t.sol` holds the contract to it on 20,661
inputs: the edges of every rule, and seeded random inputs over each function's whole domain. `model/scenarios.py`
derives every number of the scenario tests from it, step by step.

## 1. Units and notation

| Quantity | Type | Unit | Example |
|---|---|---|---|
| Price | `int64` | `price × 10^priceExponent` dollars | BTC (exponent −8): $83,884 is `8,388,400,000,000` |
| Token amount | `uint64` | base units; the token has 6 to 9 decimals | USDG (6 decimals): $10 is `10,000,000` |
| g, floor, cap, rates | `uint16`, `uint32` | basis points (bps): `10,000` = 1x = 100% | `13,000` is 1.3x; `200` is 2% |
| θ | `uint32 thetaE7` | `θ × 10^7`, so 1 bp of the price is `1,000` | 2.627 bp is `2,627` |
| Leverage L | `uint16` | a whole number from 1 to 10,000 | `1000` is 1000x |
| Time | `uint48` | whole seconds; `now` is `block.timestamp` | a 60-second bet |

- A market's `priceExponent` is −18 to 0, fixed when the market is created.
- **g** is the payout multiple: what a bet pays, in bps of its stake. **θ** is the liquidation distance: how far the
  price may move against the bet, as a share of the entry price.
- `floor(x)` is the largest integer at or below `x`. The formulas in this document are exact arithmetic; wherever the
  code divides, the formula says how it rounds.
- A long is a `Call`: it wins when the price rises. A short is a `Put`: it wins when the price falls.
- The pool's books (`PoolState`): `total` (the held stakes plus free money), `lockedMargin` (the open bets' stakes),
  `openMaxProfit` (the sum of the open bets' maximum profit), `totalOwed` (the sum of the IOUs), `poolFloor` and
  `feesPending`.
- **Free money** is `free = total − lockedMargin`. It is computed each time and never stored. `freeBefore` is free money
  measured while the bet being ended still holds its stake.

## 2. A bet

A bet is a position on one market. A market is one price feed at one leverage (ADR 0008): BTC can have a 1000x, a 500x
and a 100x market, each with its own settings. A bet keeps its market's leverage for its whole life.

| Field | Set by | Meaning |
|---|---|---|
| `marketId`, `leverage` | the user, signed | the feed and the leverage tier; together they pick the market |
| `side` | the user, signed | `Call` (long) or `Put` (short) |
| `stake` | the user, signed | the margin, pulled from the user at open (EIP-3009, exactly this amount) |
| `durationSecs` | the user, signed | one of the market's enabled durations |
| `notBefore`, `deadline` | the user, signed | the entry tick is at or after `notBefore`; the open lands by `deadline` |
| `entryPrice`, `entryPublishTime` | the relayer, from the price tick | the entry tick |
| `thetaE7` | the relayer | θ for the duration, inside that duration's rule |
| `floorBps`, `capBps` | the relayer | the least a winning bet pays and the most any bet pays, in bps of the stake |
| `liqPrice`, `capPrice`, max profit | the contract | computed at open (§4, §5) |

- **Commit first, price after.** The user signs an EIP-712 `OpenOrder` before the price is known. At the price tick
  the opener relayer adds the `OpenTerms`, and the contract checks each term against the market's bounds (§3). The
  leverage is signed, so no relayer can open the bet at another tier.
- **θ depends on the duration.** A market holds up to five duration rules. Each is a duration with a θ range
  (`thetaMinE7` to `thetaMaxE7`), and the relayer picks θ inside the range of the order's duration. Longer bets get
  wider lines. The floor and the cap must fall inside the market's ranges too.
- **The bet's clock** starts at the entry tick: `startTime = entryPublishTime` and `endTime = startTime +
  durationSecs`. A slow transaction never lengthens a bet.
- **A sale** works the same way: the user signs a `SellOrder` (`positionId`, `minAmount`, `notBefore`, `deadline`),
  and the relayer adds the `SellTerms` (`price`, `publishTime`, `valuation`, `sellAmount`). **Settlement and
  liquidation** apply one price tick (`price`, `publishTime`), sent by the settler relayer, to a batch of 1 to 100 bets
  of one market. The contract does not read a price feed itself: it checks each tick against the rules below.
- **Stored:** the `Position` keeps the user, market, side, status, times, stake, entry price, liquidation line, floor,
  cap and leverage. θ and the cap price are only in the `PositionOpened` event; `getPosition` recomputes the cap price.

## 3. Validity rules

### 3.1 A market's settings

`ConfigLib.validate(p, L)` runs in `createMarket` and `setConfig`, before anything is stored. Every refusal is
`InvalidLeverageParams`.

| # | Rule | Why |
|---|---|---|
| 1 | `1 ≤ L ≤ 10,000` | the leverage range |
| 2 | `0 < minStake ≤ maxStake` | a usable stake range |
| 3 | `10,000 < floorMinBps ≤ floorMaxBps` | a floor pays back more than the stake |
| 4 | `10,000 < capMinBps ≤ capMaxBps ≤ 40,000` | a cap above 1x and at most 4x |
| 5 | `floorMaxBps ≤ capMaxBps` | every floor fits under a cap |
| 6 | `capMaxBps − 10,000 < L × 10,000` | a short can reach the highest cap (below) |
| 7 | `maxSellFeeBps ≤ 10,000` | an early-sell fee never exceeds the valuation |
| 8 | each of the five duration rules is valid (below) | the line limit (§4) |
| 9 | `entryMaxAgeSecs > 0` | a market accepting no price age could open nothing |
| 10 | `0 < maxExposureBps ≤ 10,000` | the open gate is on, at 100% of free money at most (ADR 0009) |
| 11 | `clockSkewSecs ≤ 30` | no bet settles more than 30 seconds early (ADR 0009) |

- **A duration rule** is either unused, with every field zero and `enabled` false, or it has `0 < thetaMinE7 ≤
  thetaMaxE7`, `thetaMaxE7 × L < 10^7`, and a duration no earlier rule has. A disabled rule is checked too, so it can be
  switched on later safely.
- **The widest line** a leverage allows is therefore `floor((10^7 − 1) / L)`: 9,999 (9.999 bp) at 1000x, 19,999 at
  500x and 99,999 at 100x.
- **Rule 6 keeps a short's cap line above 0.** A short gains L times the fall in price, and a price cannot fall below
  0, so a short gains less than L times its stake. The rule only binds below 4x: from L = 4 up, `capMaxBps − 10,000 ≤
  30,000 < L × 10,000`. The highest caps below that are 1.9999x at 1x, 2.9999x at 2x and 3.9999x at 3x.
- **Left unbounded:** the sell window (`sellMinDelaySecs`, `sellCutoffSecs`), the owed limit (`maxTotalOwed`) and
  `enabled`.
- `createMarket` also requires a non-zero `marketId`, a new (feed, leverage) pair (`MarketExists`), `−18 ≤
  priceExponent ≤ 0`, and `enabled = false`. A market's leverage and exponent never change after it is created.

### 3.2 A bet's terms

`ConfigLib.validateOpen` checks a new bet against the stored settings, in this order:

| # | Rule | Error |
|---|---|---|
| 1 | `minStake ≤ stake ≤ maxStake` | `InvalidAmount` |
| 2 | `durationSecs` is the duration of an enabled rule | `InvalidLeverageParams` |
| 3 | `thetaMinE7 ≤ thetaE7 ≤ thetaMaxE7`, from that rule | `InvalidLeverageParams` |
| 4 | `floorMinBps ≤ floorBps ≤ floorMaxBps` | `InvalidLeverageParams` |
| 5 | `max(capMinBps, floorBps) ≤ capBps ≤ capMaxBps` | `InvalidLeverageParams` |

Rule 5 keeps the cap at or above the floor, so a winning bet can always pay its floor. An unused rule never matches,
not even a zero duration. `lines` then checks the leverage, θ and the cap again on their own (§4).

### 3.3 Constants

| Constant | Value | Defined in |
|---|---|---|
| `MIN_LEVERAGE`, `MAX_LEVERAGE` | 1 and 10,000 | `LeverageMath` |
| `BPS` and `E7` (the scale of θ) | 10,000 and 10,000,000 | `LeverageMath` |
| `MAX_LEVERAGE_CAP_BPS` | 40,000 (4x) | `LeverageMath` |
| `WINNER_FEE_BPS` | 200 (2%) | `LeverageMath` |
| `LOSER_FEE_BPS` | 300 (3%) | `LeverageMath` |
| `SEED_RECOVERY_CAP_TOKENS` | 500 whole tokens | `LeverageMath` |
| `MAX_CLOCK_SKEW_SECS` | 30 seconds | `ConfigLib` |
| the lowest pool floor | 500 whole tokens | `FlashOptionBase` |
| the token's decimals | 6 to 9 | `ManicFlashOption` |
| ids per `liquidate`, `settle` or `refundExpired` | 1 to 100 | `SettlementModule` |
| IOUs per `repay` | 1 to 50 | `SettlementModule` |
| the refund delay | 0 (off) or at least 1 hour | `FlashOptionBase` |
| the breaker's window | 60 to 86,400 seconds | `FlashOptionBase` |

## 4. The lines

```
liqOffset = floor(entry × thetaE7 / 10^7)
capOffset = floor(entry × (capBps − 10,000) / (L × 10,000))

Call (long):   liqPrice = entry − liqOffset     capPrice = entry + capOffset
Put (short):   liqPrice = entry + liqOffset     capPrice = entry − capOffset

touched(price) = price ≤ liqPrice  (Call)          price ≥ liqPrice  (Put)          equality counts
```

- **The liquidation line** sits θ away from the entry, whatever the leverage. A long loses when the price falls, so its
  line is below the entry; a short's is above.
- **The cap line** is where the payout reaches the cap. The payout multiple is about `1 + L × move` (§5), so it reaches
  the cap after a move of `(cap − 1x) / L`. At 1000x a 4x cap is a 0.3% move, at 500x a 2.5x cap is the same 0.3%, and
  at 100x a 2x cap is 1%.
- **Rounding.** Both offsets have positive operands, so each division rounds down, and each line lands at most one price
  unit nearer the entry than the exact value. A nearer liquidation line is touched no later, which favours the pool.
  The cap line is only reported (`PositionOpened`, `getPosition`): the payout clamps g at `capBps` by itself (§5), so
  the cap line's rounding moves no money. When the division is not exact, g at the reported cap line can be just below
  the cap (1 bp at BTC's price scale), and it reaches the cap one price unit further.
- **Checks**, in this order: `entry > 0` (`InvalidPrice`); then `1 ≤ L ≤ 10,000`, `thetaE7 > 0`, `thetaE7 × L < 10^7`,
  `10,000 < capBps ≤ 40,000` and `capBps − 10,000 < L × 10,000` (each `InvalidLeverageParams`). A line that does not fit
  `int64` reverts `MathOverflow`. `capLine` computes the cap line alone, with the same checks except θ.

**What the line means for money.** Touching the line ends the bet, and it pays nothing (§7.1). Just inside the line the
bet is still worth about `g = 10,000 − thetaE7 × L / 1,000` bps of its stake: 0.7373x at 1000x with θ = 2.627 bp. The
limit `thetaE7 × L < 10^7` puts the line before a move of `1 / L`, where the payout curve reaches 0.

## 5. The payout curve

```
move = price − entry                              (Call)
move = entry − price                              (Put)
R    = floor(move × L × 10,000 / entry)           rounded toward minus infinity
g    = 10,000 + R
if R > 0 and g < floorBps:  g = floorBps          a win pays at least the floor
if g > capBps:              g = capBps            never more than the cap
if g < 0:                   g = 0                 never below 0

payout    = floor(stake × g / 10,000)
maxProfit = floor(stake × (capBps − 10,000) / 10,000)
```

- `move` is positive when the bet is winning, on either side.
- `R` is L times the move in basis points. Each basis point of move is worth L bps of the stake: 10% of the stake at
  1000x, 5% at 500x and 1% at 100x.
- **The floor** applies only to a win (`R > 0`). A move that rounds to `R = 0` is not a win, and the bet pays back
  exactly its stake.
- **The clamps** run in this order: floor, cap, 0. `validateOpen` keeps `floorBps ≤ capBps`, so they never conflict.
- **g below 0** can only happen past the liquidation line. Such a bet is liquidated instead: `settle` and `sell`
  refuse a price that touches the line (`LiquidateInstead`).
- **The maximum profit** is the most a bet can win above its stake. `open` adds it to `openMaxProfit`, and every
  ending subtracts the same value, recomputed from the stored stake and cap. It needs `capBps ≥ 10,000`
  (`InvalidLeverageParams`).
- **A payout never exceeds `stake + maxProfit`:** `floor(stake × g / 10,000) ≤ floor(stake × capBps / 10,000) =
  stake + maxProfit`, with equality at the cap. Rounding the maximum profit down never understates what a bet can take.
- **Checks**, in this order: `entry > 0` and `price > 0` (`InvalidPrice`), then `1 ≤ L ≤ 10,000`
  (`InvalidLeverageParams`). The products are taken in 256 bits, and the payout must fit `uint64` (`MathOverflow`).

## 6. Checks at open

`open` (the opener relayer) runs these checks in order. It then writes the bet and the books, emits `PositionOpened`,
and pulls exactly the stake from the user (`TransferAmountMismatch` otherwise).

1. The brakes and the order: not halted (`Halted`); `now ≤ deadline` (`OrderExpired`); the market (feed, leverage)
   exists, is enabled and is not paused (`UnknownMarket`, `LeverageDisabled`, `LeveragePaused`); the breaker has not
   tripped (`BreakerTripped`); `positionId` is new and not zero (`PositionIdUsed`); the user signed the order.
2. The bet's terms fit the market (§3.2).
3. The entry tick is fresh (below), and `entryPublishTime ≥ notBefore` (`PriceBeforeOrder`).
4. The lines can be drawn (§4).
5. The open gate lets the bet in (below).

**The entry tick's age and clock skew** (`checkEntryTime`, also used by `sell`):

```
publishTime == 0                                 → PriceTooOld
publishTime > now + clockSkewSecs                → PriceFromFuture
publishTime < now − entryMaxAgeSecs              → PriceTooOld
```

A tick is accepted when `now − entryMaxAgeSecs ≤ publishTime ≤ now + clockSkewSecs`. A tick a little ahead of the
chain's clock counts as age 0. The comparisons never add or subtract past zero, so they cannot overflow.

**The open gate** (`openGate`):

```
totalOwed > maxTotalOwed                                                    → OpenBlockedTotalOwed
openMaxProfit + maxProfit(stake, capBps) > floor(free × maxExposureBps / 10,000)
                                                                            → OpenBlockedExposure
```

- `free` is measured before the new stake arrives. The open adds the stake to both `total` and `lockedMargin`, so free
  money does not change, and a stake never pays anyone else's winnings.
- A rate of 0 would switch the exposure test off, but `validate` keeps every market's rate at 1 to 10,000. So after
  every open, `openMaxProfit ≤ free`: free money covers the most every open bet can win (§9).

## 7. Ending a bet

A bet ends by liquidation, by settlement at expiry, by an early sale (§8) or by the safety refund. Each ending releases
the bet's hold on the books: `lockedMargin −= stake`, `openMaxProfit −= maxProfit(stake, capBps)` and
`openPositions −= 1`. `total` does not change there; each ending then takes out of `total` what leaves the pool. A
winner the pool cannot pay in full stays `Owed` until its IOU is repaid (§9).

### 7.1 Liquidation: the line touched

`liquidate(marketId, L, price, publishTime, ids)` (the settler relayer) applies one tick to a batch of 1 to 100 bets of
one market. An id that was never opened reverts (`UnknownPosition`), a bet of another market reverts
(`ConfigMismatch`), and a bet no longer open is skipped. For each open bet, in this order:

```
price ≤ 0                                              → InvalidPrice
publishTime < startTime  or  publishTime > endTime     → InvalidLiquidationWindow
publishTime > now + clockSkewSecs                      → PriceFromFuture
not touched(price)                                     → LiquidationPriceNotReached
```

Both ends of the bet's life count, and there is no age limit: an old tick inside the bet's life still liquidates it.
The user receives nothing. The pool keeps the stake, less the loser fee:

```
loserFee = freeBefore ≥ poolFloor ? floor(stake × 300 / 10,000) : 0
total   −= loserFee                                    (the fee goes to feesPending)
```

### 7.2 Settlement at expiry

`settle(marketId, L, price, publishTime, ids)` (the settler relayer) applies one tick, the close of one expiry second,
to a batch of 1 to 100 bets of one market:

```
price ≤ 0                                              → InvalidPrice
publishTime > now + clockSkewSecs                      → NotExpired
for each open bet:
  startTime + durationSecs ≠ publishTime               → InvalidPriceTimestamp
  touched(price)                                       → LiquidateInstead

g      = gBps(entryPrice, price, side, L, floorBps, capBps)          (§5)
payout = floor(stake × g / 10,000)
```

- The tick must be exactly the bet's expiry second. The clock skew lets a batch settle up to `clockSkewSecs` (at most
  30) seconds before that second on the chain's clock. Old ticks are accepted.
- The payout is split as in §7.4. The bets of a batch are settled in order, so each one's `freeBefore` already
  reflects the bets before it.

### 7.3 Fees

```
fee(amount, rate) = floor(amount × min(rate, 10,000) / 10,000)

winnerFee = fee(profit paid now, 200)                          2% of the profit actually paid
loserFee  = freeBefore ≥ poolFloor ? fee(loss, 300) : 0        3% of the loss
```

- **The winner fee** is taken at settlement (on `paid`), on a profitable sale (on `sellAmount − stake`) and on each
  repayment of an IOU (on the amount repaid). Profit that is only owed pays no fee until it is repaid.
- **Fees round down:** 2% of 49 base units is 0, of 50 it is 1. A rate above 100% counts as 100%, so a fee never
  exceeds its amount.
- **The loss** is `stake − payout` at settlement, the whole stake at liquidation, and `stake − valuation` at a sale.
- **The loser fee** is taken only while free money, measured with the bet's own stake still held, is at or above the
  pool floor.
- **Who bears them.** The winner fee comes out of what the user receives. The loser fee does not: it comes out of the
  loss the pool keeps.
- A bet pays at most one of the two, since a win has no loss and a loss has no profit. A sale can add the early-sell
  fee (§8). Every fee goes to `feesPending`, and `sweepFees` sends it to the fee recipient.

### 7.4 The settlement split

`settleSplit(payout, stake, freeBefore, totalOwed, poolFloor)`:

```
own       = min(payout, stake)                                 the user's own stake back
profit    = payout − own
paid      = totalOwed == 0 ? min(profit, freeBefore) : 0        profit paid now, from free money only
owed      = profit − paid                                      becomes an IOU (§9)
winnerFee = fee(paid, 200)
loserFee  = freeBefore ≥ poolFloor ? fee(stake − own, 300) : 0
toUser    = own + paid − winnerFee                             sent to the user now
outOfPool = own + paid + loserFee                              taken out of total
```

- The user's own stake comes back first: all of it on a win, what is left of it on a loss.
- Profit is paid only from free money. While anyone is owed (`totalOwed > 0`), a new winner's whole profit joins the
  queue, so nobody jumps it.
- Money is conserved: `own + paid + owed = payout`, and `toUser + winnerFee + loserFee = outOfPool`.
- **The books:** release the hold, then `total −= outOfPool` and `feesPending += winnerFee + loserFee`. With
  `owed > 0` the bet becomes an IOU (§9); otherwise it closes.

### 7.5 The safety refund

`refundExpired(ids)` (anyone) returns the whole stake of a bet still open `refundDelaySecs` after its expiry. It needs
`now ≥ startTime + durationSecs + refundDelaySecs` (`RefundTooEarly`), and works only while the delay is not 0
(`RefundDisabled`). No fee is taken: the hold is released and `total −= stake`, so free money does not change.

### 7.6 What the payout circuit breaker counts

Each call counts the profit users took out of the pool and the losses they left in it, before fees. `settle` counts
`paid` as profit and `stake − own` as loss; `liquidate` counts the stake as loss; `sell` counts `sellAmount − stake` as
profit, or `stake − sellAmount` as loss; `repay` counts the amount repaid as profit; the refund counts nothing.

The counters run in fixed windows of `windowSecs`: once `now ≥ windowStart + windowSecs`, both restart at 0 and the
window starts at `now`. With a limit `maxNetProfit > 0`, the breaker trips when `profitOut > lossIn + maxNetProfit`. A
trip stops `open` and `sell` until the operator resets it (ADR 0003).

## 8. Early sale

`sell(order, signature, terms)` (the opener relayer) runs these checks in order. First the brakes and the order: not
halted, `now ≤ deadline`, the bet was opened (`UnknownPosition`), its market is enabled and not paused, the breaker has
not tripped, the bet is still open (`PositionNotOpen`), and the bet's user signed the order. Then the sell window
(below) and `now < endTime`; the tick's age and skew, as at open (§6), and `publishTime ≥ notBefore`; `price > 0`
(`InvalidPrice`) and a price that does not touch the line (`LiquidateInstead`); and last the amounts (`checkSell`).

**The sell window** (`checkSellWindow`). A sale's tick is accepted when

```
startTime + sellMinDelaySecs ≤ publishTime < endTime − sellCutoffSecs
```

and every tick is refused when `endTime ≤ sellCutoffSecs`. Every refusal is `SellWindowClosed`. The sale must also land
before the bet ends (`now < endTime`), because a tick inside the window may still be up to `entryMaxAgeSecs` old.

**The valuation.** The relayer quotes `valuation`, what the bet is worth now, and `sellAmount`, what the user gets
before the winner fee. The contract does not price the bet itself. It bounds the quote, in this order:

```
gNow = gBps(entryPrice, price, side, L, floorBps, capBps)

valuation > payout(stake, gNow)                                        → ValuationAboveCurrentPayout
sellAmount > valuation                                                 → SellAmountExceedsValuation
valuation − sellAmount > floor(valuation × maxSellFeeBps / 10,000)     → SellFeeTooHigh
sellAmount < minAmount                                                 → SellAmountBelowMin
totalOwed ≠ 0                                                          → QueueNotEmpty
valuation > freeBefore + stake                                         → SellNotPayable
```

- A sale never pays more than a settlement at the same price would.
- **The early-sell fee** is `valuation − sellAmount`. The contract caps it at `maxSellFeeBps` of the valuation, rounded
  down. `validate` keeps the cap at most 100%, and the tests' example markets use 600 (6%). The contract does not
  compute the fee from the time left: the backend quotes it, and the contract only enforces the cap.
- The sale must be payable in full right now: nobody owed, and the valuation within free money plus the bet's own
  stake. A sale is never paid in part.

**The sale split** (`sellSplit`):

```
winnerFee = fee(max(sellAmount − stake, 0), 200)
toUser    = sellAmount − winnerFee
sellFee   = valuation − sellAmount
loserFee  = freeBefore ≥ poolFloor ? fee(max(stake − valuation, 0), 300) : 0
fees      = sellFee + winnerFee + loserFee                     to feesPending
outOfPool = toUser + fees = valuation + loserFee               taken out of total
```

The winner fee is 2% of the profit the user takes; the loser fee is 3% of the loss in the valuation. When `valuation >
stake > sellAmount`, neither applies, and only the early-sell fee is taken. The bet then closes.

## 9. When the pool can't pay: the IOU queue

**When an IOU forms.** At settlement, when `paid < profit`: because free money is short, or because someone is
already owed. The bet becomes `Owed`, with `owed = profit − paid` and the next queue number (`nextQueueSeq`), and
`totalOwed += owed`. The user has already received `own + paid − winnerFee`.

**While anyone is owed:** every new winner's whole profit joins the queue; sales are refused (`QueueNotEmpty`);
withdrawals are refused (`OwedOutstanding`); and opens are refused once `totalOwed > maxTotalOwed`.

**Repayment.** `repay(maxCount)` (anyone; 1 to 50 IOUs per call; not while halted) pays the queue from its head, oldest
first:

```
free      = total − lockedMargin                   never the stakes of open bets
amount    = min(owed, free)
winnerFee = fee(amount, 200)
toUser    = amount − winnerFee
remaining = owed − amount
```

The books: `total −= amount`, `totalOwed −= amount` and `feesPending += winnerFee`. When `remaining = 0`, the IOU leaves
the queue and the bet closes. A call stops when free money is 0, after an IOU it could only pay in part (which stays at
the head), or after `maxCount` IOUs.

**Why the queue stays empty under these settings.** With the open gate at 1 to 10,000 bps, as `validate` requires:

- after every open, `openMaxProfit ≤ free` (§6);
- a winner's profit is at most its own maximum profit, so it is paid in full, and free money falls by no more than
  `openMaxProfit` does;
- a loss, a liquidation, a refund or a sale valued at or below the stake never lowers free money, and a sale valued
  above the stake takes at most `valuation − stake`, which is at most the bet's maximum profit;
- a withdrawal must leave `free − amount ≥ poolFloor + openMaxProfit` (§10).

So `openMaxProfit ≤ free` holds after every action, and no IOU forms. The queue is the rule for a pool that cannot pay
its winners; Example 11 (§12) shows it at work.

## 10. Withdrawals and the books

`withdraw(purpose, amount)` (the admin) takes money out of the pool for one of two purposes: seed recovery, to the fee
recipient, or rewards, to the rewards recipient. The checks, in this order:

```
amount == 0                                                   → InvalidAmount
totalOwed ≠ 0                                                 → OwedOutstanding
free < amount + poolFloor                                     → BelowPoolFloor
free − amount − poolFloor < openMaxProfit                     → OpenExposureNotCovered
seed recovery only: seedRecovered + amount > 500 × 10^decimals → SeedRecoveryExceeded
```

- At most `free − poolFloor − openMaxProfit` can leave, and nothing while anyone is owed.
- Seed recovery takes at most 500 whole tokens in total, ever: `seedRecovered` only grows. Rewards have no cap.
- Open stakes are never free money, so they can never be withdrawn. `500 × 10^decimals` must fit `uint64`
  (`MathOverflow`); with 6 to 9 decimals it always does.
- The pool floor is at least 500 whole tokens (`setPoolFloor` refuses less with `InvalidLeverageParams`).
- Anyone may add money with `fund(amount)`: `total += amount`, provided exactly that amount arrives.

**The books, action by action.** In every row, what the user and the fee recipient get adds up to what leaves `total`.

| Action | `total` | `lockedMargin` | `openMaxProfit` | `totalOwed` | `feesPending` | The user gets |
|---|---|---|---|---|---|---|
| open | +stake | +stake | +maxProfit | | | pays in the stake |
| liquidate | −loserFee | −stake | −maxProfit | | +loserFee | nothing |
| settle | −(own + paid + loserFee) | −stake | −maxProfit | +owed | +winnerFee + loserFee | own + paid − winnerFee |
| sell | −(valuation + loserFee) | −stake | −maxProfit | | +all three fees | sellAmount − winnerFee |
| repay | −amount | | | −amount | +winnerFee | amount − winnerFee |
| refund | −stake | −stake | −maxProfit | | | stake |
| fund | +amount | | | | | |
| withdraw | −amount | | | | | (paid to a recipient) |

## 11. Rounding

The maths uses integers only. Products are taken in 256 bits, where no input can overflow, and each result is narrowed
once at the end with a range check (`MathOverflow`), never a bare cast.

Solidity's `/` on signed integers rounds toward zero: `−7 / 2 = −3`. The one division whose dividend can be negative,
`R` in §5, uses `floorDiv` instead, which rounds toward minus infinity:

```
q = a / b;  if (a % b ≠ 0 and a, b have opposite signs) q = q − 1
floorDiv(7, 2) = 3    floorDiv(−7, 2) = −4    floorDiv(7, −2) = −4    floorDiv(−7, −2) = 3
```

Every other division has operands of zero or more, so `/` already rounds down. Each rounding, and whom it favours:

| Quantity | Rounds | Effect |
|---|---|---|
| the liquidation line's offset | down | the line sits nearer the entry and is touched no later: the pool |
| the cap line's offset | down | display only: no money moves on it |
| `R`, the move | toward minus infinity | a win rounds down and a loss rounds to the larger loss: the pool |
| `payout` | down | the pool never pays above the exact value: the pool |
| `maxProfit` | down | exactly the most a payout can exceed the stake (§5) |
| the open gate's limit | down | the gate errs toward refusing: the pool |
| the winner fee | down | the user never pays a rounded-up fee: the user |
| the loser fee | down | a smaller cut of the loss the pool keeps: the pool |
| the early-sell fee's cap | down | the allowed fee errs low: the user |

In short, every rounding that decides what the pool pays out or keeps goes in the pool's favour, and no fee ever rounds
against the user.

## 12. Worked examples

Unless an example says otherwise, it uses the reference bet: BTC at exponent −8, an entry of $83,884
(`entry = 8,388,400,000,000`), a $10 stake (`10,000,000`), 1000x, θ = 2.627 bp (`2,627`), a 1.3x floor (`13,000`), a
4x cap (`40,000`) and a $500 pool floor (`500,000,000`). One basis point of the entry is `838,840,000` (`entry /
10,000`, exactly).

### Example 1: the lines at 1000x

Checked by `test/unit/LeverageMath.t.sol`.

```
liqOffset = floor(8,388,400,000,000 × 2,627 / 10,000,000)
          = floor(22,036,326,800,000,000 / 10,000,000)    = 2,203,632,680      ($22.0363268)
capOffset = floor(8,388,400,000,000 × 30,000 / (1,000 × 10,000))
          = floor(251,652,000,000,000,000 / 10,000,000)   = 25,165,200,000     ($251.652)

long:   liqPrice = 8,388,400,000,000 − 2,203,632,680  = 8,386,196,367,320    ($83,861.9636732)
        capPrice = 8,388,400,000,000 + 25,165,200,000 = 8,413,565,200,000    ($84,135.652)
short:  liqPrice = 8,388,400,000,000 + 2,203,632,680  = 8,390,603,632,680    ($83,906.0363268)
        capPrice = 8,388,400,000,000 − 25,165,200,000 = 8,363,234,800,000    ($83,632.348)
```

The long is touched at `8,386,196,367,320` and not one unit above it; the short at `8,390,603,632,680` and not one
unit below it.

### Example 2: the payout curve at 1000x

Checked by `test/unit/LeverageMath.t.sol`. A long, with `R = floor(move × 1,000 × 10,000 / 8,388,400,000,000)`:

| Price | move | exact quotient | R | g | payout |
|---|---|---|---|---|---|
| entry + $84 | 8,400,000,000 | 10,013.83 | 10,013 | 20,013 | 20,013,000 ($20.013) |
| entry + $252 | 25,200,000,000 | 30,041.49 | 30,041 | 40,041, capped to 40,000 | 40,000,000 ($40) |
| entry + $8 | 800,000,000 | 953.70 | 953 | 10,953, raised to the floor 13,000 | 13,000,000 ($13) |
| entry | 0 | 0 | 0 | 10,000 | 10,000,000 ($10) |
| entry − $8 | −800,000,000 | −953.70 | −954 | 9,046 | 9,046,000 ($9.046) |

- +$8 is a win below the floor, so it pays the floor: $11, $14 or $15 with a 1.1x, 1.4x or 1.5x floor.
- −$8: `floorDiv(−8,000,000,000,000,000, 8,388,400,000,000) = −954`. Rounding toward zero would give −953, g = 9,047,
  and $9.047: $0.001 more to the user.
- A short mirrors it: with a 1.4x floor, a short pays g = 14,000 at entry − $8 and 9,046 at entry + $8.
- The maximum profit is `floor(10,000,000 × 30,000 / 10,000) = 30,000,000` ($30); $10 + $30 = $40 is the payout at the
  cap.

### Example 3: settlement and its fees

Checked by `test/unit/LeverageMathSplits.t.sol`. The reference bet settles with $10,000 of free money and nobody owed.

```
+$84:   payout 20,013,000   own 10,000,000   paid 10,013,000
        winnerFee = floor(10,013,000 × 200 / 10,000) = 200,260
        toUser    = 10,000,000 + 10,013,000 − 200,260 = 19,812,740                        ($19.81274)
+$252:  payout 40,000,000   own 10,000,000   paid 30,000,000
        winnerFee = 600,000          toUser = 39,400,000                                   ($39.40)
−$8:    payout 9,046,000    own 9,046,000    loss = 10,000,000 − 9,046,000 = 954,000
        loserFee  = floor(954,000 × 300 / 10,000) = 28,620
        toUser    = 9,046,000        out of total = 9,046,000 + 28,620 = 9,074,620
```

- The losing bet receives its full $9.046: the $0.02862 loser fee comes out of the $0.954 the pool keeps. With free
  money one base unit below the $500 floor, the loser fee is 0.
- A short pool: with $12 free, a $40 payout gives own $10, paid $12, a winner fee of 240,000 and owed $18. The user
  gets $21.76 now and an IOU for $18.
- A queue ahead: with $1,000 free but someone owed, the same payout gives own $10, paid 0 and owed $30.

### Example 4: the 500x tier

Checked by `test/unit/LeverageMathLeverage.t.sol`. A long at 500x, θ = 11.76 bp (`11,760`), a 1.025x floor (`10,250`)
and a 2.5x cap (`25,000`).

```
liqOffset = floor(8,388,400,000,000 × 11,760 / 10,000,000)       = 9,864,758,400
liqPrice  = 8,388,400,000,000 − 9,864,758,400                    = 8,378,535,241,600       ($83,785.352416)
capOffset = floor(8,388,400,000,000 × 15,000 / (500 × 10,000))   = 25,165,200,000
capPrice  = 8,388,400,000,000 + 25,165,200,000                   = 8,413,565,200,000       ($84,135.652)

at the line:            R = floor(−9,864,758,400 × 5,000,000 / 8,388,400,000,000) = −5,880    g = 4,120
at the cap line:        R = 25,165,200,000 × 5,000,000 / 8,388,400,000,000        = 15,000    g = 25,000
one unit short of it:   R = floor(14,999.9999994)                                 = 14,999    g = 24,999
```

The cap line is the same 0.3% move as 1000x at 4x. Just inside its line the bet is worth 0.412x: it has lost 58.8%,
and `11,760 × 500 / 1,000 = 5,880`.

### Example 5: the 100x tier

Checked by `test/unit/LeverageMathLeverage.t.sol`. 100x, θ = 17.64 bp (`17,640`), a 1.005x floor (`10,050`) and a 2x
cap (`20,000`).

```
liqOffset = floor(8,388,400,000,000 × 17,640 / 10,000,000)       = 14,797,137,600
capOffset = floor(8,388,400,000,000 × 10,000 / (100 × 10,000))   = 83,884,000,000          (1% of the entry)

long:   liqPrice = 8,373,602,862,400 ($83,736.028624)     capPrice = 8,472,284,000,000 ($84,722.84)
short:  liqPrice = 8,403,197,137,600 ($84,031.971376)     capPrice = 8,304,516,000,000 ($83,045.16)

g at either line: 10,000 − 1,764 = 8,236          g at either cap line: 20,000          one unit short: 19,999
```

The floor and the cap along the long's curve, where one bp is `838,840,000`:

| Move | R | g |
|---|---|---|
| +0.1 bp (`83,884,000`) | 10 | 10,010, raised to the floor 10,050 |
| +1 bp | 100 | 10,100 |
| +99 bp | 9,900 | 19,900 |
| +100 bp | 10,000 | 20,000, the cap |
| +150 bp | 15,000 | 25,000, capped to 20,000 |

At 500x with a 1.025x floor and a 2.5x cap, +1 bp gives g = 10,500, and +30 bp reaches the cap, 25,000.

### Example 6: half a basis point

Checked by `test/unit/LeverageMathLeverage.t.sol`. A long moves half a basis point, `±419,420,000`, with no floor (1x)
and the 4x cap:

| L | Move | Exact quotient | R | g |
|---|---|---|---|---|
| 15 | +½ bp | +7.5 | 7 | 10,007 |
| 15 | −½ bp | −7.5 | −8 | 9,992 |
| 1 | +½ bp | +0.5 | 0 | 10,000 |
| 1 | −½ bp | −0.5 | −1 | 9,999 |

A win rounds down, and a loss rounds to the larger loss. At 1x with a 1.005x floor, +½ bp still gives 10,000: `R = 0`
is not a win, so the floor does not apply. Each whole basis point moves g by exactly L at every leverage swept (1x,
4x, 15x, 100x, 500x, 1000x, 2000x and 10,000x).

### Example 7: the widest line and the highest cap per leverage

Checked by `test/unit/LeverageMathLeverage.t.sol` and `test/unit/ConfigLib.t.sol`. The widest θ is the largest with
`θ × L < 10^7`, that is `floor((10^7 − 1) / L)`:

| L | 1 | 4 | 15 | 100 | 500 | 1000 | 2000 | 10,000 |
|---|---|---|---|---|---|---|---|---|
| widest `thetaE7` | 9,999,999 | 2,499,999 | 666,666 | 99,999 | 19,999 | 9,999 | 4,999 | 999 |

- One unit wider fails: at 15x, `666,667 × 15 = 10,000,005`, which is not below `10^7`.
- The 500x tier's widest line, 11.76 bp, fits 500x (`11,760 × 500 = 5,880,000`) but not 1000x (`11,760,000`).
- The highest cap a short can reach is the largest with `capBps − 10,000 < L × 10,000`: 19,999 at 1x, 29,999 at 2x,
  39,999 at 3x, and the 40,000 ceiling from 4x up.
- At 1x, a short's 1.9999x cap line is `8,388,400,000,000 − floor(8,388,400,000,000 × 9,999 / 10,000) = 838,840,000`:
  one basis point of the entry above 0.

### Example 8: a market's settings

Checked by `test/unit/ConfigLib.t.sol`. The tests' example market at 1000x has stakes of $1 to $50, floors of 1.1x to
1.5x, caps of 1.5x to 4x, a 6% early-sell fee cap, a 5-second price age, a 5-second clock skew, a sell window from the
start to 2 seconds before the end, and the open gate at 100%. Its five θ ranges are ±25% around a line, from
`floor(θ × 3 / 4)` to `floor(θ × 5 / 4)`:

| Duration | 60 s | 120 s | 180 s | 240 s | 300 s |
|---|---|---|---|---|---|
| line | 3,000 | 4,190 | 4,930 | 5,470 | 5,880 |
| θ range | 2,250 to 3,750 | 3,142 to 5,237 | 3,697 to 6,162 | 4,102 to 6,837 | 4,410 to 7,350 |

- Every range fits 1000x (the widest is 9,999). A one-minute bet at θ 2,249 or 3,751 is refused, and so is the
  five-minute line, 5,880.
- With a 1.2x cap minimum and a 1.3x floor, the lowest cap is the floor: 1.3x passes and 1.2999x does not.
- The 100x tier settings (floors 1.005x to 1.05x, caps 1.5x to 2x, lines up to 17,640) and the 500x tier settings
  (floors 1.025x to 1.25x, caps 1.5x to 2.5x, lines up to 11,760) each pass at their own leverage. The 500x settings
  fail at 1000x.

### Example 9: the open gate and withdrawals

Checked by `test/unit/LeverageMathChecks.t.sol`.

- **The gate.** $1,000 free, the gate at 100%, and $970 of open maximum profit: a bet adding $30 passes (`970 + 30 ≤
  1,000`), and one adding one base unit more is refused (`OpenBlockedExposure`).
- **Its rounding.** 1 base unit free at 1.5x: the limit is `floor(1 × 15,000 / 10,000) = 1`, so an exposure of 2 is
  refused, where rounding up would allow it. (The library takes any rate; a market's rate is at most 100%.)
- **The owed limit.** `totalOwed = 100` against a limit of 100 passes; 101 is refused (`OpenBlockedTotalOwed`).
- **Withdrawals**, with $1,500 free, a $500 floor and a 6-decimal token. With no open bets, rewards up to $1,000 pass
  and $1,000.000001 is refused (`BelowPoolFloor`). With $300 of open maximum profit, $700 passes (`1,500 − 700 − 500 =
  300 ≥ 300`), and one base unit more is refused (`OpenExposureNotCovered`).
- **Seed recovery:** $500 in total, in one go or as $300 and then $200, and never one base unit more
  (`SeedRecoveryExceeded`). With only $900 free, at most $400 can go, because the floor binds first. The cap is
  `500 × 10^decimals`: 500,000,000,000 at 9 decimals; at 17 it does not fit `uint64` (`MathOverflow`).

### Example 10: early sales

Checked by `test/unit/LeverageMathChecks.t.sol` and `test/unit/LeverageMathSplits.t.sol`.

- A $10 bet at `gNow = 13,000` is worth at most `floor(10,000,000 × 13,000 / 10,000) = 13,000,000`, so a valuation of
  13,000,001 is refused (`ValuationAboveCurrentPayout`).
- A 6% cap on a $12.50 valuation: `floor(12,500,000 × 600 / 10,000) = 750,000`. A sale amount of 11,750,000 (a fee of
  750,000) passes; 11,749,999 (a fee of 750,001) is refused (`SellFeeTooHigh`).
- A $12 valuation is payable with $2 free, since `12 ≤ 2 + 10`, and refused with one base unit less
  (`SellNotPayable`).

The splits of a $10 bet, with free money at the floor:

| Case | valuation | sellAmount | sellFee | winnerFee | loserFee | toUser | out of total |
|---|---|---|---|---|---|---|---|
| profit | 12,500,000 | 12,000,000 | 500,000 | 40,000 | 0 | 11,960,000 | 12,500,000 |
| loss | 9,000,000 | 8,600,000 | 400,000 | 0 | 30,000 | 8,600,000 | 9,030,000 |
| at the cap | 40,000,000 | 40,000,000 | 0 | 600,000 | 0 | 39,400,000 | 40,000,000 |
| in between | 10,200,000 | 9,900,000 | 300,000 | 0 | 0 | 9,900,000 | 10,200,000 |

The profit case's winner fee is `floor((12,000,000 − 10,000,000) × 200 / 10,000) = 40,000`. The loss case's loser fee
is `floor((10,000,000 − 9,000,000) × 300 / 10,000) = 30,000`, and 0 with free money one base unit below the floor.

### Example 11: the IOU queue in a small pool

Checked by `test/unit/LeverageMathSplits.t.sol`. The pool has $20 of free money, below the $500 floor, so no loser fee
is taken. Bettors A, B and C stake $10 each.

| Step | What happens | total | locked | free |
|---|---|---|---|---|
| 1 | three stakes held | $50 | $30 | $20 |
| 2 | C is liquidated: loser fee 0 (free $20 is below the floor); C's stake becomes free money | $50 | $20 | $30 |
| 3 | A settles at $40: own $10, paid $30, winner fee $0.60; A gets $39.40; $40 leaves `total` | $10 | $10 | $0 |
| 4 | B settles at $40: own $10, paid 0, owed $30; B gets $10 now and an IOU for $30 | $0 | $0 | $0 |
| 5 | D stakes $10 and is liquidated: loser fee 0; D's stake becomes free money | $10 | $0 | $10 |
| 6 | repay: amount `min(30, 10)` = $10, winner fee $0.20; B gets $9.80 and is still owed $20 | $0 | $0 | $0 |

### Example 12: times

Checked by `test/unit/LeverageMathChecks.t.sol`.

- **The entry tick**, with a 5-second age and a 5-second skew: `now − 5` and `now + 5` pass; `now − 6` is
  `PriceTooOld`, `now + 6` is `PriceFromFuture`, and a time of 0 is `PriceTooOld`.
- **The sell window** of a bet from second 1,000 to 1,060, with no delay and a 2-second cutoff: ticks at 1,000 and
  1,057 pass; 999, 1,058 and 1,060 are refused. With a 10-second delay, 1,009 is refused and 1,010 passes.
- **The liquidation window** of the same bet: ticks at 1,000 and 1,060 liquidate even with the clock at 2,000; 999 and
  1,061 are refused (`InvalidLiquidationWindow`). With the clock at 1,010 and a 5-second skew, a tick at 1,015 passes
  and 1,016 is refused (`PriceFromFuture`).
