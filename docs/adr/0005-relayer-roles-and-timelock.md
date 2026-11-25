# 0005: Separate relayer keys, a guardian, and a timelock on everything that moves money

**Status:** Accepted · **Date:** 2026-11-09

## Context
Most money lost in 2024–2026 was lost through keys, not code: Bybit (~$1.5B), Radiant (~$50M), Moby and
Ostium on Arbitrum. Our backend keys are the price oracle, and an admin key can move money or change code.

## Decision
| Role | Holder on mainnet | Can do |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | 48 h `TimelockController`, proposed and executed by the admin Safe | Roles, markets, recipients, floor, refund delay, breaker limit, withdrawals |
| `UPGRADER_ROLE` | The same timelock | Upgrades only |
| `OPERATOR_ROLE` | The admin Safe, instant | Market settings, enable, unpause, unhalt, reset the breaker. None of these moves money |
| `GUARDIAN_ROLE` | An ops key | Halt, pause a market, revoke a relayer key. It can only take power away |
| `OPENER_ROLE` | Backend relayer accounts | `open`, `sell` |
| `SETTLER_ROLE` | Different backend relayer accounts | `liquidate`, `settle` |

On testnet the deployer holds all of these.

## Consequences
- Anything that could redirect funds waits 48 h, which gives the guardian time to halt and revoke.
- A leaked relayer key can only act inside the config bounds and the circuit breaker, and is revoked at once.
- Separate opener and settler keys also give separate nonce lanes, so a stuck open never delays settlement.
- Safe signers use hardware wallets and check transaction hashes on a second device. A Safe guard blocks
  `DELEGATECALL`.

## Alternatives considered
- **A single admin Safe with no timelock:** faster operations, but one compromised Safe transaction could
  grant a malicious relayer and drain free money at once.
- **One relayer role:** simpler, but one key compromise covers both opening and settling.
