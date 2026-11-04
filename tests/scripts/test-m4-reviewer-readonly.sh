#!/usr/bin/env bash
# M4 review: read-only tools, Codex sandbox, and the same verdict/labels path.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

md="$ROOT/agents/reviewer.md"
toml="$ROOT/.codex/agents/reviewer.toml"
verdict="$ROOT/core/scripts/apply-review-verdict.sh"
tools="$(awk -F': ' '/^tools: /{print $2; exit}' "$md")"

if [[ "$tools" == *"Read"* && "$tools" == *"Grep"* && "$tools" == *"Glob"* \
  && "$tools" == *"gh pr diff"* && "$tools" == *"gh issue view"* \
  && "$tools" != *"Edit"* && "$tools" != *"Write"* && "$tools" != *"MultiEdit"* ]]; then
  ok
else
  bad "M4 reviewer tools are not read-only: $tools"
fi
if grep -q '^sandbox_mode = "read-only"$' "$toml"; then
  ok
else
  bad "M4 reviewer.toml missing sandbox_mode = \"read-only\""
fi
if grep -q 'The orchestrator runs `apply-review-verdict.sh`' "$md" \
  && grep -q 'Do not run `apply-review-verdict.sh`' "$md" \
  && grep -q 'The reviewer never applies labels' "$ROOT/agents/layers/review.md"; then
  ok
else
  bad "M4 verdict path changed: the reviewer must not apply labels"
fi
if grep -q 'review:approved' "$verdict" && grep -q 'changes_requested' "$verdict" \
  && grep -q 'approved' "$verdict"; then
  ok
else
  bad "M4 apply-review-verdict.sh no longer applies the verdict labels"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
