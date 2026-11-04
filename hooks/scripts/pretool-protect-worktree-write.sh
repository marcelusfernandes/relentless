#!/usr/bin/env bash
# pretool-protect-worktree-write.sh — PreToolUse Edit|Write|MultiEdit|NotebookEdit
# When RELENTLESS_WORKTREE or .relentless/worktree.json or RELENTLESS_ROLE=implementer:
# deny writes whose path resolves outside the worktree root.
set -euo pipefail
INPUT="$(cat 2>/dev/null || true)"  # intentional: empty stdin ok
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # before the cd below
# shellcheck source=../../core/scripts/lib/common.sh
source "${HOOK_DIR}/../../core/scripts/lib/common.sh"

is_wt=0
[[ "${RELENTLESS_ROLE:-}" == "implementer" || -n "${RELENTLESS_WORKTREE:-}" ]] && is_wt=1
CWD=""
FILE=""
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"  # intentional fail-soft
  FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .file_path // empty' 2>/dev/null || true)"  # intentional fail-soft
fi
CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
cd "$CWD" 2>/dev/null || true  # intentional fail-soft

TOP=""
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  TOP="$(git rev-parse --show-toplevel)"
fi
if [[ -n "$TOP" && -f "$TOP/.relentless/worktree.json" ]]; then is_wt=1; fi

# layers.worktrees false: do nothing. Missing config keeps the check.
# No layers object keeps it (1.4.11). A config that does not parse fails
# closed: PreToolUse treats exit 1 as a non-blocking error, so this hook
# exits 2 and names the file. Scripts still exit 1.
wt_cfg=""
if [[ -n "$TOP" && -f "$TOP/.relentless/config.json" ]]; then
  wt_cfg="$TOP/.relentless/config.json"
elif [[ -f .relentless/config.json ]]; then
  wt_cfg="$(pwd)/.relentless/config.json"
fi
if [[ -n "$wt_cfg" ]]; then
  if ! wt_err="$(jq empty "$wt_cfg" 2>&1)"; then
    echo "error: ${wt_cfg} failed to parse: ${wt_err}" >&2
    exit 2
  fi
  if ! layer_enabled worktrees "$wt_cfg"; then
    exit 0
  fi
fi

[[ "$is_wt" -eq 0 ]] && exit 0
[[ -z "$FILE" ]] && exit 0
[[ -z "$TOP" ]] && TOP="${RELENTLESS_WORKTREE:-$CWD}"

# shellcheck source=../../core/scripts/lib/realpath.sh
source "${HOOK_DIR}/../../core/scripts/lib/realpath.sh"

# Resolve absolute path (best-effort, no symlink escape for v1)
case "$FILE" in
  /*) ABS="$FILE" ;;
  *) ABS="$(cd "$CWD" 2>/dev/null && realpath_m "$FILE" 2>/dev/null || echo "$CWD/$FILE")" ;;
esac
TOP_REAL="$(realpath_m "$TOP" 2>/dev/null || echo "$TOP")"

case "$ABS" in
  "$TOP_REAL"|"$TOP_REAL"/*) exit 0 ;;
  *)
    printf 'protect-worktree: BLOCKED — write path %s is outside worktree %s\n' "$ABS" "$TOP_REAL" >&2
    exit 2
    ;;
esac
