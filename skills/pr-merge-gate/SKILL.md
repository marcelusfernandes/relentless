---
name: pr-merge-gate
description: Final orchestrator step after isolated review — resolve merge:auto/human, require CI + review:approved, merge commit or post ready-to-merge. Retargets stacked PRs before branch delete.
---

# PR merge gate (orchestrator FINAL step)

After the **isolated** reviewer returns and you run `apply-review-verdict.sh`:

## Sequence (mandatory — no human resume)
1. Implementer stops at `state:review` — **never** self-reviews or applies `review:approved`.
2. **Orchestrator** builds bundle and spawns isolated reviewer (prefer `run-isolated-review.sh --also-merge`).
3. `core/scripts/apply-review-verdict.sh --repo … --issue … --pr … --verdict approved|changes_requested`
   - `approved` → `review:approved` + `state:review`
   - `changes_requested` → **`state:in-progress`** (implementer resumes)
4. **If approved → run merge-if-ready** (do not stall):
   ```bash
   core/scripts/merge-if-ready.sh --repo OWNER/NAME --pr N --issue N
   ```

## merge-if-ready behavior
- Mode: issue `merge:auto` / `merge:human`, else `.relentless/config.json` → `merge.default`.
- Requires `review:approved` and CI green on the PR **head SHA**.
- The latest `relentless:review-verdict` comment must record that full `headRefOid`. No SHA refuses the merge. A different SHA removes `review:approved` and refuses.
- **auto:** retarget open PRs whose base is the head branch onto the PR base (usually `main`) → `gh pr merge` with the method the repo allows → delete branch only if no dependents remain → `state:done`, close issue, 🤖 merged comment.
- **human:** post 🤖 ready-to-merge comment and **wait** (do not merge).

## Helpers
- `run-isolated-review.sh` — bundle + nested reviewer (stdin) + apply + optional `--also-merge`.
- `wait-ci.sh --repo … --pr N` — foreground poll. Exit 0 green, 1 real failure, 3 still pending (re-run on the next step), 4 `CI unavailable (quota)` (do not retry CI). Do not background it. On exit 4, `merge-if-ready` itself runs `checks.install`, `checks.lint`, `checks.typecheck`, `checks.test`, and `checks.build` in a clean worktree at the PR head. A local failure is exit 1. `merge:auto` may merge after a pass and posts `<!-- relentless:local-checks -->` plus label `ci:local`. `merge:human` does not merge.
- `comment-agent.sh` — 🤖 + authorship marker without heredoc pain.
- `build-review-bundle.sh` — issue + QA + diff with lockfiles stripped.
