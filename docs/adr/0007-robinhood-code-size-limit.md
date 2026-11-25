# 0007: Contract size: Robinhood Chain's limit, 98,304 bytes

**Status:** Accepted · **Date:** 2026-11-10

## Context
- The design coded to Arbitrum One's limit, 24,576 bytes (EIP-170), so the contract could also deploy there
  (ARCHITECTURE §2).
- With the markets, the pool and the signed orders written, `ManicFlashOption` is 18,580 bytes, and the largest
  functions are still to come: open, sell, liquidate, settle, repay, the refund, the views and the breaker. Each
  inlines the maths it uses, so the finished contract would very likely pass 24,576 bytes.
- The target chain is Robinhood Chain: the testnet (46630), then mainnet (4663). Arbitrum One's 24,576-byte limit
  binds only a deployment on Arbitrum One.
- Robinhood Chain is an Orbit chain with its own parameters. Probed live on 2026-11-10 with read-only `eth_call`
  deployments, on both 4663 and 46630:
  - runtime code of 98,304 bytes deploys, and 98,305 bytes is refused ("max code size exceeded");
  - initcode of 196,608 bytes deploys, and 196,609 bytes is refused.

  That is the "96 KB" Robinhood's docs state, exactly.

## Decision
- `ManicFlashOption` must fit Robinhood Chain's limits: **98,304 bytes** of runtime code and **196,608 bytes** of
  initcode. Arbitrum One's 24,576 bytes no longer binds.
- `foundry.toml` sets `code_size_limit = 98304` for every profile. Foundry 1.8.7 uses it in two places:
  - `forge build --sizes`, which CI runs, fails above it;
  - the test EVM refuses to deploy anything larger, as the chain would.

  It derives the initcode limit, 196,608 bytes, from it, which is also Robinhood's. This was checked with a
  25,217-byte contract: refused at Foundry's default limit, accepted with this one.
- Every PR still states the size; the PR template's limit is 98,304 bytes.

## Consequences
- No size work (lens contracts, linked libraries, `delegatecall` modules) for the foreseeable future: about 80 KB of
  headroom when this was decided.
- Once the contract passes 24,576 bytes, it can't deploy as it is on Arbitrum One or any other EIP-170 chain. Moving
  there later would need a split: for example, the views in a separate lens contract.
- ADRs 0001 and 0006 judged their alternatives (Diamond, separately deployed modules) as needed only above a 24 KB
  limit. The limit is now 98,304 bytes, so both decisions stand, more firmly.
- Gas per call is unchanged. Size costs only at deployment: 200 gas per byte of code deposited.
- An Orbit chain's owner can change its limits. Before each deployment, re-check them with two read-only calls
  (`PUSH3 n, PUSH1 0, RETURN` deploys `n` zero bytes):
  ```bash
  cast call --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" --create 0x620180006000f3   # 98,304 bytes: returns the code
  cast call --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" --create 0x620180016000f3   # 98,305 bytes: "max code size exceeded"
  ```

## Alternatives considered
- **Keep 24,576 bytes and split now:** stays portable to Arbitrum One, but means a lens contract or linked libraries
  today: more audit surface, more deployments, and two addresses for the backend, for a chain we don't deploy to.
- **A linked external library for the maths:** shrinks the main contract, but adds a deployment, a linking step and
  another code address to trust, against the "no linked libraries" rule (CONVENTIONS §1).
- **`optimizer_runs = 1`:** saves only about 600 bytes, and makes every call cost more.
