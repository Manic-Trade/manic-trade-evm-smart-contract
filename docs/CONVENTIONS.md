# Conventions

These rules apply to everything in this repo. When they are silent, follow the
[Solidity style guide](https://docs.soliditylang.org/en/latest/style-guide.html), then
OpenZeppelin's [GUIDELINES.md](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/GUIDELINES.md).
Tooling enforces most of them (`forge fmt`, `forge lint`, `solhint`, and `bulloak check` for the tree tests). CI fails
on any violation.
The design these rules serve: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## 1. Layout

- One deployed contract, `ManicFlashOption`, built by inheritance. No delegatecall modules, no linked libraries.
- Dependency direction is one-way: `ManicFlashOption` → `modules/*` → `base/FlashOptionBase` →
  `base/FlashOptionStorage`. Libraries and types may be imported by any layer.
- **Modules never call or override each other.** Anything two modules need lives in `FlashOptionBase` or a library.
- **Interfaces first, in one fixed order.**
  - Every parent list starts with our interfaces: a module's slice, then `IManicFlashOptionEvents`,
    `IManicFlashOptionErrors`, `IManicFlashOptionRoles`, then OpenZeppelin's bases.
  - So: `ManicFlashOption is IManicFlashOption, <modules>` and `AdminModule is IManicFlashOptionAdmin, FlashOptionBase`.
  - Any other order fails to linearize (ARCHITECTURE §3.2).
- `ManicFlashOption.sol` holds only: the `is` list, the constructor, `initialize`, `reinitializer(n)` functions,
  `_authorizeUpgrade` and `version()`.
- One contract, interface or library per file; the file is named after it.
- `types/StorageTypes.sol` and the `Layout` struct are **frozen**: append-only (ARCHITECTURE §5).
  Any diff to them needs a storage review, and CI's upgrade-safety job (`test/upgrade/layout/check.py`, the upgrades
  plugin) must pass.
- A `reinitializer(n)` is also `onlyRole(UPGRADER_ROLE)`, and runs inside the upgrade's `upgradeToAndCall`.

## 2. Storage

- The only storage is the ERC-7201 `Layout` struct in `FlashOptionStorage`. No state variables anywhere else,
  no immutables. Constants are fine.
- Access it as `Layout storage $ = _getFlashOptionStorage();` at the top of the function.
- A renamed or retired field carries `/// @custom:oz-renamed-from <old name>` on the line above it (ARCHITECTURE §5
  rule 5).
- Work on storage pointers, never on memory copies:
  ```solidity
  Market storage m = $.markets[idx];   // good
  Market memory m = $.markets[idx];    // bad: 8 SLOADs, and writes are silently lost
  ```
- Pool books (`total`, `lockedMargin`, `openMaxProfit`, `totalOwed`, `feesPending`, `totalClaimable`)
  change only inside the `FlashOptionBase` helpers. `docs/storage-layout.md` lists which function writes which field.

