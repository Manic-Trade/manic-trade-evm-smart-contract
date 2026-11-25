# Manic Flash Option: contract architecture

**Status:** v1.0.0. Not yet deployed from this repository; deployments are recorded in `deployments/` when they
happen.

**Companion docs:** [MATH.md](MATH.md) (the maths, with worked examples), [storage-layout.md](storage-layout.md),
[integration.md](integration.md), [abi-reference.md](abi-reference.md), [gas.md](gas.md),
[security-checklist.md](security-checklist.md), [CONVENTIONS.md](CONVENTIONS.md), the decision records in
[adr/](adr/) (cited as ADR 0001 to 0009) and the [runbooks](runbooks/).

---

## 0. The product in brief

A **Flash Option** is a short bet, with leverage, on where a price will be when the bet ends.

- **The bet:** a market (a price feed at one leverage: BTC at 1000x, 500x or 100x), a side (Call: the price ends
  higher; Put: lower), a stake in USDG and a duration (1 to 5 minutes at launch).
- **Its lines:** at the entry price, a liquidation line θ away against the bet, a floor (the least a right call pays)
  and a cap (the most it pays, at most 4x the stake). In between, each 1 bp the price moves is worth L bps of the stake
  at leverage L: 10% at 1000x, 5% at 500x, 1% at 100x (§10).
- **How it ends:** *liquidated* when a tick touches the line, the stake staying in the pool (§8.4); *settled* by the
  tick at the expiry second, paying from nothing up to the cap (§8.5); *sold* early at a value the backend quotes,
  less an early-sell fee (§8.3); or *refunded* by anyone if nobody settles it within a delay after expiry (§8.6).

**Who signs what.** The user signs an EIP-712 order with no price in it (market and leverage, side, stake, duration,
`notBefore`, `deadline`) and USDG's EIP-3009 authorisation for exactly the stake; to sell, a sale order with the least
they will take (§7). The backend's relayer keys add the price tick and the terms and send the transaction, so users
never need ETH: opener keys open and sell, separate settler keys liquidate and settle. The relayer is the price
source; the contract checks each tick's age, that it came after the order, and every term against the market's
settings. The admin, upgrader, operator and guardian roles run the markets, the pool and the brakes (§4.2).

**The pool.** One USDG pool holds the open stakes and the free money: winners' profit comes out of the free money, and
losing stakes stay in it. A bet opens only while free money covers every open bet's maximum profit (the open gate,
§8.2); if a winner ever could not be paid in full, the rest would become an IOU, repaid first in, first out (§8.7).
Anyone may fund the pool; only the timelocked admin withdraws, leaving the floor (at least 500 tokens) and every open
bet's maximum profit (§8.1).

**The fees** accrue in the contract, and anyone can sweep them to the fee recipient (§8.8): 2% of the profit actually
paid to a winner; 3% of what a loser loses (the whole stake when liquidated), while free money is at or above the
floor; and the early-sell fee, quoted by the backend (1% + 5% × time left) and capped by the market's `maxSellFeeBps`
(6% at launch). Why each safety feature exists: §14.

---

## 1. Decisions at a glance

| Area | Decision | Why |
|---|---|---|
| Contracts | One implementation `ManicFlashOption`, a pure maths library `LeverageMath` (internal, inlined) and an interface `IManicFlashOption` with every type, event and error (ADR 0006) | One set of books, one event stream, the smallest audit surface |
| Upgrades | **UUPS** (ERC-1822/ERC-1967), OpenZeppelin Contracts-Upgradeable 5.x, behind `ERC1967Proxy` (ADR 0001) | OpenZeppelin's recommended pattern; cheapest per call; the upgrade logic sits in the tested implementation (§4) |
| Storage | One **ERC-7201 namespaced** struct, append-only (§5) | No collisions with the OZ bases; safe upgrades |
| Upgrade and fund authority | On mainnet a 48 h `TimelockController`, run by the admin Safe, holds `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE`: **anything that can move money or change code waits 48 h** (ADR 0005) | Bybit, Radiant and Moby were key compromises, not code bugs; the delay gives the guardian time to halt |
| Admin | `AccessControlDefaultAdminRules`: one admin, two-step transfer with a delay | A wrong address never becomes admin; a pending transfer can be cancelled |
| Roles | timelocked admin, upgrader, operator (admin Safe, instant), guardian (halt, pause, revoke relayer keys: only takes power away), opener, settler | Least privilege; a pause doesn't stop a leaked relayer key, a revoke does |
| Markets | One per price feed and leverage; the leverage is in the signed order (ADR 0008) | BTC at 1000x, 500x and 100x side by side, each with its own settings; no relayer can pick another leverage |
| User consent | EIP-712 orders signed **before** the price; the relayer adds the price | "Commit first, price after", enforced with `notBefore` |
| Price trust | `msg.sender` holds `OPENER_ROLE` (open, sell) or `SETTLER_ROLE` (liquidate, settle) | The backend is the price source; separate keys give separate nonce lanes and a smaller blast radius |
| Stake pull | EIP-3009 `receiveWithAuthorization` for exactly `order.stake`, nonce = `positionId` (ADR 0002) | No standing allowances |
| Amounts / prices / times | `uint64` base units / `int64` at the market's exponent / `uint48` seconds | Four amounts pack per slot with $18 trillion of headroom at 6 decimals; BTC at 1e-8 is about 8.4e12; `Position` slot 0 packs into 32 bytes |
| Payouts | Push first, **pull fallback** (`claimable`) when a transfer fails | A frozen or blocklisted winner can't block a batch or the IOU queue |
| Fees | Accrue in `feesPending`; a permissionless `sweepFees()` sends them | A frozen fee wallet can't block endings |
| Batches | Up to 100 ids; positions already ended are **skipped** with an event | A sale racing a settle can't sink a batch |
| Toolchain | Solidity **0.8.38**, **cancun**, legacy pipeline, OZ **5.6.1**, Foundry **1.8.7**, pinned exactly (§2, ADR 0004) | No known compiler bugs; supported by ArbOS 61; reproducible builds |

---

## 2. Toolchain and versions

Checked on 2026-11-09 against the releases, the official docs and live RPC reads; the reasons are in ADR 0004.

