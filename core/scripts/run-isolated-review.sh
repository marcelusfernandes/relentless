#!/usr/bin/env bash
# run-isolated-review.sh — orchestrator helper: build bundle → spawn isolated reviewer
# (stdin, not argv) → parse verdict → apply-review-verdict → optional merge-if-ready.
#
# The orchestrator MUST call this (or equivalent nested spawn) itself — do NOT stop
# and wait for a human/driver to resume after state:review.
#
# Usage:
#   run-isolated-review.sh --repo OWNER/NAME --pr N --issue N \
#     [--harness claude|codex] [--workdir PATH] [--out-dir PATH] \
#     [--from-output PATH] [--also-merge] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="" PR="" ISSUE="" HARNESS="" WORKDIR="." OUT_DIR="" FROM_OUTPUT="" MERGE=0 DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --from-output) FROM_OUTPUT="${2:-}"; shift 2 ;;
    --also-merge) MERGE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | tr -d '#'
      exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" && -n "$ISSUE" ]] || { echo "need --repo --pr --issue" >&2; exit 2; }

# Last non-empty line must be exactly one of the two verdict forms.
# A quoted rule earlier in the review must not decide the verdict.
read_verdict_line() {
  local file="$1" line="" last=""
  if [[ ! -f "$file" ]]; then
    echo "error: missing verdict line (no reviewer output at ${file}). No labels changed." >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -n "$line" ]]; then
      last="$line"
    fi
  done <"$file"
  case "$last" in
    "Verdict: approved"|"Verdict: changes_requested")
      printf '%s\n' "${last#Verdict: }"
      return 0
      ;;
    "Verdict: <approved|changes_requested>")
      echo "error: refusing placeholder verdict line in ${file}: [${last}]" >&2
      echo "error: that example is not a verdict. The last non-empty line must be exactly 'Verdict: approved' or 'Verdict: changes_requested'. No labels changed." >&2
      return 1
      ;;
    "")
      echo "error: missing verdict line in ${file}. The last non-empty line must be exactly 'Verdict: approved' or 'Verdict: changes_requested'. No labels changed." >&2
      return 1
      ;;
    *)
      echo "error: malformed verdict line in ${file}: [${last}]" >&2
      echo "error: the last non-empty line must be exactly 'Verdict: approved' or 'Verdict: changes_requested'. No labels changed." >&2
      return 1
      ;;
  esac
}

apply_parsed_verdict() {
  local verdict="$1"
  echo "$verdict" >"$VERDICT_FILE"
  echo "verdict: $verdict"
  "${SCRIPT_DIR}/apply-review-verdict.sh" --repo "$REPO" --issue "$ISSUE" --pr "$PR" \
    --verdict "$verdict" --review-out "$VERDICT_RAW" --workdir "$WORKDIR"
  if [[ "$verdict" == "approved" && "$MERGE" -eq 1 ]]; then
    "${SCRIPT_DIR}/merge-if-ready.sh" --repo "$REPO" --pr "$PR" --issue "$ISSUE"
  fi
  echo "== isolated review done (verdict=$verdict) =="
}

OUT_DIR="${OUT_DIR:-${WORKDIR}/.relentless/review/${PR}}"
mkdir -p "$OUT_DIR"
BUNDLE="${OUT_DIR}/review-bundle.md"
VERDICT_RAW="${OUT_DIR}/reviewer-out.md"
VERDICT_FILE="${OUT_DIR}/verdict.txt"

if [[ -n "$FROM_OUTPUT" ]]; then
  [[ -f "$FROM_OUTPUT" ]] || { echo "error: --from-output file not found: $FROM_OUTPUT" >&2; exit 1; }
  cp "$FROM_OUTPUT" "$VERDICT_RAW"
  if ! verdict="$(read_verdict_line "$VERDICT_RAW")"; then
    exit 1
  fi
  apply_parsed_verdict "$verdict"
  exit 0
fi

# Infer harness from config or PATH
if [[ -z "$HARNESS" ]]; then
  if [[ -f "${WORKDIR}/.relentless/config.json" ]]; then
    HARNESS="$(jq -r '.harness // empty' "${WORKDIR}/.relentless/config.json" 2>/dev/null || true)"  # intentional fail-soft
  fi
fi
if [[ -z "$HARNESS" || "$HARNESS" == "both" ]]; then
  if command -v claude >/dev/null 2>&1; then HARNESS="claude"
  elif command -v codex >/dev/null 2>&1; then HARNESS="codex"
  else
    echo "error: set --harness claude|codex (neither claude nor codex on PATH)" >&2
    exit 1
  fi
fi

