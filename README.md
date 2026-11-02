# Relentless

Reusable **agent workflow plugin** for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex CLI](https://github.com/openai/codex) (verified against **codex-cli 0.165.x**): GitHub issues & milestones as product outcomes, human decision gates, configurable merge policy, isolated reviewer, **agent auto-merge**.

Do **not** copy plugin `agents/` or `skills/` into consumer repos — install the plugin, then **set up the repo**.

## Getting started

Zero → first product request. Use Claude Code **or** Codex CLI (or both). Commands below match the scripts and CLIs in this repo (Claude Code 2.1.x / codex-cli 0.165.x).

### 1. Prerequisites

Install and confirm on your PATH:

| Tool | Why |
|------|-----|
| **git** | Clone, worktrees, PRs |
| **GitHub CLI (`gh`)** | Issues, labels, PRs, scopes |
| **jq** | Config / JSON in `core/scripts` |
| **python3** | Decision helpers + tests |
| **Claude Code** and/or **Codex CLI** | Harness that loads the plugin |

```bash
gh auth login
gh auth refresh -s workflow   # needed so setup can seed .github/workflows
```

The GitHub login stays in `gh` (agents reuse that account). Confirm the workflow scope:

```bash
# After you set RELENTLESS_ROOT (step 2):
"$RELENTLESS_ROOT"/core/scripts/bootstrap.sh --check-scopes
```

### 2. Install the plugin

**Claude Code** (prefer **project** scope so `.claude/settings.json` records the plugin):

```bash
claude plugin marketplace add marcelusfernandes/relentless
claude plugin install relentless@relentless --scope project -y
```

Find the install path and export it:

```bash
claude plugin list --json   # → installPath for relentless
export RELENTLESS_ROOT="<installPath>"
# example: ~/.claude/plugins/cache/relentless/relentless/1.4.9
```

**Codex CLI** (user-level only — no project-scope flag on 0.165.x; each collaborator installs):

```bash
codex plugin marketplace add marcelusfernandes/relentless
codex plugin add relentless@relentless
```

Cache path is **per version**. Pick the version directory and export it:

```bash
ls ~/.codex/plugins/cache/relentless/relentless/
export RELENTLESS_ROOT=~/.codex/plugins/cache/relentless/relentless/1.4.9   # use the version you installed
```

Keep `RELENTLESS_ROOT` in your shell profile if you run scripts outside the agent.

### 3. Set up your consumer repo

In the **target product repo** (not this plugin repo):

- **Claude:** run **`/relentless:setup`**
- **Codex:** invoke skill **`setup`** (ask the agent to run the Relentless `setup` skill)

Setup asks:

1. Target `OWNER/NAME` and local workdir (default `.`)
2. **merge.default** — `auto` or `human` (recommends `human` if no test command)
3. **decider name** (and GitHub login if not `gh api user`)
4. **harness** — `claude` | `codex` | `both`
5. **Branch protection on main?** — **off** unless you explicitly say yes. On Codex without a sandbox, local git hooks are advisory (`git push --no-verify` or `git -c core.hooksPath=/dev/null ...`); branch protection is the only hard lock on `main` there.
6. Optional first product outcome → milestone + epic after apply

Setup dry-runs, then applies, commits seeds on **`chore/relentless-setup`**, and opens a PR. **Merge that PR** before relying on labels, CI, and config.

Or run the scripts yourself (same flags as the skill):

```bash
gh auth refresh -s workflow
"$RELENTLESS_ROOT"/core/scripts/bootstrap.sh --check-scopes
"$RELENTLESS_ROOT"/core/scripts/bootstrap.sh --repo OWNER/NAME --workdir /path/to/checkout \
  --merge-default human --decider YourName --harness both
# review plan, then:
"$RELENTLESS_ROOT"/core/scripts/bootstrap.sh --repo OWNER/NAME --workdir /path/to/checkout \
  --merge-default human --decider YourName --harness both --apply
# Add --branch-protection only after an explicit yes.
```

What bootstrap seeds (CI, labels, hooks, issue forms, …): see [Prepare a consumer repo](#prepare-a-consumer-repo-required).

### Upgrade an existing consumer (1.4.9+)

Plain `--apply` still uses `seed_copy` (skips files that already exist). To refresh Relentless-owned files after a plugin bump without wiping your customizations:

```bash
"$RELENTLESS_ROOT"/core/scripts/bootstrap.sh --repo OWNER/NAME --workdir . \
  --harness both --upgrade --apply
```

`--upgrade` does not rewrite an existing config, label, template, workflow, or `.codex` file. It still adds a missing config, the docs block, and missing core labels.

### 4. First product request

In the consumer repo (with the setup PR merged), tell the agent the **product outcome** you want — e.g. “Ship a CLI that does X; exit when Y.”

What happens next (orchestrator-owned loop):

1. Milestone + understanding epic, then sub-issues
2. Implementer worktrees + PRs
3. QA → `state:review` → **isolated** reviewer → verdict → `merge-if-ready`

You only step in for **human gates**:

- **Claude:** type `/decide <issue> <option>` in the session (UserPromptSubmit hook records it).
- **Codex:** `decide.sh` refuses inside the agent (expected). Run the **exact command it prints** in your own terminal, outside the agent session.

Headless Claude (`claude -p`): set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` so print mode does not kill long background waits — details in [`docs/harness-profiles.md`](docs/harness-profiles.md).

### 5. Updating the plugin

**Claude:**

```bash
claude plugin marketplace update relentless
claude plugin update relentless@relentless -y
# restart Claude Code to apply
```

**Codex** (no `plugin update` subcommand on 0.165.x — refresh marketplace, then re-add):

```bash
codex plugin marketplace upgrade relentless
codex plugin remove relentless@relentless
codex plugin add relentless@relentless
ls ~/.codex/plugins/cache/relentless/relentless/   # point RELENTLESS_ROOT at the new version
```

### 6. Troubleshooting

- **`decide.sh` refuses inside the agent** — expected. Decider runs the printed command in their own terminal (Codex has no TTY for `/decide`).
- **CI fails with “unknown stack” / no test** — configure real checks in `.relentless/config.json` / `relentless-ci.yml` (bootstrap FAIL-closes until then).
- **Stale Codex scripts** — cache is per version; `ls ~/.codex/plugins/cache/relentless/relentless/` and update `RELENTLESS_ROOT`.
- **Missing `workflow` scope** — `gh auth refresh -s workflow`, then `bootstrap.sh --check-scopes`.
- **Headless Claude stops mid-wave** — set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (see harness profiles).

---

## Prepare a consumer repo (required)

Installing the plugin alone is not enough. Prefer **Getting started → Set up** (`/relentless:setup` or skill `setup`). Low-level: `"$RELENTLESS_ROOT"/core/scripts/bootstrap.sh` (see above).

### What setup / bootstrap does

| Piece | Behavior |
|-------|----------|
| **Config** | Writes `.relentless/config.json` only when it is missing: `base`, the merge methods the repo allows, `checks.test` from the repo's own workflow, and `layers.*` all false. An existing config is not edited. |
| **AGENTS.md / CLAUDE.md** | Upserts a `<!-- relentless:start -->` … `<!-- relentless:end -->` block. |
| **Labels** | Creates missing core labels only (`state:*`, `human:pending`, `human:decided`, `epic`). Never edits an existing label. |
| **Layers** | CI, issue templates, githooks, and decision files are written only when `layers.<name>` is already true. A fresh bootstrap leaves them off and does not touch an existing workflow, template, or `.codex` file. |
| **Branch protection** | **Off** unless you pass `--branch-protection` after an explicit yes in setup. Fail-soft if the token cannot admin the repo. On Codex without a sandbox the git hooks are advisory (`git push --no-verify` or `git -c core.hooksPath=/dev/null ...`); branch protection is the only hard lock on `main` there. |
| **Actions minutes** | Private and organization repositories have GitHub Actions minute limits. When the quota or spending limit is exhausted, `merge-if-ready` runs the configured checks locally on the PR head and notes the result on the PR. With `merge:auto`, if those checks pass and the head SHA is stable, it may merge without a human. `merge:human` still waits for a person. A self-hosted runner is how to keep real Actions CI. With no test command, the issue stops at `human:pending` and nothing is merged. |

Setup then commits seeds on `chore/relentless-setup` and opens a PR (empty repos may seed `main` first). **Merge that PR.**

### Human decisions

Agents use the same GitHub account as the decider, so they must not record decisions themselves.

- Do not run `/decide`, `decide.sh`, or `accept-adr.sh`, and do not write `Decided by`. New ADRs stay **proposed**.
- **Claude:** typing `/decide <issue> <option>` is handled by the UserPromptSubmit hook, which records the decision.
- **Codex:** commands have no TTY, even in the interactive TUI. `decide.sh` refuses and prints the exact command. That refusal is expected. The decider runs it in their own terminal, outside the agent session. With the sandbox disabled, a process that can open its own terminal lowers but does not eliminate the risk.
- If an issue is `human:pending`, post the decision request, tell the decider (`decider.name` in `.relentless/config.json`) that command, and move on. Do not retry.

### Hook tests

```bash
bash tests/hooks/test-hooks.sh
bash tests/hooks/test-decide-guard.sh
bash tests/hooks/test-githooks.sh
python3 tests/agents/test-codex-agent-briefs.py
```

CI runs the same scripts (`.github/workflows/ci.yml`). Codex has no Claude hooks, so `.codex/agents/*.toml` `developer_instructions` carry each `agents/*.md` brief. The Python check fails if a TOML drops a normative rule from its brief.

## After setup

Ask the agent for a product outcome (see [Getting started → First product request](#4-first-product-request)). Manual script equivalents if you need them:

```bash
"$RELENTLESS_ROOT"/core/scripts/create-milestone.sh --repo OWNER/NAME --title "Theme: subtitle" \
  --outcome "…" --exit-criterion "…"
"$RELENTLESS_ROOT"/core/scripts/create-epic.sh --repo OWNER/NAME --title "… understanding" \
  --milestone "Theme: subtitle" --outcome "…" --exit-criterion "…"
"$RELENTLESS_ROOT"/core/scripts/create-issue.sh --repo OWNER/NAME --title "feat: …" \
  --milestone "Theme: subtitle" --type enhancement --parent N --label merge:auto
```

Implement → QA → **stop at `state:review`** → isolated reviewer → `apply-review-verdict` → **`merge-if-ready`**.

Harness profiles: **`docs/harness-profiles.md`**. Plan / backlog: **`docs/PLAN.md`**.

## Layout

```
.agents/plugins/marketplace.json   Codex marketplace catalog
.claude-plugin/                    Claude manifests
.codex-plugin/ + plugin.json       Codex / Agent Plugins manifests
.codex/agents/                     Codex agent stubs (plugin; optional consumer seed)
agents/ skills/ commands/ hooks/   Runtime surfaces (plugin only — do not vendor)
core/                              labels, templates, scripts, schemas
AGENTS.md                          Doctrine (Claude + Codex)
docs/                              harness profiles, deferred, PLAN
```

## License

MIT

## Decision records & worktrees

- Durable choices live in `docs/decisions/` (ADR = human gate via `/decide`; notes = no gate). Agents read them before plan/implement.
- Each implementer works in its own git worktree (`skills/worktree-segura`, `worktree-create.sh`) on `<type>/<n>-<slug>` from the repo base branch (`base` in `.relentless/config.json`).
