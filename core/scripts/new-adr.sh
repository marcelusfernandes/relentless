#!/usr/bin/env bash
# new-adr.sh — create next numbered ADR under docs/decisions/adr/.
# Usage:
#   new-adr.sh --workdir PATH --title "Title" --slug slug [--issue N] [--status proposed] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="." TITLE="" SLUG="" ISSUE="" STATUS="proposed" DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --status) STATUS="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") --workdir PATH --title T --slug S [--issue N] [--status proposed] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TITLE" && -n "$SLUG" ]] || { echo "need --title --slug" >&2; exit 2; }

STATUS_LC="$(printf '%s' "$STATUS" | tr '[:upper:]' '[:lower:]')"
if [[ "$STATUS_LC" == "accepted" ]]; then
  # shellcheck source=lib/human-decision.sh
  source "${SCRIPT_DIR}/lib/human-decision.sh"
  EXACT="Record the human answer on issue ${ISSUE:-N}, option K, for docs/decisions/adr/NNNN-$(printf '%q' "$SLUG").md"
  relentless_refuse_if_agent "new-adr.sh --status accepted" "$EXACT"
  relentless_confirm_on_tty "new-adr.sh --status accepted" "$EXACT" "Create ADR \"${TITLE}\" with Status accepted? Agents must leave ADRs proposed."
  STATUS="accepted"
fi

WORKDIR="$(cd "$WORKDIR" && pwd)"
ADR_DIR="${WORKDIR}/docs/decisions/adr"
mkdir -p "$ADR_DIR" "${WORKDIR}/docs/decisions/notes"

SLUG="$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
next=1
shopt -s nullglob
existing=("$ADR_DIR"/[0-9][0-9][0-9][0-9]-*.md)
if ((${#existing[@]} > 0)); then
  last="$(printf '%s\n' "${existing[@]}" | sed -E 's|.*/([0-9]{4})-.*|\1|' | sort -n | tail -1)"
  next=$((10#$last + 1))
fi
NUM="$(printf '%04d' "$next")"
OUT="${ADR_DIR}/${NUM}-${SLUG}.md"
DATE="$(TZ=America/Sao_Paulo date +%Y-%m-%d)"
ISSUE_LINE="${ISSUE:+#${ISSUE}}"
ISSUE_LINE="${ISSUE_LINE:-(none)}"

BODY=$(cat <<EOFBODY
# ADR ${NUM} — ${TITLE}

- **Status:** ${STATUS}
- **Date:** ${DATE} (America/Sao_Paulo)
- **Issue:** ${ISSUE_LINE}
- **Human gate:** required (\`human:pending\` → \`/decide\`)
- **Decider:** _(filled when the human answers)_

## Context
(what forces the decision)

## Options

### 1. (option from decision-request)
- Pros: …
- Cons: …

### 2. …
- Pros: …
- Cons: …

## Decision
_(filled when accepted)_

## Consequences
Positive / negative / follow-ups.

## Evidence
EOFBODY
)

if [[ "$DRY" -eq 1 ]]; then
  echo "dry-run: would write $OUT"
  printf '%s\n' "$BODY"
  exit 0
fi
if [[ -e "$OUT" ]]; then
  echo "error: exists: $OUT" >&2
  exit 1
fi
printf '%s\n' "$BODY" > "$OUT"

README="${WORKDIR}/docs/decisions/README.md"
if [[ -f "$README" ]] && ! grep -q "${NUM}-${SLUG}.md" "$README"; then
  if grep -q '^### ADRs' "$README"; then
    tmp="$(mktemp)"
    awk -v line="- [ADR ${NUM} — ${TITLE}](adr/${NUM}-${SLUG}.md) — ${STATUS}" '
      /^### ADRs$/ { print; getline; if ($0 ~ /^\(none yet/) { print line; next } else { print line; print; next } }
      { print }
    ' "$README" > "$tmp" && mv "$tmp" "$README"
  else
    printf '\n- [ADR %s — %s](adr/%s-%s.md) — %s\n' "$NUM" "$TITLE" "$NUM" "$SLUG" "$STATUS" >> "$README"
  fi
fi

echo "$OUT"
