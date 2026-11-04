#!/usr/bin/env bash
# bootstrap.sh — add what a consumer repo is missing: config, the docs block,
# and core labels. Layers run when layers.<name> is true. A fresh bootstrap
# writes every switch false. A config with no layers object keeps the 1.4.11
# layers on, including githooks. Default dry-run.
# An existing label, template, or workflow is not edited. checks.test is filled
# only when that field is absent or empty. A relentless-owned file
# (.codex/agents/*.toml, .relentless/layers/<layer>.md) is refreshed only when
# it still carries the relentless:owned marker. A file without the marker is
# never touched.
set -euo pipefail

REPO="" APPLY=0 CONFIG="" WORKDIR="" SEED_FILES=1
MERGE_DEFAULT="" DECIDER_NAME="" DECIDER_GITHUB=""
HARNESS="both"
INIT_EMPTY=1
BRANCH_PROTECTION=0
UPGRADE=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/seed-relentless-docs.sh
source "${SCRIPT_DIR}/lib/seed-relentless-docs.sh"
LABELS_FILE="${SCRIPT_DIR}/../labels/labels.json"
TEMPLATES_ROOT="${SCRIPT_DIR}/../templates"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --repo OWNER/NAME [options]

  --repo OWNER/NAME
  --workdir PATH           Local checkout (needed to seed on disk)
  --apply                  Perform changes (default: dry-run)
  --config PATH            Config to read. An existing file is not rewritten.
  --no-seed-files          Skip seeding
  --check-scopes           Only check gh token scopes and exit
  --merge-default auto|human   merge.default on a new config
  --decider NAME           Set decider.name (non-interactive)
  --decider-github LOGIN   Set decider.github (default: gh api user login)
  --no-init-empty          Do not create initial commit on empty repos
  --harness claude|codex|both
  --branch-protection      Opt in to GitHub branch protection. Off unless passed.
  --upgrade                Kept for compatibility. Does not rewrite existing files.

A new config records the repo default branch (base), the merge methods the
repo allows, and checks.test from the repo's own workflow. layers.* start
false. A config with no layers object keeps every 1.4.11 layer on. Inside
layers, a switch runs only when it is true. checks.test is filled from the
repo workflow only when the field is absent or empty.
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
    --merge-default) MERGE_DEFAULT="${2:-}"; shift 2 ;;
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
if [[ -z "$MERGE_DEFAULT" ]]; then
  MERGE_DEFAULT="human"
fi

MODE="DRY-RUN"; [[ "$APPLY" -eq 1 ]] && MODE="APPLY"
UPGRADE_LABEL=""; [[ "$UPGRADE" -eq 1 ]] && UPGRADE_LABEL=" upgrade"
echo "== Relentless bootstrap ($MODE$UPGRADE_LABEL) on $REPO (harness=$HARNESS) =="

if [[ -z "$CONFIG" && -n "$WORKDIR" && -f "${WORKDIR}/.relentless/config.json" ]]; then
  CONFIG="${WORKDIR}/.relentless/config.json"
fi

CONFIG_EXISTED=0
if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
  CONFIG_EXISTED=1
  # A broken file stops here. It must not be treated as layers-off.
  require_parsed_config "$CONFIG"
fi

# True when the layer runs. See layer_enabled: missing file is off, no layers
# object is on (1.4.11, including githooks), and invalid JSON exits.
layer_on() {
  local name="$1" cfg=""
  if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
    cfg="$CONFIG"
  elif [[ -n "$WORKDIR" && -f "${WORKDIR}/.relentless/config.json" ]]; then
    cfg="${WORKDIR}/.relentless/config.json"
  fi
  layer_enabled "$name" "$cfg"
}

active_config() {
  if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
    printf '%s\n' "$CONFIG"
  elif [[ -n "$WORKDIR" && -f "${WORKDIR}/.relentless/config.json" ]]; then
    printf '%s\n' "${WORKDIR}/.relentless/config.json"
  fi
}

