# Storage layout

All of the contract's state lives in one ERC-7201 namespace. This page is its slot map, field by field, exactly
as the compiler lays it out, plus the functions that write each field.

- **The rules for changing it:** [ARCHITECTURE.md §5](ARCHITECTURE.md#5-storage-order-rules).
- **The code:** [`src/base/FlashOptionStorage.sol`](../src/base/FlashOptionStorage.sol) and
  [`src/types/StorageTypes.sol`](../src/types/StorageTypes.sol).

**How the layout is checked:**
- [`test/unit/FlashOptionStorage.t.sol`](../test/unit/FlashOptionStorage.t.sol) writes every field through the
  contract's own storage pointer and reads the raw 32-byte words back. CI fails if a field moves, grows or shrinks.
- The tables below are the compiler's output. [Regenerating them](#regenerating-these-tables) shows how to
  rebuild them.
- CI runs the OpenZeppelin upgrades plugin on every change
  ([`test/upgrade/layout/`](../test/upgrade/layout/README.md)): the layout must match the commit the change is based
  on, and every deployed version. It is the only check that notices if the `@custom:storage-location` annotation is
  lost.

**Reading the tables:**
- Slots are counted from the start of the struct (for `Layout`, from the namespace slot).
- "Byte" is the offset from the low-order end of the 32-byte word: Solidity packs a slot from its lowest-order
  bytes up, so the first field declared sits at the right-hand end of the word.
- "Written by" lists the functions that write each field (ARCHITECTURE §8–§9).

## The namespace

| | |
|---|---|
| Id | `manic.storage.FlashOption` |
| Annotation | `/// @custom:storage-location erc7201:manic.storage.FlashOption` on `FlashOptionStorage.Layout` |
| Formula | `keccak256(abi.encode(uint256(keccak256("manic.storage.FlashOption")) - 1)) & ~bytes32(uint256(0xff))` |
| Slot | `0xf273be9a24eeab036a40c6c3509d6aa7cccb8da2ecbd9965c4f2a996a54c2200` |

`cast index-erc7201 manic.storage.FlashOption` prints the slot, and the unit test recomputes it. The OpenZeppelin
bases keep their own state in their own namespaces, so nothing else is ever near it.

## `Layout`: 14 slots

| Slot | Byte | Size | Field | Type | Written by |
|---|---|---|---|---|---|
| 0 | 0 | 20 | `token` | `IERC20` | `initialize` |
| 0 | 20 | 1 | `tokenDecimals` | `uint8` | `initialize` |
| 0 | 21 | 1 | `halted` | `bool` | `setHalted` |
| 0 | 22 | 2 | `marketCount` | `uint16` | `createMarket` |
| 0 | 24 | 6 | `refundDelaySecs` | `uint48` | `initialize`, `setRefundDelay` |
| 1 | 0 | 20 | `feeRecipient` | `address` | `initialize`, `setRecipients` |
| 2 | 0 | 20 | `rewardsRecipient` | `address` | `initialize`, `setRecipients` |
| 3–6 | | 128 | `pool` | `PoolState` | [below](#poolstate-layout-slots-36) |
| 7–8 | | 64 | `breaker` | `Breaker` | [below](#breaker-layout-slots-78) |
| 9 | | 32 | `markets` | `mapping(uint16 => Market)` | `createMarket`, `setConfig`, `setPaused` |
| 10 | | 32 | `marketIndexPlusOne` | `mapping(bytes32 => uint16)`, keyed by `keccak256(abi.encode(marketId, leverage))` | `createMarket` |
| 11 | | 32 | `positions` | `mapping(bytes32 => Position)` | `open`, `sell`, `liquidate`, `settle`, `repay`, `refundExpired` |
| 12 | | 32 | `iouQueue` | `mapping(uint64 => bytes32)` | `settle` (adds an IOU), `repay` (removes it once fully repaid) |
| 13 | | 32 | `claimable` | `mapping(address => uint64)` | `_pay`, when a payout's transfer is refused (adds); `claim` (pays out) |

- Slot 0 has 2 bytes free.
- A mapping's root slot holds nothing: entry `key` lives at `keccak256(abi.encode(key, rootSlot))`.
- New fields go after `claimable` only. `pool` and `breaker` are embedded structs, so they can never grow.

## `PoolState`: Layout slots 3–6

| Slot | Byte | Size | Field | Written by |
|---|---|---|---|---|
| 3 | 0 | 8 | `total` | `open`, `liquidate`, `settle`, `sell`, `repay`, `refundExpired`, `fund`, `withdraw` |
| 3 | 8 | 8 | `lockedMargin` | `open`, `liquidate`, `settle`, `sell`, `refundExpired` |
| 3 | 16 | 8 | `openMaxProfit` | `open`, `liquidate`, `settle`, `sell`, `refundExpired` |
| 3 | 24 | 8 | `totalOwed` | `settle`, `repay` |
| 4 | 0 | 8 | `poolFloor` | `initialize`, `setPoolFloor` |
| 4 | 8 | 8 | `nextQueueSeq` | `settle` (a new IOU) |
| 4 | 16 | 8 | `nextRepaySeq` | `repay` (an IOU fully repaid) |
| 4 | 24 | 4 | `openPositions` | `open`, `liquidate`, `settle`, `sell`, `refundExpired` |
| 4 | 28 | 4 | `owedPositions` | `settle`, `repay` |
| 5 | 0 | 8 | `feesPending` | `liquidate`, `settle`, `sell`, `repay` (accrue); `sweepFees` (sends) |
| 5 | 8 | 8 | `totalClaimable` | `_pay`, when a payout's transfer is refused (adds); `claim` |
| 5 | 16 | 8 | `transferred` | `settle`, `sell`, `repay`, `refundExpired` |
| 5 | 24 | 8 | `feesPaid` | `liquidate`, `settle`, `sell`, `repay` |
| 6 | 0 | 8 | `seedRecovered` | `withdraw(SeedRecovery)` |
| 6 | 8 | 8 | `rewardsWithdrawn` | `withdraw(Rewards)` |

Slot 6 has 16 bytes free, which stay unused because the struct can't grow. Every open and every ending writes
slot 3.

## `Breaker`: Layout slots 7–8

| Slot | Byte | Size | Field | Written by |
|---|---|---|---|---|
| 7 | 0 | 8 | `profitOut` | `settle`, `sell`, `repay` (count); a new window and `resetBreaker` (zero) |
| 7 | 8 | 8 | `lossIn` | `settle`, `liquidate`, `sell` (count); a new window and `resetBreaker` (zero) |
| 7 | 16 | 6 | `windowStart` | a new window, `resetBreaker` |
| 7 | 22 | 1 | `tripped` | the count that trips it; `resetBreaker` clears it |
| 7 | 23 | 4 | `windowSecs` | `initialize`, `setBreaker` |
| 8 | 0 | 8 | `maxNetProfit` | `initialize`, `setBreaker` |

**Why this order.** Everything a batch updates is in slot 7, so counting a batch writes one slot. The limit, which
only `initialize` and `setBreaker` write, comes last. Put first, ahead of the window start, the trip flag and the
window length (19 bytes in all), it would split the counters: the compiler packs greedily, so `profitOut` would still
fit in the first slot and only `lossIn` would reach the second, and a batch would write two slots. The slot-map test
proves the order.

## `Market`: 8 slots per entry of `markets`

| Slot | Byte | Size | Field | Written by |
|---|---|---|---|---|
| 0 | 0 | 32 | `marketId` | `createMarket` |
| 1 | 0 | 1 | `enabled` | `createMarket` (off), `setConfig` |
| 1 | 1 | 1 | `paused` | `setPaused` |
| 1 | 2 | 1 | `priceExponent` | `createMarket` only |
| 1 | 3 | 1 | `entryMaxAgeSecs` | `createMarket`, `setConfig` |
| 1 | 4 | 1 | `clockSkewSecs` | `createMarket`, `setConfig` |
| 1 | 5 | 2 | `floorMinBps` | `createMarket`, `setConfig` |
| 1 | 7 | 2 | `floorMaxBps` | `createMarket`, `setConfig` |
| 1 | 9 | 2 | `capMinBps` | `createMarket`, `setConfig` |
| 1 | 11 | 2 | `capMaxBps` | `createMarket`, `setConfig` |
| 1 | 13 | 2 | `maxSellFeeBps` | `createMarket`, `setConfig` |
| 1 | 15 | 2 | `sellMinDelaySecs` | `createMarket`, `setConfig` |
| 1 | 17 | 2 | `sellCutoffSecs` | `createMarket`, `setConfig` |
| 1 | 19 | 4 | `maxExposureBps` | `createMarket`, `setConfig` |
| 1 | 23 | 8 | `minStake` | `createMarket`, `setConfig` |
| 2 | 0 | 8 | `maxStake` | `createMarket`, `setConfig` |
| 2 | 8 | 8 | `maxTotalOwed` | `createMarket`, `setConfig` |
| 2 | 16 | 2 | `leverage` | `createMarket` only: with `marketId`, the market's key |
| 3–7 | | 160 | `durations` | `createMarket`, `setConfig` (one `DurationRule` per slot) |

Slot 1 holds everything read on every open and sale (31 of 32 bytes), so those reads cost one storage read.

`leverage` uses 2 of slot 2's spare bytes, so a market needs no ninth slot (ADR 0008). Slot 2 has 14 bytes free.

## `DurationRule`: 1 slot, 5 per market

| Byte | Size | Field |
|---|---|---|
| 0 | 2 | `durationSecs` |
| 2 | 4 | `thetaMinE7` |
| 6 | 4 | `thetaMaxE7` |
| 10 | 1 | `enabled` |

## `Position`: 3 slots per entry of `positions`

| Slot | Byte | Size | Field | Written by |
|---|---|---|---|---|
| 0 | 0 | 20 | `user` | `open` |
| 0 | 20 | 2 | `marketIdx` | `open` |
| 0 | 22 | 1 | `side` | `open` |
| 0 | 23 | 1 | `status` | `open`, then each ending (`liquidate`, `settle`, `sell`, `repay`, `refundExpired`) |
| 0 | 24 | 6 | `startTime` | `open` |
| 0 | 30 | 2 | `durationSecs` | `open` |
| 1 | 0 | 8 | `stake` | `open`; cleared when the position closes |
| 1 | 8 | 8 | `entryPrice` | `open`; cleared when the position closes |
| 1 | 16 | 8 | `liqPrice` | `open`; cleared when the position closes |
| 1 | 24 | 2 | `floorBps` | `open`; cleared when the position closes |
| 1 | 26 | 2 | `capBps` | `open`; cleared when the position closes |
| 1 | 28 | 2 | `leverage` | `open`, copied from the market; cleared when the position closes |
| 2 | 0 | 8 | `owed` | `settle` (becomes an IOU), `repay` |
| 2 | 8 | 8 | `queueSeq` | `settle` (becomes an IOU); cleared by `repay` when the IOU is paid in full |

- **Slot 0 is exactly full.** It is never cleared: with `status = Closed` it is the tombstone that stops a
  `positionId` from being opened twice.
- **Slot 1** has 2 bytes free. Clearing it at the end gives a gas refund. It is kept while the position is an IOU,
  so an IOU keeps its leverage.
- **`leverage`** uses 2 of slot 1's spare bytes, so a bet needs no fourth slot (ADR 0008). A closed position's
  leverage stays readable through its `marketIdx`.
- **Slot 2** is written only for an IOU, and cleared again when `repay` pays it in full.

## Other namespaces in the proxy

The proxy also holds the state of the OpenZeppelin bases of `FlashOptionBase`, each in its own ERC-7201
namespace. Each slot is `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`, as with
ours, so none can overlap. The values are copied from the OpenZeppelin 5.6.1 sources in `lib/`.

| Namespace id | Slot | Holds |
|---|---|---|
| `openzeppelin.storage.Initializable` | `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00` | the initialized version (1) and the "initializing" flag |
| `openzeppelin.storage.AccessControl` | `0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800` | every role's members and admin role |
| `openzeppelin.storage.AccessControlDefaultAdminRules` | `0xeef3dac4538c82c8ace4063ab0acd2d15cdb5883aa1dff7c2673abb3d8698400` | the default admin, its pending transfer and the transfer delay |
| `openzeppelin.storage.EIP712` | `0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100` | the domain's name (`"Manic Flash Option"`) and version (`"1"`) |
| `openzeppelin.storage.ReentrancyGuard` | `0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00` | **transient storage only**: the guard's flag lives for one transaction and is never persisted |

`UUPSUpgradeable` is stateless. The implementation's address sits in the ERC-1967 slot
(`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`), which the proxy owns.

## Regenerating these tables

`forge inspect FlashOptionStorage storageLayout` shows nothing, because namespaced storage isn't a state variable. A
throwaway probe that declares `Layout` as a plain state variable makes the compiler report it:

```bash
cat > test/harnesses/LayoutProbe.sol <<'EOF'
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {FlashOptionStorage} from "../../src/base/FlashOptionStorage.sol";

contract LayoutProbe is FlashOptionStorage {
    Layout internal probe;
}
EOF
forge inspect test/harnesses/LayoutProbe.sol:LayoutProbe storageLayout --json   # see "types": members, slots, offsets
rm test/harnesses/LayoutProbe.sol
```

A struct's internal layout doesn't depend on where it starts, so the probe's slots and offsets equal the
namespace's, counted from the namespace slot.
