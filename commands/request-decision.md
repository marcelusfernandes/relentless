---
description: Ask the human for a decision and move the issue to human:pending
argument-hint: "<issue-number>"
---

# Ask for a human decision

Follow the **human-gate** skill. Draft `core/templates/decision-request.md` for the issue. The orchestrator posts it and sets `human:pending` plus `state:blocked`. Workers report the options and do not add those labels.
