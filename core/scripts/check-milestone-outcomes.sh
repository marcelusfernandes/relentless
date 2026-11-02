#!/usr/bin/env bash
# check-milestone-outcomes.sh — milestone product-outcome + epic/sub-issue guards.
#
# Fails when:
#   - open milestone description lacks a Product outcome section
#   - open milestone has open human:pending issues (unless --allow-pending)
#   - open milestone has no open (or any) issue labeled epic
#   - open milestone has issues that are neither the epic parent, nor a native
#     sub-issue of that epic, nor labeled orphan:ok
#
# Usage: check-milestone-outcomes.sh --repo OWNER/NAME [--milestone N|TITLE] [--allow-pending]
set -euo pipefail

REPO=""
FILTER=""
ALLOW_PENDING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --milestone) FILTER="${2:-}"; shift 2 ;;
    --allow-pending) ALLOW_PENDING=1; shift ;;
    *) shift ;;
  esac
done
[[ -n "$REPO" ]] || { echo "need --repo"; exit 2; }

DRIFT=0
PENDING_BLOCK=0
EPIC_BLOCK=0
ORPHAN_BLOCK=0

# Return 0 if CHILD_NUM is listed under PARENT_NUM's sub_issues
is_sub_issue_of() {
  local parent="$1" child="$2"
  # child is digit-validated by callers / issue numbers from API
  local found
  found="$(gh api "repos/${REPO}/issues/${parent}/sub_issues?per_page=100"     --jq "any(.[]; .number == ${child})" 2>/dev/null || echo false)"
  [[ "$found" == "true" ]]
}

while IFS= read -r row; do
  number="$(jq -r '.number' <<<"$row")"
  title="$(jq -r '.title' <<<"$row")"
  desc="$(jq -r '.description // ""' <<<"$row")"

  if [[ -n "$FILTER" ]]; then
    if [[ "$FILTER" =~ ^[0-9]+$ ]]; then
      [[ "$number" == "$FILTER" ]] || continue
    else
      [[ "$title" == "$FILTER" ]] || continue
    fi
  fi

  if ! grep -qiE 'product outcome|## outcome' <<<"$desc"; then
    echo "DRIFT: milestone \"$title\" (#$number) missing Product outcome section"
    DRIFT=1
  else
    echo "ok: $title (#$number) outcome section"
  fi

  pending="$(gh issue list --repo "$REPO" --milestone "$title" --state open --label "human:pending" --json number,title -q '.[] | "#\(.number) \(.title)"' 2>/dev/null || true)"  # intentional fail-soft
  if [[ -n "$pending" ]]; then
    echo "PENDING: milestone \"$title\" (#$number) still has human:pending issues:"
    printf '%s\n' "$pending" | while IFS= read -r line; do echo "  $line"; done
    PENDING_BLOCK=1
  else
    echo "ok: $title (#$number) no open human:pending"
  fi

  # Epic parent (prefer open epic; fall back to any epic in the milestone)
  EPIC_ROWS=()
  while IFS= read -r epic_row || [[ -n "$epic_row" ]]; do
    EPIC_ROWS+=("$epic_row")
  done < <(gh issue list --repo "$REPO" --milestone "$title" --state all --label epic \
    --json number,title,state -q '.[] | "\(.number)\t\(.state)\t\(.title)"' 2>/dev/null || true)  # intentional fail-soft

  EPIC_NUM=""
  for er in "${EPIC_ROWS[@]:-}"; do
    [[ -z "$er" ]] && continue
    en="${er%%$'\t'*}"
    rest="${er#*$'\t'}"
    est="${rest%%$'\t'*}"
    if [[ "$est" == "OPEN" || "$est" == "open" ]]; then
      EPIC_NUM="$en"
      break
    fi
  done
  if [[ -z "$EPIC_NUM" && ${#EPIC_ROWS[@]} -gt 0 && -n "${EPIC_ROWS[0]:-}" ]]; then
    EPIC_NUM="${EPIC_ROWS[0]%%$'\t'*}"
  fi

  if [[ -z "$EPIC_NUM" ]]; then
    echo "EPIC: milestone \"$title\" (#$number) has no epic parent issue"
    EPIC_BLOCK=1
  else
    echo "ok: $title (#$number) epic parent #${EPIC_NUM}"

    # Every non-epic issue in the milestone must be a sub-issue of the epic or orphan:ok
    while IFS= read -r irow; do
      [[ -z "$irow" ]] && continue
      inum="$(jq -r '.number' <<<"$irow")"
      ititle="$(jq -r '.title' <<<"$irow")"
      ilabels="$(jq -r '[.labels[].name] | join(",")' <<<"$irow")"
      [[ "$inum" == "$EPIC_NUM" ]] && continue
      if echo "$ilabels" | grep -qw epic; then
        # Nested epic: still must be linked as sub-issue of the milestone parent (or orphan:ok)
        :
      fi
      if echo "$ilabels" | grep -qw 'orphan:ok'; then
        echo "ok: #$inum orphan:ok exception"
        continue
      fi
      if is_sub_issue_of "$EPIC_NUM" "$inum"; then
        echo "ok: #$inum is sub-issue of epic #$EPIC_NUM"
      else
        echo "ORPHAN: milestone \"$title\" issue #$inum \"$ititle\" is not a sub-issue of epic #$EPIC_NUM (add link or label orphan:ok)"
        ORPHAN_BLOCK=1
      fi
    done < <(gh issue list --repo "$REPO" --milestone "$title" --state all --limit 200 \
      --json number,title,labels -q '.[] | {number,title,labels}')
  fi
done < <(gh api "repos/${REPO}/milestones?state=open&per_page=100" --jq '.[] | {number,title,description}')

if [[ "$DRIFT" -ne 0 ]]; then
  echo "result: outcome-section drift detected" >&2
fi
if [[ "$PENDING_BLOCK" -ne 0 && "$ALLOW_PENDING" -eq 0 ]]; then
  echo "result: refusing clean milestone while human:pending remains (orchestrator must not close)" >&2
fi
if [[ "$EPIC_BLOCK" -ne 0 ]]; then
  echo "result: milestone missing epic parent (planner must create-epic before sub-issues)" >&2
fi
if [[ "$ORPHAN_BLOCK" -ne 0 ]]; then
  echo "result: milestone has issues not linked as sub-issues of the epic parent" >&2
fi

rc=0
[[ "$DRIFT" -eq 0 ]] || rc=1
[[ "$PENDING_BLOCK" -eq 0 || "$ALLOW_PENDING" -eq 1 ]] || rc=1
[[ "$EPIC_BLOCK" -eq 0 ]] || rc=1
[[ "$ORPHAN_BLOCK" -eq 0 ]] || rc=1
exit "$rc"
