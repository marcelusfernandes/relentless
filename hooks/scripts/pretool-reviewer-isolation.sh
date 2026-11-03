#!/usr/bin/env bash
# PreToolUse: block an implementer from applying review:approved / apply-review-verdict / merge-if-ready.
# The signal that reaches this process is .relentless/worktree.json at the git toplevel
# (this process cwd, or the payload cwd). Role env vars are an extra signal.
# A named other role stays on its own path. Claude/Codex: exit 2 = block.
#
# Avoid false positives on docs/heredocs that merely *mention* approval or merge:
# strip heredoc bodies before matching, and require command-like patterns.
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../core/scripts/lib/common.sh
source "${HOOK_DIR}/../../core/scripts/lib/common.sh"

INPUT="$(cat || true)"  # intentional: empty stdin ok
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)"  # intentional fail-soft
[[ -n "$CMD" ]] || exit 0

# Strip heredoc bodies so prose inside cat >file <<'EOF' … EOF does not match.
strip_heredocs() {
  awk '
    BEGIN { in_h=0; tag="" }
    {
      if (in_h) {
        close_re = "^[[:space:]]*" tag "[[:space:]]*$"
        if ($0 ~ close_re) { in_h=0; tag=""; next }
        next
      }
      if ($0 ~ /<<[-]?[[:space:]]*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/) {
        line = $0
        sub(/^.*<<[-]?[[:space:]]*/, "", line)
        gsub(/['\''"]/, "", line)
        split(line, a, /[^A-Za-z0-9_]/)
        tag = a[1]
        if (tag != "") {
          in_h = 1
          keep = $0
          sub(/<<.*/, "", keep)
          if (keep ~ /[^[:space:]]/) print keep
          next
        }
      }
      print
    }
  '
}

CMD_SCAN="$(printf '%s\n' "$CMD" | strip_heredocs)"

# Drop quoted regions so a message that only mentions gh api is not an invocation.
strip_quoted_regions() {
  local s="$1"
  local i=0 len=${#s} quote="" out="" c
  while [[ $i -lt $len ]]; do
    c="${s:i:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$c" == "$quote" ]]; then quote=""; fi
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == "'" || "$c" == '"' ]]; then
      quote="$c"
      i=$((i + 1))
      continue
    fi
    out+="$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# 0 when this gh api argv has more than one method flag or any --input.
