# Security policy

## Reporting a vulnerability

Please **do not open a public GitHub issue** for a security problem. Report it privately to the repository's
maintainers, with:

- what you found, and where (contract, function, line);
- how to reproduce it (a Foundry test is ideal);
- the impact you expect (funds at risk, denial of service, wrong accounting).

We will acknowledge the report, investigate, and keep you updated until it is fixed.

## Scope

- The contracts in `src/` and their deployment scripts in `script/`.
- Deployed addresses will be listed in `deployments/` once they exist. Nothing is deployed from this repository yet.

## How the design handles security

- [`docs/security-checklist.md`](docs/security-checklist.md): every known pitfall that matters for this
  contract, the rule that answers it, and the test that proves it.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §15 and [`docs/adr/`](docs/adr/): the security design rules
  and the decisions behind them (roles and timelock, the circuit breaker, EIP-3009 stake pulls).
- [`audit/static-analysis.md`](audit/static-analysis.md): every static-analysis finding and how it was resolved, and
  the test coverage of `src/`.
