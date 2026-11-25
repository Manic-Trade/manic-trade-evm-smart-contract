# 0003: A payout circuit breaker that stops opens and sales

**Status:** Accepted · **Date:** 2026-11-09

## Context
There is no on-chain oracle: the backend's relayer key supplies every price. In July 2026 Ostium, an Arbitrum
perps protocol with nearly this model, lost about $18M when its price key was stolen and used to open positions
at fake prices and close them at real ones. Anyone can create user wallets and sign orders, so a stolen opener or
settler key could do the same here, up to the pool's free money.

## Decision
- Each ending adds the profit paid to users and the losses kept by the pool to counters in a fixed window.
- When profit paid exceeds losses kept by more than `maxNetProfit`, the breaker trips, and `open` and `sell`
  revert with `BreakerTripped`. Liquidate, settle, repay, refund and claim keep working, so honest winners
  are still paid.
- The operator resets it with `resetBreaker()` after checking what happened. Changing or disabling the
  limit (`setBreaker`) goes through the timelocked admin.

## Consequences
- The most a stolen key can take is about one window's limit (up to twice across a window boundary),
  instead of the whole free pool.
- A legitimate run of winners can also trip it. That pauses new business, not payouts, until someone checks.
- About 1 day of work. Gas: two warm storage writes per batch, not per position.

## Alternatives considered
- **A per-market bound on how far the price may move between ticks:** limits fake prices directly, but needs
  one more slot per market and tuning against real volatility. Left for a later version.
- **Relying only on the guardian's manual halt:** too slow against an automated drain.