## 3. File header and imports

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlashOptionBase} from "../base/FlashOptionBase.sol";
import {OpenOrder, OpenTerms, StakeAuth} from "../types/OrderTypes.sol";
```
- Exact pragma everywhere. Named imports only. Groups (`@openzeppelin`, `forge-std`, project) are separated by a
  blank line; `forge fmt` sorts inside each group.
- `src/` imports are relative; `test/` and `script/` import `src/...`.

## 4. Order

- File: pragma, imports, then the one contract/interface/library.
- Contract: `using` → constants → modifiers → functions.
- Functions: constructor, external, public, internal, private; `view`/`pure` last in each group.
  External functions follow ARCHITECTURE §8 order, and the interface declares them in the same order.
- Header modifiers: visibility, mutability, `override`, then `nonReentrant`, then access control:
  `external override nonReentrant onlyRole(OPENER_ROLE)`.

## 5. Naming

| What | Rule | Example |
|---|---|---|
| Contracts, structs, enums, events, errors | CapWords | `SettlementModule`, `OpenOrder` |
| Interfaces | `I` prefix | `IManicFlashOptionTrading` |
| Modules | `<Area>Module`, `abstract` | `PoolModule` |
| External/public functions | mixedCase, verb first | `refundExpired` |
| Internal/private functions (contracts) | `_mixedCase` | `_pay` |
| Library functions | no underscore | `LeverageMath.payout` |
| Parameters, locals | mixedCase; trailing `_` only to avoid shadowing | `positionId`, `token_` |
| Constants | UPPER_SNAKE. In contracts, internal and private ones start with `_` (solhint); library ones don't | `OPENER_ROLE`, `_MIN_REFUND_DELAY_SECS`, `LeverageMath.BPS` |
| Events | past tense, subject first | `PositionSettled` |
| Errors | the failed condition, plain; the names are part of the public interface, and the backend keys off them | `SellWindowClosed` |
| Mappings | named keys and values | `mapping(address account => uint64 amount) claimable;` |

Return values are unnamed unless there are several or the meaning isn't obvious.

Never name anything `at` or `error`: both become keywords in Solidity 0.9. The compiler warns today, and CI treats the
warning as an error.

## 6. Types, errors, events

- Structs and enums: file level in `src/types/`. Never redeclare a type elsewhere.
- Errors: only in `IManicFlashOptionErrors`. Events: only in `IManicFlashOptionEvents`. Each one is declared once.
- `IManicFlashOption` aggregates every API slice + events + errors + the OZ interfaces. It is the backend's ABI;
  `abi/IManicFlashOption.json` is regenerated with `forge inspect IManicFlashOption abi --json` and committed.
- Changing an event, an error, a function signature or an EIP-712 type string is an **ABI change**:
  use the `!` marker or a `BREAKING CHANGE:` footer, update CHANGELOG.md and tell the backend owner.
- Enums are stored as `uint8`, so they are append-only.

## 7. Function bodies

- Checks → effects → interactions. The only external calls are to the token.
- Write each check as `if (!cond) revert ErrorName();` — no `require` strings.
- Run the checks **in the order listed in ARCHITECTURE §8**. The interface NatSpec "Requirements" list, the
  `.tree` file and the revert tests must match that order.
- Emit an event right after the state change it describes, and before the token interaction unless it
  needs the interaction's result (for example `PayoutDeferred`).
- Emit the three widest events (`PositionOpened`, `PositionSettled`, `PositionSold`) from a small private helper
  that reads the fields from one memory struct. Emitted inline, they don't compile without via-IR ("stack too
  deep", ARCHITECTURE §11.1).
- Use named arguments for calls and struct literals with 4 or more values:
  `_closePosition({id: id, status: Status.Closed, clearSlot1: true});`.
- Do the maths in `uint256`/`int256` and narrow once at the end, with an explicit range check (`MathOverflow`).
  Never write a bare `uint64(x)`.
- Use `unchecked` only for loop counters, with a comment saying why it can't overflow.
- Every rounding gets a comment saying who it favours: `// rounds down: pool favoured`.
- No `virtual` on our own functions; `override` only where OZ requires it and on interface implementations.

## 8. NatSpec

- Interfaces carry the documentation. Implementations use `/// @inheritdoc IManicFlashOptionX`.
- Every external/public function gets `@notice`, plus one `@param` per parameter and one `@return` per return
  value. Every event gets `@notice` + `@param`, every error `@notice` (+ `@param`), every public constant `@notice`.
- State-changing functions follow this layout:
  ```solidity
  /// @notice Settles expired positions at their end-time price.
  /// @dev Emits {PositionSettled} per settled id, {PositionSkipped} per id that already ended.
  ///
  /// Requirements (in check order):
  /// - Not halted (`Halted`).
  /// - `1 <= ids.length <= MAX_BATCH` (`EmptyBatch`, `BatchSizeTooLarge`).
  ///
  /// @param marketId The Pyth feed id of the market.
  /// @return processed The number of positions settled (skipped ids excluded).
  ```
- Add an `@dev` comment for every non-obvious idiom: assembly, `floorDiv`, gas guards, narrowing casts,
  `unchecked`, signature order (ECDSA before ERC-1271), rounding.
- Struct fields get a short `//` comment, and storage structs a `// slot N` map.
- Header of each `src/` file:
  ```solidity
  /// @title TradingModule
  /// @author Manic
  /// @notice Opens and sells leveraged positions.
  /// @custom:security-contact See SECURITY.md
  ```
- Comments explain *why*, not what the code already says. The maths is explained in [`MATH.md`](MATH.md).
- Until a dedicated security address exists, `@custom:security-contact` points to `SECURITY.md`.
- A justified lint exception sits on the line before the code, with its reason:
  `// casting to int256 is safe because ...` then `// forge-lint: disable-next-line(unsafe-typecast)`.
- A Slither finding we accept is marked the same way: its reason on the comment line above, then
  `// slither-disable-next-line <detector>` on a line of its own. Keep both lines to 120 characters, or `forge fmt`
  folds the reason into the directive and breaks it. Where another tool's directive must be the line just above the
  code (solhint's, on the storage accessor's assembly), wrap the code in `slither-disable-start` / `slither-disable-end`
  instead. Each one is listed in `audit/static-analysis.md`.

## 9. Tests

