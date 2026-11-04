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
2. The orchestrator asks on the issue → `human:pending` + `state:blocked`.
3. The human picks an option on the issue, outside the agent session. Agents do not record it.
4. The ADR **Status** becomes **accepted**, the issue comment links the ADR, and the label becomes `human:decided`. `## Decision` shows only the current decision; history lives in the log.
5. Implementer/planner **read ADRs** before touching a decided area. Reviewer **requires** PRs that touch a decided area to reference the ADR path in the PR body or commits.

## Index
Keep the bullet list below current when adding records.

### ADRs
(none yet — bootstrap seeds the folders + templates)

### Notes
(none yet)

## Helpers
```bash
core/scripts/new-adr.sh --workdir . --title "…" --slug worktree-per-writer [--issue N]
```
