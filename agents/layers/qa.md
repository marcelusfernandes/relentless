<!-- relentless:owned -->
# Layer: qa

## Orchestrator
- When the implementer reports ready, spawn a separate `qa` agent with the issue and its context, never the implementer's report. Put its report in the PR body with `fill-qa-section.sh`, then continue.

## Implementer
- Never run or write QA; the orchestrator owns it.
