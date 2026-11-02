# Harness profiles (implementer vs reviewer)

Agents **must not** self-review. Use separate processes with different permissions.

**Orchestrator owns the full loop:** after `state:review`, the **same orchestrator session** must spawn the isolated reviewer (nested process), apply the verdict, and run `merge-if-ready` — do **not** stop for a human/driver resume. Prefer `core/scripts/run-isolated-review.sh --also-merge`.

Recommended orchestrator model: Codex sol 6.1 or astra; Claude Opus or Fable. This is a recommendation only. Agent files do not pin a model, and setup does not warn when another model is selected.

## Codex CLI

Codex has no Claude PreToolUse hooks, and commands have no TTY even in the interactive TUI. The guard is `.codex/agents/<role>.toml` `developer_instructions`, derived from `agents/<role>.md` (worktree, stop at `state:review`, no commit or push on main, read-only reviewer, QA and documenter limits, and the decision rules). `tests/agents/test-codex-agent-briefs.py` fails if a TOML drops a normative line from its brief.

### Implementer / orchestrator (needs git + gh)
```bash
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  --dangerously-bypass-hook-trust \
  -C /path/to/workdir \
  < implementer-prompt.md
```
Export `RELENTLESS_ROLE=implementer`. Hooks are not present in Codex; the implementer TOML still forbids `review:approved`, `merge-if-ready`, and `apply-review-verdict`, and `decide.sh` refuses when that role is set.

Prefer **Write / apply_patch** over huge `cat > file <<'EOF'` heredocs inside nested sessions — Codex shell classifiers can false-positive on heredoc bodies that look like dangerous commands.

### Reviewer (read-only)
```bash
core/scripts/build-review-bundle.sh --repo OWNER/NAME --pr N --issue N --out /tmp/review-bundle.md

# stdin — never "$(cat bundle)" as argv (large diffs fail)
# Same names the isolation hooks read. run-isolated-review.sh exports both
# before this spawn, so anything the reviewer starts inherits them.
export RELENTLESS_ROLE=reviewer
export CLAUDE_AGENT=reviewer
codex exec --sandbox read-only -C /tmp/reviewer-sandbox < /tmp/review-bundle.md
```
Or: `codex review --base main …` with the same bundle. Do **not** pass implementer chat.

One-shot (orchestrator):
```bash
core/scripts/run-isolated-review.sh --repo OWNER/NAME --pr N --issue N \
  --harness codex --workdir . --also-merge
```

## Claude Code

### Implementer / orchestrator
```bash
# 0 disables the print-mode background-task ceiling (default is 10 minutes).
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
  claude -p --dangerously-skip-permissions < orchestrator-prompt.md
# Live logs — stream-json REQUIRES --verbose on Claude Code 2.1.x+:
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
  claude -p --verbose --output-format stream-json --dangerously-skip-permissions < orchestrator-prompt.md
```

### Headless / print mode (`claude -p`)

After the model ends a turn, print mode waits for background tasks and then stops the session. The default ceiling is `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` (10 minutes). The process prints `Background tasks still running … stopping them` and dies, so a dogfood wave needs a manual continue. Set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` to disable that ceiling, or set a high millisecond value to raise it.

Disabling the ceiling is a backstop. CI and reviewer waits still run in the foreground: `wait-ci.sh` polls and exits 3 with `CI: pending` when its budget is spent, and the next step runs it again. Exit 0 is green, 1 is a real failure, 4 is `CI unavailable (quota)` (do not retry CI; `merge-if-ready` runs local checks). `run-isolated-review.sh` blocks until the reviewer exits. Do not background those commands, and do not use `gh run watch` or `run_in_background` for them — a watcher stays alive after the turn and is what trips the ceiling.

### Reviewer (restricted tools)
```bash
# stdin / file — never "$(cat review-bundle.md)" as argv
# pretool-reviewer-isolation.sh reads these. Export before the spawn so the
# reviewer process and anything it spawns stay on the reviewer side of the hook.
export RELENTLESS_ROLE=reviewer
export CLAUDE_AGENT=reviewer
claude -p --agent relentless:reviewer \
  --allowedTools "Read,Grep,Glob,Bash(gh pr view *),Bash(gh pr diff *),Bash(gh pr checks *),Bash(gh issue view *),Bash(gh api --method GET *),Bash(gh api -X GET *)" \
  --verbose --output-format stream-json \
  < /tmp/review-bundle.md
```
`run-isolated-review.sh` exports both names before the Claude spawn, the Claude fallback spawn, and the Codex spawn. The `relentless:reviewer` agent brief is read-only by doctrine, and the Claude allowlist is read-only `gh` only: `gh pr view`, `gh pr diff`, `gh pr checks`, `gh issue view`, and `gh api` GET (`--method GET` or `-X GET`). It does not allow comment, edit, merge, label, review, or `gh api -X POST|PATCH|DELETE`. The allowlist star matches the rest of the command, so `pretool-reviewer-isolation.sh` blocks a reviewer `gh api` that has a second `-X`/`--method` (including `-XPOST` and `--method=POST`) or any `--input`. One explicit GET with `-f` or `-F` stays allowed. Prefer not combining with `--dangerously-skip-permissions`. Label writes and merge stay with the orchestrator (`apply-review-verdict.sh` and `merge-if-ready.sh`).

One-shot (orchestrator):
```bash
core/scripts/run-isolated-review.sh --repo OWNER/NAME --pr N --issue N \
  --harness claude --workdir . --also-merge
