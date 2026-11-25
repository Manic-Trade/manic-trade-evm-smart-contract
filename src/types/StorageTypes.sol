// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

// The types stored in the contract's storage, or carried in its events. This file is FROZEN once deployed: a stored
// struct or enum may only gain members at the end, never be reordered or changed, because storage is read by
// position (docs/CONVENTIONS.md §2, docs/ARCHITECTURE.md §5). Structs embedded in another struct (`DurationRule` in
// `Market`; `PoolState` and `Breaker` in `Layout`) can't gain members at all, because that would shift every field
// declared after them.
// The `// slot N` maps are part of the design: test/unit/FlashOptionStorage.t.sol writes every field and reads the raw
// storage words back, so a reordered or resized field fails CI.

/// @notice The direction of a bet: Call wins when the price rises ("Higher", a long), Put wins when it falls
///         ("Lower", a short).
/// @dev Stored as a `uint8` inside each position, so members can only ever be appended.
enum Side {
    Call,
    Put
}

/// @notice What an admin withdrawal from the pool is for. Both need the pool above its floor and nobody owed.
/// @dev `SeedRecovery`: taking back the launch seed, at most 500 whole tokens in total, to the fee recipient.
///      `Rewards`: surplus paid back to users (for example competitions), to the rewards recipient. Carried as a
///      `uint8` in the withdrawal event, so members can only ever be appended.
enum WithdrawPurpose {
    SeedRecovery,
    Rewards
}

/// @notice Where a position is in its life: None → Open → (Owed →) Closed. A status only ever moves forward.
/// @dev `None`: the id was never used. `Open`: running, its stake held in the pool. `Owed`: ended as a winner the
///      pool couldn't pay in full, with an IOU in the repay queue. `Closed`: finished. A finished position's slot 0
///      stays behind with `Closed` as a tombstone, so a `positionId`, which is also the order's nonce, can never be
///      opened twice. Stored as a `uint8`, so members can only ever be appended.
enum Status {
    None,
    Open,
    Owed,
    Closed
}

/// @notice An allowed position duration and the range of liquidation distances θ a bet of that length may have.
///         Longer bets get wider lines, since the price wanders further.
/// @dev One slot (11 of 32 bytes). Embedded five times in `Market`, so it can never gain a field. The duration is a
///      `uint16`: it allows up to about 18 hours, far more than the 1 to 5 minutes offered, and keeps `Position`
///      slot 0 at exactly 32 bytes.
struct DurationRule {
    // slot 0 (11 bytes)
    uint16 durationSecs; // the bet's length, e.g. 60; 0 marks an unused slot, whose fields must then all be 0
    uint32 thetaMinE7; // the narrowest liquidation distance θ (× 1e7) for this length
    uint32 thetaMaxE7; // the widest; θ × leverage < 1e7, so under 10 bp at 1000x
    bool enabled; // a disabled rule is kept, and still validated, but no new bet can use it
}

/// @notice One market's settings: the bounds every bet on it is checked against. One per price feed and leverage
///         (ADR 0008), in `Layout.markets`: BTC can have a 1000x, a 500x and a 100x market, each with its own
///         settings.
/// @dev 8 slots. Slot 1 holds everything read on every open and sale. A market holds no token and no keys of its
///      own: the token is global, and the roles act on every market. `ConfigParams` (types/ParamTypes.sol) is this
///      struct without `marketId`, `paused`, `priceExponent` and `leverage`.
struct Market {
    // slot 0
    bytes32 marketId; // the Pyth feed id
    // slot 1: read on every open and sale (31 bytes)
    bool enabled; // off at creation; while off, nobody can open or sell (open positions still end)
    bool paused; // the per-market brake: stops open and sell only
    int8 priceExponent; // set at creation and never changed (BTC: -8)
    uint8 entryMaxAgeSecs; // how old the price tick of an open or a sale may be
    uint8 clockSkewSecs; // how far ahead of the chain's clock a tick's time may be; at most 30
    uint16 floorMinBps; // the range of floors, the least a right call pays (13_000 = 1.3x)
    uint16 floorMaxBps;
    uint16 capMinBps; // the range of caps, the most a bet pays (40_000 = 4x)
    uint16 capMaxBps;
    uint16 maxSellFeeBps; // the largest early-sell fee, as a share of the valuation (600 = 6%)
    uint16 sellMinDelaySecs; // a sale is allowed from start + this...
    uint16 sellCutoffSecs; // ...until more than this before the end
    uint32 maxExposureBps; // open gate: open max profit ≤ free money × this / 10_000; 1 to 10_000 (launch: 10_000)
    uint64 minStake; // the smallest stake, in base units
    // slot 2 (18 bytes)
    uint64 maxStake; // the largest stake, in base units
    uint64 maxTotalOwed; // open gate: new bets are blocked while total owed exceeds this
    uint16 leverage; // 1x to 10,000x; with marketId, the market's key, so set at creation and never changed
    // slots 3-7
    DurationRule[5] durations; // the allowed durations; unused rules are all zero
}

