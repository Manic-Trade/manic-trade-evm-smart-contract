# 0001: UUPS proxy with one ERC-7201 namespaced storage struct

**Status:** Accepted · **Date:** 2026-11-09

## Context
The contract must be fixable during testnet and early mainnet, so it is upgradeable. Upgrades are where
proxies most often go wrong: an uninitialised implementation, an open upgrade function, or a storage
layout that shifts between versions.

## Decision
- An OpenZeppelin 5.6.1 `UUPSUpgradeable` implementation behind an `ERC1967Proxy`.
- All state in **one** struct at an ERC-7201 namespace (`erc7201:manic.storage.FlashOption`). There are no
  contract-level state variables and no `immutable`s.
- The constructor calls `_disableInitializers()`. The proxy is deployed with `initialize` in the same
  transaction. `_authorizeUpgrade` is gated by `UPGRADER_ROLE`, which is held by a 48 h timelock on mainnet.
- The storage layout is append-only. The full rules are in `docs/CONVENTIONS.md`. The OpenZeppelin
  upgrades plugin checks every new version in CI.

## Consequences
- Calls pay no proxy admin check, so UUPS is the cheapest proxy per call.
- The upgrade logic lives in our implementation. If a new version forgot `UUPSUpgradeable`, it could never
  be upgraded again; OpenZeppelin 5 checks `proxiableUUID` on upgrade to prevent that.
- Field order in storage is permanent, and every PR touching `src/base/FlashOptionStorage.sol` or
  `src/types/StorageTypes.sol` needs extra review.

## Alternatives considered
- **Transparent proxy:** a `ProxyAdmin` per proxy and an admin check on every call. No benefit for one contract.
- **Beacon:** only useful for many proxies sharing one implementation.
- **Diamond (ERC-2535):** only for contracts over 24 KB; much larger audit surface.
- **No proxy:** the safest code, but bugs found on testnet could not be fixed in place. Reconsider freezing
  upgrades (renouncing `UPGRADER_ROLE`) once outside liquidity arrives.
