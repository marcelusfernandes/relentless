#!/usr/bin/env bash
# M3 — a disabled layer does not act. One case per layer.
# With that layer false, its hooks exit 0, its scripts are not called, and the
# core briefs (orchestrator and implementer, md and toml) do not contain its
# sentences. The nucleus still runs (create-issue.sh).
#
# Config key: the cut names the layers and leaves the JSON path open.
# This suite uses .relentless/config.json "layers": { "<name>": false }.
# Names: merge, review, qa, worktrees, decisions, templates, ci, githooks, docs.
# Nested under "layers" because top-level "merge" is already the merge policy.
#
# Expected red on v1.4.11. Later minimal-cut PRs turn it green.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

BOOT="$ROOT/core/scripts/bootstrap.sh"
mkdir -p "$TMP/bin" "$TMP/corebin"
printf '%s\n' 'body' >"$TMP/body"

cat >"$TMP/corebin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
echo "https://github.com/acme/consumer/issues/3"
EOF
chmod +x "$TMP/corebin/gh"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
if [[ "$1" == "auth" ]]; then
  echo "Token scopes: 'repo', 'workflow'"
  exit 0
fi
if [[ "$1" == "repo" ]]; then
  if [[ "$*" == *"isEmpty"* ]]; then
    echo false
    exit 0
  fi
  if [[ "$*" == *"defaultBranchRef"* ]]; then
    echo develop
    exit 0
  fi
  exit 0
fi
if [[ "$1" == "label" && "$2" == "list" ]]; then
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo ada
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

# Codex files that belong to a layer. Nucleus agents (orchestrator, implementer,
# planner) and .codex/config.toml are not a layer's seed.
# review → reviewer.toml, qa → qa.toml, docs → documenter.toml.
layer_codex_files() { # layer
  case "$1" in
    review) printf '%s\n' .codex/agents/reviewer.toml ;;
    qa) printf '%s\n' .codex/agents/qa.toml ;;
    docs) printf '%s\n' .codex/agents/documenter.toml ;;
  esac
}

# Briefs the nucleus always loads. Layer files are not part of this text when
# that layer is off (agents/layers/<name>.md is read only while the layer is on).
brief_hits() { # phrase
  local phrase="$1" f
  for f in "$ROOT/agents/orchestrator.md" "$ROOT/agents/implementer.md" \
    "$ROOT/.codex/agents/orchestrator.toml" "$ROOT/.codex/agents/implementer.toml"; do
    if grep -qF -- "$phrase" "$f"; then
      printf '%s\n' "$phrase"
      return 0
    fi
  done
  return 1
}

assert_briefs_clean() { # layer phrase...
  local layer="$1" phrase hit=""
  shift
  for phrase in "$@"; do
    if brief_hits "$phrase" >/dev/null; then
      hit="${hit} ${phrase}"
    fi
  done
  if [[ -n "$hit" ]]; then
    bad "M3 ${layer}: core brief still has layer sentences while layers.${layer} is false:${hit}"
  else
    ok
  fi
}

core_still_runs() { # layer
  local layer="$1" out rc log got
  got="$(PATH="$TMP/corebin:$PATH" command -v gh 2>/dev/null || true)"
  if [[ "$got" != "$TMP/corebin/gh" ]]; then
    bad "M3 ${layer}: gh on PATH is '${got:-missing}', not stub $TMP/corebin/gh; refusing to call gh"
    return
  fi
  : >"$TMP/gh-core.log"
  out="$(PATH="$TMP/corebin:$PATH" GH_LOG="$TMP/gh-core.log" \
    bash "$ROOT/core/scripts/create-issue.sh" --repo acme/consumer --title t --body-file "$TMP/body" 2>&1)"
  rc=$?
  log="$(cat "$TMP/gh-core.log")"
  if [[ "$rc" -eq 0 && "$log" == *"issue create"* ]]; then
    ok
  else
    bad "M3 ${layer}: core create-issue.sh failed while the layer is off (rc=$rc): $out"
  fi
}

write_config() { # repo layer-to-disable
  local repo="$1" off="$2"
  mkdir -p "$repo/.relentless"
  jq -n --arg off "$off" '{
    decider: {name: "Ada", github: "ada"},
    merge: {default: "human", allow_issue_override: false},
    workers: {default: {github: "ada"}},
    layers: {
      merge: true, review: true, qa: true, worktrees: true,
      decisions: true, templates: true, ci: true, githooks: true, docs: true
    }
  } | .layers[$off] = false' >"$repo/.relentless/config.json"
  if [[ "$(jq -r --arg off "$off" '.layers[$off]' "$repo/.relentless/config.json")" != "false" ]]; then
    bad "M3 ${off}: config layers.${off} was not false"
  else
    ok
  fi
}

fresh_repo() { # dir branch
  local repo="$1" branch="$2"
  rm -rf "$repo"
  mkdir -p "$repo/.github/ISSUE_TEMPLATE"
  git -C "$repo" init -q -b "$branch"
  printf '%s\n' '{"scripts":{"test":"vitest"}}' >"$repo/package.json"
  printf '%s\n' 'name: Consumer bug' >"$repo/.github/ISSUE_TEMPLATE/bug.yml"
}