```

## Orchestrator final step (both)
After isolated review returns `approved` and `apply-review-verdict.sh … --verdict approved`:
```bash
core/scripts/merge-if-ready.sh --repo OWNER/NAME --pr N --issue N
```
- `merge:auto` (or config default auto): wait CI green on head SHA → **retarget open PRs stacked on the head branch** → `gh pr merge` with the method the repo allows (delete branch only if no dependents remain) → `state:done` → close issue.
- `merge:human`: post 🤖 ready-to-merge and **do not** merge.

## Plugin script path
```bash
# Claude
claude plugin list --json   # → installPath
export RELENTLESS_ROOT="<installPath>"

# Codex — prefer cache path, not .tmp marketplaces clone
# ~/.codex/plugins/cache/relentless/relentless/<version>/
export RELENTLESS_ROOT=~/.codex/plugins/cache/relentless/relentless/1.4.6
```

## Project-scoped plugin install

| Runtime | Project scope? | How |
|---------|----------------|-----|
| Claude Code | **Yes** — `--scope project` (also `user`, `local`; default `user`) | Writes `.claude/settings.json` `enabledPlugins`; collaborators get prompted. Prefer this over copying agents/skills into the repo. |
| Codex CLI 0.165.x | **No** equivalent flag on `codex plugin add` | Plugins live in user `~/.codex/config.toml`. Each collaborator installs. Do not invent a project install. |

Bootstrap `--harness claude|codex|both` (default `both`) only seeds `.codex/agents/*.toml` stubs when Codex is in use; it never vendors Claude `agents/`/`skills/`. Prefer **`/relentless:setup`** / skill `setup` for the full interactive consumer prep.

## Human decisions

Agents share the human's GitHub identity. There is no marker file or env token that proves a human (the agent could write it).

- **Claude:** typing `/decide <issue> <option>` runs `hooks/scripts/userprompt-decide.sh` (UserPromptSubmit). The hook records the decision. The agent does not call `decide.sh`.
- **Codex:** commands have no TTY, even in the interactive TUI, so the human cannot confirm `/decide` from inside a Codex session. `decide.sh` and `accept-adr.sh` refuse and print the exact command. That refusal is expected behavior, not a broken lock. Do not retry or try another route. The decider runs it in their own terminal, outside the agent session:

```bash
core/scripts/decide.sh --repo OWNER/NAME --issue N --option K
```

With the sandbox disabled, a process that allocates its own terminal lowers but does not eliminate the risk. `merge-if-ready` posts `blocked: ADR accepted without a verified decision-request` and exits non-zero, without merging, when the diff has an accepted ADR and neither the linked issue nor its native sub-issue parent has a `decide.sh` record (`relentless:author=human` for `decider.name` and `relentless:decision`). Body lines such as `Parent:` / `Epic:` / `Part of #N`, and an issue cited only inside the ADR, do not count. `merge:auto` and `merge:human` both stop.

If the issue has `human:pending`, post the decision request, tell the decider (`decider.name` from config, not a hardcoded person) that command, and move on to another ready issue.

## Git hooks in the consumer repo

Setup / `bootstrap.sh` installs `.relentless/githooks/pre-commit` and `pre-push`:

- Unset `core.hooksPath` → set it to `.relentless/githooks`. An existing executable `.git/hooks/pre-commit` or `pre-push` is still chained.
- Existing `core.hooksPath` (husky or otherwise) → left unchanged; the hook files gain one `# relentless:githooks` chain call. Re-running does not duplicate it.
- They refuse commits on `main`/`master`, pushes that update `refs/heads/main` or `refs/heads/master`, and non-fast-forward pushes. The pre-push hook sees the old and new SHAs, not the `--force` flag, so a fast-forward update is allowed even if the client passed `--force`. The agent PreToolUse hook still blocks every force-push spelling (`-f`, `--force`, `--force-with-lease`, `+refspec`) before git runs.
- GitHub branch protection on main is **not** enabled by default. Setup asks; pass `--branch-protection` only after an explicit yes (fail-soft). On Codex without a sandbox the git-side hooks are advisory, since an agent can bypass them with `git push --no-verify` or `git -c core.hooksPath=/dev/null ...`, so branch protection is the only hard lock on `main` there. Private and organization repositories also have GitHub Actions minute limits. When that quota or the spending limit is exhausted, `merge-if-ready` runs the configured checks locally on the PR head and notes that on the PR. With `merge:auto`, a pass on a stable head SHA may merge without a human. `merge:human` still waits. A self-hosted runner is how to keep real Actions CI. Proposed in `docs/decisions/adr/0003-ci-quota-local-checks.md`.

## End of turn

There is no Claude Stop hook. The implementer brief is the rule: tests pass, and nothing is left uncommitted, before report back. QA checks a turn that slips through. `checks.test` is still the project test command written into CI, and `merge-if-ready` runs it on the PR head when Actions quota skips CI.

## Hook regression tests

```bash
bash tests/hooks/test-hooks.sh          # PreToolUse protect-main, reviewer isolation, decide block
bash tests/hooks/test-decide-guard.sh   # agent refusal, forged env, human PTY, UserPromptSubmit, merge ADR guard
bash tests/hooks/test-githooks.sh       # core.hooksPath install, husky chain, main and force-push
python3 tests/agents/test-codex-agent-briefs.py  # Codex TOML instructions cover agents/*.md
```

CI (`.github/workflows/ci.yml`) runs the same scripts.
