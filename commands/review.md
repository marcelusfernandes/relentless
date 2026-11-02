---
description: Orchestrator spawns isolated reviewer (stdin bundle), applies verdict, then merge-if-ready — no human resume
argument-hint: "<pr-number> [issue-number]"
---

# /review

**You (orchestrator) run this end-to-end.** Do not stop for a driver to spawn the reviewer.

Prefer one-shot:
```bash
core/scripts/run-isolated-review.sh --repo OWNER/NAME --pr $1 --issue $2 \
  --harness claude --workdir . --also-merge
```

Manual sequence:
1. Build bundle (lockfiles excluded):
   ```bash
   core/scripts/build-review-bundle.sh --repo OWNER/NAME --pr $1 --issue $2 --out review-bundle.md
   ```
2. Fresh reviewer session — **stdin**, not argv (`$(cat …)` fails on large diffs):
   - Claude: `RELENTLESS_ROLE=reviewer CLAUDE_AGENT=reviewer claude -p --agent relentless:reviewer --verbose --output-format stream-json < review-bundle.md`
   - Codex: `RELENTLESS_ROLE=reviewer CLAUDE_AGENT=reviewer codex exec --sandbox read-only < review-bundle.md`
   `run-isolated-review.sh` exports `RELENTLESS_ROLE=reviewer` and `CLAUDE_AGENT=reviewer` before either spawn (and before the Claude fallback), so reviewer-isolation hooks apply to that process and anything it spawns.
3. Parse verdict; run:
   ```bash
   core/scripts/apply-review-verdict.sh --repo … --issue … --pr … --verdict approved|changes_requested
   ```
4. If `approved` → **immediately** `/merge` / `merge-if-ready.sh` (do not stall).
5. If `changes_requested` → issue is already `state:in-progress`; send implementer back.