| Item | Pin | Why |
|---|---|---|
| Solidity | **0.8.38**, exact (`foundry.toml`, `pragma solidity 0.8.38;`) | The only release with no known bugs (0.8.36 has four). Re-check `bugs.json` at audit freeze; fallback 0.8.37 |
| EVM target | **`cancun`**, explicit | The lowest target with PUSH0, TSTORE/TLOAD and MCOPY, which OZ ≥ 5.5 needs. ArbOS 61 supports up to `osaka`, so it leaves margin; solc's default is `osaka` since 0.8.31 |
| Pipeline | optimizer, 200 runs, **`via_ir = false`** | Four of 2026's compiler bugs were via-IR only; accurate coverage |
| OpenZeppelin | Contracts and Contracts-Upgradeable **v5.6.1**, submodules at the tag | The newest audited release (5.7.0 isn't); this proxy stays on 5.x for life |
| Foundry / forge-std | **v1.8.7** / **v1.17.0** | v1.9.0 changes bytecode metadata; forge-std 1.17 needs Foundry ≥ 1.8.3 |
| Upgrade checks | openzeppelin-foundry-upgrades **v0.4.4**, `@openzeppelin/upgrades-core` 1.48.0 | The `upgrades` profile (AST, build info, storage layouts, Node.js). CI runs the validator as its own process, before `Upgrade.s.sol`, so no test or deployment needs FFI; `ffi` is on only in that profile |
| Proxy | `ERC1967Proxy` + `UUPSUpgradeable` | OZ 5.6 requires init data at deployment, which suits the same-transaction `initialize` |
| Size limit | **98,304 bytes** of code, 196,608 of initcode (`code_size_limit`: `forge build --sizes` and the test EVM) | Robinhood Chain's limits, probed live on 4663 and 46630 (ADR 0007). On Arbitrum One (24,576 bytes) the contract would need a split |
| Static analysis | Slither 0.11.6, `forge lint`, solhint, `forge fmt --check`, all in CI | Every Slither finding fixed or accepted with its reason (`audit/static-analysis.md`). Aderyn was retired, so it isn't run |
| Not run | Halmos (symbolic proofs of `floorDiv` and the splits), Echidna or Medusa | Candidates for more assurance |

**Chain facts (checked live):**

| | Arbitrum One / Sepolia | Robinhood 4663 / 46630 |
|---|---|---|
| ArbOS | 61 (Elara) | 61 (Elara) |
| Max contract size | 24,576 bytes | 98,304 bytes (initcode 196,608), probed exactly |
| Blocks per second (whole-second timestamps, shared by several blocks) | ~3.7 | ~9.8 |
| Sequencer timestamp bounds | 24 h back / 768 s ahead | 4 days back / 1 h ahead |
| Ordering | Timeboost (200 ms delay outside the express lane) | First come, first served; drops transactions tied to sanctioned addresses |
| `block.number` | an L1 block number | an L1 block number |
| Missing opcodes | BLOBBASEFEE unsupported; PREVRANDAO = 1; BLOBHASH = 0 | same |
| Stablecoin | USDC (EIP-3009, permit) | USDG (6 decimals, EIP-3009, permit); none on testnet, where `MockUSDG` stands in |

- **Solidity 0.9-ready:** no `send` or `transfer`, no virtual modifiers, no comparisons between contract types, no
  identifiers named `at`, `error`, `layout` or `transient`.
- **Each deployed implementation's `build-info` is kept** (`deployments/<chainId>/build-info-v<version>/`) as the next
  upgrade's reference layout.
- **Sequencer and time:** the 5-second freshness window is measured on the sequencer's clock, so the sequencer is
  trusted for it (audit scope). A transaction forced in through L1 during an outage can carry an old
  `block.timestamp`, but every price-carrying function is relayer-only, and short order deadlines expire.
- **Reproducible for years:** the pinned compiler, EVM target and OZ tag, with the CI lockfiles, rebuild
  byte-identical, and no gas amount is hard-coded (no `transfer()` stipend, no fixed gas forwarded). The one gas
  number, `MIN_PAY_GAS`, is a lower bound (§8.8).

---

## 3. Contract layout

### 3.1 Repository `manic-trade-evm-smart-contract`

The layout follows ADR 0006 and `docs/CONVENTIONS.md` §1; each folder's README says what belongs in it.

```text
src/
├── ManicFlashOption.sol         entry: `is` list, constructor, initialize, reinitializers, _authorizeUpgrade, version()
├── base/                        FlashOptionStorage (the ERC-7201 `Layout`; must be a contract: §4.2),
│                                FlashOptionBase (OZ bases, roles, _pay, gates, signature check, books)
├── modules/                     abstract, one per area; never call or override each other:
│                                AdminModule, TradingModule (open, sell), SettlementModule (liquidate, settle,
│                                refundExpired, repay), PoolModule (fund, withdraw, claim, sweepFees), ViewsModule
├── interfaces/                  IManicFlashOption (the ABI, committed as abi/IManicFlashOption.json), one slice per
│                                module, Events, Errors, Roles, external/IUSDG.sol
├── libraries/                   LeverageMath (§10), ConfigLib (§8.1), OrderLib (§7), BreakerLib (§8.11)
└── types/                       StorageTypes (append-only), OrderTypes (= EIP-712 field order), ParamTypes, MathTypes
test/         Base.t.sol, SettlementBase.t.sol, utils/, mocks/, harnesses/ and the suites of §13
model/        MATH.md again, in Python, and the generator of the vectors test/model/ checks (§13)
script/       DeployMockUsdg, Deploy, Configure, Upgrade, Smoke; config/chains.toml, config/MarketSettings.sol
deployments/  <chainId>.json and <chainId>/build-info-v<version>/, written when a deployment happens
abi/          IManicFlashOption.json, kept current by CI;  snapshots/: the gas benchmarks;  audit/: scope and triage
docs/         this file, MATH.md, CONVENTIONS.md, security-checklist.md, storage-layout.md, integration.md,
              abi-reference.md, gas.md, adr/, runbooks/, tools/
```

### 3.2 Inheritance

```solidity
abstract contract FlashOptionStorage { /* Layout + _getFlashOptionStorage() */ }

abstract contract FlashOptionBase is
    IManicFlashOptionEvents,              // our interfaces first, in IManicFlashOption's order (see below)
    IManicFlashOptionErrors,
    IManicFlashOptionRoles,               // the role ids, implemented by public constants
    Initializable,
    UUPSUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardTransient,          // OZ 5.6.1, needs cancun; stateless, so safe behind a proxy
    FlashOptionStorage
{ /* role ids, setting limits, the setters initialize shares with the admin module */ }

abstract contract AdminModule is IManicFlashOptionAdmin, FlashOptionBase { /* each module lists its slice first */ }

contract ManicFlashOption is IManicFlashOption, AdminModule, TradingModule, SettlementModule, PoolModule, ViewsModule {
    /* constructor, initialize, _authorizeUpgrade, version */
}
```
- **Interfaces first.** C3 linearization lists parents from the most basic to the most derived, and our interfaces
  reach `ManicFlashOption` twice (through `IManicFlashOption`, and through the base and the modules), so they come
  first, in one fixed order: the module slices, events, errors, roles, then OpenZeppelin's. With `IManicFlashOption`
  last, compilation fails: "Linearization of inheritance graph impossible".
- Each OZ 5.x base keeps its state in its own ERC-7201 namespace, so the base order doesn't move storage, but it fixes
  the order of initializer calls. `UUPSUpgradeable` 5.6.1 is stateless, with no `__UUPSUpgradeable_init`.
- No contract-level state variables (the only storage is `Layout`, §6.6) and no `immutable`s, which would live in the
  implementation's bytecode, where an upgrade could silently change them.
- `constructor() { _disableInitializers(); }`, so nobody can initialize the implementation itself.

---

## 4. Upgradability

### 4.1 Pattern choice

| Pattern | Verdict |
|---|---|
| **UUPS (chosen)** | A minimal ERC-1967 proxy; `upgradeToAndCall` lives in the implementation behind `_authorizeUpgrade`, so calls pay no admin check. OZ 5 checks the new implementation is UUPS too (`proxiableUUID`), so an upgrade can't remove the upgrade function |
| Transparent | A `ProxyAdmin` per proxy and an admin check on every call, for no benefit here |
| Beacon / Diamond (ERC-2535) | For many proxies sharing an implementation / for contracts over the size limit (a big audit surface) |
| No proxy | The safest code, but no fixes during testnet and early mainnet. Reconsider freezing upgrades once outside liquidity providers arrive |

### 4.2 Who can upgrade, and how

| Network | `UPGRADER_ROLE` holder | Process |
|---|---|---|
| Local / testnet | the deployer EOA (or a 1-of-1 Safe) | `Upgrade.s.sol`: validate the layout, deploy the implementation, `upgradeToAndCall` |
| Mainnet | `TimelockController` (48 h minimum; proposer and executor: the admin Safe; cancellers: the admin Safe and the guardian) | Layout validated in CI → implementation deployed → the Safe schedules `upgradeToAndCall` → 48 h → the Safe executes. Halting needs no timelock |

**Role map (mainnet, ADR 0005):**

| Role | Holder | Delay | Can do |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | timelock | 48 h | grant/revoke roles, `createMarket`, `setRecipients`, `setPoolFloor`, `setRefundDelay`, `setBreaker`, `withdraw`, its own two-step transfer |
| `UPGRADER_ROLE` | timelock | 48 h | `upgradeToAndCall`; separate, so upgrades can be frozen by renouncing it alone |
| `OPERATOR_ROLE` | admin Safe (e.g. 3-of-5, hardware keys) | none | `setConfig`, switch markets on or off, pause and unpause, halt and unhalt, `resetBreaker`; none moves money. `validate` bounds the payout settings, the open gate (1 bp to 100%) and the clock skew (at most 30 s; ADR 0009); the owed limit, price age and sell window are unbounded |
| `GUARDIAN_ROLE` | ops Safe or a monitored ops key | none | `setHalted(true)`, `setPaused(market, true)`, `revokeRelayer(role, account)`: only takes power away |
| `OPENER_ROLE` | backend relayer accounts | — | `open`, `sell` |
| `SETTLER_ROLE` | other backend relayer accounts | — | `liquidate`, `settle` |

**Safe hygiene (from Bybit, Radiant):** hardware wallets, the Safe transaction hash checked on a second device, a guard
that blocks `DELEGATECALL`, no Safe modules; the same for timelock proposals.

- `_authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}` is the only upgrade gate
  (`test/concrete/upgradeToAndCall/`). Role ids are `bytes32 public constant`s (the `keccak256` of each name) in
  `FlashOptionBase`, declared in `IManicFlashOptionRoles`; every role's admin is `DEFAULT_ADMIN_ROLE`; `initialize`
  grants each role, none to the deployer.
- An upgrade that adds state ships an upgrader-only `reinitializer(n)`, called in the same `upgradeToAndCall` (where
  the caller is still the upgrader), so new fields are never unset and nobody else can run it later.
- Each version keeps the name `ManicFlashOption` and carries
  `/// @custom:oz-upgrades-from build-info-v1.0.0:ManicFlashOption`, for a script that upgrades through the plugin;
  CI's layout check names each `deployments/*/build-info-v*/` reference itself. `Upgrade.s.sol` runs after that
  check, then confirms nothing but the implementation changed (every setting, role, market and book).
- `FlashOptionStorage` must be a contract in the inheritance chain, or the plugin silently skips the check. The plugin
  also refuses two structs on one namespace anywhere in the build (`DuplicateNamespaceError`), so the upgrade test's
  V2 mock reaches its new field by slot (the namespace's root + 14).

**What each key can do alone, if it leaks** (`test/access/KeyBlastRadius.t.sol` pins each bound):

| Key | Alone, it can | It can't | Bound by |
|---|---|---|---|
| Upgrader | install any code: one call can empty the contract | — | the 48 h timelock, which the guardian can cancel |
| Admin | withdraw free money above the floor and the open bets' cover, to recipients it names; grant itself any role | touch the floor or the cover, or withdraw while winners are owed | the 48 h timelock |
| Opener | open signed orders at any entry price; open and sell its own wallets' bets at fake prices | change a signed term, reuse an id, open late, take more than the stake | the breaker; a revoke |
| Settler | end open bets at prices past their lines; settle its own wallets' bets at fake prices, up to the skew (≤ 30 s) early | keep the stakes it ends: they stay in the pool | the breaker; a revoke |
| Operator | loosen settings within `validate` (gate at 100%, 30 s skew, owed limit off, 255 s price age, a 100% sell-fee cap, any stake); lift stops; reset the breaker | move money, grant roles, upgrade, switch the gate off, set a skew over 30 s | the Safe's signers and monitoring; a reset re-arms the breaker in full, so it follows a check of the trip |
| Guardian | halt, pause, revoke relayer keys | undo a stop, touch another role, move money | — |
| Anyone | fund, claim for an account, sweep fees, refund, repay | be paid by any of them: each pays the account it is for | — |

---

## 5. Storage order rules

Storage is read by **position**, so field order is part of the contract.

1. **Append only.** In `Layout`, `Market`, `Position`, `PoolState` and `DurationRule`, never reorder, remove or insert
   a field. The plugin accepts an insert into unused bytes (layout-check variant 04); this rule still forbids it, and
   review enforces that. `Market.leverage` and `Position.leverage` were placed in unused bytes before any version was
   deployed (ADR 0008); from the first deployment on, there are no exceptions.
2. **Embedded structs are frozen** (`PoolState` and `Breaker` in `Layout`, `DurationRule[5]` in `Market`): a new field
   would shift everything after it. New pool data goes at the end of `Layout`.
3. **Never change a fixed array's length** (`DurationRule[5]` stays 5).
4. **Never change a field's type**, even to one of the same size: `int64` to `uint64` reinterprets the bits.
5. **Retired fields stay** as a same-type `__deprecated_<name>`; a renamed field carries
   `/// @custom:oz-renamed-from <old name>`, or the plugin refuses it (variants 05 and 11).
6. **Enums are append-only:** `Side`, `Status` and `WithdrawPurpose` are stored as `uint8`.
7. **Pack by access:** fields used together share a slot; the slot maps in §6 are part of the design.
8. **Order matters outside storage too:** the EIP-712 type strings (§7), event fields and error arguments are the
   backend's ABI.
9. **CI enforces it:** `test/unit/FlashOptionStorage.t.sol` writes every field and reads the raw words back
   ([storage-layout.md](storage-layout.md)); the upgrade-safety job runs OpenZeppelin's plugin
   (`test/upgrade/layout/check.py`) against the base commit and every deployed build-info, the only check that notices
   a missing `@custom:storage-location`; and 15 variant patches, each a rule kept or broken, must pass or fail exactly
   as their headers say ([test/upgrade/layout/README.md](../test/upgrade/layout/README.md)).

---

## 6. Types

In `src/types/` (`StorageTypes`, `ParamTypes`, `OrderTypes`, `MathTypes`) and `src/base/FlashOptionStorage.sol`
(§6.6). `test/unit/FlashOptionStorage.t.sol` proves every slot map below.

### 6.1 Enums (stored as `uint8`; append only)

```solidity
enum Side { Call, Put }                        // Call = the price ends higher, Put = it ends lower
enum Status { None, Open, Owed, Closed }       // None = id never used; Closed = tombstone, id can never be reused
enum WithdrawPurpose { SeedRecovery, Rewards }
```
A finished position's slot 0 stays as a `Closed` tombstone, so an id is never reused and doubles as the order nonce.

### 6.2 `DurationRule`: one slot (11 of 32 bytes)

```solidity
struct DurationRule {
    uint16 durationSecs;   // 0 = unused slot (then every field must be 0)
    uint32 thetaMinE7;
    uint32 thetaMaxE7;     // θ × leverage < 1e7: under 10 bp at 1000x
    bool   enabled;
}
```
A `uint16` allows about 18 hours, far beyond the 1–5 minutes offered, and keeps `Position` slot 0 at 32 bytes.

### 6.3 `Market`: one per feed and leverage, in `mapping(uint16 => Market)`; 8 slots

```solidity
struct Market {
    // slot 0
    bytes32 marketId;           // the Pyth feed id
    // slot 1: read on every open and sale (31 bytes)
    bool    enabled;            // off at creation
    bool    paused;             // per-market brake: stops open + sell only
    int8    priceExponent;      // set at creation, never updated (BTC: -8)
    uint8   entryMaxAgeSecs;
    uint8   clockSkewSecs;      // at most 30 (ADR 0009)
    uint16  floorMinBps;
    uint16  floorMaxBps;
    uint16  capMinBps;
    uint16  capMaxBps;
    uint16  maxSellFeeBps;
    uint16  sellMinDelaySecs;
    uint16  sellCutoffSecs;
    uint32  maxExposureBps;     // 1 to 10_000 (ADR 0009); 10_000 at launch = 100%
    uint64  minStake;
    // slot 2 (18 bytes)
    uint64  maxStake;
    uint64  maxTotalOwed;
    uint16  leverage;           // 1x to 10,000x; with marketId, the market's key; never changes
    // slots 3-7
    DurationRule[5] durations;
}
```
The token is global, and roles replace per-market keys. `ConfigParams` is `Market` without `marketId`, `paused`,
`priceExponent` and `leverage`; `setConfig` replaces all of it at once.

### 6.4 `Position`: one per bet, in `mapping(bytes32 => Position)`

```solidity
struct Position {
    // slot 0: kept forever as the tombstone (exactly 32 bytes)
    address user;              // 20  every payout goes here (or to claimable[user])
    uint16  marketIdx;         //  2  index into markets; batches check it (ConfigMismatch)
    Side    side;              //  1
    Status  status;            //  1
    uint48  startTime;         //  6  the entry tick's publish time
    uint16  durationSecs;      //  2  endTime = startTime + durationSecs
    // slot 1: cleared when the position closes (gas refund) (30 bytes)
    uint64  stake;
    int64   entryPrice;
    int64   liqPrice;
    uint16  floorBps;
    uint16  capBps;
    uint16  leverage;          //  2  copied from the market at open; settle and sell pay at it
    // slot 2: written only if the position becomes an IOU
    uint64  owed;
    uint64  queueSeq;
}
```
- The cap price and θ, never read after open, go only in `PositionOpened` (`getPosition` recomputes the cap price with
  `LeverageMath.capLine`, which needs no θ). An open writes 2 new slots; an ending reads 2, rewrites `status` (warm)
  and clears slot 1.
- **The bet's own leverage** stays while the bet is an IOU and is cleared with slot 1 (the market index still gives
  it). No function changes a market's leverage, so the copy always equals the market's: it completes the bet's record
  and spares a batch or a sale a read of the market's slot 2.

### 6.5 `PoolState` (embedded in `Layout`; frozen; 4 slots)

```solidity
struct PoolState {
    // slot 0: written by every open and every ending
    uint64 total;              // held stakes + free money (excludes feesPending and claimable)
    uint64 lockedMargin;       // sum of open stakes
    uint64 openMaxProfit;      // sum of stake × (cap − 1) over open positions
    uint64 totalOwed;          // sum of owed over IOUs
    // slot 1
    uint64 poolFloor;          // ≥ 500 whole tokens
    uint64 nextQueueSeq;
    uint64 nextRepaySeq;
    uint32 openPositions;
    uint32 owedPositions;
    // slot 2
    uint64 feesPending;        // accrued, not yet swept
    uint64 totalClaimable;     // sum of claimable[]
    uint64 transferred;        // cumulative credited to users (pushed or claimable)
    uint64 feesPaid;           // cumulative fees taken out of total
    // slot 3 (16 bytes free; leave them unused, see rule 2)
    uint64 seedRecovered;      // ≤ 500 whole tokens, ever
    uint64 rewardsWithdrawn;
}
```
`free = total − lockedMargin` is computed, never stored. An open or a queued IOU that would wrap a 32-bit count reverts
`MathOverflow` (`test/concrete/counters/`).

### 6.5b `Breaker` (embedded in `Layout`; frozen; 2 slots)

```solidity
struct Breaker {               // payout circuit breaker (§8.11)
    // slot 0: the current window, the only slot a counted batch writes (27 bytes)
    uint64 profitOut;          // profit paid to users in this window
    uint64 lossIn;             // losers' losses kept by the pool in this window
    uint48 windowStart;        // start of the current fixed window
    bool   tripped;            // true = open and sell blocked until the operator resets
    uint32 windowSecs;         // 60 ≤ windowSecs ≤ 86_400
    // slot 1
    uint64 maxNetProfit;       // net profit allowed out per window, in base units; 0 = off
}
```
Everything a batch updates shares slot 0 (§5 rule 7), so a count writes one slot. (The compiler packs greedily: with
the limit first, only `lossIn` would move to slot 1.)

### 6.6 `Layout`: the namespaced root

```solidity
/// @custom:storage-location erc7201:manic.storage.FlashOption
struct Layout {
    // slot 0 (30 bytes)
    IERC20  token;             // the stablecoin, set once in initialize
    uint8   tokenDecimals;     // read once at initialize; 6 to 9, so every amount fits a uint64
    bool    halted;            // global stop (guardian)
    uint16  marketCount;
    uint48  refundDelaySecs;   // safety refund delay after expiry (default 24 h; 0 = off) (§8.6)
    // slots 1, 2
    address feeRecipient;
    address rewardsRecipient;
    // slots 3-6, 7-8
    PoolState pool;
    Breaker breaker;
    // mapping roots, one slot each
    mapping(uint16 => Market)      markets;
    mapping(bytes32 => uint16)     marketIndexPlusOne;   // keccak256(abi.encode(marketId, leverage)) → index + 1
    mapping(bytes32 => Position)   positions;
    mapping(uint64 => bytes32)     iouQueue;             // seq → positionId
    mapping(address => uint64)     claimable;
    // ── new fields go below this line only ──
}
// slot = keccak256(abi.encode(uint256(keccak256("manic.storage.FlashOption")) - 1)) & ~bytes32(uint256(0xff))
//      = 0xf273be9a24eeab036a40c6c3509d6aa7cccb8da2ecbd9965c4f2a996a54c2200 (a unit test recomputes it)
```

### 6.7 Calldata structs

```solidity
struct OpenOrder {             // signed by the user (EIP-712), contains no price
    bytes32 positionId;        // backend-generated, random, never zero, single use
    address user;
    bytes32 marketId;
    uint16  leverage;          // with marketId, picks the market; signed, so no relayer can open at another
    Side    side;
    uint64  stake;
    uint16  durationSecs;
    uint48  notBefore;         // the entry tick must be published at or after this
    uint48  deadline;          // block.timestamp must be ≤ this
}
struct OpenTerms {             // added by the relayer at the tick
    int64  entryPrice;
    uint48 entryPublishTime;
    uint32 thetaE7;
    uint16 floorBps;
    uint16 capBps;
}
struct StakeAuth {             // the user's EIP-3009 ReceiveWithAuthorization for exactly o.stake, nonce = o.positionId
    uint256 validAfter;
    uint256 validBefore;
    bytes   signature;         // passed through to the token
}
struct SellOrder {             // signed by the position's user
    bytes32 positionId;
    uint64  minAmount;
    uint48  notBefore;
    uint48  deadline;
}
struct SellTerms {             // added by the relayer
    int64  price;
    uint48 publishTime;
    uint64 valuation;
    uint64 sellAmount;
}
struct InitParams {            // admin and upgrader: the timelock on mainnet; operator: the admin Safe
    address admin;
    uint48  adminTransferDelay;// the admin's two-step transfer delay (mainnet: 2 days)
    address upgrader;
    address operator;
    address guardian;
    address[] openers;
    address[] settlers;
    IERC20  token;
    uint64  poolFloor;
    address feeRecipient;
    address rewardsRecipient;
    uint48  refundDelaySecs;   // 24 h
    uint64  breakerMaxNetProfit;
    uint32  breakerWindowSecs; // e.g. 3600
}
```

### 6.8 Constants

| Name | Value | Note |
|---|---|---|
| `MIN_LEVERAGE` / `MAX_LEVERAGE` | 1 / 10_000 | the allowed leverage L, a whole number |
| `BPS` / `E7` | 10_000 / 10_000_000 | 1x or 100%; θ's scale (`thetaE7 = θ × 1e7`) |
| `MAX_LEVERAGE_CAP_BPS` | 40_000 | 4x, the highest cap |
| `WINNER_FEE_BPS` / `LOSER_FEE_BPS` | 200 / 300 | 2% and 3% |
| `MIN_POOL_FLOOR_TOKENS` / `SEED_RECOVERY_CAP_TOKENS` | 500 / 500 | × 10^decimals |
| `MAX_BATCH` / `MAX_REPAY_PER_CALL` | 100 / 50 | ids per batch; IOUs per `repay` |
| `MIN_PAY_GAS` / `OUT_OF_GAS_DIVISOR` | 60_000 / 16 | `_pay`'s gas floor (a lower bound, confirmed against USDG on a fork) and its out-of-gas test (§8.8) |
| `MAX_CLOCK_SKEW_SECS` | 30 | the widest skew `validate` accepts: six times the launch value, half the shortest bet (ADR 0009) |

The line limit is θ × L < 1e7 (`thetaWithinLimit`): 10 bp at 1000x, 20 bp at 500x, 100 bp at 100x. `LeverageMath`
holds the leverage, scale, cap, fee and seed-cap constants; `FlashOptionBase` the setting limits (the floor, a 1-hour
minimum refund delay, breaker windows of 60 to 86,400 s) and `_pay`'s two; `SettlementModule` the batch limits;
`ConfigLib` the skew bound; `ManicFlashOption` the decimals bounds (6, 9); `AdminModule` the exponent bounds (−18, 0).

---

## 7. Signatures (EIP-712)

- **Domain:** `EIP712("Manic Flash Option", "1")`, plus the chain id and `verifyingContract` (the proxy), added by
  OZ, which recomputes the separator if the chain id changes and exposes the domain through `eip712Domain()`
  (ERC-5267).
- **Type strings** (field order = struct order; enums encode as `uint8`):
  ```
  OpenOrder(bytes32 positionId,address user,bytes32 marketId,uint16 leverage,uint8 side,uint64 stake,uint16 durationSecs,uint48 notBefore,uint48 deadline)
  SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)
  ```
- **The check** (`_checkSignature`; else `InvalidSignature`): `ECDSA.tryRecover` must return the expected signer
  (`order.user`, or `position.user` for a sale), rejecting a malleable `s`, a `v` other than 27 or 28, a length other
  than 65 and the zero address; only if that fails, ERC-1271 through `isValidERC1271SignatureNowCalldata`, which reads
  at most 32 bytes of reply (an address without code fails; §15 rule 13). ECDSA goes first so a user's EOA that later
  gets EIP-7702 code still verifies; OZ's `isValidSignatureNow` skips ECDSA for any address with code.
- **The backend sends** 65 bytes, `r ‖ s ‖ v`, `v` = 27 or 28, low `s`; a 64-byte compact signature or a `v` of 0 or 1
  is refused. `OrderLib.hashStruct`, `_openOrderDigest` / `_sellOrderDigest` and the views `hashOpenOrder` /
  `hashSellOrder` build and expose the digests.
- **Replay:** an open's id is single use (tombstone), a position closes on its first sale, every signature expires at
  its `deadline` (about 30 s), and the domain binds the chain and the proxy, so a testnet signature never works on
  mainnet.
- **Shared vectors:** `test/fixtures/eip712_vectors.json` holds the type hashes, the separator of a fixed test domain
  (chain 46630, contract `0x7357…7357`) and the digests and signatures of Anvil's public key 0, made by Foundry's
  `cast`, never by this repository's Solidity (`test/fixtures/README.md`). The backend's signing must reproduce every
  vector before it integrates.
- **Stake pull (ADR 0002):** with each order the user signs the token's `ReceiveWithAuthorization(from=user, to=proxy,
  value=stake, validAfter, validBefore, nonce=positionId)`. Only the `to` address can submit it, so nobody can
  front-run it, and it leaves nothing approved, so a bug can never pull more than one stake. USDG on Robinhood Chain
  and USDC both implement it, ERC-1271 included. The contract still checks its own `OpenOrder` signature (both
  signatures come from the backend's custody signer in one request). `fund` uses `approve` + `transferFrom`.

---

## 8. External functions

Legend: **OPENER** / **SETTLER**: the relayer roles; **O**: operator (instant); **G**: guardian; **A**: admin and
**U**: upgrader (timelocked on mainnet); **any**: anyone. Every state-changing function is `nonReentrant`. The checks
run in the order listed, which the tests pin: a call breaking several reverts with the first one's error (§11.2).
Costs: [gas.md](gas.md).

### 8.1 Setup and admin

| Function | Who | Checks → effects |
|---|---|---|
| `initialize(InitParams p)` | once, through the proxy constructor | non-zero addresses, in field order (`ZeroAddress`) → `6 ≤ decimals ≤ 9` (`InvalidTokenDecimals(decimals)`) → `poolFloor ≥ 500 × 10^dec` (`InvalidLeverageParams`) → refund delay `0` or `≥ 1 h` (`InvalidRefundDelay`) → breaker window `60…86_400` (`InvalidBreakerParams`) → roles granted; token, decimals, floor, recipients, refund delay and breaker set, each emitting its setter's event |
| `createMarket(bytes32 marketId, uint16 leverage, int8 priceExponent, ConfigParams p)` | A | `marketId ≠ 0` (`InvalidLeverageParams`) → the pair is new (`MarketExists`) → `−18 ≤ exp ≤ 0` (`InvalidLeverageParams`) → `p.enabled` false: a market starts switched off (`InvalidLeverageParams`) → `validate(p, leverage)` → fewer than 65,535 markets (`MathOverflow`) → stored at the next index, unpaused; `MarketCreated`, then `ConfigUpdated` |
| `setConfig(bytes32 marketId, uint16 leverage, ConfigParams p)` | O | the market exists (`UnknownMarket`) → `validate(p, leverage)` → every setting replaced, `enabled` included (never the id, leverage, pause or exponent); `ConfigUpdated` |
| `setPaused(bytes32 marketId, uint16 leverage, bool paused)` | pause: G or O, else `AccessControlUnauthorizedAccount(caller, GUARDIAN_ROLE)`; unpause: O only (`OnlyOperatorCanUnpause`) | the market exists (`UnknownMarket`) → `PauseChanged`, even if unchanged |
| `setHalted(bool halted)` | halt: G or O, else as above; unhalt: O only (`OnlyOperatorCanUnhalt`) | → `HaltChanged`, even if unchanged |
| `setPoolFloor(uint64)` | A | `≥ 500 × 10^dec` (`InvalidLeverageParams`) → `PoolFloorUpdated` |
| `setRecipients(address fee, address rewards)` | A | non-zero (`ZeroAddress`) → `RecipientsUpdated` |
| `setRefundDelay(uint48 secs)` | A | `0` (off) or `≥ 1 h` (`InvalidRefundDelay`) → `RefundDelayUpdated`. A refund reads the delay when it runs, so this reaches open bets |
| `setBreaker(uint64 maxNetProfit, uint32 windowSecs)` | A | `60 ≤ windowSecs ≤ 86_400` (`InvalidBreakerParams`); `0` = off → `CircuitBreakerUpdated`. Leaves the counters, window start and a trip alone. Timelocked, since a higher or no limit weakens protection |
| `resetBreaker()` | O | clears `tripped`, zeroes both counters, starts the window now → `CircuitBreakerReset`; allowed at any time |
| `withdraw(WithdrawPurpose purpose, uint64 amount)` | A | `amount > 0` (`InvalidAmount`) → `totalOwed == 0` (`OwedOutstanding`) → `free ≥ amount + floor` (`BelowPoolFloor`) → **`free − amount − floor ≥ openMaxProfit`** (`OpenExposureNotCovered`) → seed cap (`SeedRecoveryExceeded`) → `total −= amount`, the purpose's counter `+= amount`; `PoolWithdrawn`; then the transfer, to the fee recipient for seed recovery or the rewards recipient for rewards (a failure reverts everything) |
| `upgradeToAndCall(address, bytes)` / roles and the two-step admin transfer | U / A | OZ |

`setPoolFloor`, `setRecipients`, `setRefundDelay` and `setBreaker` share their setter with `initialize`.

**`validate(ConfigParams, leverage)`** (`ConfigLib`, compiled once behind a private function) checks, at the market's
leverage L: L in 1–10,000; `0 < minStake ≤ maxStake`; `10_000 < floorMin ≤ floorMax`; `10_000 < capMin ≤ capMax ≤
40_000`, `floorMax ≤ capMax` and `capMax − 10_000 < L × 10_000` (a short can reach the cap; binds only below 4x);
`maxSellFee ≤ 10_000`; each duration slot all zero, or `0 < θmin ≤ θmax`, `θmax × L < 1e7` and no duplicate duration
(disabled rules too, so they can be switched on later); and last, `withinEvmBounds`: `entryMaxAgeSecs > 0` (a market
accepting no price age could never open a bet), `0 < maxExposureBps ≤ 10_000` and `clockSkewSecs ≤ 30`. Every refusal
is `InvalidLeverageParams`. The sell window, the owed limit and `enabled` are unbounded.

**Why the gate and the skew are bounded (ADR 0009).** The operator sets both, at once. Unbounded, a leaked operator key
could switch the gate off or above 100% (bets promising more than the pool holds, winners owed IOUs) or set a
255-second skew (a settler settling bets that early). 30 s is six times the launch skew and half the shortest bet, and
a low skew only delays opens and settles while the chain's clock lags. `openGate` still reads 0 as off, but with every
gate at 100% or less no IOU can form (§12, invariant 5): the IOU path (§8.7) is a backstop only an upgrade could
reach, and its tests switch a gate off in storage (`test/utils/LayoutWriter.sol`).

**Leverage:** `createMarket` checks the settings at the given leverage, `setConfig` at the market's own, which never
changes; `test/concrete/leverages/` pins 1000x (a 10 bp line refused, 9.999 bp accepted) and the 500x and 100x tiers.

### 8.2 `open(OpenOrder o, bytes sig, OpenTerms t, StakeAuth a) → void`: OPENER

1. `!halted` (`Halted`)
2. `block.timestamp ≤ o.deadline` (`OrderExpired`)
3. the market of `(o.marketId, o.leverage)` exists (`UnknownMarket`) → `enabled` (`LeverageDisabled`) → `!paused`
   (`LeveragePaused`) → `!breaker.tripped` (`BreakerTripped`)
4. `o.positionId ≠ 0` and `positions[id].status == None` (`PositionIdUsed`)
5. signature valid for `o.user` (`InvalidSignature`)
6. `validateOpen(stake, duration, θ, floor, cap)` (`InvalidAmount` / `InvalidLeverageParams`)
7. `checkEntryTime(now, t.entryPublishTime, maxAge, skew)` (`PriceTooOld` / `PriceFromFuture`)
8. `t.entryPublishTime ≥ o.notBefore` (`PriceBeforeOrder`)
9. `(liq, cap) = lines(entry, side, m.leverage, θ, cap)` (`InvalidPrice` / `InvalidLeverageParams`)
10. `mp = maxProfit(stake, cap)`; `openGate(totalOwed, maxTotalOwed, openMaxProfit, mp, free, maxExposureBps)`
    (`OpenBlockedTotalOwed` / `OpenBlockedExposure`)
11. **Effects:** write the position (2 slots, with the market's leverage); `total += stake`, `lockedMargin += stake`,
    `openMaxProfit += mp`, `openPositions++`, each checked (`MathOverflow`)
12. Event `PositionOpened`, before the token call (checks → effects → interactions)
13. **Interaction:** `token.receiveWithAuthorization(o.user, this, o.stake, a.validAfter, a.validBefore, o.positionId,
    a.signature)`; the balance must then have risen by exactly `stake`, or `TransferAmountMismatch(expected,
    received)` reverts everything. This catches a fee-on-transfer token, a swapped token facet, and USDG's silent
    no-op: for a nonce already used or cancelled, USDG emits `AuthorizationAlreadyUsed` and returns **without
    reverting or moving tokens** (verified in Paxos's source; `MockUSDG` reproduces it)

**Notes:**
- Checks 1–5 are `_checkOrder`, 6–10 `_checkTerms` (split for the legacy pipeline's stack). `validateOpen`:
  `minStake ≤ stake ≤ maxStake` (`InvalidAmount`); an enabled rule for the duration, θ inside it, the floor inside its
  range, and `max(capMin, floor) ≤ cap ≤ capMax` (`InvalidLeverageParams`).
- The pull uses the `bytes signature` form of `receiveWithAuthorization` (`0x88b7ab63`), which live USDG implements.
  Only the payee can submit it: a stranger who copies it gets `CallerMustBePayee`, and it stays unused.
- USDG reverts a bad stake authorisation with `InvalidSignature()`, our selector too. The order signature is checked
  first, so if `open` reverts `InvalidSignature` while the order's signature checks out against `hashOpenOrder`, the
  stake authorisation is the bad one. USDG's other errors (`AddressFrozen`, `ContractPaused`, …) pass through.

### 8.3 `sell(SellOrder s, bytes sig, SellTerms t) → void`: OPENER

1. `!halted` (`Halted`)
2. `block.timestamp ≤ s.deadline` (`OrderExpired`)
3. position exists (`UnknownPosition`) → market `enabled` (`LeverageDisabled`) → `!paused` (`LeveragePaused`) →
   `!breaker.tripped` (`BreakerTripped`)
4. `status == Open` (`PositionNotOpen`): a single sale reverts; it is not skipped
5. signature valid for `position.user` (`InvalidSignature`)
6. `checkSellWindow(start, end, publishTime, minDelay, cutoff)`, then `block.timestamp < endTime` (both
   `SellWindowClosed`)
7. `checkEntryTime(...)` (`PriceTooOld` / `PriceFromFuture`)
8. `t.publishTime ≥ s.notBefore` (`PriceBeforeOrder`)
9. `price > 0` (`InvalidPrice`) → `!touched` (`LiquidateInstead`)
10. `gNow = gBps(...)` at the bet's own leverage; `checkSell(stake, gNow, valuation, sellAmount, s.minAmount,
    maxSellFee, totalOwed, freeBefore)`, raising in order `ValuationAboveCurrentPayout` /
    `SellAmountExceedsValuation` / `SellFeeTooHigh` / `SellAmountBelowMin` / `QueueNotEmpty` / `SellNotPayable`
11. `split = sellSplit(...)`; release the margin; `total −= valuation + loserFee`; `transferred += toUser`;
    `feesPending += fees`; `feesPaid += fees`; status → `Closed`, clear slot 1
12. Event `PositionSold`; then `_pay(user, toUser, id)`

**Notes:**
- Checks 1–8 are `_checkSale`, 9–10 and the split `_priceSale`. The order names no market: the position's own applies.
- **Why the sale must land before the bet ends** (check 6): a tick in the window may be up to `entryMaxAgeSecs` old,
  so a sale priced just before the cutoff could land after the expiry (up to 2 s after at the launch values), racing
  `settle`; the first to land would win, the sale at a stale price.
- Free money is measured with the stake still held, for `SellNotPayable` and the loser fee, so a sale is never partly
  paid. `PositionSold` precedes the payout; a frozen user's proceeds wait in `claimable`; a starved call reverts.

### 8.4 `liquidate(bytes32 marketId, uint16 leverage, int64 price, uint48 publishTime, bytes32[] ids) → uint256 processed`: SETTLER

- Batch checks: `!halted` (`Halted`); `1 ≤ ids.length ≤ 100` (`EmptyBatch` / `BatchSizeTooLarge`); the market exists
  (`UnknownMarket`): a batch holds one feed at one leverage.
- Per id:
  1. `status == None` reverts (`UnknownPosition`); `marketIdx` mismatch reverts (`ConfigMismatch`).
  2. `status ≠ Open`: **skip**, emitting `PositionSkipped`.
  3. `checkLiquidation(start, end, liq, side, price, publishTime, now, skew)`, raising `InvalidPrice` /
     `InvalidLiquidationWindow` / `PriceFromFuture` / `LiquidationPriceNotReached`.
  4. `freeBefore`; release the margin; `fee = loserFee(stake, freeBefore, floor)`; `total −= fee`; `fees += fee`;
     `Closed`; event.
- After the loop: `feesPending += fees`; `feesPaid += fees`. Old ticks are accepted, so the backend can replay after an
  outage.

**Notes:**
- `liquidate` and `settle` share `_checkBatch` (the batch as one memory struct, for the stack) and `_batchPosition`,
  whose `UnknownPosition(id)` and `ConfigMismatch(id)` come **before** the skip, so another market's position reverts
  the batch even after it ended. Skipped: a bet sold or ended earlier, an IOU, an id listed twice.
- Every ending's books go through `_releaseMargin` (stake, max profit, open count), `_closePosition` (`Closed`, slot 0
  kept, slot 1 cleared) and `_accrueFees` (once per call). The loser fee uses free money from before the release.
- No tokens move here: fees wait for `sweepFees`, so there is nothing to re-enter from.

### 8.5 `settle(bytes32 marketId, uint16 leverage, int64 price, uint48 publishTime, bytes32[] ids) → uint256 processed`: SETTLER

- Batch checks: `!halted`; batch size; market exists; `price > 0` (`InvalidPrice`); `publishTime ≤ now + skew`
  (`NotExpired`).
- Per id:
  1. Unknown / `ConfigMismatch` revert; not `Open`: skip.
  2. `endTime == publishTime` (`InvalidPriceTimestamp`) → `!touched` (`LiquidateInstead`).
  3. `g = gBps(...)` at the bet's own leverage; `amount = payout(stake, g)`;
     `split = settleSplit(amount, stake, freeBefore, totalOwed, floor)`.
  4. Release the margin; `total −= own + paid + loserFee`; `transferred += toUser`; `fees += winnerFee + loserFee`.
  5. If `owed > 0`: `queueSeq = nextQueueSeq++`, `totalOwed += owed`, `owedPositions++`, `iouQueue[seq] = id`, status
     → `Owed` (slot 2 written, slot 1 kept for repay). Otherwise `Closed`, slot 1 cleared.
  6. Event `PositionSettled`; then `_pay(user, toUser, id)`.
- After the loop: `feesPending += fees`; `feesPaid += fees`.

**Notes:** the price check is batch-wide here but per position in `liquidate`, so a `liquidate` batch whose every id is
skipped succeeds at any price. `NotExpired` lets the tick lead `block.timestamp` by the skew, so a bet can be settled
up to that many seconds early; the tick must be exactly the expiry second. `paidNow` in `PositionSettled` is what the
user is owed now, paid or deferred (`PayoutDeferred` follows a deferral); a starved call reverts
`InsufficientGasForPayout` instead (`test/concrete/settle/`).

### 8.6 `refundExpired(bytes32[] ids) → uint256 processed`: any (while `refundDelaySecs > 0`; default 24 h)

1. The refund is on: `refundDelaySecs > 0` (`RefundDisabled`).
2. `1 ≤ ids.length ≤ 100` (`EmptyBatch` / `BatchSizeTooLarge`).
3. Per id: opened (`UnknownPosition(id)`); not `Open`: skip; `block.timestamp ≥ endTime + refundDelaySecs`
   (`RefundTooEarly(id)`), summed in 256 bits.
4. Release the margin; `total −= stake`; `transferred += stake`; `Closed`; `PositionRefunded`; `_pay(user, stake)`.

**Notes:** it needs no price, so it names no market and a batch may mix markets. No fees, no breaker count, and free
money doesn't change. The delay is read when it runs; after the delay, a late settle and a refund can both end a bet,
and the first to land does. **No brake stops it** (§8.10), since it only returns a user's own stake;
`test/concrete/brakes/` replays the outage it exists for.

### 8.7 `repay(uint256 maxCount) → uint256 repaid`: any

`repay` walks the IOU queue from its head, so no caller can skip or reorder it. With every gate bounded (§8.1), no IOU
can form (§12, invariant 5): the queue is a backstop for a state only an upgrade could reach.

- `!halted`; `1 ≤ maxCount ≤ 50` (`InvalidMaxCount`).
- Loop while `nextRepaySeq < nextQueueSeq` and `n < maxCount`:
  1. `id = iouQueue[nextRepaySeq]`; `split = repaySplit(owed, free)`; `amount == 0` → break.
  2. `total −= amount`; `totalOwed −= amount`; `transferred += toUser`; `fees += winnerFee`; `owed = remaining`.
  3. If `remaining == 0`: `owedPositions−−`, `nextRepaySeq++`, `delete iouQueue[seq]`, status → `Closed`.
  4. Event `OwedRepaid`; then `_pay(user, toUser, id)`.
  5. If `remaining > 0`, break: a partial payment stops at the head.

**Notes:** free money is `total − lockedMargin`, never open stakes. It returns how many IOUs it repaid; all but perhaps
the last were paid in full. A fully paid IOU keeps only its slot-0 tombstone; a part-paid one keeps its slots, `owed`
lowered. Two mutations are equivalent by construction: walking past the tail pays nothing, and dropping the stop after
a partial payment changes nothing (a partial payment uses up free money).

### 8.8 Payouts, claims and fees

```solidity
function _pay(address to, uint64 amount, bytes32 positionId) internal {   // FlashOptionBase
    if (amount == 0) return;
    uint256 gasBefore = gasleft();
    if (gasBefore < MIN_PAY_GAS) revert InsufficientGasForPayout();     // starving the call can't defer a payout
    if (token.trySafeTransfer(to, amount)) return;                      // false on a revert or a `false` return
    if (gasleft() <= gasBefore / 16) revert InsufficientGasForPayout(); // out of gas, not a refusal
    claimable[to] += amount; pool.totalClaimable += amount;             // both checked (`MathOverflow`)
    emit PayoutDeferred(positionId, to, amount);
}
```
- A refusal (frozen, paused, blocklisted) defers the payout; running out of gas reverts, so a relayer can't starve calls
  to push honest winners into `claimable`.
- **Out of gas or a refusal?** A call forwards at most 63/64 of the gas (EIP-150), so a transfer that runs out k calls
  deep leaves `_pay` about k/64 of its gas, while a refusal leaves most of it. `gasBefore / 16` catches three levels:
  the token, a proxy in front of it (USDG has one) and one call it makes. At 10,000,000 gas, `/64` missed a starved
  transfer behind a proxy and `/32` one a level further down. `test/concrete/pay/` runs all four shapes.
- **`MIN_PAY_GAS` is the main defence:** on a fork of mainnet (`test/fork/RealUsdg.t.sol`), paying a new holder from a
  contract with every slot cold costs 46,720 gas on the real USDG (39,731 on the mock), 13,280 under the floor; the
  test fails if that margin runs out.
- Robinhood Chain can **filter whole transactions** (L2Beat): a batch paying a sanctioned address may be dropped,
  which the contract can't catch. The backend should screen users and split a batch that keeps failing.

| Function | Who | Behaviour |
|---|---|---|
| `claim(address account)` | any | `claimable[account] > 0` (`NothingToClaim`) → cleared, `totalClaimable −= amount`, `Claimed`, then the transfer to `account`, **never anyone else**, so a frozen address can't move its money. A failure reverts everything |
| `sweepFees()` | any | `feesPending > 0` (`InvalidAmount`) → zeroed, `FeesSwept`, then the transfer to `feeRecipient`; a failure reverts and the fees stay pending |
| `fund(uint64 amount)` | any | `amount > 0` (`InvalidAmount`) → `total + amount` fits (`MathOverflow`) → `safeTransferFrom` → the balance rose by exactly `amount` (`TransferAmountMismatch`) → `total += amount`; `PoolFunded`. The pull comes first because the check needs what arrived |

### 8.9 Views

In `ViewsModule`: `getPosition(id)` (the `Position`, its `endTime` and recomputed `capPrice`); `getMarket(marketId,
leverage)` and `marketIdAt(idx)` (both revert `UnknownMarket`), `marketCount()`; `getPool()`, `freeMoney()`,
`claimableOf(account)`, `queueHead()` (`(nextRepaySeq, 0, 0)` when nobody is owed); `getBreaker()`, `recipients()`,
`token()`, `halted()`, `refundDelaySecs()`; `hashOpenOrder` / `hashSellOrder`; `eip712Domain()`, `version()` →
`"1.0.0"`, and the OZ role views.

- Every getter that reads the `Layout` is `nonReentrantView` (§15 rule 12), so a token callback never sees half-updated
  books (`test/concrete/reentrancy/`).
- A never-used id returns an empty record (`None`): how the backend tells an id is free. The cap price is `capLine` at
  the bet's own leverage (a fuzz test proves it equals `lines`'), and 0 once the position has closed.
- The integrators' guide is [integration.md](integration.md); [abi-reference.md](abi-reference.md) is generated from
  the compiler, and CI fails if it or `abi/IManicFlashOption.json` is stale.

### 8.9b Guardian

- `revokeRelayer(bytes32 role, address account)` is GUARDIAN-only and works for `OPENER_ROLE` and `SETTLER_ROLE` only
  (any other role: `InvalidRelayerRole(role)`). It takes effect at once. Revoking a key the account doesn't hold does
  nothing and emits nothing.
- Granting a key back needs the timelocked admin.

### 8.10 What `halted` and `paused` stop

| | open | sell | liquidate | settle | repay | refund | fund | withdraw | claim | sweepFees | admin, config, upgrade |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Market `!enabled` or `paused` | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Global `halted` | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Breaker `tripped` | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

### 8.11 Payout circuit breaker (ADR 0003)

**Threat** (Ostium, Arbitrum, July 2026, ~$18M): a stolen price-signer key opened positions at fake prices and closed
them at real ones, in a loop. Anyone can create user wallets here, so a stolen OPENER or SETTLER key could do the
same, up to the pool's free money, before a human halts.

1. **Count:** each call adds up in memory, before fees, the profit it pays and the losses it keeps, and writes the
   breaker once:

   | Action | `profitOut +=` | `lossIn +=` |
   |---|---|---|
   | settle | `split.paid` | `stake − split.own` |
   | liquidate | — | `stake` |
   | sell | `sellAmount − stake` if positive | `stake − sellAmount` if positive |
   | repay | the repaid `amount` (an IOU's profit counts when repaid) | — |
   | refund | — | — |

2. **Window:** fixed; at or after `windowStart + windowSecs`, the counters restart at 0 from `block.timestamp`.
3. **Trip:** when `maxNetProfit > 0` and `profitOut > lossIn + maxNetProfit`: `tripped = true`,
   `CircuitBreakerTripped(profitOut, lossIn, windowStart)`.
4. **While tripped:** `open` and `sell` revert `BreakerTripped`; liquidate, settle, repay, refund and claim go on.
5. **Reset:** the operator's `resetBreaker()`, after checking what happened. The limit (`setBreaker`) is the
   timelocked admin's.

**Notes:**
- Fixed windows can let up to 2× the limit through across a boundary. A per-market price-move bound is left for a
  later version (ADR 0003).
- `BreakerLib.count` and `reset` run on `Breaker storage` (unit-tested alone). `liquidate`, `settle` and `repay` count
  once after their loop, so a trip's event is the call's last; `sell` counts after `PositionSold`, before its payout.
  A call that counts nothing writes nothing; one that counts writes slot 0 only (about 7,000 gas a call, 700 a
  position).
- Sums are taken in 256 bits; a counter passing 64 bits reverts `MathOverflow`. The first count on a chain starts the
  first window. The trip happens only on the change; the counters keep running while the breaker is off or tripped.
  `setBreaker` never clears a trip; `resetBreaker` works at any time.
- **Tests:** every settlement checker models the breaker's 6 fields. `test/concrete/breaker/` runs the fake-price loop
  with stolen opener and settler keys: the second round's settle trips it at $1,500 out (with the breaker off, three
  rounds take $2,250). `test/access/FakePriceLoop.t.sol` uses one key: the opener alone trips it on the seventh $150
  sale ($1,050), the settler alone across 1000x, 500x and 100x at $1,100; after a revoke and a reset, the revoked key
  can't restart it.

---

## 9. Money flows (the books after each action)

`fee*` = what accrues to `feesPending`; `→user` = pushed, or added to `claimable` if the push fails.

| Action | total | lockedMargin | openMaxProfit | totalOwed | feesPending | to the user | counters |
|---|---|---|---|---|---|---|---|
| open | +stake | +stake | +mp | | | (pulls stake) | openPositions +1 |
| liquidate | −loserFee | −stake | −mp | | +loserFee | 0 | openPositions −1 |
| settle | −(own+paid+loserFee) | −stake | −mp | +owed | +winnerFee+loserFee | own+paid−winnerFee | open −1; if owed: owed +1, nextQueueSeq +1 |
| sell | −(valuation+loserFee) | −stake | −mp | | +sellFee+winnerFee+loserFee | sellAmount−winnerFee | open −1 |
| repay | −amount | | | −amount | +winnerFee | amount−winnerFee | if fully repaid: owed −1, nextRepaySeq +1 |
| refund | −stake | −stake | −mp | | | stake | open −1 |
| fund | +amount | | | | | | |
| withdraw | −amount | | | | | (to the fee or rewards recipient) | seedRecovered or rewardsWithdrawn +amount |
| claim | | | | | | (pays out of `totalClaimable`) | totalClaimable −x |
| sweepFees | | | | | −x | (to feeRecipient) | |

**Conservation:** for every action, (tokens that leave the contract) + Δ`total` + Δ`feesPending` + Δ`totalClaimable` =
(tokens that enter). Hence the core invariant `token.balanceOf(this) ≥ total + feesPending + totalClaimable`. Equality
holds unless someone donates tokens directly; donations are never counted.

---

## 10. `LeverageMath`: the maths

`src/libraries/LeverageMath.sol` holds the maths as internal pure functions; the splits are structs (`MathTypes.sol`).
Units: prices `int64` at the market's exponent, amounts `uint64` base units, L a whole number 1–10,000, multiples and
rates in bps (10,000 = 1x = 100%), θ as `thetaE7 = θ × 1e7`.

- **The lines** (`lines`, `capLine`): the liquidation line sits `entry × θ / 1e7` from the entry, against the bet; the
  cap line `entry × (cap − 1x) / (L × 10,000)`, in its favour. `leverageAllowed`, `thetaWithinLimit` (θ × L < 1e7: the
  line sits where the payout is still positive) and `capReachable` (cap − 10,000 < L × 10,000) guard them.
- **The payout** (`gBps`, `payout`): `R = floor(move × L × 10,000 / entry)`; `g = 10,000 + R`, raised to the floor on
  a win, held to the cap, never below 0; `payout = stake × g / 10,000`; `maxProfit = stake × (cap − 1x)`.
- **The checks** (`checkLiquidation`, `checkEntryTime`, `openGate`, `checkSellWindow`, `checkSell`, `checkWithdraw`),
  each with its errors in a fixed order; **the fees** (`fee`, `winnerFee`, `loserFee`) and **the splits**
  (`settleSplit`, `sellSplit`, `repaySplit`).

The full specification, with worked examples, is [docs/MATH.md](MATH.md).

**Implementation rules:**
- Compute in `int256` / `uint256`; narrow only at the end, with an explicit range check that reverts `MathOverflow`,
  never a bare `uint64(x)` cast.
- No `unchecked` blocks in money paths; `unchecked` only for loop counters.
- Every rounding goes in the pool's favour: payouts and fees round down, the losing side floor-divides.
- Negative quotients floor toward −∞ through `floorDiv`, because Solidity's `/` truncates toward 0:
  `q = a / b; if (a % b != 0 && ((a < 0) != (b < 0))) q -= 1;`. No time comparison adds or subtracts past zero.

Unit tests check the worked examples and each edge, fuzzing checks the properties at any leverage, and 23 deliberate
bugs in the maths were each caught by a test.

---

## 11. Events and errors

Declared once in `IManicFlashOptionEvents.sol` and `IManicFlashOptionErrors.sol`; the aggregate ABI is committed in
`abi/IManicFlashOption.json` (CI fails if stale), and `test/unit/IManicFlashOptionAbi.t.sol` pins every signature.

### 11.1 Events

Event names and field order are part of the backend's ABI. `positionId` and `user` are indexed on every position
event; the four position events end with the bet's `uint16 leverage`, unindexed (`PositionOpened` already has three
indexed topics). `MarketCreated`, `ConfigUpdated` and `PauseChanged` carry the leverage after the market id, both
indexed, so an indexer can filter by the pair.

```solidity
event PositionOpened(bytes32 indexed positionId, address indexed user, bytes32 indexed marketId, Side side,
    uint64 stake, int64 entryPrice, int8 priceExponent, int64 liqPrice, int64 capPrice, uint32 thetaE7, uint16 floorBps,
    uint16 capBps, uint48 startTime, uint48 endTime, uint16 leverage);
