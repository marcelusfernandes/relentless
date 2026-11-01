# Decision records

First-class Relentless practice. **Read `docs/decisions/` before planning or implementing.** Agents start here to navigate decisions.

Append-only history: `docs/decisions/log.jsonl` (one JSON object per line). `## Decision` shows only the current decision; history lives in the log. Orchestrator commits ADR rewrites and log lines on the **same branch where the decision was taken** and ships them with that PR (before review when the decision precedes review).

Two layers:

| Kind | Path | Human gate? | When |
|------|------|-------------|------|
| **ADR** | `docs/decisions/adr/NNNN-<slug>.md` | **Yes** — explicit owner OK via `/decide`. Silence ≠ approval. | Architecture, public contract, merge/security policy, durable product choice |
| **Note** | `docs/decisions/notes/YYYY-MM-DD-<slug>.md` | **No** | Measured behavior kept on purpose; author doctrine; non-contract scope clarifications |

## ADR vs note
- Changes how the system is built or what it promises externally → **ADR** + human gate.
- Records what the code already does and marks it intentional → **note**.
- Unsure → start a note; promote to ADR if a contract appears.

## Lifecycle (durable human decisions)
1. Agent drafts `decision-request` (numbered options with pros/cons) and may pre-create `docs/decisions/adr/NNNN-<slug>.md` with **Status: proposed**.
2. `request-decision.sh` → `human:pending` + `state:blocked`.
3. The decider picks an option outside the agent session: Claude `/decide`, or `decide.sh --adr PATH` in their own terminal (or `--create-adr`). Agents do not run it. A refusal inside Codex is expected (no TTY, even in the interactive TUI).
4. Decide flow sets ADR **Status: accepted** and **Decided by**, comments `ADR: docs/decisions/adr/…` on the issue, flips `human:decided`. `## Decision` shows only the current decision; history lives in the log.
5. Implementer/planner **read ADRs** before touching a decided area. Reviewer **requires** PRs that touch a decided area to reference the ADR path in the PR body or commits.

## Index
Keep the bullet list below current when adding records.

### ADRs
- [ADR 0003 — CI quota exhaustion falls back to local checks run by merge-if-ready](adr/0003-ci-quota-local-checks.md) — accepted
- [ADR 0002 — Decision records are first-class](adr/0002-decision-records-first-class.md) — accepted
- [ADR 0001 — Worktree per writer](adr/0001-worktree-per-writer.md) — accepted

### Notes
(none yet)

## Helpers
```bash
core/scripts/new-adr.sh --workdir . --title "…" --slug worktree-per-writer [--issue N]
core/scripts/decide.sh --repo OWNER/NAME --issue N --option K --adr docs/decisions/adr/0001-….md
core/scripts/decide.sh --repo OWNER/NAME --issue N --option K --create-adr --title "…" --slug …
```
