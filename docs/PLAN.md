# PLAN — relentless

Reusable agent-workflow plugin for **Claude Code** and **Codex**. New personal projects start with labels, templates, doctrine, skills, agents, hooks, and a bootstrap that installs them.

| | |
|--|--|
| Plugin name | `relentless` |
| Repo | https://github.com/marcelusfernandes/relentless |
| Artifact language | English |
| Research / decisions | 2026-10-31 (America/Sao_Paulo) |

---

## 0. Closed decisions

| # | Topic | Decision |
|---|--------|----------|
| 1 | Merge | Configurable. Setup chooses repo default (`auto` / `human`). Per-issue `merge:auto` / `merge:human` override. |
| 2 | Branch ruleset | Opt-in at setup; fail soft on API/permission errors — never abort bootstrap. |
| 3 | Language | English only for plugin artifacts. |
| 4 | PR14 + PR15 | In v1 as light templates. **Key principle:** milestones = **product outcomes**; engineering work = issues under an outcome milestone. |
| 5 | Product Upstream | Out of scope. See §5 (`bus-upstream` assessment). |
| 6 | Proof vs Dogfood | Remove Proof (PR8). Keep Dogfooding as a **QA section** owned by the **qa** agent. |
| A | Human labels | `human:pending` and `human:decided`. Never bare-remove pending — flip to decided. `state:blocked` pairs with pending on escalation. |
| B | Authorship markers | Agent: `🤖` + `<!-- relentless:author=agent -->`. Relayed human: `☺️` + `<!-- relentless:author=human decider="<name>" -->`. Decider name from setup config, not GitHub account. |
| C | Assignees | Assignee = worker in progress; reassign to decider on `human:pending`. Reviewer assignment = **v1.1**. |
| D | Decision request | When applying `human:pending`, comment **must** follow `core/templates/decision-request.md`: question/context, numbered options with pros/cons, agent recommendation. `/decide` records the chosen option with ☺️ and flips to `human:decided`. |

---

## 1. Practice inventory (include / exclude)

### Planning
| ID | Practice | Decision | Notes |
|----|----------|----------|-------|
| PR1 | Issue-first | include | English template; QA/dogfood section instead of Proof |
| PR2 | Milestone as phase + exit criteria | include + strengthen | Must state product outcome |
| PR3 | Epic → sub-issues | include | Tie to outcome milestone |

### Governance
| ID | Practice | Decision | Notes |
|----|----------|----------|-------|
| PR4 | Decision records | include | ADR = human gate |
| PR5 | Explicit human gates | include | Closed list; blocked + pending |
| PR7 | Isolated review + merge | include | Mode from setup |
| PR14 | Review findings → follow-up | include (light) | Outcome-framed when user-facing |
| PR15 | Dated status snapshot | include (light) | Template under docs/status |

### Agents / Git / quality
| ID | Practice | Decision |
|----|----------|----------|
| PR6 | Named roles | include (orchestrator session + implementer / reviewer / qa / documenter) |
| PR9 | Worktree per writer | include |
| PR10 | Conventional commits + Closes #N | include |
| PR11 | `state:*` taxonomy | include + human/merge/review labels |
| PR8 | Proof machine | **exclude** |
| PR16 | Dogfooding | **include** (replaces Proof) |
| PR12 | External content = data | include (doctrine) |
| PR13 | Explicit named failure | include |

### Lateral
- Hooks (worktree write guard when that layer is on): include, no proof checks  
- Ruleset script: opt-in, fail soft  
- Domain skills, Notion “add product”, Product Upstream/BUS: **exclude**

---

## 2. New design details

### 2.1 Product-outcome milestones
A milestone describes a user-observable product result and exit criteria verified **by using the product**. Engineering-only titles are forbidden as milestones; they are issues under an outcome milestone.

Artifacts: `core/templates/milestone-outcome.md`, skill `milestone-guard`, `core/scripts/check-milestone-outcomes.sh`.

### 2.2 Merge modes
- `merge.default`: `auto` | `human` in `.relentless/config.json`
- Overrides: `merge:auto` / `merge:human` on the issue when allowed
- Skill: `pr-merge-gate`

### 2.3 Human gate + decision-request (D)
Flow:

1. Agent drafts comment from **`core/templates/decision-request.md`** (question, context, numbered options with pros/cons, recommendation).
2. `core/scripts/request-decision.sh` (or `/request-decision`) posts it, adds `human:pending` + `state:blocked`, assigns `decider.github`.
3. Human replies with an option number.
4. `/decide` / `core/scripts/decide.sh` posts ☺️ relayed-decision marker, flips `human:pending` → `human:decided`, clears blocked, sets `state:todo`, reassigns worker.

Doctrine (`AGENTS.md`) and skill `human-gate` both require the template.

### 2.4 Authorship + assignees
See decisions B and C. Config schema: `core/schemas/config.schema.json`.

### 2.5 Dogfood QA
Skill `dogfood-qa`; agent `qa`. Structured QA section on issue/PR. No provas runner.

---

## 3. Repository layout (v1)

```
.claude-plugin/plugin.json
.codex-plugin/plugin.json
.codex/agents/*.toml
marketplace/marketplace.json
agents/{planner,implementer,qa}.md
skills/{bootstrap,human-gate,issue-lifecycle,milestone-guard,pr-merge-gate,dogfood-qa}/SKILL.md
commands/{decide,bootstrap,request-decision}.md
hooks/hooks.json
core/labels/labels.json
core/templates/{decision-request,authorship-markers,issue-body,milestone-outcome}.md
core/scripts/{bootstrap,decide,request-decision,check-milestone-outcomes}.sh
core/schemas/{config.schema.json,config.example.json}
AGENTS.md
docs/PLAN.md
README.md
LICENSE
```

