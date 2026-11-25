# Integrating with the Manic Flash Option contract

For the backend (the relayers, the signing service, the indexer) and the frontend. It says what to call, in which
order, what to sign, what comes back, and what to do when a call is refused.

**Status:** v1.0.0: everything in this guide is built and tested. The first testnet deployment from this repository
is pending; once a chain is deployed, its addresses are in `deployments/<chainId>.json` ([§13](#13-deployments)).

**The leverage** is the user's choice:
- A market is a price feed at one leverage, so BTC can have a 1000x, a 500x and a 100x market, each with its own
  settings. The user signs the leverage in the `OpenOrder`. `createMarket`, `setConfig`, `setPaused`, `liquidate`,
  `settle`, `getMarket` and `marketIdAt` take or return it, and `open` and `hashOpenOrder` through the order;
  `MarketCreated`, `ConfigUpdated` and `PauseChanged` carry it.
- Each bet keeps its own copy of its market's leverage. `getPosition` returns it in the `Position`, settle and sell
  value the bet at it, and `PositionOpened`, `PositionLiquidated`, `PositionSettled` and `PositionSold` carry it as
  their last field.

**The sources of truth:**
- `abi/IManicFlashOption.json`: the ABI, regenerated and checked by CI on every change.
- [abi-reference.md](abi-reference.md): every selector, event topic and error id, generated from the compiler.
- `src/interfaces/`: each function's NatSpec, with its checks in order.
- `test/fixtures/eip712_vectors.json`: the signing vectors your signer must reproduce ([§12](#12-signing)).
- [ARCHITECTURE.md](ARCHITECTURE.md) §8: the design of each function.

---

## 1. The contract in one page

- **One contract, behind an ERC-1967 (UUPS) proxy.** Always call the proxy's address.
- **The token is USDG**, 6 decimals. Every amount is a `uint64` in base units: $1 is `1_000_000`.
- **Prices** are `int64` at the market's exponent, as Pyth publishes them. BTC's exponent is −8, so $83,884 is
  `8_388_400_000_000`.
- **A market** is a Pyth feed at one leverage, keyed by the pair: the feed id (`bytes32`, for example BTC/USD
  `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`) and the leverage (`uint16`, 1 to 10,000:
  `1000` is 1000x). BTC at 1000x and BTC at 500x are two markets, with their own settings and pause.
- **Times** are seconds (`uint48`), compared with the chain's `block.timestamp`.
- **Multiples and fees** are in basis points: `10_000` is 1x, or 100%.
- **A position** is keyed by a `bytes32` id that the backend chooses ([§2](#2-opening-a-bet)). Its status moves one
  way only: `None` (never used) → `Open` → (`Owed` →) `Closed`.

**Who calls what:**

| Caller | Functions |
|---|---|
| Opener relayer (`OPENER_ROLE`) | `open`, `sell` |
| Settler relayer (`SETTLER_ROLE`) | `liquidate`, `settle` |
| Anyone | `repay`, `refundExpired`, `claim`, `sweepFees`, `fund` |
| Operator (`OPERATOR_ROLE`, the admin Safe) | `setConfig`, `setPaused`, `setHalted`, `resetBreaker` |
| Guardian (`GUARDIAN_ROLE`) | `setHalted(true)`, `setPaused(…, true)`, `revokeRelayer` |
| Admin (`DEFAULT_ADMIN_ROLE`, behind a 48-hour timelock on mainnet) | `createMarket`, `setPoolFloor`, `setRecipients`, `setRefundDelay`, `setBreaker`, `withdraw`, role grants |
| Upgrader (`UPGRADER_ROLE`, behind the same timelock) | `upgradeToAndCall`, which is only in the implementation's ABI |

The relayers are trusted for the **price only**. Everything else they send is checked against the user's signature
or the market's bounds.

**How much it costs**, as whole transactions in the worst case (every payout a transfer to an empty balance), on the
mock token. [gas.md](gas.md) has every number, kept current by CI, and how to size batches and set gas limits:
- one `open`: about 220,000 gas;
- one `sell` at a profit: about 180,000;
- `settle`: about 166,000 for one bet and 5.34 million for 100, about 52,000 per bet more;
- `liquidate`: about 119,000 for one bet and 1.83 million for 100, about 17,000 per bet more;
- `repay`: about 112,000 for one IOU and 1.69 million for 50;
- `refundExpired`: about 136,000 for one bet and 2.19 million for 50.

The real USDG adds about 7,000 gas per payout. Every batch the contract accepts fits Robinhood Chain's
32,000,000-gas transaction limit with room to spare.

The circuit breaker's count is in these: about 7,000 gas per call that counts, and about 700 per position in a
batch.

---

## 2. Opening a bet

**1. Choose the position id.** A fresh random `bytes32`, never used before by anyone. It is the position's key for
life, and also the nonce of the user's stake authorisation, so it can fund one bet once.
`getPosition(id).position.status == None` means it is free. The id must be in the order the user signs, so make it
when the user asks to bet, before the price.

**2. The user signs an `OpenOrder`** (EIP-712, [§12](#12-signing)), before any price is known:

| Field | Type | Meaning |
|---|---|---|
| `positionId` | `bytes32` | the id from step 1 |
| `user` | `address` | the bettor; every payout goes to this address |
| `marketId` | `bytes32` | the Pyth feed id |
| `leverage` | `uint16` | the leverage the user chose: with `marketId` it names the market (BTC at 1000, 500 or 100). Signed, so no relayer can open the bet at another |
| `side` | `uint8` | `0` = Call (Higher, a long), `1` = Put (Lower, a short) |
| `stake` | `uint64` | the margin, from the market's `minStake` to its `maxStake` |
| `durationSecs` | `uint16` | one of the market's enabled durations (60, 120, 180, 240 or 300 at launch) |
| `notBefore` | `uint48` | the second the user signed: the price tick must be published at or after it |
| `deadline` | `uint48` | the last second the contract accepts the order (about 30 seconds after signing) |

**3. The user signs a USDG `ReceiveWithAuthorization`** (EIP-3009) for exactly the stake: `from` the user, `to` the
proxy, `value` = `stake`, `nonce` = `positionId`, and a short `validAfter`/`validBefore` window. It is signed under
USDG's own EIP-712 domain (read the token's `DOMAIN_SEPARATOR()`). The type hash is
`0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8`. Only the contract, as the payee, can submit it,
so nobody can front-run it, and the user never approves anything.

**4. At the price tick, the opener calls** `open(o, signature, t, a)`:
- `t` (`OpenTerms`) carries the tick and the bet's terms: `entryPrice`, `entryPublishTime`, `thetaE7` (the
  liquidation distance θ × 1e7, inside the duration's range), `floorBps` and `capBps` (inside the market's ranges, the
  cap at least the floor). The ranges are the market's own: each leverage has its own.
- The contract works the line and the cap price out at the market's leverage: at leverage L, a 1 bp move is worth L
  bps of the stake (10% at 1000x, 5% at 500x, 1% at 100x). The bet keeps a copy of that leverage, and is valued at
  it until it ends.
- `a` (`StakeAuth`) carries `validAfter`, `validBefore` and the user's `signature` from step 3.

The tick must be:
- at most `entryMaxAgeSecs` old (5 at launch);
- at most `clockSkewSecs` ahead of the chain's clock (5 at launch, 30 at most);
- at or after `notBefore`.

**Timing on the Robinhood testnet** (measured on 2026-11-23 by the smoke test, `script/smoke.py`, on a test
deployment):
- **The chain's clock runs behind real time.** The latest block's timestamp trailed it by 1.31 s at the median and
  2.36 s at most, over 40 samples. The local clock was checked against NTP, within 0.01 s.
  - So a fresh tick looks up to about 2.4 s "ahead" of the chain. The clock skew of 5 covers that.
  - Ages count from the chain's clock, so the lag also buys the opener about a second.
- **The landing time.** A signed open or sale, sent at once with the nonce and gas given, landed 1 to 2 s after its
  tick's time (23 of 23).
  - When each `cast` call fetched its own nonce, gas and estimate, and the driver read state after stamping the tick, it
    landed 3 to 5 s after, at the edge of the 5-second age. The first sale was refused that way.
  - **For the backend:** do every read before taking the tick, and send within about 3 s of its publish time.
- **Keep both at 5.** Below 3, fresh ticks would sometimes be refused as ahead of the chain. Above 5 gives a stale price
  longer to be used, with nothing gained at these delays.

**The bet's clock starts at the tick**, not when the transaction lands: `endTime = entryPublishTime + durationSecs`.

**What comes back:**
- `PositionOpened` (15 fields) gives the line, the cap price, the start, the expiry and the leverage.
- The pool's total and held margin rise by the stake, and its open max profit by `stake × (cap − 1x)`.
- The contract checks its balance rose by exactly the stake.

**The open gate** refuses a bet the pool couldn't cover:
- `OpenBlockedExposure` when the open bets' max profit, this one's included, would pass the share of free money set by
  `maxExposureBps` (100% at launch; `validate` allows 1 bp to 100%, ADR 0009);
- `OpenBlockedTotalOwed` while the IOUs owed pass `maxTotalOwed`.

---

## 3. Selling early

**The user signs a `SellOrder`:**

| Field | Type | Meaning |
|---|---|---|
| `positionId` | `bytes32` | the position to sell; the signer must be its user |
| `minAmount` | `uint64` | the least the user accepts, before the 2% winner fee |
| `notBefore` | `uint48` | the second the user signed: the tick must be at or after it |
| `deadline` | `uint48` | the last second the contract accepts the order |

**At the tick, the opener calls** `sell(s, signature, t)`. `t` (`SellTerms`) carries `price`, `publishTime`, and the
quote: `valuation` (what the bet is worth now) and `sellAmount` (the valuation less the early-sell fee).

**The contract bounds the quote with its own maths:**
- the tick inside the sell window: from `start + sellMinDelaySecs` until `sellCutoffSecs` before the end (0 and 2 at
  launch), fresh, and at or after `notBefore`;
- the sale landing before the end. One that lands at or after the end is refused (`SellWindowClosed`), and the bet is
  settled instead, so send a sale as soon as you have its tick;
- a positive price that doesn't touch the line;
- the valuation at most what the bet pays at this price, at its own leverage;
- the sale amount at most the valuation;
- the early-sell fee (`valuation − sellAmount`) at most `maxSellFeeBps` of the valuation (6% at launch);
- the sale amount at least `minAmount`;
- nobody owed;
- the valuation within free money plus the bet's own stake.

A sale is never paid in part.

**What comes back:** `PositionSold`. The user gets the sale amount less 2% of any profit (the part above the stake).
The fees (the early-sell fee, and the 2% winner fee or a 3% loser fee) go to the pending fees. The position closes, so
the same order can never sell it twice.

---

## 4. Ending bets: `liquidate`, `settle` and the safety refund

`liquidate` and `settle` take one market (a feed and a leverage), one price tick and **1 to 100 position ids**, and
return how many they ended. **Group the ids by market:** a position of another market, including the same feed at
another leverage, reverts the batch with `ConfigMismatch(id)`. Only the halt stops them; a paused or switched-off
market and a tripped breaker don't, so a bet can always end.

**`liquidate(marketId, leverage, price, publishTime, ids)`** ends every position whose line the tick touches.
Equality counts: for a Call the price is at or below the line, for a Put at or above it. The tick must fall within
each bet's life, from its start to its expiry inclusive, and be at most the clock skew ahead. Old ticks are accepted,
so you can catch up after an outage. The user gets nothing back. The stake stays in the pool as free money, less a 3%
loser fee while free money is at or above the floor.

**`settle(marketId, leverage, price, publishTime, ids)`** pays every position at its expiry second, valued at the
bet's own leverage (its market's, copied when it opened):
- `publishTime` must equal each position's `endTime`, and may be up to the clock skew ahead of the chain's clock;
- a position whose line the tick touches must be liquidated instead (`LiquidateInstead(id)`, same tick);
- it pays `stake × g`, less 2% of the profit paid now, or a 3% loser fee on a loss while free money is at or above the
  floor;
- profit the pool can't pay now becomes an IOU at the back of the repay queue ([§5](#5-the-iou-queue-and-repay)).

**Batches that never get stuck:**
- **An id that has already ended** is skipped with `PositionSkipped(id, status)`, and the rest of the batch goes on.
  That covers a sale in the same block, an IOU, or an id listed twice.
- **An id that doesn't fit the batch reverts it, naming the id:** `UnknownPosition(id)`, `ConfigMismatch(id)`
  (another market), `InvalidPriceTimestamp(id)`, `LiquidateInstead(id)`, `LiquidationPriceNotReached(id)` or
  `InvalidLiquidationWindow(id)`. Drop that id and resend the rest.
- **A payout the token refuses** (a frozen user, a paused token) waits in `claimable` ([§6](#6-payouts-that-wait-claimable)).
  It never fails the batch.

**`refundExpired(ids)`, the safety refund,** is the last resort if the backend stops. Anyone may call it, and no
brake stops it: not the halt, a pause, a switched-off market or a tripped breaker.
- It returns each listed bet's whole stake to its user, with no fee, once `refundDelaySecs()` (24 hours at launch)
  have passed since the bet's expiry: `block.timestamp ≥ endTime + refundDelaySecs`. Free money doesn't change.
- It takes 1 to 100 ids, of any markets, and needs no price. It skips ids that have already ended
  (`PositionSkipped`), and reverts `UnknownPosition(id)` for an id never opened, `RefundTooEarly(id)` for an open bet
  that isn't due yet, and `RefundDisabled` while the admin has switched it off (a delay of 0).
- Each refund emits `PositionRefunded(positionId, user, stake)`, then pays the stake like any payout
  ([§6](#6-payouts-that-wait-claimable)). It returns how many it refunded.
- **For the backend:** keep settling every bet at its expiry second. Once a bet's delay has passed, a late `settle`
  and a refund can both end it: whichever lands first does, and the other skips it. After an outage, settle what
  you can before the delay runs out.
- **For the frontend:** a bet still `Open` after `endTime + refundDelaySecs()` can be refunded. Any account can send
  the call, the user's own included if it holds ETH for gas.

---

## 5. The IOU queue and repay

An IOU forms when a winner's profit is more than the pool's free money at settle, or when anyone is already owed (new
winners join the back of the queue, so nobody jumps it). The exposure gate is at most 100% (`validate` refuses it off
or above, ADR 0009), so free money always covers the open bets' max profit and IOUs can't form; the queue is the
safety net, for a state only an upgrade could reach.

**`repay(maxCount)`**, which anyone may call (the backend after each settle batch), pays the queue from free money,
strictly in order, from the head:
- each repayment pays as much as free money allows, less 2%;
- an IOU paid in full leaves the queue;
- the first one paid in part stays at the head, and the call stops;
- it also stops when free money runs out, when the queue is empty, or after `maxCount` (1 to 50) repayments.

It returns how many it repaid, and emits `OwedRepaid` for each. `queueHead()` shows who is next and what they are
owed. While anyone is owed, no sale can go through (`QueueNotEmpty`), and nothing can be withdrawn.

---

## 6. Payouts that wait: `claimable`

Every payout (a settle, a sale, a repayment, a refund) tries the transfer once:
- **If USDG refuses it** (the user is frozen, or the token is paused), the amount is kept for the user in
  `claimableOf(user)`, with `PayoutDeferred(positionId, user, amount)`, and the call goes on. Show it in the user's
  balance.
- **`claim(user)`**, which anyone may call, later pays it **to that user only**.
- **A starved call reverts** with `InsufficientGasForPayout` instead of deferring, so a relayer can never push honest
  winners into `claimable` by sending too little gas. A payout needs at least 60,000 gas. Retry with a higher limit.

---

## 7. Money in and out of the pool

| Function | Who | What |
|---|---|---|
| `fund(amount)` | anyone | Adds free money: approve the proxy for `amount` first. The balance must rise by exactly `amount` |
| `withdraw(purpose, amount)` | admin | Seed recovery (at most $500 in total, to the fee recipient) or rewards (to the rewards recipient), only while nobody is owed and what stays above the floor covers every open bet's max profit |
| `sweepFees()` | anyone | Sends every pending fee to the fee recipient |
| `claim(account)` | anyone | Pays an account's claimable balance to that account |

---

## 8. The brakes and the settings

| | `open` | `sell` | `liquidate`, `settle` | `repay` | `refundExpired` | the pool functions |
|---|---|---|---|---|---|---|
| Market switched off or paused | stops | stops | runs | runs | runs | run |
| Contract halted | stops | stops | stops | stops | runs | run |
| Breaker tripped | stops | stops | runs | runs | runs | run |

The guardian or the operator halts and pauses; only the operator releases. The guardian can also revoke a relayer key
at once (`revokeRelayer`); granting one back needs the timelocked admin.

**The payout circuit breaker** guards against a stolen relayer key: one that opens bets at fake prices and settles
them at real ones, in a loop.
- **It counts, in fixed windows** (one hour at launch), the users' winnings and losses before fees:
  - a settle counts the profit it pays now and the loss;
  - a liquidation counts the stake as a loss;
  - a sale counts its sale amount against the stake;
  - a repayment counts what it repays, so an IOU's profit counts when it is paid, not when it is owed;
  - a refund counts nothing.
- **It trips** when a window's profit out is more than its losses in plus the limit (`maxNetProfit`), with
  `CircuitBreakerTripped(profitOut, lossIn, windowStart)`, once. The call that trips it still completes, so its
  winners are paid.
- **While it is tripped,** `open` and `sell` revert `BreakerTripped`. Liquidations, settles, repayments, refunds and
  claims go on, and the counting goes on too.
- **The operator's `resetBreaker`** clears the trip and starts a fresh window. The admin's `setBreaker` changes the
  limit (0 switches the breaker off) and the window. It doesn't clear a trip.
- **For the backend:** alert someone on `CircuitBreakerTripped`. Stop sending opens and sales until `getBreaker()`
  shows `tripped == false`. Keep settling and liquidating as usual.
- **For the frontend:** while `getBreaker().tripped`, show that new bets and early sales are paused.

**The setup and settings functions** (none of them is called by the relayers):

| Function | Who | What |
|---|---|---|
| `initialize(p)` | once, inside the proxy's deployment | the roles, the token, the floor, the recipients, the refund delay and the breaker |
| `createMarket(marketId, leverage, priceExponent, config)` | admin | a new market, a feed at one leverage, always created switched off; its settings are checked at that leverage |
| `setConfig(marketId, leverage, config)` | operator | replaces every setting of a market, `enabled` included; never its leverage |
| `setPaused(marketId, leverage, paused)` | guardian or operator to pause; operator to unpause | one leverage of a feed; `setHalted` stops every market |
| `setHalted(halted)` | guardian or operator to halt; operator to release | |
| `setPoolFloor(poolFloor)` | admin | at least 500 whole tokens |
| `setRecipients(feeRecipient, rewardsRecipient)` | admin | |
| `setRefundDelay(refundDelaySecs)` | admin | how long after expiry a bet may be refunded: 0 switches the refund off, otherwise at least 1 hour (`InvalidRefundDelay`); it applies to bets already open |
| `setBreaker(maxNetProfit, windowSecs)` | admin | the circuit breaker's limit per window (0 switches it off) and its window, 60 seconds to 1 day (`InvalidBreakerParams`); it leaves the counters and a trip alone |
| `resetBreaker()` | operator | clears a trip and starts a fresh window |
| `revokeRelayer(role, account)` | guardian | opener and settler keys only, at once |
| `upgradeToAndCall(implementation, data)` | upgrader (timelocked) | not in `IManicFlashOption`, only in the implementation's ABI |

---

## 9. Reading the state

| Getter | Returns |
|---|---|
| `getPosition(id)` | The stored `Position`, its `endTime`, and its `capPrice`, at the bet's own `leverage`, which the `Position` holds. A never-used id returns an empty record with `status` `None`. A closed position keeps only its first slot (user, market index, side, status, start, duration): its terms, the leverage included, read 0, and so does its cap price; its market index still names its market, and so its leverage. An IOU keeps its terms and also reads `owed` and `queueSeq` |
| `getMarket(marketId, leverage)` | The market's `Market` settings, its leverage included; reverts `UnknownMarket` for a pair no market has |
| `marketCount()`, `marketIdAt(index)` | The markets, by index (the index positions record); `marketIdAt` returns `(marketId, leverage)` |
| `getPool()` | Every field of the pool's books (`PoolState`) |
| `freeMoney()` | `total − lockedMargin`: what new bets, repayments and withdrawals are measured against |
| `claimableOf(account)` | What waits for `account` to claim |
| `queueHead()` | `(queueSeq, positionId, owed)` of the next IOU; `(nextRepaySeq, 0, 0)` when nobody is owed |
| `getBreaker()` | The circuit breaker's window, counters, limit and whether it has tripped |
| `token()`, `halted()`, `refundDelaySecs()`, `recipients()` | The settings |
| `hashOpenOrder(o)`, `hashSellOrder(s)` | The EIP-712 digest of an order, to check your encoding against the deployment |
| `eip712Domain()`, `version()` | The signing domain (ERC-5267) and the implementation's version |
| `hasRole(role, account)` and the role ids | OpenZeppelin's role views |

Every getter that reads the contract's books reverts while one of its state-changing functions is running
(read-only reentrancy protection). That only affects a contract that reads them from inside a call into this one,
never an off-chain read.

---

## 10. Events

| Event | When | Notes |
|---|---|---|
| `PositionOpened` | `open` | The line, the cap price, θ, the floor, the cap, the start, the expiry and the leverage |
| `PositionSold` | `sell` | The price, g now, the valuation, the sale amount, each fee and the leverage |
| `PositionLiquidated` | `liquidate`, once per ended id | The stake lost, the loser fee and the leverage |
| `PositionSettled` | `settle`, once per ended id | g, the payout, what the user got now (`paidNow`), what is `owed` and its `queueSeq`, each fee and the leverage |
| `PositionSkipped` | a batch met an id that had already ended | Its status |
| `PositionRefunded` | `refundExpired`, once per refunded id | The stake returned |
| `OwedRepaid` | `repay`, once per repayment | The amount, the winner fee and what stays owed |
| `PayoutDeferred` | a payout the token refused | Right after its ending's event; the amount is in `claimableOf(to)` |
| `Claimed`, `FeesSwept`, `PoolFunded`, `PoolWithdrawn` | the pool functions | |
| `MarketCreated`, `ConfigUpdated`, `PauseChanged`, `HaltChanged`, `PoolFloorUpdated`, `RecipientsUpdated`, `RefundDelayUpdated`, `CircuitBreakerUpdated`, `CircuitBreakerTripped`, `CircuitBreakerReset` | the admin functions, and the breaker's trip | |

**Reading them:**
- **`positionId` and `user` are indexed** on every position event, so you can filter by either.
- **`MarketCreated`, `ConfigUpdated` and `PauseChanged` carry the leverage right after the market id**, both indexed,
  so you can filter by the pair.
- **The four position events end with the bet's leverage,** unindexed: `PositionOpened` already has three indexed
  topics. Read it from the data.
- **Read at the `finalized` block tag** (or at least `safe`), and key each log by `(transactionHash, logIndex)`.
- **A reverted transaction emits nothing.**
- **The ending events come before their payout's transfer** in the same transaction. The ending event says what the
  user is owed now; a `PayoutDeferred` right after it says the transfer waited.

---

## 11. Errors, and what to do about them

Every error is a custom error. Their selectors are in [abi-reference.md](abi-reference.md). Errors raised for one
position inside a batch carry its id.

| Error | Meaning | What to do |
|---|---|---|
| `AccessControlUnauthorizedAccount(account, role)` | the caller lacks the role | use the right relayer key |
| `Halted` | the contract is halted | wait for the operator |
| `LeverageDisabled`, `LeveragePaused` | the market is off or paused | stop opening and selling on it |
| `BreakerTripped` | the payout circuit breaker tripped | wait for the operator's reset |
| `OrderExpired` | past the order's `deadline` | ask the user to sign again |
| `PositionIdUsed` | the id is zero or was used before | choose a new id, and a new signature |
| `InvalidSignature` | the order isn't signed by its user (or, for `open`, USDG refused the stake authorisation, which uses the same error name) | check the order against `hashOpenOrder`/`hashSellOrder`; if that matches, the stake authorisation is the bad one |
| `TransferAmountMismatch(expected, received)` | the stake didn't arrive in full; `(stake, 0)` means the authorisation's nonce was already used or cancelled, which USDG ignores silently | new id and new signatures |
| USDG's own errors (`AddressFrozen`, `ContractPaused`, `AuthorizationExpired`, …) | the stake pull failed | see the message |
| `InvalidAmount`, `InvalidLeverageParams` | the stake, duration, θ, floor or cap is outside the market's bounds | fix the terms |
| `PriceTooOld`, `PriceFromFuture` | the tick is too old, or too far ahead of the chain's clock | use a fresh tick |
| `PriceBeforeOrder` | the tick is before the order's `notBefore` | use a tick at or after it |
| `InvalidPrice` | the price is zero or negative | |
| `OpenBlockedExposure`, `OpenBlockedTotalOwed` | the pool can't cover another bet now | refuse the bet |
| `UnknownMarket` | no market has this feed at this leverage | |
| `UnknownPosition(id)`, `ConfigMismatch(id)` | in a batch: an id never opened, or of another market (another feed, or the same feed at another leverage) | drop the id and resend it in its own market's batch |
| `InvalidPriceTimestamp(id)` | settle: the tick isn't that position's expiry second | settle it with its own second |
| `LiquidateInstead(id)` | settle or sell: the price touches the line | liquidate it at the same tick |
| `LiquidationPriceNotReached(id)`, `InvalidLiquidationWindow(id)` | liquidate: the tick doesn't touch the line, or is outside the bet's life | drop the id |
| `NotExpired` | settle: the tick is more than the clock skew ahead | wait |
| `EmptyBatch`, `BatchSizeTooLarge` | a batch of 0 or more than 100 ids | split the batch |
| `InvalidMaxCount` | `repay` with 0 or more than 50 | |
| `PositionNotOpen` | sell: the position has already ended | |
| `SellWindowClosed` | sell: too early, within the cutoff before the end, or landing at or after the end | at or after the end, settle the bet instead |
| `ValuationAboveCurrentPayout`, `SellAmountExceedsValuation`, `SellFeeTooHigh`, `SellAmountBelowMin` | sell: the quote is out of bounds | fix the quote |
| `QueueNotEmpty`, `SellNotPayable` | sell: someone is owed, or the pool can't pay the whole valuation now | the sale isn't possible now |
| `InsufficientGasForPayout` | a payout had too little gas | resend with a higher gas limit |
| `MathOverflow` | a book counter would overflow its type | should never happen; report it |
| `Panic(0x11)`, the compiler's arithmetic error | a book decrement would underflow, which means an invariant broke | should never happen; report it at once |
| `NothingToClaim` | `claim` for an account with nothing waiting | |
| `OwedOutstanding`, `BelowPoolFloor`, `OpenExposureNotCovered`, `SeedRecoveryExceeded` | `withdraw` refused | |
| `RefundDisabled` | `refundExpired`: the admin has switched the refund off | |
| `RefundTooEarly(id)` | `refundExpired`: that bet's expiry plus the refund delay hasn't passed | wait until `endTime + refundDelaySecs()`, or drop the id and resend |
| `ZeroAddress`, `InvalidTokenDecimals`, `MarketExists`, `OnlyOperatorCanUnpause`, `OnlyOperatorCanUnhalt`, `InvalidRelayerRole`, `InvalidRefundDelay`, `InvalidBreakerParams` | the setup and settings functions ([§8](#8-the-brakes-and-the-settings)) | |

---

## 12. Signing

**The EIP-712 domain** (the contract's `eip712Domain()` returns it):

| Field | Value |
|---|---|
| `name` | `Manic Flash Option` |
| `version` | `1` |
| `chainId` | the deployment's chain: 46630 (Robinhood testnet) or 4663 (mainnet) |
| `verifyingContract` | the proxy's address |

**The type strings**, exactly (the field order is the struct's; `side` is a `uint8`):

```text
OpenOrder(bytes32 positionId,address user,bytes32 marketId,uint16 leverage,uint8 side,uint64 stake,uint16 durationSecs,uint48 notBefore,uint48 deadline)
SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)
```

with the type hashes `0xfdf5c145d2145b57fd84fa99ed38082c86b234326f84c1896eb2894e43e0b85b` (`OpenOrder`) and
`0x927542b7482a808b01930cc9195eb224106f6615ad2d9ae39be4b84a9229f83b` (`SellOrder`). The digest is
`keccak256(0x1901 ‖ domainSeparator ‖ structHash)`; `hashOpenOrder` and `hashSellOrder` return it for a deployment.

**The signature format:**
- **From an EOA:** 65 bytes, `r ‖ s ‖ v`, with `v` = 27 or 28 and a low `s`. A 64-byte compact (EIP-2098) signature,
  a `v` of 0 or 1, and a high `s` are refused.
- **From a contract wallet:** checked through its ERC-1271 `isValidSignature`.
- **Order of checks:** ECDSA first, then ERC-1271, so an EOA with EIP-7702 code still signs with its own key.

**The vectors:**
- `test/fixtures/eip712_vectors.json` gives the type hashes, a domain separator and, for each order, its struct hash,
  digest and signature. They were made with Foundry's `cast` (alloy's EIP-712) and the public Anvil test key 0. The
  open orders are at 1000x, 500x and 100x, plus one with every field at its widest.
- **Your signer must reproduce every hash and signature in it before integrating.**
- `test/fixtures/README.md` says how they were made.

---

## 13. Deployments

Nothing is deployed from this repository yet. Once a chain is deployed, its record,
`deployments/<chainId>.json`, holds the proxy's address (the one every call and event uses), the implementation, the
token and the block to read events from ([deployments/README.md](../deployments/README.md)).

| Chain | Id | USDG | Record |
|---|---|---|---|
| Robinhood Chain testnet | 46630 | a mock with USDG's behaviour (`script/DeployMockUsdg.s.sol`), since the testnet has none | `deployments/46630.json`, once deployed |
| Robinhood Chain | 4663 | Paxos USDG | `deployments/4663.json`, once deployed |

Robinhood Chain allows contracts up to 98,304 bytes, and this one fits. Its blocks are about 0.1 seconds apart, with
timestamps in whole seconds, so many blocks share a `block.timestamp`.
