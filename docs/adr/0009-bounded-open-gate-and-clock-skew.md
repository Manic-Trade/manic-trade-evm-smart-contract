# 0009: Bound the open gate and the clock skew in `validate`

**Status:** Accepted · **Date:** 2026-11-19

## Context
- `validate` bounds a market's payout settings: the lines, the floors, the caps and the early-sell fee's cap. It left
  two settings unbounded:
  - the open gate (`maxExposureBps`), where 0 switches the gate off;
  - the clock skew (`clockSkewSecs`), up to 255 seconds in a `uint8`.
- The operator sets both through `setConfig`. On mainnet the operator is the admin Safe, and it acts at once, with no
  timelock (ADR 0005).
- The blast-radius tests of the access-control suite (`test/access/KeyBlastRadius.t.sol`) showed what a leaked
  operator key could do with them:
  - switch the gate off or above 100%, so bets can promise more than the pool holds, and winners are owed IOUs;
  - set a 255-second skew, so a settler key can settle bets up to 255 seconds before they end.
- The launch values are a gate at 100% (`maxExposureBps` 10,000) and a 5-second skew. With the gate at 100% or less,
  free money always covers the open bets' max profit, so nobody is ever owed (ARCHITECTURE §12, invariant 5).

## Decision
- **`validate` also requires `0 < maxExposureBps ≤ 10_000` and `clockSkewSecs ≤ 30`**
  (`ConfigLib.MAX_CLOCK_SKEW_SECS`). These checks come after every other check, beside the price-age check
  (`entryMaxAgeSecs > 0`), in `ConfigLib.withinEvmBounds`. The refusal is the same error, `InvalidLeverageParams`.
- **The skew bound is 30 seconds:** six times the launch value, and half the shortest bet (60 seconds).
  - A skew lets a tick be that far ahead of the chain's clock, so a bet can be settled that early.
  - A lower skew only delays opens and settles while the chain's clock lags, so a low bound fails safe.
- **`LeverageMath.openGate` keeps "0 = off".** The maths doesn't change; only the settings check does.

## Consequences
- **A leaked operator key is bounded.** It can no longer let bets in beyond full cover, or let a settler key settle
  more than 30 seconds early. The loosest settings it can set are the gate at 100% and a 30-second skew (the
  operator's blast-radius test).
- **No IOU can form while the code is as deployed.**
  - The IOU queue, `repay` and `maxTotalOwed` stay in the code, as a backstop: an upgrade, behind the 48-hour timelock,
    could switch the gate off again.
  - Their tests reach that state by writing the gate straight into storage (`test/utils/LayoutWriter.sol`).
- **Invariant 5 holds for the whole of the main stateful campaign.** Only the $20-pool campaign, which switches its
  gates off in storage, takes it out of play.
- **No ABI or storage change.** The contract grows by 117 bytes.

## Alternatives considered
- **Refuse only a gate above 100%.** It still lets the operator set 0, which switches the gate off, so it doesn't
  close the hole the blast-radius tests found.
- **An admin-only setter for the gate.** It would keep over-exposure possible, behind the 48-hour timelock, at the cost
  of a new function, an ABI change and a row in the access matrix. Nothing planned needs over-exposure, and an upgrade
  can add it if something ever does.
- **A skew bound of 10 or 60 seconds.**
  - 10 seconds leaves less room if the sequencer's clock lags.
  - 60 seconds would let a settle come a whole shortest bet early.
- **Leave both unbounded, and rely on the Safe's signers and monitoring.** The operator acts at once, so a leaked key
  would act before anyone could react.
