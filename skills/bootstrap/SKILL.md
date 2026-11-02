---
name: bootstrap
description: Low-level Relentless seed (config, docs block, core labels). Prefer skill setup / /relentless:setup for interactive prep. Dry-run first unless user asks to apply.
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

## Behavior
- Writes `.relentless/config.json` only when it is missing: `base`, the merge methods the repo allows, `checks.test` from the repo's own workflow, and `layers.*` all false.
- Upserts `<!-- relentless:start -->` blocks in AGENTS.md / CLAUDE.md.
- Creates missing core labels only (`state:*`, `human:pending`, `human:decided`, `epic`). Never edits an existing label.
- Does not edit an existing config, template, workflow, or `.codex` file.
- CI, templates, githooks, and decisions run only when `layers.<name>` is already true.
- Never vendors plugin agents/skills.
- Does **not** enable GitHub branch protection unless `--branch-protection` is passed.

## Upgrade (v1.4.9+)

```bash
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --harness both --upgrade          # dry-run
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --harness both --upgrade --apply
```

Does not rewrite an existing config, label, template, workflow, or `.codex` file. Still adds a missing config, the docs block, and missing core labels.