# Single-line `run:` steps. Prefer a command that mentions test.
read_repo_test_command() {
  local root="$1" f line cmd picked=""
  [[ -n "$root" && -d "$root/.github/workflows" ]] || return 0
  for f in "$root"/.github/workflows/*; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        *run:*)
          cmd="${line#*run:}"
          cmd="${cmd#"${cmd%%[![:space:]]*}"}"
          cmd="${cmd%"${cmd##*[![:space:]]}"}"
          [[ -n "$cmd" && "$cmd" != "|" ]] || continue
          if [[ -z "$picked" ]]; then
            picked="$cmd"
          fi
          if printf '%s\n' "$cmd" | grep -q 'test'; then
            printf '%s\n' "$cmd"
            return 0
          fi
          ;;
      esac
    done <"$f"
  done
  printf '%s\n' "$picked"
}

read_merge_methods() {
  local raw
  # intentional fail-soft: a repo that does not answer still gets a config
  raw="$(gh api "repos/${REPO}" --jq '{allow_merge_commit,allow_squash_merge,allow_rebase_merge}' 2>/dev/null || true)"
  if printf '%s' "$raw" | jq -e 'type == "object" and has("allow_squash_merge")' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c '{merge: .allow_merge_commit, squash: .allow_squash_merge, rebase: .allow_rebase_merge}'
  fi
}

write_fresh_config() {
  local dest="$1" login base test_cmd methods
  mkdir -p "$(dirname "$dest")"
  login="${DECIDER_GITHUB:-$(gh api user -q .login 2>/dev/null || echo "")}"
  # intentional fail-soft: record an empty base rather than inventing one
  base="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name // empty' 2>/dev/null || true)"
  test_cmd="$(read_repo_test_command "$WORKDIR")"
  methods="$(read_merge_methods || true)"
  if [[ -n "$methods" ]]; then
    jq -n \
      --arg name "${DECIDER_NAME:-$login}" \
      --arg gh "$login" \
      --arg merge "$MERGE_DEFAULT" \
      --arg base "$base" \
      --arg test "$test_cmd" \
      --argjson methods "$methods" \
      '{
        decider: {name: $name, github: $gh},
        workers: {default: {github: $gh}},
        merge: {default: $merge, allow_issue_override: true},
        base: $base,
        merge_methods: $methods,
        checks: {test: $test},
        layers: {
          merge: false, review: false, qa: false, worktrees: false,
          decisions: false, templates: false, ci: false, githooks: false, docs: false
        }
      }' >"$dest"
  else
    jq -n \
      --arg name "${DECIDER_NAME:-$login}" \
      --arg gh "$login" \
      --arg merge "$MERGE_DEFAULT" \
      --arg base "$base" \
      --arg test "$test_cmd" \
      '{
        decider: {name: $name, github: $gh},
        workers: {default: {github: $gh}},
        merge: {default: $merge, allow_issue_override: true},
        base: $base,
        checks: {test: $test},
        layers: {
          merge: false, review: false, qa: false, worktrees: false,
          decisions: false, templates: false, ci: false, githooks: false, docs: false
        }
      }' >"$dest"
  fi
  echo "config written: $dest (base=$(jq -r '.base // empty' "$dest"), merge.default=$(jq -r .merge.default "$dest"), checks.test=$(jq -r '.checks.test // empty' "$dest"))"
}

SCOPE_OK=0
if check_gh_workflow_scope; then SCOPE_OK=1
else
  echo "warn: continuing without workflow scope" >&2
fi

IS_EMPTY="$(gh repo view "$REPO" --json isEmpty -q .isEmpty 2>/dev/null || echo false)"
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name // empty' 2>/dev/null || true)"  # intentional fail-soft

if [[ "$IS_EMPTY" == "true" || -z "$DEFAULT_BRANCH" ]]; then
  echo "empty-repo: no default branch yet"
  if [[ "$INIT_EMPTY" -eq 1 && "$APPLY" -eq 1 && -n "$WORKDIR" ]]; then
    echo "plan: create initial README commit"
    mkdir -p "$WORKDIR"
    (
      cd "$WORKDIR"
      if [[ ! -d .git ]]; then git init -b main; git remote add origin "https://github.com/${REPO}.git" 2>/dev/null || true; fi  # intentional fail-soft
      if [[ ! -f README.md ]]; then
        printf '# %s\n\nBootstrapped by Relentless.\n' "${REPO##*/}" > README.md
      fi
      git config user.email >/dev/null 2>&1 || git config user.email "relentless-bot@users.noreply.github.com"
      git config user.name >/dev/null 2>&1 || git config user.name "Relentless Bootstrap"
      git add README.md
      if git commit -m "chore: initial commit" 2>/dev/null; then
        git push -u origin HEAD
        echo "empty-repo: pushed initial commit"
      fi
    )
  elif [[ "$INIT_EMPTY" -eq 0 ]]; then
    echo "warn: --no-init-empty; create an initial commit before milestones"
  fi