Consumer projects keep `.relentless/config.json` (not committed to the plugin as the live config).

---

## 4. Bootstrap

`core/scripts/bootstrap.sh --repo OWNER/NAME [--config PATH] [--apply]`

- Default **dry-run**
- Creates/updates labels from `core/labels/labels.json`
- Validates config lightly
- Rulesets: only if `rulesets.apply`, fail soft

---

## 5. bus-upstream assessment (read-only)

Do **not** port BUS/Product Upstream into v1. Useful inspirations already absorbed:

- Outcome-oriented planning language  
- Explicit `/decide`-style human relay  
- Dry-run / `--apply` bootstrap habit  
- Optional HTML comment markers for machines  

Leave full upstream process documentation out of this plugin.

---

## 6. Validation (v1 gate)

| Check | How |
|-------|-----|
| Shell syntax | `bash -n` on `core/scripts/*.sh` |
| Claude plugin shape | `claude plugin validate` when CLI available |
| Bootstrap dry-run | Against `marcelusfernandes/relentless` (no `--apply` unless asked) |
| Template presence | `decision-request.md` referenced from doctrine + human-gate + `/decide` |
| No notes/ in git | Research notes stay out of this repo |

---

## 7. v1.1 backlog (documented only)

- Reviewer auto-assignment  
- Richer ruleset applicator  
- Reviewer GitHub auto-assignment (still v1.1)  
- Richer status snapshot automation beyond write-status-snapshot.sh  

---

## 8. Non-goals

- Writing into other product repos during scaffold  
- Applying labels with `--apply` without explicit approval  
- Merging the scaffold PR without human review  
- Proof/provas surfaces  
- Shipping Product Upstream inside Relentless  

---

## 9. Dogfood friction follow-up (2026-10-31)

Addressed in tree after Teste-relentless dogfood:

- Bootstrap: `--check-scopes`, `workflow` guidance, seed files + CI template, empty-repo warning
- State labels: swap-only via `lib/common.sh` / `set-state.sh`
- `create-issue.sh` resolves milestone by number
- Isolated `reviewer` agent (Claude + Codex) + orchestrator doctrine
- Milestone must not close with open `human:pending`
- Hooks enforce (PreToolUse exit 2) for pending/decide misuse
- Codex install via `.agents/plugins/marketplace.json` + `codex plugin marketplace add` / `codex plugin add`

## 10. Epic + label taxonomy (2026-10-31)

Shipped: expanded labels (type / epic / investigation / severity / GitHub defaults; **no** complexity), `create-epic` / `add-sub-issue` / `create-issue --parent` / `close-epic`, `decompose-epic` skill, milestone guards (epic parent + sub-issue linkage), lohra-ts issue form (Proof → QA/dogfood), apollo-style milestone + epic understanding, investigation template.

## 11. Repo setup / stack CI (2026-10-31) — v1.4.0

Bootstrap prepares the consumer: stack detection, FAIL-closed or real `relentless-ci.yml`, idempotent AGENTS/CLAUDE blocks, epic issue form + blank_issues disabled, `checks` in config, interactive `setup` / `/relentless:setup`.

## 12. R3 dogfood friction (folded into v1.4.0)

- merge-if-ready retargets open PRs stacked on the head branch before --delete-branch (avoids base_ref_deleted).
- Reviewer prompts via stdin/file; Claude stream-json requires --verbose; run-isolated-review.sh for self-sufficient orchestrator loop.
- Isolation hook strips heredoc bodies to avoid false positives on docs text.
- Codex: prefer Write/apply_patch over huge shell heredocs in nested sessions.

## 13. v1.4.0 include completion (2026-10-31)

Shipped against §1 inventory:

| ID | Practice | In tree |
|----|----------|---------|
| PR1–3,5,7,11,16 | Issue/milestone/epic/human-gate/review-merge/labels/dogfood | yes (prior) |
| PR4 | Decision records | yes — `docs/decisions/`, templates, `new-adr`/`accept-adr`/`decide --adr`, bootstrap seed, dogfood ADR 0001–0002 |
| PR6 | Named roles | yes — orchestrator + documenter + existing |
| PR9 | Worktree per writer | yes — skill + create/cleanup + hooks + implementer briefs |
| PR10 | Conventional commits + Closes #N | yes — doctrine + `check-commit-msg.sh` |
| PR12 | External content = data | yes — AGENTS + agent briefs + seeded blocks |
| PR13 | Explicit named failure | yes — doctrine; scripts annotate intentional fail-soft |
| PR14 | Follow-ups after review | yes — `follow-up-after-review.md` |
| PR15 | Status snapshot | yes — template + `write-status-snapshot.sh` |
| Hooks | protect-worktree-write (worktrees layer). protect-main removed | yes |

## 14. v1.4.1 hook and decision guards (2026-10-31)

- PreToolUse protect-main was removed. Commits and pushes on main are the repo's branch protection and, when the githooks layer is on, `.relentless/githooks`.
- `tests/hooks/` regression harness; CI runs it.
- Setup installs consumer `pre-commit` / `pre-push` via `core.hooksPath` (chains husky, does not clobber). GitHub branch protection stays opt-in.
- Human decisions: agents cannot run `decide.sh` / `accept-adr.sh`; Claude UserPromptSubmit records a typed `/decide`; Codex refuses without a TTY and tells the decider the exact terminal command. `merge-if-ready` refuses an accepted ADR with no decision-request comment.

## 15. Future evolution — native issue dependencies

Plan only. Not implemented in this release.

- Native GitHub issue dependencies (blocked-by).
- A `next-ready` script that lists issues whose blockers are all closed.

Until that ships, dependencies stay in prose (`## Dependencies` / `Blocked by:` in issues). That convention is what dogfood used.
