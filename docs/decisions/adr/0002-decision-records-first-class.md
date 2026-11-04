# ADR 0002 — Decision records are first-class

- **Status:** accepted
- **Date:** 2026-10-31 (America/Sao_Paulo)
- **Issue:** (none)
- **Human gate:** required (`human:pending` → `/decide`)
- **Decider:** Marcelus

## Context
Without durable ADRs, human gates evaporate into chat. lohra-ts and apollo keep architecture behind numbered ADRs with human acceptance. Relentless must seed docs/decisions and wire /decide → ADR.

## Options

### 1. Seed docs/decisions (ADR + note); /decide accepts ADRs; agents must read before plan/implement; reviewer requires ADR refs
- Pros: durable memory; audit trail; dogfoodable
- Cons: more process for small forks

### 2. Keep decisions only in GitHub issue comments
- Pros: less filesystem surface
- Cons: hard to discover; no status field contract (rejected)

## Decision
Option 1 accepted on 2026-10-31. Templates + new-adr; bootstrap seeds consumer docs/decisions.


## Consequences
Positive / negative / follow-ups.

## Evidence
