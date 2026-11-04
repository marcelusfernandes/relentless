#!/usr/bin/env bash
# Shared helpers for Relentless core scripts.
# shellcheck source=lib/common.sh

die() { echo "error: $*" >&2; exit 1; }

STATE_LABELS=(state:todo state:in-progress state:blocked state:review state:done)

resolve_config() {
  local cfg="${1:-}"
  if [[ -n "$cfg" && -f "$cfg" ]]; then
    (cd "$(dirname "$cfg")" && echo "$(pwd)/$(basename "$cfg")")
    return 0
  fi
  if [[ -n "$cfg" && "$cfg" != /* && -n "${WORKDIR:-}" && -f "${WORKDIR}/${cfg}" ]]; then
    echo "${WORKDIR}/${cfg}"
    return 0
  fi
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"  # intentional fail-soft
  if [[ -n "$root" && -f "${root}/.relentless/config.json" ]]; then
    echo "${root}/.relentless/config.json"
    return 0
  fi
  if [[ -f ".relentless/config.json" ]]; then
    echo "$(pwd)/.relentless/config.json"
    return 0
  fi
  echo ""
  return 1
}

# Plugin root (install cache or checkout). Prefer RELENTLESS_ROOT, else this script tree.
relentless_root() {
  if [[ -n "${RELENTLESS_ROOT:-}" && -d "${RELENTLESS_ROOT}" ]]; then
    echo "$RELENTLESS_ROOT"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$here"
}

# set_issue_state REPO ISSUE state:NAME [quiet=0]
# One GET + one PATCH; preserves non-state labels; never stacks state:*.
set_issue_state() {
  local repo="$1"
  local issue="$2"
  local target="$3"
  local quiet="${4:-0}"
  local current new_json
  current="$(gh api "repos/${repo}/issues/${issue}" --jq '[.labels[].name]' 2>/dev/null || echo '[]')"
  new_json="$(jq -c --arg t "$target" --argjson states "$(printf '%s\n' "${STATE_LABELS[@]}" | jq -R . | jq -s .)" '
    ([.[] | select(. as $l | $states | index($l) | not)] + [$t]) | unique
  ' <<<"$current")"
  # Build -f labels[]= args
  local args=(-X PATCH "repos/${repo}/issues/${issue}")
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    args+=(-f "labels[]=${name}")
  done < <(jq -r '.[]' <<<"$new_json")
  if [[ "$quiet" -eq 1 ]]; then
    gh api "${args[@]}" >/dev/null
  else
    gh api "${args[@]}" --jq '"\(.html_url) → labels updated"' >/dev/null
    echo "${repo}#${issue} → ${target}"
  fi
}

check_gh_workflow_scope() {
  local status scopes
  status="$(gh auth status 2>&1 || true)"  # intentional fail-soft
  if echo "$status" | grep -qiE "Token scopes:.*['\"]workflow['\"]|scopes:.*workflow"; then
    echo "gh scopes: workflow present"
    return 0
  fi
  scopes="$(gh api -i -X GET /user 2>&1 | grep -i '^x-oauth-scopes:' || true)"  # intentional fail-soft
  if echo "$scopes" | grep -qw workflow; then
    echo "gh scopes: workflow present"
    return 0
  fi
  echo "error: GitHub token is missing the 'workflow' scope." >&2
  echo "  Relentless cannot push .github/workflows/*.yml without it." >&2
  echo "  Fix: gh auth refresh -s workflow" >&2
  return 1
}

# resolve_merge_mode REPO ISSUE CONFIG → prints auto|human
# allow_issue_override false: ignore merge:* labels and use merge.default.
# true (or omitted): a merge:* label on the issue wins. merge:human beats merge:auto.
resolve_merge_mode() {
  local repo="$1" issue="$2" config="${3:-}"
  local allow="true" labels
  if [[ -n "$config" && -f "$config" ]]; then
    # `//` treats JSON false as empty, so a boolean false must be read with has().
    allow="$(jq -r 'if (.merge | type) == "object" and (.merge | has("allow_issue_override")) then (.merge.allow_issue_override | tostring) else "true" end' "$config")"
  fi
  if [[ "$allow" != "false" ]]; then
    labels="$(gh api "repos/${repo}/issues/${issue}" --jq '[.labels[].name] | join("\n")' 2>/dev/null || true)"  # intentional fail-soft
    if echo "$labels" | grep -Fxq "merge:human"; then
      echo "human"; return 0
    fi
    if echo "$labels" | grep -Fxq "merge:auto"; then
      echo "auto"; return 0
    fi
  fi
  if [[ -n "$config" && -f "$config" ]]; then
    jq -r '.merge.default // "human"' "$config"
    return 0
  fi
  echo "human"
}

# Exit 1 when the file exists and is not JSON. A missing file returns 0.
# The error names the file. Callers must not treat a broken file as layers-off
# or as "no base".
require_parsed_config() {
  local cfg="${1:-}" err
  [[ -n "$cfg" && -f "$cfg" ]] || return 0
  if ! err="$(jq empty "$cfg" 2>&1)"; then
    echo "error: ${cfg} failed to parse: ${err}" >&2
    exit 1
  fi
}

# 0 when the layer is on.
# Missing file → off (return 1). Callers that keep the pre-layer behavior when
# the file is absent must not call this.
# No `layers` object → on. That is an install from before layers (1.4.11),
# including githooks.
# Inside `layers`, only JSON true is on. Invalid JSON exits 1 via require_parsed_config.
layer_enabled() {
  local name="$1" cfg="${2:-}" has val
  if [[ -z "$cfg" || ! -f "$cfg" ]]; then
    return 1
  fi
  require_parsed_config "$cfg"
  has="$(jq -r 'has("layers")' "$cfg")"
  if [[ "$has" != "true" ]]; then
    return 0
  fi
  val="$(jq -r --arg n "$name" 'if (.layers | type) == "object" and (.layers | has($n)) then (.layers[$n] | tostring) else "false" end' "$cfg")"
  [[ "$val" == "true" ]]
}