fi

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

# Write checks.test from the repo workflow only when that field is absent or empty.
# A value the repo already set is left alone. Other config fields are not rewritten.
fill_empty_checks() {
  local dest="$1" detected current tmp
  [[ -n "$dest" && -f "$dest" ]] || return 0
  detected="$(read_repo_test_command "$WORKDIR")"
  [[ -n "$detected" ]] || return 0
  current="$(jq -r '.checks.test // empty' "$dest")"
  [[ -z "$current" ]] || return 0
  echo "config fill: checks.test from the repo workflow"
  if [[ "$APPLY" -eq 1 ]]; then
    tmp="$(mktemp)"
    jq --arg t "$detected" '.checks = (.checks // {}) | .checks.test = $t' "$dest" >"$tmp"
    mv "$tmp" "$dest"
  fi
}

# The only place a relentless-owned file is refreshed.
# .codex/agents/*.toml and .relentless/layers/<layer>.md are rewritten only when
# the consumer file still carries the relentless:owned marker. A file without
# that marker was edited by the repo and is never touched.
refresh_owned() {
  local src="$1" dest_rel="$2" dest
  if [[ -z "$WORKDIR" ]]; then
    echo "skipped: ${dest_rel} (needs --workdir)"
    return 0
  fi
  dest="${WORKDIR}/${dest_rel}"
  if [[ ! -e "$dest" ]]; then
    echo "skipped: ${dest_rel} (absent)"
    return 0
  fi
  if [[ ! -f "$src" ]]; then
    echo "skipped: ${dest_rel} (no source)"
    return 0
  fi
  if grep -q 'relentless:owned' "$dest"; then
    if [[ "$APPLY" -eq 1 ]]; then
      cp "$src" "$dest"
      echo "refreshed: ${dest_rel}"
    else
      echo "refreshed (dry-run): ${dest_rel}"
    fi
  else
    echo "skipped: ${dest_rel}"
  fi
}

copy_layer_file() {
  local name="$1" src rel
  src="${SCRIPT_DIR}/../../agents/layers/${name}.md"
  rel=".relentless/layers/${name}.md"
  if [[ -z "$WORKDIR" ]]; then
    echo "seed (needs --workdir): ${rel}"
    return 0
  fi
  if [[ ! -e "${WORKDIR}/${rel}" ]]; then
    seed_copy "$src" "$rel"
  else
    refresh_owned "$src" "$rel"
  fi
}

# Core agents are refreshed when present and marked, and are not created.
# Layer agents are created only when that layer is on.
refresh_codex_agent() {
  local agent="$1" layer="${2:-}" src rel
  src="${SCRIPT_DIR}/../../.codex/agents/${agent}.toml"
  rel=".codex/agents/${agent}.toml"
  [[ -f "$src" ]] || return 0
  if [[ -n "$WORKDIR" && -e "${WORKDIR}/${rel}" ]]; then
    refresh_owned "$src" "$rel"
    return 0
  fi
  if [[ -n "$layer" ]] && layer_on "$layer"; then
    seed_copy "$src" "$rel"
  fi
}

