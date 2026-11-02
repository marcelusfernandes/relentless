---
name: worktree-segura
description: One implementer per git worktree from the repo base branch on branch <type>/<n>-<slug>. Use at the start of every implementation and whenever a write hook complains.
---

# Safe worktree (worktree-segura)

Lineage: marvinz → apollo → lohra-ts (ADR worktree-per-writer). Relentless ports the practice generically — no product-specific prova/stack.

## Doctrine
- **One writer per worktree.** Never share a checkout across parallel implementers.
- Branch from **fresh `origin/<base>`** (default `main`). **Never** branch off another feature branch.
- Branch name: `<type>/<issue>-<slug>` (e.g. `feat/12-add-login`).
- **Remote push of a new ref = lock.** If push fails because the branch exists, do not steal — pick another issue or resume that worktree.
- Remove the worktree **after** merge (`worktree-cleanup.sh` / merge-if-ready `--cleanup-worktree`), never before.
- When `layers.worktrees` is on, the worktree hook blocks writes outside the worktree. Commits and pushes on main are the repo's branch protection.

## A. Create (orchestrator or implementer start)
```bash
core/scripts/worktree-create.sh \
  --repo OWNER/NAME --issue N --slug SLUG --type feat \
  --workdir /path/to/primary-checkout
# prints: export RELENTLESS_WORKTREE=… ; cd …
```
Optional: `--parent DIR`, `--path DIR`, `--base main`, `--dry-run`, `--no-push`.

## B. Before the first line
1. `cd "$RELENTLESS_WORKTREE"` (or the path from create).
2. Base check: `git fetch origin && git merge-base --is-ancestor "origin/$(jq -r .base .relentless/config.json)" HEAD`.
3. Write probe: `printf x > .scratch && rm .scratch`.
4. If the primary repo has `.worktreeinclude`, create already copied those paths — confirm secrets/local files you need are present.
5. `export RELENTLESS_ROLE=implementer RELENTLESS_WORKTREE="$(pwd)"`.

## C. While working
- **No destructive git:** no `stash`, `reset --hard`, `checkout -- <file>`, `clean -fd`. Compare with `git diff` / `git show`. Recover with `git reflog` first.
- Checkpoint: commit when green. Uncommitted work exists only in this tree.
- Round 2+ (same issue after review): stay in **the same** worktree; pull/merge `origin/<branch>` if needed; never force-push.
- Conflict with the base branch on a published branch: `git fetch origin && git merge "origin/$(jq -r .base .relentless/config.json)"`.

## D. Before report back
Commit an intentional checkpoint before reporting back. git stash is forbidden. Passing tests and a clean worktree are part of that report; a failing test is a blocker, not a finished turn.

## E. After merge
Orchestrator / merge-if-ready cleans up:
```bash
core/scripts/worktree-cleanup.sh --path "$RELENTLESS_WORKTREE" --repo OWNER/NAME
```
