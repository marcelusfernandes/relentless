---
name: human-gate
description: Block work pending a human decision. The orchestrator posts the question, the options, and a recommendation, and sets human:pending plus state:blocked. Workers never add those labels. Durable choices draft a proposed ADR.
---

# Human gate

## Required comment
Follow `core/templates/decision-request.md` (question, numbered options with pros/cons, recommendation).

## Durable decisions → ADR
If the options change architecture, a public contract, merge/security policy, or another rule that should outlive the issue:
1. Create a **proposed** ADR before or with the request:
   `core/scripts/new-adr.sh --workdir . --title "…" --slug … --issue N`
2. Mention the path in the decision-request body (`Proposed ADR: docs/decisions/adr/NNNN-….md`).
3. The **human** resolves it, not the agent. Agents never add `human:decided` and never mark the ADR accepted.

## Flow
Workers report what needs deciding, the options with their impacts, and a recommendation. They never add `human:pending` or `human:decided`.

1. The orchestrator posts the comment and sets `human:pending` plus `state:blocked` (one `state:*` only), then moves on to another ready issue.
2. The human answers on the issue and the label becomes `human:decided`. The orchestrator resumes from that comment.

## Human decisions
- If a human decision is needed, report to the orchestrator what needs deciding, the options with their impacts, and your recommendation. Never add `human:pending` or `human:decided`.
- Outside the orchestrator's list of human waits, do not pause for a human; report back.
