# Decision records

Each file records one architecture decision: what was decided, why, and what it costs. They are short
on purpose. Read them before changing the thing they decide; to reverse a decision, add a new record
that supersedes the old one rather than editing it.

| # | Decision | Status |
|---|---|---|
| [0001](0001-uups-proxy-with-erc7201-storage.md) | UUPS proxy with one ERC-7201 namespaced storage struct | Accepted |
| [0002](0002-eip3009-stake-pull.md) | Pull each stake with EIP-3009, never a standing allowance | Accepted |
| [0003](0003-payout-circuit-breaker.md) | A payout circuit breaker that stops opens and sales | Accepted |
| [0004](0004-toolchain.md) | Toolchain pins: solc 0.8.38, cancun, legacy pipeline, OZ 5.6.1, Foundry 1.8.7 | Accepted |
| [0005](0005-relayer-roles-and-timelock.md) | Separate relayer keys, a guardian, and a timelock on everything that moves money | Accepted |
| [0006](0006-one-contract-abstract-modules.md) | One deployed contract, built from abstract modules over a shared base | Accepted |
| [0007](0007-robinhood-code-size-limit.md) | Contract size: Robinhood Chain's limit, 98,304 bytes | Accepted |
| [0008](0008-one-market-per-feed-and-leverage.md) | One market per price feed and leverage, and the leverage in the signed order | Accepted |
| [0009](0009-bounded-open-gate-and-clock-skew.md) | Bound the open gate and the clock skew in `validate` | Accepted |

New records start from [`0000-template.md`](0000-template.md): Status and Date, then Context, Decision,
Consequences and Alternatives considered.
