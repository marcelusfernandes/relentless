#!/usr/bin/env bash
# bootstrap.sh — prepare a consumer repo for Relentless: labels, stack-aware CI,
# idempotent AGENTS/CLAUDE blocks, issue forms, config with checks.
# Default dry-run. Prefer the setup skill / /relentless:setup for interactive use.
set -euo pipefail

REPO="" APPLY=0 CONFIG="" WORKDIR="" SEED_FILES=1
MERGE_DEFAULT="" DECIDER_NAME="" DECIDER_GITHUB=""
HARNESS="both"
INIT_EMPTY=1
MERGE_DEFAULT_EXPLICIT=0
BRANCH_PROTECTION=0
UPGRADE=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/detect-stack.sh
source "${SCRIPT_DIR}/lib/detect-stack.sh"
# shellcheck source=lib/render-ci.sh
source "${SCRIPT_DIR}/lib/render-ci.sh"
# shellcheck source=lib/seed-relentless-docs.sh
source "${SCRIPT_DIR}/lib/seed-relentless-docs.sh"
LABELS_FILE="${SCRIPT_DIR}/../labels/labels.json"
TEMPLATES_ROOT="${SCRIPT_DIR}/../templates"
SCHEMA_EXAMPLE="${SCRIPT_DIR}/../schemas/config.example.json"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --repo OWNER/NAME [options]

  --repo OWNER/NAME
  --workdir PATH           Local checkout (needed to seed on disk / initial commit)
  --apply                  Perform changes (default: dry-run)
  --config PATH            Config to validate
  --no-seed-files          Skip seeding
  --check-scopes           Only check gh token scopes and exit
  --merge-default auto|human   Set merge.default (if stack unknown / no test and
                           you omit this, defaults to human with a warning)
  --decider NAME           Set decider.name (non-interactive)
  --decider-github LOGIN   Set decider.github (default: gh api user login)
  --no-init-empty          Do not create initial commit on empty repos
  --harness claude|codex|both
                           Which agent harness this repo uses (default: both).
  --branch-protection      Opt in to GitHub branch protection on the default
                           branch. Off unless this flag is passed. Fail-soft.
  --upgrade                Refresh Relentless-owned files that already exist
                           (Codex agent TOMLs, issue forms, docs blocks).
                           Preserves consumer-customized .checks and does not
                           regenerate .github/workflows/relentless-ci.yml when
                           that file already exists. First-time install still
                           uses plain --apply (seed_copy skips existing files).

Detects stack under --workdir, writes .github/workflows/relentless-ci.yml (real
checks or FAIL-closed placeholder), upserts <!-- relentless:start --> blocks in
AGENTS.md / CLAUDE.md, seeds issue forms including epic + config.yml
(blank_issues_enabled: false), records checks in .relentless/config.json.
Installs .relentless/githooks (pre-commit, pre-push) via core.hooksPath, or
chains an existing hooksPath / husky without replacing it. GitHub branch
protection stays off unless --branch-protection.
USAGE
}

CHECK_SCOPES_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --no-seed-files) SEED_FILES=0; shift ;;
    --check-scopes) CHECK_SCOPES_ONLY=1; shift ;;
    --merge-default) MERGE_DEFAULT="${2:-}"; MERGE_DEFAULT_EXPLICIT=1; shift 2 ;;
    --decider) DECIDER_NAME="${2:-}"; shift 2 ;;
    --decider-github) DECIDER_GITHUB="${2:-}"; shift 2 ;;
    --no-init-empty) INIT_EMPTY=0; shift ;;
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --branch-protection) BRANCH_PROTECTION=1; shift ;;
    --upgrade) UPGRADE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$CHECK_SCOPES_ONLY" -eq 1 ]]; then
  check_gh_workflow_scope
  exit $?
fi

[[ -n "$REPO" ]] || { usage; exit 2; }
for cmd in jq gh; do command -v "$cmd" >/dev/null || { echo "error: $cmd required" >&2; exit 1; }; done
[[ -f "$LABELS_FILE" ]] || { echo "error: labels missing" >&2; exit 1; }

