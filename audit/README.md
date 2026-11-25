# `audit/`: static analysis, coverage and mutation testing

The triage of every automated finding on `src/` (fixed, or explained and accepted), the lints, the test coverage of
`src/`, and how well the tests catch real bugs.

- [`static-analysis.md`](static-analysis.md): Slither's findings, the lints, the coverage of `src/`,
  and what CI checks.
- [`mutation.md`](mutation.md): a mutation run, 35 single-point bugs put into `src/` one at a time, each caught by the
  tests, and the two tests it showed were missing.
- The threat model, and the rule that answers each pitfall:
  [`docs/security-checklist.md`](../docs/security-checklist.md).