# -X / --method count once each, including -XPOST and --method=POST.
# One explicit GET plus -f/-F is not denied here.
gh_api_args_denied() {
  local method=0 token next
  while [[ $# -gt 0 ]]; do
    token="$1"
    shift
    [[ "$token" == "--" ]] && break
    if [[ "$token" == "--input" || "$token" == --input=* ]]; then
      return 0
    fi
    if [[ "$token" == "-X" || "$token" == "--method" ]]; then
      method=$((method + 1))
      if [[ $# -gt 0 ]]; then
        next="$1"
        if [[ "$next" != -* ]]; then
          shift
        fi
      fi
      continue
    fi
    if [[ "$token" == -X?* || "$token" == --method=* ]]; then
      method=$((method + 1))
      continue
    fi
  done
  [[ "$method" -gt 1 ]]
}

# 0 when any gh api invocation in the command is denied.
reviewer_gh_api_unsafe() {
  local scan line base i j n
  local -a words args
  scan="$(strip_quoted_regions "$CMD_SCAN")"
  scan="${scan//||/$'\n'}"
  scan="${scan//&&/$'\n'}"
  scan="${scan//;/$'\n'}"
  scan="${scan//|/$'\n'}"
  scan="${scan//&/$'\n'}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    words=()
    read -r -a words <<< "$line" || true  # intentional: empty segment
    n=${#words[@]}
    i=0
    while [[ $i -lt $n ]]; do
      base="${words[$i]##*/}"
      if [[ "$base" == "gh" && $((i + 1)) -lt $n && "${words[$((i + 1))]}" == "api" ]]; then
        args=()
        j=$((i + 2))
        while [[ $j -lt $n ]]; do
          args+=("${words[$j]}")
          j=$((j + 1))
        done
        if [[ ${#args[@]} -gt 0 ]] && gh_api_args_denied "${args[@]}"; then
          return 0
        fi
      fi
      i=$((i + 1))
    done
  done <<< "$scan"
  return 1
}

ROLE="${RELENTLESS_ROLE:-${CODEX_THREAD_ROLE:-}}"
AGENT="${CLAUDE_AGENT:-${AGENT_NAME:-}}"

# worktree-create writes this marker. The harness does not export a role into
# the hook process, so an untracked marker is the signal that reaches the hook.
# A tracked marker is on every checkout of that commit, including main, so it
# is not a role signal. protect-worktree-write still treats a present file as
# a worktree for path confinement; that check is not this role check.
worktree_marker_at() {
  local dir="$1" top=""
  [[ -n "$dir" && -d "$dir" ]] || return 1
  if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    top="$(git -C "$dir" rev-parse --show-toplevel)"
  else
    return 1
  fi
  [[ -f "$top/.relentless/worktree.json" ]] || return 1
  if git -C "$top" ls-files --error-unmatch .relentless/worktree.json >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

in_implementer_worktree() {
  local pcwd=""
  if worktree_marker_at "$(pwd)"; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1 && [[ -n "${INPUT:-}" ]]; then
    pcwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"  # intentional fail-soft
  fi
  if [[ -n "$pcwd" ]] && worktree_marker_at "$pcwd"; then
    return 0
  fi
  return 1
}

# Env role is an extra signal. A named other role (orchestrator, reviewer)
# is not an implementer, even inside a worktree. No role plus the marker is.
is_implementer=0
other_role=0
case "$ROLE" in
  reviewer|orchestrator|qa|planner|documenter) other_role=1 ;;
esac
case "$AGENT" in
  reviewer|orchestrator|qa|planner|documenter|*:reviewer|*:orchestrator|*:qa|*:planner|*:documenter) other_role=1 ;;
esac
if [[ "$ROLE" == "implementer" ]] || [[ "$AGENT" == *"implementer"* ]]; then
  is_implementer=1
elif [[ "$other_role" -eq 0 ]] && in_implementer_worktree; then
  is_implementer=1
fi

# Label/verdict application (not merge-if-ready — orchestrator must run that)
looks_like_review_label() {
  echo "$CMD_SCAN" | grep -qE '(^|[[:space:];|&])(\./|[^[:space:]]*/)?apply-review-verdict\.sh([[:space:]]|$)' \
    || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+(label[[:space:]]+(add|create|edit)|issue[[:space:]]+edit|pr[[:space:]]+edit)[^|;]*review:approved' \
    || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+api[[:space:]][^|;]*review:approved'
}

looks_like_merge_if_ready() {
  echo "$CMD_SCAN" | grep -qE '(^|[[:space:];|&])(\./|[^[:space:]]*/)?merge-if-ready\.sh([[:space:]]|$)'
}

looks_like_push_or_pr_merge() {
  echo "$CMD_SCAN" | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)' \
    || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+pr[[:space:]]+(create|merge)([[:space:]]|$)'
}

if [[ "$is_implementer" -eq 1 ]]; then
  if looks_like_review_label || looks_like_merge_if_ready || looks_like_push_or_pr_merge; then
    # Allow git push during implement (needed); only block review + merge-if-ready + gh pr merge
    if looks_like_review_label || looks_like_merge_if_ready || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
      echo "[relentless] BLOCKED: implementer role must stop at state:review. Do not apply review labels or merge. Orchestrator spawns isolated reviewer." >&2
      exit 2
    fi
  fi
  exit 0
fi

# Reviewer-side checks follow layers.review. The implementer block above does not.
# Missing config keeps the checks (they were always on before layers).
# No layers object keeps them on (1.4.11). A config that does not parse fails
# closed: PreToolUse treats exit 1 as a non-blocking error, so this hook
# exits 2 and names the file. Scripts still exit 1.
review_layer_active() {
  local top cfg err
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"  # intentional fail-soft: not every cwd is a checkout
  cfg=""
  if [[ -n "$top" && -f "${top}/.relentless/config.json" ]]; then
    cfg="${top}/.relentless/config.json"
  elif [[ -f .relentless/config.json ]]; then
    cfg="$(pwd)/.relentless/config.json"
  else
    return 0
  fi
  if ! err="$(jq empty "$cfg" 2>&1)"; then
    echo "error: ${cfg} failed to parse: ${err}" >&2
    exit 2
  fi
  layer_enabled review "$cfg"
}

# Reviewer only. The gh allowlist star matches the rest of the command, so a
# second method flag or --input still looks like an allowed GET. Deny those here.
# One -X/--method, including with -f/-F, stays allowed. Other roles are unchanged.
is_reviewer=0
if [[ "$ROLE" == "reviewer" || "$AGENT" == "reviewer" || "$AGENT" == *":reviewer" ]]; then
  is_reviewer=1
fi
if [[ "$is_reviewer" -eq 1 ]] && review_layer_active && reviewer_gh_api_unsafe; then
  echo "[relentless] BLOCKED: reviewer gh api may use one -X/--method and must not pass --input." >&2
  exit 2
fi

# Non-implementer heuristic: applying review:approved AND pushing/merging in one bash
# (self-review in same session). Orchestrator-only merge-if-ready is allowed.
if looks_like_review_label && looks_like_push_or_pr_merge; then
  echo "[relentless] BLOCKED: do not self-review and push/merge in the same session. Stop at state:review; orchestrator spawns isolated reviewer then merge-if-ready." >&2
  exit 2
fi

exit 0
