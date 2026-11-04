---
name: decompose-epic
description: After an outcome milestone exists, create the parent epic (understanding) first, then native GitHub sub-issues. Use when opening a milestone wave, when work is too big for one session/PR, or when asked to break an epic. Not for implementing code.
argument-hint: '--milestone "Theme: subtitle" | --epic N'
allowed-tools: Bash, Read, Grep, Glob, Write
user-invocable: true
---

# Decompose epic — parent understanding, then sub-issues

Apollo-style **issue-mãe** first; lohra-ts native `sub_issues` for children. English artifacts.

## Order (mandatory)

1. **Milestone** already open with product outcome + exit criterion  
   (`create-milestone.sh` — title shape `Theme: subtitle`).
2. **Parent epic** in that milestone (`create-epic.sh`) containing:
   - Product outcome + deliverable + exit criterion / validates-with + depends-on
   - **Understanding** (problem/context before breaking down)
   - **Decisions fixed for this wave** (human forks: report options, impacts, and a recommendation; the orchestrator asks and applies `human:pending`)
   - **Decomposition plan (waves)** and dependencies
3. **Only then** create sub-issues (`create-issue.sh --parent N` or `add-sub-issue.sh`).
4. Sub-issues that are still too big for one session/PR become **nested epics** with their own sub-issues.

Never create leaf issues in a milestone before the epic parent exists (guards fail).

## Commands

```bash
core/scripts/create-milestone.sh --repo OWNER/NAME \
  --title "Auth: user can sign in" \
  --outcome "…" --exit-criterion "…" \
  --deliverable "…" --validates-with "…" --depends-on "none"

core/scripts/create-epic.sh --repo OWNER/NAME \
  --title "Auth wave: understanding" --milestone "Auth: user can sign in" \
  --outcome "…" --exit-criterion "…" \
  --understanding "…" --decisions "…" --plan "Wave 1: …"

# Sub-issue (body = core/templates/issue-body.md; type label required)
core/scripts/create-issue.sh --repo OWNER/NAME \
  --title "feat: wire login form" --milestone "Auth: user can sign in" \
  --type enhancement --parent N --label merge:auto

# Or link an existing issue
core/scripts/add-sub-issue.sh --repo OWNER/NAME --parent N --child M

# Close epic only when every sub-issue is closed
core/scripts/close-epic.sh --repo OWNER/NAME --epic N
```

`add-sub-issue` uses REST `POST .../issues/{parent}/sub_issues` with `sub_issue_id` = child's **database id** (integer JSON via `--input`). `gh` may lack `--parent`.

## Sub-issue authoring (apollo task + lohra sections)

- Title: conventional `<type>: <short>` (or apollo `<type>(<scope>): …` if the repo uses scopes).
- Body: `core/templates/issue-body.md` (User Story → … → References). QA is written on the PR, not as an empty issue section.
- Exactly one type label: `bug` | `enhancement` | `documentation` | `investigation` (parents: `epic`).
- Inherit the milestone; set **Dependencies** (`Blocked by: #N`).
- Files = globs the PR may touch; keep one-PR-sized.
- Investigation probes use the Investigation template — outcome is a **decision or follow-ups**, not permanent code.

## Guards

```bash
core/scripts/check-milestone-outcomes.sh --repo OWNER/NAME
```

Fails if a milestone lacks an epic parent, or has issues not linked as sub-issues of it (exception: `orphan:ok`).