event PositionLiquidated(bytes32 indexed positionId, address indexed user, Side side, uint64 stake, int64 liqPrice,
    int64 price, uint48 publishTime, uint48 endTime, uint64 loserFee, uint16 leverage);
event PositionSettled(bytes32 indexed positionId, address indexed user, Side side, uint64 stake, int64 finalPrice,
    uint48 publishTime, uint16 gBps, uint64 payout, uint64 paidNow, uint64 owed, uint64 queueSeq, uint64 winnerFee,
    uint64 loserFee, uint16 leverage);
event PositionSold(bytes32 indexed positionId, address indexed user, Side side, uint64 stake, int64 price,
    uint48 publishTime, uint16 gNowBps, uint64 valuation, uint64 sellAmount, uint64 sellFee, uint64 winnerFee,
    uint64 loserFee, uint16 leverage);
event OwedRepaid(bytes32 indexed positionId, address indexed user, uint64 queueSeq, uint64 amount, uint64 winnerFee,
    uint64 remainingOwed);
event PoolFunded(address indexed actor, uint64 amount);
event PoolWithdrawn(WithdrawPurpose purpose, uint64 amount, address indexed destination);
event MarketCreated(bytes32 indexed marketId, uint16 indexed leverage, uint16 index, int8 priceExponent);
event ConfigUpdated(bytes32 indexed marketId, uint16 indexed leverage, address indexed actor, ConfigParams params);
event PauseChanged(bytes32 indexed marketId, uint16 indexed leverage, address indexed actor, bool paused);
event HaltChanged(address indexed actor, bool halted);
event PoolFloorUpdated(uint64 poolFloor);
event RecipientsUpdated(address indexed feeRecipient, address indexed rewardsRecipient);
event RefundDelayUpdated(uint48 refundDelaySecs);
event PayoutDeferred(bytes32 indexed positionId, address indexed to, uint64 amount);
event Claimed(address indexed account, uint64 amount);
event FeesSwept(address indexed to, uint64 amount);
event PositionSkipped(bytes32 indexed positionId, Status status);
event PositionRefunded(bytes32 indexed positionId, address indexed user, uint64 stake);
event CircuitBreakerUpdated(uint64 maxNetProfit, uint32 windowSecs);
event CircuitBreakerTripped(uint64 profitOut, uint64 lossIn, uint48 windowStart);
event CircuitBreakerReset(address indexed actor);
```
Plus OZ's `Initialized`, `Upgraded`, `RoleGranted`, `RoleRevoked`, `DefaultAdmin*` and `EIP712DomainChanged`. The
backend reads logs at the `finalized` (or `safe`) tag, keyed by `(txHash, logIndex)`; a reverted transaction emits
nothing. The three widest events are emitted from small private helpers reading one memory struct, which avoids
"stack too deep" under the legacy pipeline.

### 11.2 Errors (custom errors)

The error names are part of the public interface: the backend keys off them. 52 errors (`id` is a `bytes32
positionId`):

| Group | Errors |
|---|---|
| Switches and markets | `Halted`, `UnknownMarket`, `LeverageDisabled`, `LeveragePaused`, `BreakerTripped` |
| Orders and signatures | `OrderExpired`, `PositionIdUsed`, `InvalidSignature`, `PriceBeforeOrder`, `TransferAmountMismatch(uint256 expected, uint256 received)` |
| Prices and parameters | `InvalidPrice`, `InvalidLeverageParams`, `MathOverflow`, `InvalidAmount` |
| Price times | `PriceTooOld`, `PriceFromFuture`, `InvalidLiquidationWindow(id)`, `LiquidationPriceNotReached(id)`, `InvalidPriceTimestamp(id)`, `NotExpired`, `LiquidateInstead(id)` |
| Positions and batches | `UnknownPosition(id)`, `ConfigMismatch(id)`, `PositionNotOpen`, `EmptyBatch`, `BatchSizeTooLarge` |
| Opening / selling | `OpenBlockedTotalOwed`, `OpenBlockedExposure` / `SellWindowClosed`, `ValuationAboveCurrentPayout`, `SellAmountExceedsValuation`, `SellFeeTooHigh`, `SellAmountBelowMin`, `QueueNotEmpty`, `SellNotPayable` |
| Repay, refund, payouts | `InvalidMaxCount`, `RefundDisabled`, `RefundTooEarly(id)`, `InsufficientGasForPayout`, `NothingToClaim` |
| Withdrawing | `OwedOutstanding`, `BelowPoolFloor`, `OpenExposureNotCovered`, `SeedRecoveryExceeded` |
| Admin | `ZeroAddress`, `InvalidTokenDecimals(uint8 decimals)`, `InvalidRefundDelay`, `MarketExists`, `OnlyOperatorCanUnpause`, `OnlyOperatorCanUnhalt`, `InvalidRelayerRole(bytes32 role)`, `InvalidBreakerParams` |

- The seven errors raised for one position in a batch carry its id, so the backend can drop that id and resend; the
  batch-wide `InvalidPrice` and `PriceFromFuture` carry none.
- Role checks revert with OZ's `AccessControlUnauthorizedAccount(account, role)`. A decrement of the books that the §12
  invariants make safe is plain checked arithmetic: if one ever broke, it would revert with `Panic(0x11)`, never wrap.
- USDG's own errors pass through `open`'s stake pull (§8.2); its `InvalidSignature()` shares our selector.

---

## 12. Invariants (checked by the stateful fuzz suite after every action)

1. `token.balanceOf(this) ≥ pool.total + pool.feesPending + pool.totalClaimable`.
2. `pool.lockedMargin == Σ stake`, `pool.openMaxProfit == Σ maxProfit(stake, cap)` and `pool.openPositions == count`,
   all over `Open` positions.
3. `pool.totalOwed == Σ owed` and `pool.owedPositions == count`, over `Owed` positions. `nextRepaySeq ≤ nextQueueSeq`,
   and `iouQueue[s]` is `Owed` for every `s` in `[nextRepaySeq, nextQueueSeq)`.
4. `pool.total ≥ pool.lockedMargin`: free money is never negative.
5. While every bet was opened with `0 < maxExposureBps ≤ 10_000`: `totalOwed == 0` forever, and `free ≥ openMaxProfit`
   after every open and at every step; withdrawals keep `openMaxProfit` covered above the floor (§8.1). `validate`
   keeps every gate in that range (ADR 0009), so this holds short of an upgrade; the $20-pool campaign switches its
   gates off in storage to explore the IOU path.
6. `pool.seedRecovered ≤ 500 × 10^dec`. No withdrawal ever reduces `free` below `poolFloor + openMaxProfit`.
7. `totalClaimable == Σ claimable[a]`.
8. A `positionId` never goes from `Closed` back to `Open`; a status only moves forward: None → Open → (Owed →) Closed.
9. A user's total receipts never exceed `stake × cap / 10_000` per position (fees only lower them).
10. Only `OPENER_ROLE` (open, sell) and `SETTLER_ROLE` (liquidate, settle) can change positions. Only `repay` and
    `refund` are open to anyone, and they can only move money to its rightful owner.
11. While the breaker is tripped, no position is opened or sold. It trips only on a call that counted profit past its
    limit, and only on the change. An untripped breaker with a limit sits at `profitOut ≤ lossIn + maxNetProfit`,
    unless the limit was switched on or lowered since the last count. After a trip, settles and repays keep counting
    (§8.11 step 4): what the breaker stops is new risk.
12. The contract never holds an allowance from any account (security checklist SIG-8): stakes come in by EIP-3009, and
    `fund` spends its allowance in full.
13. Every refusal that can be predicted from the state happens, with exactly its error (the brakes, the open gate, the
    withdrawal checks, nothing to claim or sweep, a token pause or freeze); everything else goes through.
14. Every bet keeps its market's leverage: each market keeps the leverage of its key, every bet stays on the market its
    order signed, and while open or owed it holds that leverage, which its settle, sale and `getPosition` use (an
    IOU's repayment is fixed). Once closed, it holds none.

**The stateful suite** (`test/invariant/`; handlers described in `test/README.md`) drives 20 actions on BTC at 1000x,
500x and 100x sharing one pool: prices (with leaps past every 100x cap) and the clock, opens, sales, batches (a mixed
one must be refused), refunds, repays, pool money, donations, brakes, settings in and out of bounds, the breaker,
freezes and a stranger calling 19 gated functions. Handlers never revert, check each expected refusal's exact error,
and track where the money went around every call. Two campaigns: the launch pool ($1,000) and a $20 pool with every
gate off, where IOUs of three leverages form. After each run, `afterInvariant` ends every bet, repays every IOU, pays
every claim and sweeps the fees; the books must then hold only free money and donations.

---

## 13. Test plan (Foundry)

Every suite runs with `forge test` on every pull request and push unless noted; CI uses the `ci` profile, with more
fuzz and invariant runs. `test/README.md` describes each folder.

| Suite | What | When |
|---|---|---|
| Unit | `test/unit/`: the libraries without a proxy (`LeverageMath` with MATH.md's worked examples), the storage layout (§5 rule 9), the ABI, the mock token | Every PR and push |
| Model vectors | `test/model/ModelVectors.t.sol`: 20,661 vectors of 24 functions of `LeverageMath` and `ConfigLib` (`test/fixtures/model/`), made by `model/flash_option_math.py`, a second implementation of MATH.md in Python: every output exact, and every refused input the model's error, with its arguments | Every PR and push; CI also checks the vectors are what the model gives now (`model/generate_vectors.py --check`) |
| Concrete (behaviour) | `test/concrete/<fn>/`: each external function from a `.tree` of every branch in check order: the happy path, **every error in that order**, every role gate and event field; plus `views/`, `reentrancy/`, `brakes/`, `breaker/`, `counters/`, `pay/`, `checkSignature/`, `leverages/`. Endings run through the checkers of `test/SettlementBase.t.sol`, whose own model (`test/utils/Calculations.sol`, never calling `src/`) is compared with every log, pool field, slot and balance | Every PR and push; `bulloak check` keeps trees and tests in step |
| Fuzz | `test/fuzz/`, 65 properties: the maths (`floorDiv` against a reference, `g` monotonic, `payout ≤ stake × cap`, conserving splits), every way a signature can be wrong (signer, domain, chain, replay, expiry, `notBefore`, malleable `s`, bad `v` or length, ERC-1271 and EIP-7702 signers), the order rules at their edges, rounding at tiny stakes; contract-level properties at any leverage (a changed leverage, an overpriced sale and a mixed batch are refused) | 1,000 runs locally, 10,000 in CI, 100,000 in the deep run (`deep-fuzz.yml`: weekly if `dev` changed, and on demand) |
| Invariant (stateful) | `test/invariant/`: §12's 14 invariants after every call, two campaigns, a wind-down after each run | Depth 100: 32 runs locally, 128 in CI, 1,000 in the deep run |
| Access control | `test/access/`: `AccessMatrix.t.sol`, 32 rows (the 30 state-changing functions, pausing and halting apart) × 11 users, each outcome exact, held to the compiled ABI, a random address refused everywhere; `KeyBlastRadius.t.sol` (§4.2); `FakePriceLoop.t.sol` (§8.11) | Every PR and push |
| Scenarios | `test/scenarios/`: whole stories with exact expected numbers, to the base unit: liquidations, settlements (IOUs in a $20 pool) and sales of a $10 one-minute BTC long at $83,884 (θ 3 bp, floor 1.3x, cap 4x); a repay queue; 500x and 100x beside 1000x on one pool, at every bound, with an IOU queue across leverages. `model/scenarios.py` derives every asserted number from the model | Every PR and push; CI checks the derivations (`model/scenarios.py --check`) |
| Signing vectors | `test/signing/Eip712Vectors.t.sol`: deployed at the vectors' address on their chain, the contract gives exactly the domain, digests and signatures of `test/fixtures/eip712_vectors.json` (§7) | Every PR and push |
| Upgrade | `test/upgrade/Upgrade.t.sol`: a proxy with real state (bets and IOUs at three leverages, claimable payouts, changed settings and roles) upgraded to a V2 mock with an upgrader-only `reinitializer(2)`: only the implementation slot, the initializer version and the new field change, every view reads the same, V2 carries on with V1's bets, and a rollback changes only the implementation. `layout/check.py`: the plugin against the base, every deployed version and 15 variants | `forge test`; the layout check in its own CI job |
| Fork (real USDG) | `test/fork/`, on a fork of Robinhood Chain mainnet with the real USDG: EOA, ERC-1271 and EIP-7702 stakes, a frozen winner, a pause, a cancelled authorisation, a transfer's gas against `_MIN_PAY_GAS`; and the mock beside the real token, step by step | Weekly, on PRs touching the contract, the mock or the fork tests, and on demand (`fork.yml`); skipped without `ROBINHOOD_RPC_URL` |
| Scripts | `test/script/`: the deploy sequence through each script's own `run()`; each script's checks failing on each value they guard; the deployed market settings held to the tested ones; bad inputs refused | Every PR and push |
| Gas | `test/gas/Gas.t.sol`: each call's execution and calldata gas, from cold state, worst case ([gas.md](gas.md)) | CI fails if the snapshots or gas.md drift, or a number rises over 5% above the base (label `gas-regression-accepted` for a deliberate rise) |
| Coverage gate | `forge coverage` of `src/`: every line, function and reachable branch; the one unreachable branch (`toUint16`'s guard, behind `gBps`' clamp) is listed with its reason in `test/coverage/check.py`, which fails if a test ever takes it | CI's Coverage job |
| Static analysis | Slither 0.11.6 on `src/` (triage: `audit/static-analysis.md`), `forge lint`, solhint | CI fails on any new finding or warning |

---

## 14. Design choices

Each feature below is deliberate, and answers a way a bet, a key or a token could fail.

- **The safety refund** (§8.6): if the backend never settles a bet, anyone returns its stake once the refund delay
  after expiry has passed (24 h by default, at least 1 h, or 0 for off). No brake stops it; it only returns the user's
  own stake.
- **The payout circuit breaker** (§8.11, ADR 0003): a stolen relayer key with wallets of its own could open at fake
  prices and end at real ones, so profit paid is counted against losses kept in a window, and opens and sales stop
  once the net passes the limit. Endings, repayments, refunds and claims go on.
- **Claimable payouts for frozen USDG users** (§8.8): a payout the token refuses waits in `claimable`, so a frozen or
  blocklisted user can't block a batch or the IOU queue, and `claim` pays only that account. Running out of gas is not
  a refusal: it reverts. Fees accrue and are swept, so a frozen fee wallet blocks nothing either.
- **The guardian and the halt** (§4.2, §8.9b, §8.10): the guardian halts everything, pauses a market or revokes a
  relayer key at once, but can't undo a stop, touch another role or move money; only the operator releases a stop. A
  pause stops only open and sell, so open bets still end and pay. Opening and settling use separate keys (ADR 0005).
- **Withdrawals keep the open bets' maximum profit covered** (§8.1): free money must still hold the floor plus every
  open bet's maximum profit, and nothing can be withdrawn while winners are owed.
- **The bounded open gate and clock skew** (§8.1, ADR 0009): the gate between 1 bp and 100%, the skew at most 30 s, so
  a leaked operator key can't let bets in beyond full cover or let a settler end a bet more than 30 s early.
- **The user's signature covers the leverage and the order** (§7): an `OpenOrder` names the market id and the
  leverage, so no relayer can open the bet at another, and carries `notBefore` and a `deadline` of about 30 s; a sale
  needs the position's user's own `SellOrder`. One market per feed and leverage (ADR 0008); each bet keeps its own
  copy of the leverage (§6.4).
- **The stake moves by an EIP-3009 authorisation** (§7, ADR 0002): exactly the stake, once, nonce = the position id,
  submitted only by the contract, which checks its balance rose by exactly that. No allowance is ever left standing.
- **A sale must land before its bet expires** (§8.3), or a sale priced with a tick up to the price age old could land
  after the expiry and race the settle.
- **Batches skip ended bets and hold up to 100** (§8.4–§8.6): a bet ended since the batch was built is skipped, so a
  race can't sink the batch; an id that doesn't belong reverts with that id, so the backend can drop it and resend.
- **Endings never wait for a fresh price:** liquidations accept old ticks, and a settle binds to the tick at the expiry
  second, so after an outage every bet can still end (§15 rule 14).
- **The IOU queue is first in, first out** (§8.7): while anyone is owed, a new winner's whole profit joins the queue
  and sales are refused; opens stop once the total owed passes `maxTotalOwed`.
- **Settings that could never work are refused**, such as `entryMaxAgeSecs = 0`. A duration rule's length is a
  `uint16` (at most 65,535 s), and times are `block.timestamp` seconds, never negative.

---

## 15. Security design rules (short form; full checklist in [security-checklist.md](security-checklist.md))

1. Access control on every state-changing function, tested negatively, role by role.
2. Proxy safety: `_disableInitializers()` in the constructor; `initialize` called inside the proxy deployment, so
   nobody can front-run it; `_authorizeUpgrade` gated; the layout validated in CI.
3. Checks → effects → interactions everywhere, plus `nonReentrant`. The only external calls are to the token. The one
   exception is `fund`, which pulls before it books, because it books what actually arrived (§8.8). Every
   state-changing function is re-entered from inside a token transfer in `test/concrete/reentrancy/`.
4. SafeERC20 for every token call. Pulls are checked by balance delta, and pushes never revert a batch.
5. EIP-712 with a bound domain, single-use ids and deadlines. ECDSA first, then ERC-1271.
6. No `block.number`: on Arbitrum chains it returns an L1 block number. Time checks use `block.timestamp` with
   `clockSkewSecs`.
7. No unbounded loops: batches are capped at 100 and repay at 50.
8. No hard-coded gas stipends; `MIN_PAY_GAS` is a lower bound only.
9. Checked maths everywhere money moves; explicit range checks on every narrowing cast; `floorDiv` for signed division.
10. Keys:
    - Mainnet: anything that moves money or changes code goes through the 48 h timelock. The guardian can only halt,
      pause and revoke relayer keys. Relayers can't move pool money except through the maths.
    - A leaked relayer key can, at worst, open and end positions within the config bounds at prices it chooses. With
      attacker-made user wallets, that can drain free money (the Ostium pattern), so we rely on fast detection, the
      guardian, and the payout circuit breaker (§8.11, ADR 0003), which caps what such a loop takes in a window.
11. Settle and liquidate must never revert because of a stored position, for any positive price. Proven by fuzzing
    every stored-position shape, so a batch can't get stuck.
12. Views that integrators may read (`getPool`, `freeMoney`) revert while the reentrancy guard is held, which blocks
    read-only reentrancy.
13. No ERC-2771 meta-transactions, no `Multicall`, no `delegatecall`, no `selfdestruct`, no `tx.origin`, no
    `code.length` checks to decide whether a caller is an EOA (EIP-7702 broke that).
14. Freshness limits apply to open and sell only. Settle binds to `publishTime == endTime` with no freshness limit, and
    liquidate accepts old ticks, so an outage never leaves positions impossible to end. `refundExpired` is the last
    resort if the backend never comes back, which is why the safety refund exists.
