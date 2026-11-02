---
description: Prepare this GitHub repo for Relentless (interactive setup → bootstrap → PR)
argument-hint: "[OWNER/NAME]"
---

# /relentless:setup

Follow skill **`setup`** end-to-end.

1. Ask merge.default, decider name, harness, and whether to enable GitHub branch protection on main (default **no** — only if the user says yes). Git hooks are the `githooks` layer and stay off on a fresh bootstrap. On Codex without a sandbox those git-side hooks are advisory, since an agent can bypass them with `git push --no-verify` or `git -c core.hooksPath=/dev/null ...`, so branch protection is the only hard lock on `main` there. Also warn that private and organization repositories have GitHub Actions minute limits: when they are exhausted, `merge-if-ready` runs local checks and notes it on the PR; `merge:auto` may merge, `merge:human` still waits, and a self-hosted runner is how to keep real CI. Optional first outcome.
2. Recommend Claude `--scope project` install (Codex: user-level).
3. `bootstrap.sh --check-scopes` then **dry-run** with `--workdir` of this repo; show the config, docs block, and missing core labels. Do not plan CI, templates, or git hooks unless that layer is already true.
4. On approval: `--apply`, commit seeded files on `chore/relentless-setup`, open PR (or note empty-repo main).
5. Optionally `create-milestone` + `create-epic` if the user gave an outcome.

`$ARGUMENTS` may be `OWNER/NAME`. Default workdir `.`.
