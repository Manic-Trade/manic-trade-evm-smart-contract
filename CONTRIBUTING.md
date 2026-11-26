# Contributing

How to build, test and change the Flash Options contract. The coding, NatSpec, test and git rules are
in [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).

## Quick start

You need [Foundry](https://getfoundry.sh) **1.8.7**: every tool version is pinned
([ADR 0004](docs/adr/0004-toolchain.md)).

```bash
# Foundry, pinned
curl -L https://foundry.paradigm.xyz | bash
foundryup --install v1.8.7

# The repository and its pinned dependencies
git clone --recurse-submodules https://github.com/Manic-Trade/manic-trade-evm-smart-contract.git
cd manic-trade-evm-smart-contract

forge build
forge test
```

The fork tests need an RPC URL (`cp .env.example .env`, then fill it in), and skip themselves without one.

## Toolchain

| Tool | Version |
|---|---|
| Foundry | v1.8.7 |
| Solidity | 0.8.38, EVM target `cancun`, optimizer 200 runs, no via-IR |
| OpenZeppelin Contracts + Contracts-Upgradeable | 5.6.1 |
| forge-std | 1.17.0 |
| openzeppelin-foundry-upgrades | 0.4.4 (needs Node.js ≥ 18 for upgrade checks) |
| bulloak | v0.8.1, the release binary from [github.com/alexfertel/bulloak](https://github.com/alexfertel/bulloak) (the tree tests; CI checks the release's SHA-256; locally it is optional) |

## Commands

| Task | Command |
|---|---|
| Build, with contract sizes | `forge build --sizes` |
| Run all tests | `forge test` |
| Run one test file, verbose | `forge test --match-path test/Toolchain.t.sol -vvv` |
| Lint | `forge lint` (src) and `npx solhint@6.2.5 -c test/.solhint.json 'test/**/*.sol'` |
| CI-strength fuzzing | `FOUNDRY_PROFILE=ci forge test` |
| Deep fuzzing (100,000 cases per property; CI runs it each week `dev` changed) | `FOUNDRY_PROFILE=deep forge test --match-path 'test/fuzz/*'` |
| Deep invariant runs (1,000 runs of 100 calls per campaign; CI runs them each week `dev` changed) | `FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'` |
| Upgrade-safety check: the layout against `dev`, and the 15 variants (needs Node.js 22; CI runs it on every change) | `python3 test/upgrade/layout/check.py --base origin/dev` |
| The maths model: recompute MATH.md's worked examples | `python3 model/flash_option_math.py` |
| Check the model's vectors are current (CI runs it on every change) / regenerate them | `python3 model/generate_vectors.py --check` / `python3 model/generate_vectors.py` |
| Check the scenario tests' numbers against the model (CI runs it on every change) / print the derivations | `python3 model/scenarios.py --check` / `python3 model/scenarios.py [NAME]` |
| Format / check formatting | `forge fmt` / `forge fmt --check` |
| Coverage | `forge coverage` |
| Gas snapshot | `forge snapshot` |
| Regenerate the committed ABI | `forge inspect IManicFlashOption abi --json > abi/IManicFlashOption.json` |
| Check the tree tests | `bulloak check 'test/concrete/**/*.tree'` |
| Start a new tree's tests | `bulloak scaffold -s 0.8.38 -w test/concrete/<fn>/<fn>.tree` |

## How we work

- **Branches:**
  - `dev` is the default branch and always holds stable, tested code.
  - `main` only receives code that is deployed to mainnet.
- **One branch per change,** branched from `dev`:
  1. The work is developed and fully tested there.
  2. It goes into `dev` through a pull request.
  3. Each pull request includes its own tests and documentation.
- **Commits** are small and explain what changed and why.
- Pull requests are merged with a merge commit (not squashed), so every commit stays readable in the history.
- The coding, documentation, test and commit rules are in [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).
