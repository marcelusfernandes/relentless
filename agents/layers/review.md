<!-- relentless:owned -->
# Layer: review

Read this when `layers.review` is true.

- Pass the issue to the reviewer subagent, read the verdict, and you may guide the reviewer. Then run `apply-review-verdict`. The reviewer does not apply labels.
- The reviewer reads the diff with `gh pr diff`, skipping lockfiles. Do not use `run-isolated-review`.
- On round 2, address every blocker and major in the latest `relentless:review-verdict` before pushing.
