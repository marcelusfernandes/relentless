#!/usr/bin/env bash
# create-issue.sh — create issue; --label APPENDS to defaults (always keeps state:todo
# unless overridden by another state:*). Optionally link as a native GitHub sub-issue.
#
# Doctrine: every issue gets exactly one type label (bug|enhancement|documentation|
# investigation, or epic for parents). Work too big for one session/PR becomes an
# epic with sub-issues (judgment call — no complexity labels).
set -euo pipefail

REPO="" TITLE="" MILESTONE="" BODY_FILE="" PARENT="" TYPE=""
EXTRA_LABELS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BODY="${SCRIPT_DIR}/../templates/issue-body.md"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --repo OWNER/NAME --title TEXT [options]

  --milestone N|TITLE   Milestone number or exact title
  --body-file PATH      Default: core/templates/issue-body.md
  --label NAME          Repeatable; APPENDED to default state:todo
  --type NAME           bug|enhancement|documentation|investigation (or epic for parents)
  --parent N            After create, link as native sub-issue of parent #N
                        (REST sub_issues; inherits parent milestone if unset)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --milestone) MILESTONE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --label) EXTRA_LABELS+=("${2:-}"); shift 2 ;;
    --type) TYPE="${2:-}"; shift 2 ;;
    --parent) PARENT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$REPO" && -n "$TITLE" ]] || { usage; exit 2; }
BODY_FILE="${BODY_FILE:-$DEFAULT_BODY}"
[[ -f "$BODY_FILE" ]] || { echo "error: body file not found: $BODY_FILE" >&2; exit 1; }

if [[ -n "$TYPE" ]]; then
  case "$TYPE" in
    bug|enhancement|documentation|investigation|epic) EXTRA_LABELS+=("$TYPE") ;;
    *) echo "error: --type must be bug|enhancement|documentation|investigation|epic" >&2; exit 2 ;;
  esac
fi

has_state=0
for l in ${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"}; do
  [[ "$l" == state:* ]] && has_state=1
done
LABELS=()
if [[ "$has_state" -eq 0 ]]; then
  LABELS+=(state:todo)
fi
for l in ${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"}; do
  LABELS+=("$l")
done
UNIQUE_LABELS=()
while IFS= read -r l; do
  UNIQUE_LABELS+=("$l")
done < <(printf '%s\n' "${LABELS[@]}" | awk 'NF && !seen[$0]++')
LABELS=(${UNIQUE_LABELS[@]+"${UNIQUE_LABELS[@]}"})

MS_ARGS=()
if [[ -n "$MILESTONE" ]]; then
  MS_TITLE=""
  if [[ "$MILESTONE" =~ ^[0-9]+$ ]]; then
    MS_TITLE="$(gh api "repos/${REPO}/milestones/${MILESTONE}" --jq .title 2>/dev/null || true)"  # intentional fail-soft
    [[ -n "$MS_TITLE" ]] || { echo "error: milestone number $MILESTONE not found in $REPO" >&2; exit 1; }
    echo "milestone: #$MILESTONE → \"$MS_TITLE\""
  else
    MS_TITLE="$MILESTONE"
  fi
  MS_ARGS=(--milestone "$MS_TITLE")
fi

LABEL_ARGS=()
for l in "${LABELS[@]}"; do
  LABEL_ARGS+=(--label "$l")
done

URL="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" ${MS_ARGS[@]+"${MS_ARGS[@]}"} "${LABEL_ARGS[@]}")"
echo "$URL"

NUM="$(basename "$URL")"
if [[ -n "$PARENT" ]]; then
  [[ "$PARENT" =~ ^[0-9]+$ ]] || { echo "error: --parent must be an issue number" >&2; exit 2; }
  "${SCRIPT_DIR}/add-sub-issue.sh" --repo "$REPO" --parent "$PARENT" --child "$NUM"
fi
