# 0004: Toolchain pins

**Status:** Accepted · **Date:** 2026-11-09

## Context
Deployed bytecode never changes, but we will rebuild this code for upgrades for years. Compilers, EVM
defaults and libraries keep moving: solc's default EVM target changed to `osaka` in 0.8.31, seven compiler
bugs were published in 2026, and Foundry minor releases have changed bytecode metadata.

## Decision
| Item | Pin | Reason |
|---|---|---|
| Solidity | 0.8.38, exact (`pragma solidity 0.8.38;`) | The only release with no known bugs; 0.8.36 has four (SOL-2026-4…7) |
| EVM target | `cancun`, explicit | Lowest target with PUSH0, TSTORE/TLOAD and MCOPY, which OpenZeppelin ≥ 5.5 needs; all target chains run ArbOS 61 |
| Pipeline | Legacy, optimizer 200 runs, `via_ir = false` | Four of 2026's compiler bugs were via-IR only; coverage stays accurate |
| OpenZeppelin | Contracts + Contracts-Upgradeable 5.6.1 | Newest audited release; 5.7.0 is unaudited |
| Foundry | v1.8.7 | v1.9.0 changed bytecode metadata and has a long "action required" list |
| forge-std | v1.17.0 | Needs Foundry ≥ 1.8.3 |
| Upgrades plugin | openzeppelin-foundry-upgrades v0.4.4 | Storage-layout validation; needs Node.js and FFI (only in the `upgrades` profile) |

## Consequences
- A rebuild years from now produces the same bytecode, as long as these pins and each deployed version's
  `build-info` (kept in `deployments/`) are preserved.
- Moving any pin is a deliberate change with its own PR and a check of the compiler bug list.
- Solidity 0.9 is in development; the code avoids what it removes (`send`, `transfer`, virtual modifiers,
  comparing contract types, identifiers named `at`, `error`, `layout`, `transient`).

## Alternatives considered
- **Latest of everything:** newest fixes, but also newest bugs (5.7.0 unaudited, Foundry 1.9 changes).
- **`osaka` target:** works on today's chains, but leaves no margin if an Orbit chain lags an upgrade.