if [[ -n "$MERGE_DEFAULT" && "$MERGE_DEFAULT" != "auto" && "$MERGE_DEFAULT" != "human" ]]; then
  echo "error: --merge-default must be auto|human" >&2; exit 2
fi
case "$HARNESS" in
  claude|codex|both) ;;
  *) echo "error: --harness must be claude|codex|both" >&2; exit 2 ;;
esac

MODE="DRY-RUN"; [[ "$APPLY" -eq 1 ]] && MODE="APPLY"
UPGRADE_LABEL=""; [[ "$UPGRADE" -eq 1 ]] && UPGRADE_LABEL=" upgrade"
echo "== Relentless bootstrap ($MODE$UPGRADE_LABEL) on $REPO (harness=$HARNESS) =="

SCOPE_OK=0
if check_gh_workflow_scope; then SCOPE_OK=1
else
  if [[ "$APPLY" -eq 1 && "$SEED_FILES" -eq 1 ]]; then
    echo "error: refusing --apply with seed files while 'workflow' scope is missing." >&2
    exit 1
  fi
  echo "warn: continuing without workflow scope (CI seed skipped on apply)" >&2
fi

IS_EMPTY="$(gh repo view "$REPO" --json isEmpty -q .isEmpty 2>/dev/null || echo false)"
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name // empty' 2>/dev/null || true)"  # intentional fail-soft

if [[ "$IS_EMPTY" == "true" || -z "$DEFAULT_BRANCH" ]]; then
  echo "empty-repo: no default branch yet"
  if [[ "$INIT_EMPTY" -eq 1 ]]; then
    echo "plan: create initial README commit on main"
    if [[ "$APPLY" -eq 1 ]]; then
      if [[ -z "$WORKDIR" ]]; then
        echo "error: --workdir required to create initial commit on empty repo" >&2
        exit 1
      fi
      mkdir -p "$WORKDIR"
      if [[ ! -d "$WORKDIR/.git" ]]; then
        git clone "https://github.com/${REPO}.git" "$WORKDIR" 2>/dev/null || true  # intentional fail-soft
      fi
      (
        cd "$WORKDIR"
        if [[ ! -d .git ]]; then git init -b main; git remote add origin "https://github.com/${REPO}.git" 2>/dev/null || true; fi  # intentional fail-soft
        if [[ ! -f README.md ]]; then
          printf '# %s\n\nBootstrapped by Relentless.\n' "${REPO##*/}" > README.md
        fi
        if [[ ! -f .gitignore ]]; then
          cp "${TEMPLATES_ROOT}/gitignore" .gitignore
        fi
        git config user.email >/dev/null 2>&1 || git config user.email "relentless-bot@users.noreply.github.com"
        git config user.name >/dev/null 2>&1 || git config user.name "Relentless Bootstrap"
        git add README.md .gitignore
        if git commit -m "chore: initial commit" 2>/dev/null; then
          git push -u origin HEAD:main
          echo "empty-repo: pushed initial commit"
        else
          git push -u origin HEAD:main 2>/dev/null || true  # intentional fail-soft
        fi
      )
    fi
  else
    echo "warn: --no-init-empty; create an initial commit before milestones"
  fi
fi

# --- Stack detection ---
STACK="unknown"; PM=""; INSTALL=""; LINT=""; TYPECHECK=""; TEST=""; BUILD=""; HAS_TEST=0
if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
  detect_stack "$WORKDIR"
  echo "stack: $STACK (pm=${PM:-n/a} has_test=$HAS_TEST)"
  echo "  install: ${INSTALL:-"(none)"}"
  echo "  lint: ${LINT:-"(none)"}"
  echo "  typecheck: ${TYPECHECK:-"(none)"}"
  echo "  test: ${TEST:-"(none)"}"
  echo "  build: ${BUILD:-"(none)"}"
else
  echo "stack: (no --workdir — skip detection; CI will FAIL-closed if seeded without workdir apply)"
fi

