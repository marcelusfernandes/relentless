# ADR 0003 — CI quota exhaustion falls back to local checks run by merge-if-ready

- **Status:** accepted
- **Date:** 2026-10-31 (America/Sao_Paulo)
- **Issue:** #16
- **Human gate:** required (`human:pending` → `/decide`)
- **Decider:** human

## Context
Private and organization repositories have GitHub Actions minute limits. When the quota or spending limit is hit, jobs do not run (`startup_failure`, billing annotations, or a completed run with no steps). Treating that as a red test makes agents edit correct code and retry CI.

`wait-ci.sh` exits 4 with `CI unavailable (quota)` and does not retry. Only `merge-if-ready.sh` may then run `checks.install`, `checks.lint`, `checks.typecheck`, `checks.test`, and `checks.build` in a clean worktree at the PR head. It posts `<!-- relentless:local-checks -->`, applies `ci:local`, and re-reads the head SHA before merging. A real test failure stays exit 1 and does not take this path. If `checks.test` resolves to nothing, it labels `human:pending` and does not merge. `merge:human` still waits.

A self-hosted runner is how to keep real Actions CI. The rule in Decision is the owner's selection. This record stays proposed until the decider accepts it on issue #16 (https://github.com/marcelusfernandes/relentless/issues/16), which is the linked issue for PR #15.

## Options

### 1. `merge:auto` may merge when those local checks pass
- Pros: the wave continues when Actions minutes are gone and the head still passes the repo's own checks
- Cons: the merge is not backed by GitHub-hosted CI; a later push can invalidate the run (the script refuses if the head SHA moved)

### 2. `merge:auto` must wait for a human, the same as `merge:human`
- Pros: no merge until a person has seen that CI did not run
- Cons: autonomous waves stop at the quota even when local checks passed

## Decision
Option 1 accepted on 2026-10-31. merge:auto may merge on green local checks when CI is unavailable (quota).


## Consequences
`merge-if-ready` merges on that path only when `review:approved`, the `ADRs:` line, and the stable head SHA still hold. A local check failure is a normal test failure and does not merge. No test command labels `human:pending` and does not merge. A self-hosted runner remains the way to keep GitHub-hosted CI.

Agents must not run or report the checks themselves, and must not merge when `merge-if-ready` exits non-zero. They quote its output, label `human:pending`, and stop.

## Evidence
`wait-ci.sh` exit 4; `merge-if-ready.sh` local worktree; tests in `tests/scripts/test-wait-ci.sh`.