/// @notice One bet, in `Layout.positions` under its `positionId`.
/// @dev 3 slots. Slot 0 is exactly 32 bytes and stays forever as the tombstone. Slot 1 is cleared when the position
///      closes (a gas refund). Slot 2 is written only if the position becomes an IOU.
///      Not stored:
///      - the position id, which is the mapping key, and the feed, which `marketIdx` leads to;
///      - the cap price and θ, which are never read after the open, so they are only in the `PositionOpened` event
///        (the `getPosition` view recomputes the cap price);
///      - the end time, which is `startTime + durationSecs`.
struct Position {
    // slot 0: kept forever as the tombstone (32 bytes)
    address user; // the bettor; every payout goes here, or to claimable[user]
    uint16 marketIdx; // the market's index in Layout.markets; batches check it (ConfigMismatch)
    Side side; // Call = Higher, Put = Lower
    Status status; // None → Open → (Owed →) Closed
    uint48 startTime; // the entry tick's publish time
    uint16 durationSecs; // endTime = startTime + durationSecs
    // slot 1: cleared when the position closes (30 bytes)
    uint64 stake; // the margin, held in the pool while the position is open
    int64 entryPrice; // the entry tick's price, at the market's exponent
    int64 liqPrice; // touching this price (equality counts) liquidates the bet
    uint16 floorBps; // the least a right call pays, in bps of the stake
    uint16 capBps; // the most the bet pays, in bps of the stake
    uint16 leverage; // copied from the market at open; settle and sell pay at it
    // slot 2: written only if the position becomes an IOU (16 bytes)
    uint64 owed; // the profit still to repay
    uint64 queueSeq; // the IOU's place in the repay queue
}

/// @notice The pool's books.
/// @dev 4 slots, embedded in `Layout`, so it can never gain a field: new pool data goes at the end of `Layout`
///      instead. Free money (`total - lockedMargin`) is computed each time, never stored. `feesPending` and
///      `totalClaimable` are kept apart from `total`: fees accrue and are swept separately, and payouts that fail
///      wait in `claimable`.
struct PoolState {
    // slot 0: written by every open and every ending
    uint64 total; // held stakes + free money (excludes feesPending and totalClaimable)
    uint64 lockedMargin; // the sum of the open positions' stakes
    uint64 openMaxProfit; // the sum of stake × (cap - 1) over open positions, for the exposure gate
    uint64 totalOwed; // the sum of `owed` over IOUs
    // slot 1
    uint64 poolFloor; // free money below which no loser fee is taken and no withdrawal may go (≥ 500 tokens)
    uint64 nextQueueSeq; // the queue number the next IOU gets
    uint64 nextRepaySeq; // the queue number of the head, the next IOU to repay
    uint32 openPositions; // the number of open positions
    uint32 owedPositions; // the number of IOUs still owed
    // slot 2
    uint64 feesPending; // fees accrued and not yet swept to the fee recipient
    uint64 totalClaimable; // the sum of claimable[]
    uint64 transferred; // cumulative amount credited to users, pushed or made claimable
    uint64 feesPaid; // cumulative fees taken out of `total`
    // slot 3 (the other 16 bytes stay unused: this struct can't grow)
    uint64 seedRecovered; // cumulative seed recovery; never above 500 whole tokens
    uint64 rewardsWithdrawn; // cumulative rewards withdrawals
}

/// @notice The payout circuit breaker's counters and limit (docs/ARCHITECTURE.md §8.11).
/// @dev 2 slots, embedded in `Layout`, so it can never gain a field. It trips when the profit paid out in one window
///      exceeds the losses kept by more than `maxNetProfit` (ADR 0003), and then blocks open and sell until the
///      operator resets it. Ordered by access (§5 rule 7): everything a batch updates is in slot 0, so counting a
///      batch writes one slot. `maxNetProfit` doesn't fit beside it, so it alone takes slot 1, which only
///      `setBreaker` writes.
struct Breaker {
    // slot 0: the current window, the only slot a counted batch writes (27 bytes)
    uint64 profitOut; // the profit paid to users in this window
    uint64 lossIn; // the losers' losses kept by the pool in this window
    uint48 windowStart; // the start of the current fixed window
    bool tripped; // true = open and sell blocked until the operator resets it
    uint32 windowSecs; // the window's length: 60 ≤ windowSecs ≤ 86_400
    // slot 1
    uint64 maxNetProfit; // net profit allowed out per window, in base units; 0 = off
}
