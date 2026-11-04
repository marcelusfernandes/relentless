<!-- relentless:owned -->
# Layer: worktrees

## Orchestrator
- One writer per worktree. Create each implementer's branch and worktree with `worktree-create.sh`, which runs `gh issue develop`; never share a checkout across parallel implementers.
- Remove a worktree only after its PR is merged.

## Implementer
- Work only inside the worktree you were given, with `RELENTLESS_ROLE=implementer` and `RELENTLESS_WORKTREE` set to it.
