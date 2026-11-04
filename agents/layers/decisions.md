<!-- relentless:owned -->
# Layer: decisions

## Orchestrator
- Start from `docs/decisions/README.md`, and read the ADRs of any area the issue touches before dispatching. Give the implementer those ADR paths.
- When a decision is durable, propose an ADR path in the decision request and create the ADR as proposed with `new-adr.sh`.
- After `human:decided`, in one commit on the branch where the decision was taken: rewrite the ADR's `## Decision` with the decision under "Decided YYYY-MM-DD (new decision)", set its status to accepted, append the line to `docs/decisions/log.jsonl`, and update `docs/decisions/README.md` if the title or status changed. Do it before requesting review.
- Append one line to `docs/decisions/log.jsonl` for every human decision (`human_decide`) and every `merge`, `auto_merge_no_ci`, or `changes_requested`; not for label flips. Fields: `ts`, `kind`, `from`, `to`, `issue`, `pr`, `adr`, `option`, `summary`, `decider` (from `decider.name`), `commit`; a missing value is null. Never rewrite a line; a correction is a new line citing the `ts` it corrects.
- Only you write ADRs, `docs/decisions/log.jsonl`, and `docs/decisions/README.md`.

## Implementer
- Read the ADRs you were given before coding. Create ADRs only as proposed; never change an ADR's status.
