---
name: setup
description: Prepare a consumer GitHub repo for Relentless — interactive merge/decider/harness, stack detection, bootstrap dry-run then apply, commit seeds on a branch and open a PR (or main for empty repos). Optional first milestone+epic. Use when the user asks to set up Relentless, bootstrap a project, or "prepare the repo".
argument-hint: '[OWNER/NAME] [--workdir PATH]'
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion
user-invocable: true
---

# /relentless:setup — prepare the user's repo

Goal: the consumer repo works with Relentless end-to-end (labels, real CI, docs blocks, issue forms, config). Prefer this over raw `bootstrap.sh`.

## Interactively collect (AskUserQuestion or chat)

1. **Target** `OWNER/NAME` and local `--workdir` (default `.`)
2. **merge.default**: `auto` | `human`  
   - If stack detection finds no test command, **recommend human** and only set `auto` if the user insists (warn that merge-if-ready trusts CI).
3. **decider.name** (and github login if not `gh api user`)
4. **harness**: `claude` | `codex` | `both`
   Recommended orchestrator model: Codex sol 6.1 or astra; Claude Opus or Fable. This is a recommendation only. Do not pin it in an agent file, and do not warn automatically when another model is selected.
5. **GitHub branch protection on main**: optional question, **off unless the user explicitly says yes**. Do not pass `--branch-protection` otherwise. Local git hooks are installed either way. When you ask, state plainly that on Codex without a sandbox the git-side hooks are advisory, since an agent can bypass them with `git push --no-verify` or `git -c core.hooksPath=/dev/null ...`, so branch protection is the only hard lock on `main` there. If they say yes, the apply command includes `--branch-protection` (fail-soft when the token cannot admin the repo). In the same breath, warn that private and organization repositories have GitHub Actions minute limits. When the quota or spending limit is exhausted, the harness runs the configured checks locally on the PR head and notes that on the PR; `merge:auto` may merge and `merge:human` still waits for a person. A self-hosted runner is how to keep real Actions CI. The agent does not merge on local checks when the mode is `merge:human`. If no test command is configured, the run stops at `human:pending`.
6. Optional: **first product outcome** text → after apply, create milestone + epic

## Upgrade (existing Relentless consumer)

If the repo already has Relentless and you only need the new agent briefs / docs blocks:

```bash
"$RELENTLESS_ROOT/core/scripts/bootstrap.sh" --repo OWNER/NAME --workdir . \
  --harness both --upgrade --apply
```

Adds only what is missing. Keeps customized checks, stack, package manager, merge default, issue forms, and an existing or deleted `relentless-ci.yml`. Then commit on a branch and open a PR as usual.

## Plugin install (before or during)


**Claude (project scope):**
```bash
claude plugin marketplace add marcelusfernandes/relentless
claude plugin install relentless@relentless --scope project -y
```

**Codex 0.165.x (user-level only):**
```bash
codex plugin marketplace add marcelusfernandes/relentless
codex plugin add relentless@relentless
```

## Steps

```bash
export RELENTLESS_ROOT=…   # plugin installPath
cd "$WORKDIR"

"$RELENTLESS_ROOT/core/scripts/bootstrap.sh" --check-scopes
# refresh workflow scope if needed:
# gh auth refresh -s workflow

# Dry-run — show plan (stack, CI, docs, labels)
"$RELENTLESS_ROOT/core/scripts/bootstrap.sh" --repo OWNER/NAME --workdir . \
  --merge-default human --decider "NAME" --harness both

# After user approves the plan:
"$RELENTLESS_ROOT/core/scripts/bootstrap.sh" --repo OWNER/NAME --workdir . \
  --merge-default human --decider "NAME" --harness both --apply
# Add --branch-protection only after an explicit yes. Default is off.
```

## Commit + PR

Unless the repo was empty and bootstrap already pushed `main`:

```bash
branch="chore/relentless-setup"
git checkout -b "$branch"
git add AGENTS.md CLAUDE.md .relentless .github docs/relentless .codex 2>/dev/null || true
git status
git commit -m "chore: Relentless setup (labels, CI, docs, issue forms)"
git push -u origin HEAD
gh pr create --title "chore: Relentless setup" --body "## Relentless setup

- Stack-detected CI (\`.github/workflows/relentless-ci.yml\`)
- Idempotent AGENTS.md / CLAUDE.md blocks
- Issue forms (relentless, investigation, epic) + blank_issues disabled
- \`.relentless/config.json\` with checks + merge.default
"
```

Empty repo: seeds may land on `main` via bootstrap initial commit — still open a follow-up PR if more files need review.

## Optional first wave

If the user described a product outcome:

```bash
"$RELENTLESS_ROOT/core/scripts/create-milestone.sh" --repo OWNER/NAME \
  --title "Theme: subtitle" --outcome "…" --exit-criterion "…"
"$RELENTLESS_ROOT/core/scripts/create-epic.sh" --repo OWNER/NAME \
  --title "… understanding" --milestone "Theme: subtitle" \
  --outcome "…" --exit-criterion "…" --understanding "…"
```

## What "prepared" means

| Artifact | Behavior |
|----------|----------|
| Labels | Idempotent create/edit from `labels.json` |
| CI | `relentless-ci.yml` with real commands **or** FAIL-closed if no test |
| Docs | `<!-- relentless:start -->` blocks upserted (never skip existing files) |
| Issues | `relentless.yml` + `investigation.yml` + `epic.yml` + `config.yml` |
| Config | `checks.{install,lint,typecheck,test,build}` + `stack` |
| Git hooks | `.relentless/githooks/pre-commit` and `pre-push`. `core.hooksPath` points at them, or an existing hooksPath / husky is chained and not replaced. They refuse commits on main/master, pushes to main/master, and non-fast-forward pushes. |
| Branch protection | **Off** unless the setup question was answered yes (`--branch-protection`, fail-soft). On Codex without a sandbox the git hooks are advisory (`git push --no-verify` or `git -c core.hooksPath=/dev/null ...`); branch protection is the only hard lock on `main` there. Private and organization repos have Actions minute limits; when they are exhausted, `merge-if-ready` falls back to local checks and notes it on the PR. A self-hosted runner keeps real CI. `merge:human` still waits. |

Never vendor plugin `agents/` / `skills/` into the consumer.


## After setup — product loop is self-sufficient

Once the user describes the product, the **orchestrator** (not a human driver) must:
1. Create milestone + epic + sub-issues
2. Implement → QA → `state:review`
3. Spawn isolated reviewer itself (`run-isolated-review.sh --merge` or equivalent nested `claude`/`codex`)
4. Continue to `merge-if-ready` without waiting for a resume prompt

Dogfood / real-user simulation: install plugin → `/relentless:setup` → answer questions → ask for the product. No mid-flow human wiring of review/merge.
