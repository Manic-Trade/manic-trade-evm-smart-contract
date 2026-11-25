# 0002: Pull each stake with EIP-3009, never a standing allowance

**Status:** Accepted · **Date:** 2026-11-09

## Context
Users never hold ETH; the backend relays every transaction. The usual pattern (an EIP-2612 `permit` for a
large allowance, then `transferFrom` per bet) leaves every user with a standing approval on our contract,
so one bug in a `transferFrom` path could drain every approved wallet. A `permit` sent by anyone can also be
front-run to make our transaction revert.

## Decision
With each order the user also signs USDG's EIP-3009 `ReceiveWithAuthorization` for exactly `stake`, with
`nonce = positionId` and `to =` our proxy. `open` calls `receiveWithAuthorization`, which only the `to`
address may submit, then checks the contract's balance rose by exactly `stake`.

## Consequences
- No allowance ever exists, so a contract bug can never pull more than one order's stake from a user.
- Front-running is impossible, because only our contract can submit the authorisation.
- The backend signs two EIP-712 messages per order (the `OpenOrder` and the authorisation), both through its
  custody signer in one request.
- USDG on Robinhood Chain supports it (checked live on 2026-11-09), and so does USDC, so a token change
  would not change the design.
- USDG treats an EIP-3009 nonce that was already used or cancelled as a **silent no-op**: it emits
  `AuthorizationAlreadyUsed`, moves nothing and does not revert. A user (or the backend's custody signer) can also
  cancel an authorization before the relayer submits it. So `open` must check that its balance rose by exactly
  `stake` (`TransferAmountMismatch`), or a position could open with no stake. `MockUSDG` reproduces this behaviour.

## Alternatives considered
- **Bounded `permit` allowance, renewed automatically:** smaller change for the backend, but users keep a
  standing allowance.
- **Permit2:** another external dependency, and still a standing approval to Permit2.