# bash -x writes the trace to stderr. bash 3.2 has no BASH_XTRACEFD, so the
# trace file is the only copy of bootstrap's stderr.
boot_err() {
  tail -n 12 "$TMP/boot.trace" 2>/dev/null | tr '\n' ' '
}

run_boot() { # repo  (stdout in $TMP/boot.out, stderr+trace in $TMP/boot.trace, rc in BOOT_RC)
  local repo="$1" got
  : >"$TMP/gh.log"
  : >"$TMP/boot.out"
  : >"$TMP/boot.trace"
  got="$(PATH="$TMP/bin:$PATH" command -v gh 2>/dev/null || true)"
  if [[ "$got" != "$TMP/bin/gh" ]]; then
    printf '%s\n' "guard: gh on PATH is '${got:-missing}', not ${TMP}/bin/gh" >"$TMP/boot.trace"
    BOOT_RC=99
    return 0
  fi
  PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" \
    bash -x "$BOOT" --repo acme/consumer --workdir "$repo" \
      --merge-default human --decider Ada --decider-github ada \
      --harness both --no-init-empty --apply \
      >"$TMP/boot.out" 2>"$TMP/boot.trace"
  BOOT_RC=$?
}

assert_layer_codex_absent() { # repo layer
  local repo="$1" layer="$2" path hit=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ -e "$repo/$path" ]]; then
      hit="${hit} ${path}"
    fi
  done <<LIST
$(layer_codex_files "$layer")
LIST
  if [[ -n "$hit" ]]; then
    bad "M3 ${layer}: bootstrap seeded layer files under .codex while layers.${layer} is false:${hit}"
  else
    ok
  fi
}

# Returns 1 when bootstrap itself failed. The caller skips layer file checks.
boot_layer() { # repo layer
  run_boot "$1"
  if [[ "$BOOT_RC" -ne 0 ]]; then
    bad "M3 $2: bootstrap exited $BOOT_RC before the layer check: $(boot_err)"
    return 1
  fi
  assert_layer_codex_absent "$1" "$2"
  return 0
}

# --- merge: no hook. Scripts and sentences must be absent. ---
layer_merge() {
  local repo="$TMP/merge-repo"
  fresh_repo "$repo" develop
  write_config "$repo" merge
  core_still_runs merge
  ok
  boot_layer "$repo" merge
  assert_briefs_clean merge \
    'merge-if-ready' 'wait-ci' 'pin approval to SHA' 'merge:auto' 'CI red log' 'exits non-zero'
}

# --- review: implementer half of pretool-reviewer-isolation must not block. ---
layer_review() {
  local repo="$TMP/review-repo" rc payload
  fresh_repo "$repo" develop
  write_config "$repo" review
  core_still_runs review
  boot_layer "$repo" review
  payload="$(jq -n --arg c 'core/scripts/apply-review-verdict.sh --pr 3 --verdict approved' '{tool_input:{command:$c}}')"
  rc="$(cd "$repo" && printf '%s' "$payload" | env RELENTLESS_ROLE=implementer \
    bash "$ROOT/hooks/scripts/pretool-reviewer-isolation.sh" >/dev/null 2>&1; echo $?)"
  if [[ "$rc" -eq 0 ]]; then
    ok
  else
    bad "M3 review: pretool-reviewer-isolation.sh exited ${rc} for an implementer apply-review-verdict while layers.review is false; a disabled layer hook must exit 0"
  fi
  assert_briefs_clean review 'apply-review-verdict' 'run-isolated-review' 'round 2'
}

# --- qa: no hook. fill-qa-section is not in the core brief. ---
layer_qa() {
  local repo="$TMP/qa-repo"
  fresh_repo "$repo" develop
  write_config "$repo" qa
  core_still_runs qa
  ok
  boot_layer "$repo" qa
  assert_briefs_clean qa 'fill-qa-section' 'Spawn qa'
}

# --- worktrees: protect-worktree hook must not block; worktree-create is not called from the brief. ---
layer_worktrees() {
  local repo="$TMP/wt-repo" rc payload
  fresh_repo "$repo" develop
  git -C "$repo" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
  write_config "$repo" worktrees
  core_still_runs worktrees
  boot_layer "$repo" worktrees
  payload="$(jq -n --arg cwd "$repo" --arg f "$TMP/outside.txt" '{cwd:$cwd, tool_input:{file_path:$f}}')"
  rc="$(cd "$repo" && printf '%s' "$payload" | env RELENTLESS_ROLE=implementer \
    bash "$ROOT/hooks/scripts/pretool-protect-worktree-write.sh" >/dev/null 2>&1; echo $?)"
  if [[ "$rc" -eq 0 ]]; then
    ok
  else
    bad "M3 worktrees: pretool-protect-worktree-write.sh exited ${rc} for a write outside the worktree while layers.worktrees is false; a disabled layer hook must exit 0"
  fi
  assert_briefs_clean worktrees 'One writer per worktree' 'worktree-create'
}

