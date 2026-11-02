---
name: bootstrap
description: Low-level Relentless seed (labels, stack CI, docs blocks). Prefer skill setup / /relentless:setup for interactive prep. Dry-run first unless user asks to apply.
---

# Bootstrap (low-level)

Prefer **`setup`** for the full interactive flow (PR, plugin install, first epic).

```bash
core/scripts/bootstrap.sh --check-scopes
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --merge-default human --decider NAME --harness both
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --merge-default human --decider NAME --harness both --apply
```

## Behavior (v1.4+)
- Detects stack (node/python/go/rust) → writes `.github/workflows/relentless-ci.yml`
- Unknown / no test → FAIL-closed CI + `merge.default=human` unless `--merge-default auto` explicit
- Upserts `<!-- relentless:start -->` blocks in AGENTS.md / CLAUDE.md
- Seeds issue forms including **epic** + `config.yml` (`blank_issues_enabled: false`)
- Records `checks` + `stack` in `.relentless/config.json`
- Never vendors plugin agents/skills
- Installs `.relentless/githooks` (or chains an existing hooksPath / husky). Does **not** enable GitHub branch protection unless `--branch-protection` is passed.

## Upgrade (v1.4.9+)

```bash
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --harness both --upgrade          # dry-run
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --harness both --upgrade --apply
```

Refreshes Codex agent TOMLs and docs blocks. Adds missing labels, config keys, and templates without rewriting ones that exist. Does not overwrite `stack`, `package_manager`, `checks`, or `merge.default`. Creates `relentless-ci.yml` only on the first bootstrap. Seeds `.codex/config.toml` marketplace pin when missing.

