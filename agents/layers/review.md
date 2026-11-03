<!-- relentless:owned -->
# Layer: review

## Orchestrator
- When the work is ready (after QA when `layers.qa` is true), set `state:review` and spawn the `reviewer` subagent in a fresh context. Give it the issue and PR numbers and the issue's context; never the implementer's reasoning, chat, or report.
- You may steer the reviewer with questions about the issue or the diff, never with arguments for approval.
- Apply its verdict with `apply-review-verdict.sh`. The reviewer never applies labels.
- On `changes_requested`, set `state:in-progress` and resume the same implementer on the same branch; review again after its next push.

## Implementer
- On round 2, read the latest `relentless:review-verdict` comment on the PR, address every blocker and major before pushing, and reply to each one in the PR.
