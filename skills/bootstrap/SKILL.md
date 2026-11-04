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
- Writes `.relentless/config.json` when it is missing: `base`, the merge methods the repo allows, `checks.test` from the repo's own workflow, and `layers.*` all false.
- Fills `checks.test` on an existing config only when that field is absent or empty.
- Upserts `<!-- relentless:start -->` blocks in AGENTS.md / CLAUDE.md from the enabled layers. With every layer off, the wave ends at `state:review`.
- Creates missing core labels only (`state:*`, `human:pending`, `human:decided`, `epic`). Never edits an existing label.
- Refreshes `.codex/agents/*.toml` and `.relentless/layers/<layer>.md` only when the file still has the `relentless:owned` marker. A file without the marker is never touched.
- A config with no `layers` key keeps the 1.4.11 layers on, including githooks. Inside `layers`, a switch runs only when it is true. A fresh bootstrap leaves every layer off.
- Never vendors plugin agents/skills.
- Does **not** enable GitHub branch protection unless `--branch-protection` is passed.

## Upgrade (v1.4.9+)

```bash
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --harness both --upgrade          # dry-run
core/scripts/bootstrap.sh --repo OWNER/NAME --workdir PATH \
  --harness both --upgrade --apply
```

Does not rewrite an existing label, template, or workflow. Refreshes a Codex brief or layer file only when it still carries the `relentless:owned` marker. Still adds a missing config, the docs block, and missing core labels.