# Safe merge default when checks are weak
if [[ "$HAS_TEST" -eq 0 || "$STACK" == "unknown" ]]; then
  if [[ "$MERGE_DEFAULT_EXPLICIT" -eq 0 ]]; then
    MERGE_DEFAULT="human"
    echo "warn: stack unknown or no test command — forcing merge.default=human"
    echo "warn: pass --merge-default auto explicitly only if you accept merge-if-ready risk"
  elif [[ "$MERGE_DEFAULT" == "auto" ]]; then
    echo "warn: merge.default=auto requested but no reliable test detected — CI will FAIL until configured"
  fi
fi
# If still empty, leave example default from schema (human)
if [[ -z "$MERGE_DEFAULT" ]]; then
  MERGE_DEFAULT="human"
fi

if [[ -z "$CONFIG" && -n "$WORKDIR" && -f "${WORKDIR}/.relentless/config.json" ]]; then
  CONFIG="${WORKDIR}/.relentless/config.json"
fi

write_or_patch_config() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  if [[ ! -f "$dest" ]]; then
    cp "$SCHEMA_EXAMPLE" "$dest"
  fi
  local login
  login="${DECIDER_GITHUB:-$(gh api user -q .login 2>/dev/null || echo "")}"
  local name="${DECIDER_NAME:-}"
  local merge="${MERGE_DEFAULT:-}"
  local tmp
  tmp="$(mktemp)"
  # On --upgrade, keep consumer-customized checks (F47). Fresh installs still
  # get detected stack checks. Missing checks keys are filled either way.
  jq --arg name "$name" --arg gh "$login" --arg merge "$merge" \
    --arg stack "$STACK" --arg pm "$PM" \
    --arg install "$INSTALL" --arg lint "$LINT" --arg typecheck "$TYPECHECK" \
    --arg test "$TEST" --arg build "$BUILD" \
    --argjson bp "${BRANCH_PROTECTION:-0}" \
    --argjson upgrade "${UPGRADE:-0}" \
    '
    if ($name | length) > 0 then .decider.name = $name else . end |
    if ($gh | length) > 0 then .decider.github = $gh | .workers.default.github = $gh else . end |
    if ($merge | length) > 0 then .merge.default = $merge else . end |
    if $bp == 1 then .rulesets = ((.rulesets // {}) + {apply: true}) else . end |
    .stack = $stack |
    .package_manager = (if $pm | length > 0 then $pm else null end) |
    (if $upgrade == 1 and (.checks | type == "object") then
      .checks = (
        .checks
        | .install = (if (.install // "") == "" then $install else .install end)
        | .lint = (if (.lint // "") == "" then $lint else .lint end)
        | .typecheck = (if (.typecheck // "") == "" then $typecheck else .typecheck end)
        | .test = (if (.test // "") == "" then $test else .test end)
        | .build = (if (.build // "") == "" then $build else .build end)
      )
    else
      .checks = {
        install: $install,
        lint: $lint,
        typecheck: $typecheck,
        test: $test,
        build: $build
      }
    end)
    ' "$dest" >"$tmp" && mv "$tmp" "$dest"
  if [[ "${UPGRADE:-0}" -eq 1 ]]; then
    echo "config written: $dest (upgrade: preserved existing checks; merge.default=$(jq -r .merge.default "$dest"), stack=$(jq -r .stack "$dest"), decider=$(jq -r .decider.name "$dest"))"
  else
    echo "config written: $dest (merge.default=$(jq -r .merge.default "$dest"), stack=$(jq -r .stack "$dest"), decider=$(jq -r .decider.name "$dest"))"
  fi
}

if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
  echo "config: found $CONFIG"
  if ! jq -e '.decider.name and .decider.github and .merge.default' "$CONFIG" >/dev/null 2>&1; then
    echo "warn: config missing required fields" >&2
  else
    echo "config: basic schema ok"
  fi
  if ! jq -e '.workers and (.workers | type == "object") and (.workers | length > 0)' "$CONFIG" >/dev/null 2>&1; then
    echo "warn: config.workers missing or empty" >&2
  else
    echo "config: workers ok"
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    write_or_patch_config "$CONFIG"
  else
    echo "plan: would patch config with merge.default=${MERGE_DEFAULT} stack=${STACK} checks=…"
  fi
else
  echo "config: none yet"
  echo "plan: seed config with merge.default=${MERGE_DEFAULT} decider=${DECIDER_NAME:-'(from gh)'} stack=${STACK}"
fi

EXISTING="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"  # intentional fail-soft
while IFS= read -r row; do
  name="$(jq -r '.name' <<<"$row")"
  color="$(jq -r '.color' <<<"$row")"
  desc="$(jq -r '.description' <<<"$row")"
  if grep -Fxq "$name" <<<"$EXISTING"; then
    echo "label exists: $name"
    if [[ "$APPLY" -eq 1 ]]; then
      gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null || true  # intentional fail-soft
    fi
  else
    echo "label create: $name"
    if [[ "$APPLY" -eq 1 ]]; then
      gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null || true  # intentional fail-soft
    fi
  fi
done < <(jq -c '.labels[]' "$LABELS_FILE")

seed_copy() {
  local src="$1" dest_rel="$2"
  if [[ -z "$WORKDIR" ]]; then
    echo "seed (needs --workdir): $dest_rel"; return 0
  fi
  local dest="${WORKDIR}/${dest_rel}"
  if [[ -e "$dest" ]]; then
    echo "seed skip (exists): $dest_rel"; return 0
  fi
  echo "seed write: $dest_rel"
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  fi
}

# Always overwrite Relentless-owned template files (idempotent refresh)
seed_write() {
  local src="$1" dest_rel="$2"
  if [[ -z "$WORKDIR" ]]; then
    echo "seed (needs --workdir): $dest_rel"; return 0
  fi
  echo "seed write: $dest_rel (owned)"
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$(dirname "${WORKDIR}/${dest_rel}")"
    cp "$src" "${WORKDIR}/${dest_rel}"
  fi
}

if [[ "$SEED_FILES" -eq 1 ]]; then
  echo "-- seed plan --"
  if [[ -z "$WORKDIR" ]]; then
    echo "seed: no --workdir; listing paths only"
  fi

  if [[ -n "$WORKDIR" ]]; then
    dest_cfg="${WORKDIR}/.relentless/config.json"
    if [[ "$APPLY" -eq 1 ]]; then
      write_or_patch_config "$dest_cfg"
    else
      echo "seed write: .relentless/config.json (merge=${MERGE_DEFAULT} stack=${STACK})"
    fi
  else
    echo "seed (needs --workdir): .relentless/config.json"
  fi

  # Issue forms — Relentless-owned, refresh
  seed_write "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/relentless.yml" ".github/ISSUE_TEMPLATE/relentless.yml"
  seed_write "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/investigation.yml" ".github/ISSUE_TEMPLATE/investigation.yml"
  seed_write "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/epic.yml" ".github/ISSUE_TEMPLATE/epic.yml"
  seed_write "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/config.yml" ".github/ISSUE_TEMPLATE/config.yml"
  seed_copy "${TEMPLATES_ROOT}/github/PULL_REQUEST_TEMPLATE.md" ".github/PULL_REQUEST_TEMPLATE.md"
  # Starter ignore. Skip when the consumer already has one.
  seed_copy "${TEMPLATES_ROOT}/gitignore" ".gitignore"

  # AGENTS.md / CLAUDE.md — idempotent delimited blocks
  if [[ -n "$WORKDIR" ]]; then
    agents_block="$(render_relentless_agents_block "$MERGE_DEFAULT" "$HARNESS" "$STACK" "$INSTALL" "$LINT" "$TYPECHECK" "$TEST" "$BUILD")"
    claude_block="$(render_relentless_claude_block "$MERGE_DEFAULT" "$HARNESS" "$STACK" "$TEST")"
    if [[ "$APPLY" -eq 1 ]]; then
      upsert_relentless_block "${WORKDIR}/AGENTS.md" "$agents_block"
      upsert_relentless_block "${WORKDIR}/CLAUDE.md" "$claude_block"
    else
      echo "seed upsert: AGENTS.md (relentless block)"
      echo "seed upsert: CLAUDE.md (relentless block)"
    fi
  else
    echo "seed (needs --workdir): AGENTS.md / CLAUDE.md relentless blocks"
  fi

  if [[ "$HARNESS" == "codex" || "$HARNESS" == "both" ]]; then
    for agent in planner implementer qa reviewer orchestrator documenter; do
      src="${SCRIPT_DIR}/../../.codex/agents/${agent}.toml"
      if [[ ! -f "$src" ]]; then
        continue
      fi
      # F46: --upgrade refreshes owned agent briefs; first install keeps seed_copy.
      if [[ "$UPGRADE" -eq 1 ]]; then
        seed_write "$src" ".codex/agents/${agent}.toml"
      else
        seed_copy "$src" ".codex/agents/${agent}.toml"
      fi
    done
    # F48: pin marketplace ref in project .codex/config.toml when missing (Codex has no lockfile).
    if [[ -n "$WORKDIR" ]]; then
      codex_cfg="${WORKDIR}/.codex/config.toml"
      pin_ver="$(jq -r .version "${SCRIPT_DIR}/../../plugin.json" 2>/dev/null || echo "")"
      if [[ -n "$pin_ver" ]]; then
        if [[ ! -f "$codex_cfg" ]]; then
          echo "seed write: .codex/config.toml (marketplace pin ref=v${pin_ver})"
          if [[ "$APPLY" -eq 1 ]]; then
            mkdir -p "$(dirname "$codex_cfg")"
            cat > "$codex_cfg" <<EOF
# Relentless Codex pin (no native per-project plugin lockfile on 0.165.x).
# After bumping the plugin, re-run bootstrap --upgrade or edit ref= below.
[marketplaces.relentless]
source_type = "git"
source = "https://github.com/marcelusfernandes/relentless"
ref = "v${pin_ver}"

[plugins."relentless@relentless"]
enabled = true
EOF
          fi
        elif [[ "$UPGRADE" -eq 1 ]]; then
          if grep -q '^\[marketplaces\.relentless\]' "$codex_cfg" 2>/dev/null; then
            echo "seed skip (exists): .codex/config.toml marketplace pin — edit ref= manually or replace the file"
          else
            echo "seed append: .codex/config.toml marketplace pin ref=v${pin_ver}"
            if [[ "$APPLY" -eq 1 ]]; then
              cat >> "$codex_cfg" <<EOF

# Relentless Codex pin (added by bootstrap --upgrade)
[marketplaces.relentless]
source_type = "git"
source = "https://github.com/marcelusfernandes/relentless"
ref = "v${pin_ver}"

[plugins."relentless@relentless"]
enabled = true
EOF
            fi
          fi
        else
          echo "seed skip (exists): .codex/config.toml"
        fi
      fi
    fi
  else
    echo "seed skip (--harness claude): .codex/agents/*.toml"
  fi

  # CI — first install writes relentless-ci.yml; --upgrade keeps an existing file (F47).
  if [[ "$SCOPE_OK" -eq 1 ]]; then
    if [[ -n "$WORKDIR" ]]; then
      ci_dest="${WORKDIR}/.github/workflows/relentless-ci.yml"
      if [[ "$UPGRADE" -eq 1 && -f "$ci_dest" ]]; then
        echo "seed skip (upgrade preserves CI): .github/workflows/relentless-ci.yml"
      else
        echo "seed write: .github/workflows/relentless-ci.yml (stack=${STACK} has_test=${HAS_TEST})"
        if [[ "$APPLY" -eq 1 ]]; then
          render_relentless_ci_to_file "$ci_dest"
        fi
      fi
    else
      echo "seed (needs --workdir): .github/workflows/relentless-ci.yml"
    fi
  else
    echo "seed skip (no workflow scope): .github/workflows/relentless-ci.yml"
  fi

  seed_copy "${TEMPLATES_ROOT}/milestone-outcome.md" "docs/relentless/milestone-outcome.example.md"
  seed_copy "${TEMPLATES_ROOT}/epic-body.md" "docs/relentless/epic-body.example.md"
  seed_copy "${TEMPLATES_ROOT}/investigation-body.md" "docs/relentless/investigation-body.example.md"

  # Decision records (first-class) + status + follow-up + worktreeinclude
  seed_copy "${TEMPLATES_ROOT}/decisions/README.md" "docs/decisions/README.md"
  seed_copy "${TEMPLATES_ROOT}/decisions/log.jsonl" "docs/decisions/log.jsonl"
  seed_copy "${TEMPLATES_ROOT}/decisions/adr-template.md" "docs/decisions/adr/TEMPLATE.md"
  seed_copy "${TEMPLATES_ROOT}/decisions/note-template.md" "docs/decisions/notes/TEMPLATE.md"
  seed_copy "${TEMPLATES_ROOT}/status-mN.md" "docs/status/TEMPLATE.md"
  seed_copy "${TEMPLATES_ROOT}/follow-up-after-review.md" "docs/relentless/follow-up-after-review.example.md"
  # .worktreeinclude — only if absent (consumer-owned secrets list)
  if [[ -n "$WORKDIR" ]]; then
    wtinc="${WORKDIR}/.worktreeinclude"
    if [[ ! -f "$wtinc" ]]; then
      echo "seed write: .worktreeinclude"
      if [[ "$APPLY" -eq 1 ]]; then
        cat > "$wtinc" <<'WTINC'
# Paths (relative to repo root) copied into each Relentless worktree after `worktree-create.sh`.
# Add local-only files the implementer needs (.env.local, etc.). Do not commit secrets.
# .env.local
WTINC
      fi
    else
      echo "seed skip (exists): .worktreeinclude"
    fi
    # Ensure adr/notes dirs exist on apply even if copy skipped
    if [[ "$APPLY" -eq 1 ]]; then
      mkdir -p "${WORKDIR}/docs/decisions/adr" "${WORKDIR}/docs/decisions/notes" "${WORKDIR}/docs/status"
    fi
  else
    echo "seed (needs --workdir): docs/decisions/*, docs/status/TEMPLATE.md, .worktreeinclude"
  fi
else
  echo "seed: skipped (--no-seed-files)"
fi

apply_branch_protection() {
  local branch="${DEFAULT_BRANCH:-main}"
  [[ -n "$branch" ]] || branch="main"
  local resp rc
  set +e
  resp="$(gh api -X POST "repos/${REPO}/rulesets" --input - <<JSON
{
  "name": "relentless-protect-default",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/${branch}"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"}
  ]
}
JSON
)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    # intentional fail-soft: branch protection is opt-in and often denied by token scope
    echo "warn: branch protection API failed (not enabled): ${resp}" >&2
    return 0
  fi
  echo "branch protection: enabled on ${branch} (deletion + non-fast-forward blocked)"
}

if [[ -n "$WORKDIR" ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    "${SCRIPT_DIR}/install-githooks.sh" --workdir "$WORKDIR"
  else
    echo "plan: install .relentless/githooks (pre-commit, pre-push)"
    echo "plan: core.hooksPath=.relentless/githooks, or chain an existing hooksPath/husky without replacing it"
    echo "plan: hooks refuse commits on main/master, pushes to main/master, and force-pushes"
  fi
else
  echo "githooks: needs --workdir"
fi

if [[ "$BRANCH_PROTECTION" -eq 1 ]]; then
  echo "branch protection: opted in (fail-soft)"
  if [[ "$APPLY" -eq 1 ]]; then
    apply_branch_protection
  else
    echo "plan: would enable GitHub branch protection on ${DEFAULT_BRANCH:-main}"
  fi
else
  echo "branch protection: off (default; pass --branch-protection only after an explicit yes)"
fi

echo "== done ($MODE) =="
echo "tip: use skill setup or /relentless:setup for interactive prep (PR with seeds)."
echo "tip: do NOT copy plugin agents/skills into this repo."
echo "tip: Claude — install at PROJECT scope:"
echo "     claude plugin marketplace add marcelusfernandes/relentless"
echo "     claude plugin install relentless@relentless --scope project -y"
echo "tip: Codex (0.165.x) user-level only: codex plugin add relentless@relentless"
echo "tip: upgrading an existing consumer: re-run with --upgrade --apply (refreshes owned files, keeps checks + CI)."
