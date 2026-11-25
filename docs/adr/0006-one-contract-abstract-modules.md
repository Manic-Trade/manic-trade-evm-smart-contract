# 0006: One deployed contract, built from abstract modules over a shared base

**Status:** Accepted · **Date:** 2026-11-09

## Context
The contract has about thirty external functions across admin, trading, settlement, pool money and views.
One large file is hard to read and review. Separately deployed modules (Euler's `delegatecall` pattern)
add deployment and upgrade complexity we don't need under the 24 KB size limit.

## Decision
- Exactly **one** deployed implementation, `ManicFlashOption`, assembled by inheritance:
  `ManicFlashOption → modules/* → base/FlashOptionBase → base/FlashOptionStorage`.
- `FlashOptionStorage` is an **abstract contract** holding the ERC-7201 `Layout`. It must be a contract, not a
  library or a file-level struct: the OpenZeppelin upgrades plugin only finds namespaced structs declared in
  contracts of the inheritance chain, and would otherwise skip the layout check without any error.
- `FlashOptionBase` holds the OpenZeppelin bases, the roles and every internal helper two modules need
  (payouts, gates, signature checks, book-keeping).
- **Modules never call or override each other**, and our own functions are never `virtual`.
- Pure logic lives in internal libraries (`LeverageMath`, `OrderLib`, `BreakerLib`). The circuit breaker is a
  library, not a module, because both trading and settlement update it.
- The full layout and rules are in `src/README.md` and `docs/CONVENTIONS.md` §1.

## Consequences
- Each file is small and has one job, and the dependency direction is easy to check in review.
- The compiler still sees one contract, so size, selectors and storage are checked as a whole.
- The inheritance order of the OpenZeppelin bases is set in `FlashOptionBase`. It doesn't move storage (each
  OpenZeppelin base uses its own ERC-7201 namespace), but it fixes the order of initializer calls.

## Alternatives considered
- **One large contract file:** simplest to compile, hardest to read and review.
- **Separately deployed modules with `delegatecall`:** only needed above 24 KB; adds proxies, selectors to
  route, and upgrade steps per module.
- **Diamond (ERC-2535):** the same, plus a large audit surface.