- Folders: `unit/` (libraries and test doubles, no proxy), `concrete/<fn>/` (BTT), `fuzz/`, `invariant/`, `access/`,
  `scenarios/`, `signing/`, `model/`, `upgrade/`, `fork/`, `gas/`, `script/`; shared code in `Base.t.sol`, `utils/`,
  `mocks/`, `harnesses/`. Rules that cross functions get their own `concrete/` folder without a tree: `views/`, `reentrancy/`,
  `brakes/`, `breaker/`, `counters/`, `leverages/`.
- Each state-changing function with ordered checks has `concrete/<fn>/<fn>.tree`.
  - Write the tree first, with the test contract's name as its root (`<Function>_Concrete_Test`).
  - Then run `bulloak scaffold -s 0.8.38 -w test/concrete/<fn>/<fn>.tree` (bulloak v0.8.1), and fill in the tests.
  - CI runs `bulloak check`, so the tests follow the tree branch for branch, in order.
- Each revert test breaks its own check and every later one, while every earlier check passes. Getting its own
  error then also proves the check order.
- Test contracts are named `<Function>_<Kind>_Test`. Test functions:
  `test_<Behaviour>`, `test_RevertWhen_<Condition>`, `test_RevertGiven_<State>`, `testFuzz_<Property>`,
  `invariant_<NN>_<Property>` (NN = ARCHITECTURE §12 number).
- Each test file opens with a `///` block: what it covers, which tree, which ARCHITECTURE section.
- Assert every event field, every changed storage field and every token balance. For reverts, assert the exact
  error and its arguments.
- No magic numbers in tests: use `Defaults`. No `vm.assume` where `bound` works.
- Tests deploy the proxy with `UnsafeUpgrades` (coverage-friendly, no FFI), and no test needs FFI. The upgrades plugin
  runs in `test/upgrade/layout/check.py`, which builds with `FOUNDRY_PROFILE=upgrades` and calls the validator itself.
  Learned building it:
  - Never declare a struct carrying `Layout`'s `@custom:storage-location`, even in a test contract: the plugin refuses
    two structs on one namespace (`DuplicateNamespaceError`), and then checks nothing in the whole build. A V2 mock
    reaches an appended field by its slot (`ManicFlashOptionV2Mock`).
  - A variant patch (`test/upgrade/layout/variants/`) names the plugin's reasons, not just pass or fail: a variant that
    fails for another reason (a typo that breaks the build, a different field) would otherwise prove nothing.
  - Prove what an upgrade touched with `vm.startStateDiffRecording()`: the slots it changed are the whole story.
