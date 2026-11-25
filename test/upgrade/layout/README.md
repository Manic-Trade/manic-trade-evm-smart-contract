# `test/upgrade/layout/`: the upgrade-safety check

`check.py` runs OpenZeppelin's upgrades plugin (`@openzeppelin/upgrades-core` 1.48.0, the validator that
`Upgrades.validateUpgrade` calls) on `ManicFlashOption`. Storage is read by position, so a new version that moves one
field scrambles every value behind the proxy, and nothing reverts to warn anyone
([ARCHITECTURE §5](../../../docs/ARCHITECTURE.md)). The plugin compares two builds' storage layouts and reports any
field that moved, changed type or disappeared. It also refuses code an upgradeable contract must not have, such as an
immutable or a `selfdestruct`.

## What it checks

| Check | Against | Must |
|---|---|---|
| The current code | nothing | be upgrade-safe |
| The current code | `--base <ref>`: in CI, the pull request's base, or the previous commit on a push | keep the base's layout |
| The current code | every `deployments/<chainId>/build-info-v<version>/` (none until the first deployment) | keep the deployed layout |
| Each variant below | the current code | pass or fail exactly as its header says, with the reasons it names |

The variants show that the check is live on our storage, not silently skipped, and what each rule of §5 looks like
when it is kept or broken. They don't pin today's layout: `test/unit/FlashOptionStorage.t.sol` does that, slot by slot,
and the base check keeps any pull request from changing it.

## Running it

From the repository root, with Foundry and Node.js 22 on `PATH`:

```sh
python3 test/upgrade/layout/check.py --base origin/dev   # everything; about a minute
python3 test/upgrade/layout/check.py --only 06           # one variant
python3 test/upgrade/layout/check.py --keep              # keep the temporary builds, to look inside
```

Each build uses foundry.toml's `upgrades` profile (the AST, the build-info and the `storageLayout` output) and goes to
a temporary folder, so `out/` and `cache/` are never touched. No FFI: the validator runs as a normal process.

## The variants

Each `variants/NN-name.patch` is a `git diff` of `src/` with one change, under a header:

```text
# Rule: the rule of §5 it keeps or breaks
# Change: what the patch does
# Expect: pass | fail
# Reason: text the validator must print (one line each; only for fail)
```

| Variant | Change | Plugin |
|---|---|---|
| 01-append-field | `Layout` gains `newSetting` at its end, set by a `reinitializer(2)` only the upgrader can run | passes |
| 02-append-enum-member | `Status` gains `Archived` after `Closed` | passes |
| 03-append-position-field | `Position`, stored in a mapping, gains a field at its end | passes |
| 04-fill-unused-bytes | a `uint64` inserted into slot 2's unused bytes: nothing moves | passes (§5 still forbids it) |
| 05-rename-field-annotated | `feeRecipient` renamed `treasury`, with `@custom:oz-renamed-from feeRecipient` | passes |
| 06-move-field | `claimable` moved above `iouQueue` | Deleted `iouQueue`, Inserted `iouQueue` |
| 07-insert-field | a `uint256` inserted before `pool` | Inserted `newSetting` |
| 08-grow-embedded-struct | `PoolState`, embedded in `Layout`, gains a field | Upgraded `pool` to an incompatible type |
| 09-resize-array | `Market.durations` from 5 rules to 6 | Bad array resize from 5 to 6 |
| 10-retype-field | `Position.entryPrice` from `int64` to `uint64` | Bad upgrade from int64 to uint64 |
| 11-rename-field | `feeRecipient` renamed `treasury`, without the annotation | Renamed `feeRecipient` to `treasury` |
| 12-remove-field | `rewardsRecipient` removed | Deleted `rewardsRecipient` |
| 13-reorder-enum | `Status`'s `Owed` and `Closed` swapped | Deleted `Owed`, Inserted `Owed` |
| 14-drop-annotation | `Layout`'s `@custom:storage-location` removed | Deleted namespace `erc7201:manic.storage.FlashOption` |
| 15-add-immutable | an immutable set in the constructor | Variable `_DEPLOYED_AT` is immutable |

Two of these are worth knowing before writing a real V2:
- **04:** the plugin checks where each field sits, not the order they are declared in, so a field that only fills
  unused bytes passes. §5 still forbids inserting anywhere but the end, for whoever reads `Layout` next, and only review
  enforces that.
- **05 and 11:** a renamed field needs `@custom:oz-renamed-from <old name>` on the line above it. That includes the
  `__deprecated_<name>` renames §5 rule 5 uses to retire a field.

A real V2's reinitializer (01) isn't checked as an initializer: the plugin skips reinitializers unless they carry
`@custom:oz-upgrades-validate-as-initializer`, which would then require them to call every parent's initializer again.

## When a patch stops applying

A change to `src/` near a patch's lines makes `git apply` refuse it, and the check fails with "does not apply". Remake
the patch on the new code: make the same change in a scratch copy, take `git diff` of `src/`, and put the header back.
The reasons can stay: they quote the validator's words about fields and types, never line numbers.
