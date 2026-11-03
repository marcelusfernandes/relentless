# ADR 0001 — Worktree per writer

- **Status:** accepted
- **Date:** 2026-10-31 (America/Sao_Paulo)
- **Issue:** #0
- **Human gate:** required (`human:pending` → `/decide`)
- **Decider:** Marcelus

## Context
Stacked PRs and shared checkouts caused agents to collide (dirty trees, wrong base branches, `base_ref_deleted` after merges). Lineage marvinz → apollo → lohra-ts proved one writer per worktree from a fresh copy of the repository default branch.

## Options

### 1. One git worktree per implementer from the repository default branch; remote branch push is the lock
- Pros: isolation; no shared dirty tree; clear lock; cleanup after merge
- Cons: more disk; need `.worktreeinclude` for local secrets

### 2. Shared primary checkout with branch switching
- Pros: simple
- Cons: parallel writers collide; stacked PR pain (rejected)

### 3. Persistent long-lived agent branches without worktrees
- Pros: fewer paths
- Cons: stale bases; easy to commit on wrong branch (rejected)

## Decision
Option 1 accepted on 2026-10-31. Skill worktree-segura; scripts worktree-create/cleanup; hook protect-worktree-write when the worktrees layer is on. The protect-main hook was removed; the repo's branch protection and the githooks layer are the lock. There is no Stop hook.


## Consequences
Positive / negative / follow-ups.

## Evidence
