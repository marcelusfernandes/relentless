#!/usr/bin/env bash
# fill-qa-section.sh — post QA as a 🤖 PR comment with <!-- relentless:qa --> and patch the PR body.
# Patching the ## QA / dogfood result section is the default. --patch-body is explicit.
# --no-patch-body posts the comment only.
# Usage: fill-qa-section.sh --repo OWNER/NAME --pr N --body-file PATH [--patch-body|--no-patch-body]
set -euo pipefail
REPO="" PR="" BODY_FILE="" PATCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --patch-body) PATCH=1; shift ;;
    --no-patch-body) PATCH=0; shift ;;
    *) shift ;;
  esac
done
[[ -n "$REPO" && -n "$PR" && -n "$BODY_FILE" && -f "$BODY_FILE" ]] || { echo "need --repo --pr --body-file" >&2; exit 2; }

TMP="$(mktemp)"
{
  echo "🤖 QA / dogfood result"
  echo ""
  echo "<!-- relentless:author=agent -->"
  echo "<!-- relentless:qa -->"
  echo ""
  cat "$BODY_FILE"
} >"$TMP"
gh pr comment "$PR" --repo "$REPO" --body-file "$TMP"
rm -f "$TMP"

if [[ "$PATCH" -eq 1 ]]; then
  # Best-effort: replace ## QA / dogfood result section in PR body
  BODY="$(gh pr view "$PR" --repo "$REPO" --json body -q .body)"
  QA="$(cat "$BODY_FILE")"
  # ENVIRON keeps newlines. awk -v drops them on BSD awk, so a multi-line QA
  # report would be stored as its first line only.
  NEW="$(printf '%s\n' "$BODY" | QA="$QA" awk '
    BEGIN { qa = ENVIRON["QA"]; inqa = 0 }
    /^## QA \/ dogfood result/ { print; print qa; inqa = 1; next }
    /^## / && inqa { inqa = 0 }
    inqa { next }
    { print }
  ')"
  gh pr edit "$PR" --repo "$REPO" --body "$NEW" >/dev/null || true  # intentional fail-soft
fi
echo "ok QA posted on PR #$PR"
