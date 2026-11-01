---
description: Low-level Relentless bootstrap (dry-run first). Prefer /relentless:setup for interactive prep.
argument-hint: "<owner/name> [workdir]"
---

# /bootstrap

Prefer **`/relentless:setup`** (skill `setup`). This command is the raw script. It installs git hooks. Add `--branch-protection` only after an explicit yes; GitHub branch protection stays off by default. On Codex without a sandbox the git-side hooks are advisory, since an agent can bypass them with `git push --no-verify` or `git -c core.hooksPath=/dev/null ...`, so branch protection is the only hard lock on `main` there.

```bash
core/scripts/bootstrap.sh --check-scopes
core/scripts/bootstrap.sh --repo $1 --workdir ${2:-.} \
  --merge-default human --decider Marcelus --harness both
# after approval:
core/scripts/bootstrap.sh --repo $1 --workdir ${2:-.} \
  --merge-default human --decider Marcelus --harness both --apply
```

Upgrade an existing consumer (preserves checks + CI):

```bash
core/scripts/bootstrap.sh --repo $1 --workdir ${2:-.} --harness both --upgrade
core/scripts/bootstrap.sh --repo $1 --workdir ${2:-.} --harness both --upgrade --apply
```