- Invariant handlers (`test/invariant/`): inherit `BaseHandler` (the actors, the call counters, the checks around
  every call) and keep ghost state in `stores/FlashOptionStore.sol`. A handler never reverts: it draws inputs that must
  go through, and makes a call it expects to be refused with `_attempt`, checking the exact error. Learned building
  them:
  - Name every handler with `targetContract` as well as `targetSelector`. `targetSelector` alone narrows a contract's
    functions but leaves the fuzzer calling every other contract the set-up deployed, the token included.
  - Foundry picks each targeted function with equal odds, whichever handler it is in, so make a rare event rare inside
    its action (a brake goes on one call in twelve).
  - `vm.recordLogs()` keeps the logs of a call that then reverts, so code that reads logs must drop a refused call's
    (`_attempt` does).
  - Deploy handlers with `deployCode`: `new` copies each one's creation code into the test contract, which then passes
    the 98,304-byte limit.
  - One campaign per test contract checks every `invariant_` function after each call, so a new invariant adds no
    campaign.
  - A batch holds one market, and the contract checks a bet's market before its status, so even an ended bet of
    another market refuses the whole batch (`ConfigMismatch`). Build each batch from one market's bets.
  - The legacy pipeline runs out of stack in an action that both builds and sends a batch: build it in one helper and
    send it in another (`SettlementHandler`'s `_touchedBatch`, `_dueBatch` and `_sendBatch`).
- JSON fixtures (`test/fixtures/`): read them with `vm.parseJsonType` and an explicit type string, never `parseJson` +
  `abi.decode`, which orders struct fields alphabetically.
- The maths has a second implementation, `model/flash_option_math.py`. A change to the maths changes docs/MATH.md and
  the model first, then regenerates the vectors (`python3 model/generate_vectors.py`), and `test/model/` must pass
  with them. A vector that changes is a rule that changed, so its diff is reviewed with the code.
- A scenario test (`test/scenarios/`) comes with its derivation in `model/scenarios.py`: a function of the same name,
  in the class of its test contract, that works out every number the test asserts from the model and lists the test's
  other literals as inputs. `python3 model/scenarios.py --check` fails on a test without one.
- Gas: `vm.snapshotGasLastFrame("<name>")` in `test/gas/`; every change to `snapshots/` is explained in the PR.
- Fork tests (`test/fork/`, on `Fork_Base_Test`) fork Robinhood Chain mainnet through `ROBINHOOD_RPC_URL`, and skip
  themselves without it, so `forge test` never needs the network. The public RPC keeps only minutes of state, so they
  fork `ROBINHOOD_FORK_BLOCK` if it is set (the weekly fork job sets it to the latest block once per run) and the latest
  block if not; pinning an older block needs an archive RPC. Since the state moves, they check behaviour, never a
  balance or a supply they didn't set themselves.
- `vm.prank` applies to the next call, and an argument that calls the contract (signing a sale calls
  `hashSellOrder`) uses it up. Sign first, into a variable, then prank. `vm.expectCall(..., 0)` counts calls to the end
  of the test, so put a "never called" check last.

## 10. Scripts and deployments

- Inputs: `script/config/chains.toml` (one table per chain id). Outputs: `deployments/<chainId>.json`.
- Keys: `--account` (keystore) on testnet, `--ledger`/Safe on mainnet. Never put a private key in `.env`.
- Every script ends with assertions that revert on any mismatch (roles, config, implementation slot, domain,
  disabled markets, code size).
- After a deployment, copy the `upgrades` profile's `build-info/` to `deployments/<chainId>/build-info-v<version>/`,
  run `script/build_info.py` on it (no local path is committed), and commit it, together with `broadcast/` for that
  chain, once `script/bytecode.py` shows it is the deployed code (docs/runbooks/deploy-testnet.md, step 6). Never
  commit `cache/`.
- Scripts send from the address chains.toml names (`vm.startBroadcast(address)`), so a test runs the same `run()`
  with no key. On anvil, its well-known test keys may go on the command line; nowhere else.
- Revert messages in scripts may be long: an operator reads them to learn which value is wrong.
  `script/.solhint.json` is the test rule set with `reason-string` off, and CI lints `script/` with it.

## 11. Size and gas

- `ManicFlashOption` must stay ≤ 98,304 bytes, Robinhood Chain's limit (ADR 0007). `forge build --sizes` fails the
  build otherwise (`code_size_limit` in `foundry.toml`), and every PR states the current size.
- Keep modifier bodies to a single internal call (modifiers are inlined at every use).

## 12. Git

- Conventional Commits: `type(scope): imperative summary` (≤ 72 chars). Scopes: `admin trading settlement pool
  views base storage math orders breaker types interfaces script deploy test invariant fork gas ci deps docs`.
- Body: what and why; say whether storage or ABI changed.
- Footer: `BREAKING CHANGE: ...` for ABI changes.
- One logical change per commit, with its tests. Refactors and formatting are separate commits.

Example:
```text
feat(math): compute gBps with floor division

Solidity's signed `/` truncates toward zero, so a losing price move must
go through floorDiv, which rounds toward minus infinity, or the loss
rounds in the user's favour. Checked against the worked examples in
docs/MATH.md and a fuzzed reference floor.

Storage: no change. ABI: no change.
```
- **Merge commits, not squash.** Each commit stays in the history, so every commit must build, pass the tests and
  read well on its own. The PR title follows the same `type(scope): summary` format.
- One branch per change, branched from `dev` and merged into `dev` by pull request. `dev` is the default branch;
  `main` matches `dev` until the mainnet launch, and after it only receives what is deployed to mainnet.

## 13. Docs

- README: what it is, why Robinhood Chain, its status and addresses, the repo map and security. CONTRIBUTING.md:
  the quick start, the toolchain, the commands and how we work.
- CHANGELOG.md: per contract version; always lists ABI and storage changes.
- `docs/adr/NNNN-title.md` (MADR). Write one for every decision that someone could reasonably undo later.
  Never edit an accepted ADR; supersede it.

## 14. Freeze rule

The metadata hash covers the source text, comments included. After the audit freeze, **any** edit to `src/`,
even a comment or a reformat, changes the deployed bytecode. Batch such edits into the next versioned upgrade,
and never reformat a deployed source with a newer `forge fmt` outside an upgrade.

## 15. Further reading for this codebase

- [`security-checklist.md`](security-checklist.md): every pitfall that matters here, and the rule that answers it.
- [`MATH.md`](MATH.md): the maths the contract computes.
- [`adr/0004-toolchain.md`](adr/0004-toolchain.md): why each version is pinned.
- [`adr/`](adr/): the decisions behind the design.
