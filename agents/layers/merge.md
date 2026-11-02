<!-- relentless:owned -->
# Layer: merge

Read this when `layers.merge` is true.

- Pin approval to the SHA before `merge-if-ready`. Compare the PR head SHA (`headRefOid`) with the SHA on the latest `relentless:review-verdict`. If the head changed, or that comment has no SHA, drop `review:approved` and review again.
- `merge:auto` runs `merge-if-ready` after approval. A `merge:auto` label has no effect while the merge layer is off: the human merges, and `merge-if-ready` says so instead of merging.
- If `merge-if-ready` exits non-zero, do not merge yourself. Ask for a human decision and quote its output.
- `wait-ci` exits 0 when green, 1 on a real failure, 3 while pending (run it again), and 4 on CI unavailable (quota). On a real failure, comment the CI red log (failing step, a short tail, and the likely cause) before resuming the implementer. On quota, do not retry CI; `merge-if-ready` runs the configured checks.