if [[ "$SEED_FILES" -eq 0 ]]; then
  echo "seed: skipped (--no-seed-files)"
  echo "== done ($MODE) =="
  exit 0
fi

echo "-- seed plan --"

if [[ -n "$WORKDIR" ]]; then
  dest_cfg="${WORKDIR}/.relentless/config.json"
  if [[ -f "$dest_cfg" || "$CONFIG_EXISTED" -eq 1 ]]; then
    echo "config: kept existing ${CONFIG:-$dest_cfg}"
    fill_empty_checks "${CONFIG:-$dest_cfg}"
  elif [[ "$APPLY" -eq 1 ]]; then
    write_fresh_config "$dest_cfg"
    CONFIG="$dest_cfg"
  else
    echo "plan: would write .relentless/config.json (base from the repo, layers off, merge.default=${MERGE_DEFAULT})"
  fi
else
  echo "seed (needs --workdir): .relentless/config.json"
fi

# Core labels only. Create the missing ones. Never edit an existing label.
EXISTING="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"  # intentional fail-soft
while IFS= read -r row; do
  name="$(jq -r '.name' <<<"$row")"
  color="$(jq -r '.color' <<<"$row")"
  desc="$(jq -r '.description' <<<"$row")"
  if grep -Fxq "$name" <<<"$EXISTING"; then
    echo "label exists: $name"
  else
    echo "label create: $name"
    if [[ "$APPLY" -eq 1 ]]; then
      gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null || true  # intentional fail-soft: label may appear between list and create
    fi
  fi
done < <(jq -c '.labels[]' "$LABELS_FILE")

if [[ -n "$WORKDIR" ]]; then
  cfg_docs="$(active_config)"
  doc_install=""
  doc_lint=""
  doc_type=""
  doc_test=""
  doc_build=""
  enabled=""
  if [[ -n "$cfg_docs" ]]; then
    doc_install="$(jq -r '.checks.install // empty' "$cfg_docs")"
    doc_lint="$(jq -r '.checks.lint // empty' "$cfg_docs")"
    doc_type="$(jq -r '.checks.typecheck // empty' "$cfg_docs")"
    doc_test="$(jq -r '.checks.test // empty' "$cfg_docs")"
    doc_build="$(jq -r '.checks.build // empty' "$cfg_docs")"
  fi
  for layer_name in merge review qa worktrees decisions templates ci githooks docs; do
    if layer_on "$layer_name"; then
      enabled="${enabled} ${layer_name}"
    fi
  done
  enabled="${enabled# }"
  agents_block="$(render_relentless_agents_block "$MERGE_DEFAULT" "$HARNESS" "repo" "$doc_install" "$doc_lint" "$doc_type" "$doc_test" "$doc_build" "$enabled")"
  claude_block="$(render_relentless_claude_block "$MERGE_DEFAULT" "$HARNESS" "repo" "$doc_test")"
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

if layer_on templates; then
  seed_copy "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/relentless.yml" ".github/ISSUE_TEMPLATE/relentless.yml"
  seed_copy "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/investigation.yml" ".github/ISSUE_TEMPLATE/investigation.yml"
  seed_copy "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/epic.yml" ".github/ISSUE_TEMPLATE/epic.yml"
  seed_copy "${TEMPLATES_ROOT}/github/ISSUE_TEMPLATE/config.yml" ".github/ISSUE_TEMPLATE/config.yml"
  seed_copy "${TEMPLATES_ROOT}/github/PULL_REQUEST_TEMPLATE.md" ".github/PULL_REQUEST_TEMPLATE.md"
else
  echo "seed skip (layers.templates is not true): issue and PR templates"
fi