# --- decisions: bootstrap must not seed docs/decisions; brief must not carry ADR sentences. ---
layer_decisions() {
  local repo="$TMP/dec-repo" seeded=""
  fresh_repo "$repo" develop
  write_config "$repo" decisions
  core_still_runs decisions
  if boot_layer "$repo" decisions; then
  if [[ -e "$repo/docs/decisions/README.md" || -e "$repo/docs/decisions/log.jsonl" || -e "$repo/docs/decisions/adr/TEMPLATE.md" ]]; then
    [[ -e "$repo/docs/decisions/README.md" ]] && seeded="${seeded} docs/decisions/README.md"
    [[ -e "$repo/docs/decisions/log.jsonl" ]] && seeded="${seeded} docs/decisions/log.jsonl"
    [[ -e "$repo/docs/decisions/adr/TEMPLATE.md" ]] && seeded="${seeded} docs/decisions/adr/TEMPLATE.md"
    bad "M3 decisions: new-adr templates were seeded while layers.decisions is false:${seeded}"
  else
    ok
  fi
  fi
  assert_briefs_clean decisions 'new-adr' 'log.jsonl' '## Decision'
}

# --- templates: no brief sentences. Bootstrap must not seed issue or PR forms. ---
layer_templates() {
  local repo="$TMP/tpl-repo" seeded=""
  fresh_repo "$repo" develop
  write_config "$repo" templates
  core_still_runs templates
  ok
  if boot_layer "$repo" templates; then
    [[ -e "$repo/.github/ISSUE_TEMPLATE/investigation.yml" ]] && seeded="${seeded} investigation.yml"
    [[ -e "$repo/.github/ISSUE_TEMPLATE/epic.yml" ]] && seeded="${seeded} epic.yml"
    [[ -e "$repo/.github/ISSUE_TEMPLATE/relentless.yml" ]] && seeded="${seeded} relentless.yml"
    [[ -e "$repo/.github/PULL_REQUEST_TEMPLATE.md" ]] && seeded="${seeded} PULL_REQUEST_TEMPLATE.md"
    if [[ -n "$seeded" ]]; then
      bad "M3 templates: bootstrap seeded issue or PR templates while layers.templates is false:${seeded}"
    else
      ok
    fi
    if [[ -f "$repo/.github/ISSUE_TEMPLATE/bug.yml" ]]; then
      ok
    else
      bad "M3 templates: consumer bug.yml disappeared while layers.templates is false"
    fi
  fi
}

# --- ci: detect-stack and render-ci must not run. No brief sentences. ---
layer_ci() {
  local repo="$TMP/ci-repo"
  fresh_repo "$repo" develop
  write_config "$repo" ci
  core_still_runs ci
  ok
  if boot_layer "$repo" ci; then
  if grep -E 'detect-stack\.sh|render-ci\.sh' "$TMP/boot.trace" >/dev/null; then
    bad "M3 ci: detect-stack.sh or render-ci.sh ran while layers.ci is false: $(grep -E 'detect-stack\.sh|render-ci\.sh' "$TMP/boot.trace" | head -n 1)"
  else
    ok
  fi
  if [[ -e "$repo/.github/workflows/relentless-ci.yml" ]]; then
    bad "M3 ci: render-ci wrote .github/workflows/relentless-ci.yml while layers.ci is false"
  else
    ok
  fi
  fi
}

# --- githooks: install must not run; pre-commit and pre-push exit 0. Off by default in the cut. ---
layer_githooks() {
  local repo="$TMP/ghk-repo" rc
  fresh_repo "$repo" main
  git -C "$repo" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
  write_config "$repo" githooks
  core_still_runs githooks
  if boot_layer "$repo" githooks; then
  if [[ -e "$repo/.relentless/githooks/pre-commit" || -e "$repo/.relentless/githooks/pre-push" ]]; then
    bad "M3 githooks: install-githooks.sh wrote .relentless/githooks while layers.githooks is false"
  else
    ok
  fi
  fi
  rc="$(cd "$repo" && bash "$ROOT/core/templates/githooks/pre-commit" </dev/null >/dev/null 2>&1; echo $?)"
  if [[ "$rc" -eq 0 ]]; then
    ok
  else
    bad "M3 githooks: pre-commit exited ${rc} on main while layers.githooks is false; a disabled layer hook must exit 0"
  fi
  rc="$(cd "$repo" && printf '%s\n' 'abc abc refs/heads/main def' | bash "$ROOT/core/templates/githooks/pre-push" >/dev/null 2>&1; echo $?)"
  if [[ "$rc" -eq 0 ]]; then
    ok
  else
    bad "M3 githooks: pre-push exited ${rc} for refs/heads/main while layers.githooks is false; a disabled layer hook must exit 0"
  fi
}

# --- docs: no hook. write-status-snapshot is not in the core brief. ---
layer_docs() {
  local repo="$TMP/docs-repo"
  fresh_repo "$repo" develop
  write_config "$repo" docs
  core_still_runs docs
  ok
  boot_layer "$repo" docs
  assert_briefs_clean docs 'write-status-snapshot' 'documenter'
}

layer_merge
layer_review
layer_qa
layer_worktrees
layer_decisions
layer_templates
layer_ci
layer_githooks
layer_docs

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
