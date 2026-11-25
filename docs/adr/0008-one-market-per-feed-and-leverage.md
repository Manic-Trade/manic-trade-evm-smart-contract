# 0008: One market per price feed and leverage, and the leverage in the signed order

**Status:** Accepted · **Date:** 2026-11-17

## Context
- The Flash Option lets the user choose the leverage: any whole number from 1x to 10,000x, instead of a fixed 1000x.
  BTC is to run at 1000x, 500x and 100x side by side, each with its own settings (the 500x and 100x tier settings
  have their own floors, caps and lines).
- The maths already takes the leverage as an input (`lines`, `capLine`, `gBps`, `ConfigLib.validate`), but every
  market is still 1000x (`LAUNCH_LEVERAGE`).
- The user signs only an EIP-712 order (ADR 0002, ARCHITECTURE §7), and the relayer picks the rest of the call. A
  leverage outside the order would be the relayer's choice, not the user's.
- Nothing is deployed yet, so the storage layout can still change without a migration.

## Decision
- **A market is a feed at one leverage.** `Market` gains `uint16 leverage`, set by `createMarket` and never changed:
  with `marketId` it is the market's key. `marketIndexPlusOne` is keyed by `keccak256(abi.encode(marketId,
  leverage))`.
- **The field goes into 2 of `Market` slot 2's 16 unused bytes,** after `maxTotalOwed`, so no field moves and the
  mapping keeps its type. OpenZeppelin's layout check accepts it against `dev`. ARCHITECTURE §5 rule 1 ("append only")
  forbids such an insert once a version is deployed; this one is allowed because none is. From the first deployment
  on, rule 1 applies without exception.
- **`createMarket`, `setConfig`, `setPaused`, `liquidate`, `settle` and `getMarket` take the pair; `marketIdAt`
  returns it.** `createMarket` checks the settings at the market's leverage; `setConfig` at its own. A batch holds one
  market, so a position of another leverage reverts `ConfigMismatch(id)`.
- **`OpenOrder` gains `uint16 leverage`, right after `marketId`,** so the user's signature covers it, and `open` finds
  its market from the order's pair. The type string and type hash change, and so does every signing vector.
- **`MarketCreated`, `ConfigUpdated` and `PauseChanged` carry the leverage right after the market id, indexed,** so
  an indexer can filter by the pair.
- **Each bet keeps its own copy of the leverage:** `Position.leverage`, in slot 1's unused bytes, an insert of the
  same kind, allowed for the same reason.

## Consequences
- BTC can run 1000x, 500x and 100x side by side on one pool, each with its own floors, caps, lines, stakes and pause.
  The halt still stops every market at once.
- The backend groups batches by market (feed and leverage), names the leverage in every admin call, and signs it in
  every order. Its signer must reproduce the new vectors (`test/fixtures/eip712_vectors.json`) before integration.
- 10 of the 58 functions change their interface: 7 directly, and `open`, `hashOpenOrder` and `getPosition` through
  their structs. The ABI files are regenerated.
- Gas:
  - each market lookup hashes the pair first: one more `keccak256` of 64 bytes (42 gas for the hash itself);
  - `open` already reads the market's slot 2, where the leverage sits;
  - a batch and a sale would read slot 2 too, one cold storage read (2,100 gas) per batch or sale. The bet's own copy
    of the leverage avoids it: it sits in the bet's slot 1, which both read anyway (measured at the largest call:
    `settle` 1,452 gas less, `sell` 1,644, `liquidate` 1,537).

## Alternatives considered
- **A new storage field, `mapping(bytes32 => mapping(uint16 => uint16))`, instead of hashing the pair into the
  existing mapping:** clearer to read, but it appends a field to `Layout` and leaves `marketIndexPlusOne` keyed
  differently for each version. The hash keeps one mapping and one lookup.
- **The leverage outside the signed order** (the relayer names the market): fewer changes for the backend's signer,
  but a relayer, or a leaked relayer key, could open a user's bet at another leverage. The user's choice must be
  signed.
- **Appending `leverage` to `Market` after `durations`:** follows rule 1 literally, but puts it in a slot of its own,
  a ninth, read on every open and batch. Nothing is deployed, so the cheaper place is free to take.
- **A separate market id per leverage** (for example the feed id hashed with the leverage as `marketId`): one
  argument fewer, but the market would no longer carry the feed id the backend and the oracle use.