if layer_on decisions; then
  seed_copy "${TEMPLATES_ROOT}/decisions/README.md" "docs/decisions/README.md"
  seed_copy "${TEMPLATES_ROOT}/decisions/log.jsonl" "docs/decisions/log.jsonl"
  seed_copy "${TEMPLATES_ROOT}/decisions/adr-template.md" "docs/decisions/adr/TEMPLATE.md"
  seed_copy "${TEMPLATES_ROOT}/decisions/note-template.md" "docs/decisions/notes/TEMPLATE.md"
else
  echo "seed skip (layers.decisions is not true): docs/decisions"
fi

if layer_on ci; then
  ci_cfg="$(active_config)"
  if [[ -n "$WORKDIR" && -f "${WORKDIR}/.github/workflows/relentless-ci.yml" ]]; then
    echo "seed skip (exists): .github/workflows/relentless-ci.yml"
  elif [[ "$CONFIG_EXISTED" -eq 1 && -n "$ci_cfg" ]] && ! jq -e 'has("layers")' "$ci_cfg" >/dev/null; then
    # 1.4.11 did not recreate a workflow the repo had removed.
    echo "seed skip (existing install, workflow absent): .github/workflows/relentless-ci.yml"
  elif [[ "$SCOPE_OK" -eq 1 && -n "$WORKDIR" ]]; then
    # shellcheck source=lib/detect-stack.sh
    source "${SCRIPT_DIR}/lib/detect-stack.sh"
    # shellcheck source=lib/render-ci.sh
    source "${SCRIPT_DIR}/lib/render-ci.sh"
    detect_stack "$WORKDIR"
    echo "seed write: .github/workflows/relentless-ci.yml (stack=${STACK:-unknown})"
    if [[ "$APPLY" -eq 1 ]]; then
      render_relentless_ci_to_file "${WORKDIR}/.github/workflows/relentless-ci.yml"
    fi
  else
    echo "seed skip (no workflow scope or no workdir): .github/workflows/relentless-ci.yml"
  fi
else
  echo "seed skip (layers.ci is not true): .github/workflows/relentless-ci.yml"
fi

if layer_on githooks; then
  if [[ -n "$WORKDIR" ]]; then
    if [[ "$APPLY" -eq 1 ]]; then
      "${SCRIPT_DIR}/install-githooks.sh" --workdir "$WORKDIR"
    else
      echo "plan: install .relentless/githooks (pre-commit, pre-push)"
    fi
  else
    echo "githooks: needs --workdir"
  fi
else
  echo "seed skip (layers.githooks is not true): .relentless/githooks"
fi

for layer_name in merge review qa worktrees decisions templates ci githooks docs; do
  if layer_on "$layer_name"; then
    copy_layer_file "$layer_name"
  fi
done

if [[ "$HARNESS" == "codex" || "$HARNESS" == "both" ]]; then
  refresh_codex_agent orchestrator
  refresh_codex_agent implementer
  refresh_codex_agent planner
  refresh_codex_agent reviewer review
  refresh_codex_agent qa qa
  refresh_codex_agent documenter docs
else
  echo "seed skip (--harness claude): .codex/agents/*.toml"
fi

if [[ "$BRANCH_PROTECTION" -eq 1 ]]; then
  echo "branch protection: opted in (fail-soft; config is not rewritten)"
  if [[ "$APPLY" -eq 1 ]]; then
    branch="${DEFAULT_BRANCH:-main}"
    # intentional fail-soft: branch protection is opt-in and often denied
    gh api -X POST "repos/${REPO}/rulesets" --input - <<JSON || echo "warn: branch protection API failed" >&2
{
  "name": "relentless-protect-default",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/${branch}"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]
}
JSON
  fi
else
  echo "branch protection: off (default; pass --branch-protection only after an explicit yes)"
fi

echo "== done ($MODE) =="
echo "tip: use skill setup or /relentless:setup for interactive prep."
echo "tip: do NOT copy plugin agents/skills into this repo."
echo "tip: re-run --apply to add a missing config, docs block, or core label. A marked relentless file is refreshed. A file without the marker stays as the repo wrote it."
