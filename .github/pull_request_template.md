<!-- Title: `type(scope): imperative summary`, e.g. `feat(trading): reject prices before the order`. PRs are merged with a merge commit, so each commit in the branch must read well on its own. -->

## What and why
<!-- What changes, and the reason. Link the ARCHITECTURE section or ADR it implements. -->

## Impact
- [ ] **Storage:** no change / append-only (CI's upgrade-safety job passes: the layout against the base and every
      `deployments/<chain>/build-info-v…`)
- [ ] **ABI:** no change / changed (functions, events, errors or EIP-712 strings) → `abi/IManicFlashOption.json`
      regenerated, CHANGELOG updated, backend owner tagged
- [ ] **Roles / access control:** no change / changed (every gate has a negative test)
- [ ] **Money paths** (open, sell, liquidate, settle, refund, repay, withdraw, claim, sweepFees, fund): untouched /
      touched → invariants re-run with the deep profile
- [ ] **Code size:** `ManicFlashOption` = _____ bytes (≤ 98,304, Robinhood Chain's limit)
- [ ] **Gas:** no change in `snapshots/`, or every change explained below

## How it was tested
<!-- Commands and results, e.g. `forge test` (N passed), `python3 test/upgrade/layout/check.py --base origin/dev`,
     `forge coverage` (src lines/branches %), deep invariant run link. -->

## Checklist
- [ ] `forge fmt --check`, `forge lint` and `solhint` are clean
- [ ] `.tree` files updated and `bulloak check` passes
- [ ] NatSpec complete (interface `@notice`/`@param`/`@return`, Requirements list in check order)
- [ ] Checks run in the order of ARCHITECTURE §8, and the tests assert that order
- [ ] Slither: no new findings, or triaged in `audit/static-analysis.md`
- [ ] Docs updated (ARCHITECTURE, ADR, storage-layout.md, CHANGELOG) where relevant
- [ ] No secrets, RPC keys or private keys in code, config or `broadcast/`

## Notes for reviewers
<!-- Risky spots, open questions, follow-ups. -->