echo "== isolated review (harness=$HARNESS) PR #$PR issue #$ISSUE =="
echo "foreground: reviewer runs in this process until it exits; do not background it"

"${SCRIPT_DIR}/build-review-bundle.sh" --repo "$REPO" --pr "$PR" --issue "$ISSUE" --out "$BUNDLE"
echo "bundle: $BUNDLE ($(wc -c <"$BUNDLE") bytes)"

PROMPT_FILE="${OUT_DIR}/reviewer-prompt.md"
{
  echo "You are the Relentless isolated reviewer. Read-only."
  echo "The last line of your output must be exactly \`Verdict: approved\` or \`Verdict: changes_requested\`."
  echo "Do not edit files, push, or merge. Prefer not re-running full CI."
  echo ""
  cat "$BUNDLE"
} > "$PROMPT_FILE"

if [[ "$DRY" -eq 1 ]]; then
  echo "dry-run: would spawn $HARNESS reviewer with stdin from $PROMPT_FILE"
  echo "dry-run: would export RELENTLESS_ROLE=reviewer CLAUDE_AGENT=reviewer"
  echo "dry-run: then apply-review-verdict + $([ "$MERGE" -eq 1 ] && echo merge-if-ready || echo 'no merge step')"
  exit 0
fi

# Isolation hooks (pretool-reviewer-isolation.sh, pretool-gh-workflow.sh) read
# these names. Export before every spawn so the reviewer process, its Claude
# fallback, the Codex spawn, and anything the reviewer itself spawns inherit them.
export RELENTLESS_ROLE=reviewer
export CLAUDE_AGENT=reviewer

# Pass bundle via stdin/file — NEVER "$(cat bundle)" as argv (fails on large diffs).
# Claude reviewer gh is read-only: view/diff/checks/issue view and GET api.
# No comment, edit, merge, label, review, or api -X POST|PATCH|DELETE.
REVIEWER_ALLOWED_TOOLS="Read,Grep,Glob,Bash(gh pr view *),Bash(gh pr diff *),Bash(gh pr checks *),Bash(gh issue view *),Bash(gh api --method GET *),Bash(gh api -X GET *)"
case "$HARNESS" in
  claude)
    # stream-json requires --verbose on Claude Code 2.1.x+
    claude -p \
      --agent relentless:reviewer \
      --allowedTools "$REVIEWER_ALLOWED_TOOLS" \
      --verbose \
      --output-format stream-json \
      < "$PROMPT_FILE" \
      > "${OUT_DIR}/reviewer.stream.jsonl" 2>"${OUT_DIR}/reviewer.stderr.log" || true  # intentional fail-soft
    # Extract last assistant text if stream-json; else fall back to raw
    if [[ -s "${OUT_DIR}/reviewer.stream.jsonl" ]]; then
      jq -r 'select(.type=="assistant" or .message.content) | .message.content[]? // . | select(.type=="text")? // empty | .text // empty' \
        "${OUT_DIR}/reviewer.stream.jsonl" 2>/dev/null | tail -n +1 > "$VERDICT_RAW" || true  # intentional fail-soft
      if [[ ! -s "$VERDICT_RAW" ]]; then
        # Alternate stream shape: result field
        jq -r 'select(.type=="result") | .result // empty' "${OUT_DIR}/reviewer.stream.jsonl" 2>/dev/null > "$VERDICT_RAW" || true  # intentional fail-soft
      fi
    fi
    if [[ ! -s "$VERDICT_RAW" ]]; then
      # Non-stream fallback
      claude -p --agent relentless:reviewer --allowedTools "$REVIEWER_ALLOWED_TOOLS" \
        < "$PROMPT_FILE" > "$VERDICT_RAW" 2>>"${OUT_DIR}/reviewer.stderr.log" || true  # intentional fail-soft
    fi
    ;;
  codex)
    # Prefer Write/apply_patch inside nested sessions; avoid huge shell heredocs (Codex classifier false positives).
    codex exec \
      --sandbox read-only \
      -C "$WORKDIR" \
      < "$PROMPT_FILE" \
      > "$VERDICT_RAW" 2>"${OUT_DIR}/reviewer.stderr.log" || true  # intentional fail-soft
    ;;
  *)
    echo "error: unknown harness $HARNESS" >&2; exit 2 ;;
esac

if ! VERDICT="$(read_verdict_line "$VERDICT_RAW")"; then
  echo "---- reviewer output (tail) ----" >&2
  tail -40 "$VERDICT_RAW" >&2 || true  # intentional fail-soft: show context after a parse failure
  exit 1
fi
apply_parsed_verdict "$VERDICT"
