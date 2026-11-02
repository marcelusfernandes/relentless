<!-- relentless:owned -->
# Layer: worktrees

Read this when `layers.worktrees` is true.

- One writer per worktree. Never share a checkout across parallel implementers.
- Create it with `worktree-create`. The branch comes from `gh issue develop`. If that fails, stop and show the error.
