<!-- relentless:owned -->
# Layer: merge

This layer works only with `layers.review` also true. If review is off, ignore this file and follow the core rule: stop at `state:review`.

## Orchestrator
- Wait for CI in the foreground with `wait-ci.sh`; run it again while it reports pending. Do not background it or use `gh run watch`. Exit 0 is green, 1 a real failure, 3 pending, 4 CI unavailable (quota).
- CI red log: on a real failure (exit 1), read the failed job log and comment on the issue with the failing step, a short log tail, and the likely cause before resuming the implementer.
- If no test step ran (startup_failure, billing, spending limit, or minutes exhausted), it is not a code failure: do not change code and do not retry CI. Run `merge-if-ready.sh`, which runs the checks on the PR head and decides.
- Pin approval to SHA: before `merge-if-ready.sh`, compare the PR head SHA (`headRefOid`) with the SHA on the latest `relentless:review-verdict`. If the head changed or the verdict has no SHA, remove `review:approved` and run the review again.
- On `approved` with `merge:auto`, run `merge-if-ready.sh` (add `--cleanup-worktree` when the worktree is known), then set `state:done`.
- If `merge-if-ready.sh` exits non-zero, never post its messages, apply merge labels, or merge yourself. Ask for a decision as in the core rules, with its output quoted, and stop.

## Implementer
- After opening the PR, wait for CI with `wait-ci.sh` in the foreground and report its exit code. On exit 4, do not change code or retry CI; report ready for review.
