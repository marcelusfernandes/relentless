---
description: The human records the chosen option on the issue. Agents do not record it.
argument-hint: "<issue-number> <option-number>"
---

# Human records the decision

The human answers on the issue. The label becomes `human:decided`. Agents do not record that answer and do not add the label.

## Who does it

- The human, outside the agent session.
- **Claude:** a UserPromptSubmit hook can record a typed answer from the human.
- **Codex:** commands have no TTY, even in the interactive TUI. The human answers on the issue.

## Human decisions
- If a human decision is needed, report to the orchestrator what needs deciding, the options with their impacts, and your recommendation. Never add `human:pending` or `human:decided`.
- Outside the orchestrator's list of human waits, do not pause for a human; report back.

## Do not
- Record the answer from an agent role
- Mark an ADR accepted
- Pass `--status accepted` to `new-adr.sh` (ADRs are created **proposed**)
