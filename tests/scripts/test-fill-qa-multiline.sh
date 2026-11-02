#!/usr/bin/env bash
# Multi-line QA text and relentless doc blocks must survive awk.
# BSD awk drops newlines passed with awk -v; the scripts pass them via ENVIRON.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '%s\n' "${GH_PR_BODY:?}"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "edit" ]]; then
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--body" ]]; then
      printf '%s\n' "$arg" >"${GH_EDIT_BODY:?}"
    fi
    prev="$arg"
  done
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 99
EOF
chmod +x "$TMP/bin/gh"

QA_FILE="$TMP/qa.md"
cat >"$QA_FILE" <<'EOF'
Line one of the dogfood.
Line two with: a colon and "quotes".
A literal backslash \ stays.
# not a heading

- bullet after a blank line
##not-a-section
EOF

export GH_LOG="$TMP/gh.log"
export GH_EDIT_BODY="$TMP/edited.md"
export GH_PR_BODY=$'## Summary\nhello\n\n## QA / dogfood result\nold line one\nold line two\n\n## Notes\nkeep me'
: >"$GH_LOG"

out="$(
  PATH="$TMP/bin:$PATH" \
  GH_LOG="$GH_LOG" \
  GH_PR_BODY="$GH_PR_BODY" \
  GH_EDIT_BODY="$GH_EDIT_BODY" \
  "$ROOT/core/scripts/fill-qa-section.sh" --repo o/r --pr 7 --body-file "$QA_FILE" 2>&1
)"
rc=$?
edited="$(cat "$GH_EDIT_BODY" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$edited" == *"Line one of the dogfood."* \
  && "$edited" == *"Line two with: a colon and \"quotes\"."* \
  && "$edited" == *"A literal backslash \ stays."* \
  && "$edited" == *"- bullet after a blank line"* \
  && "$edited" == *"##not-a-section"* \
  && "$edited" == *"## Notes"* \
  && "$edited" == *"keep me"* \
  && "$edited" != *"old line one"* \
  && "$edited" != *"old line two"* ]]; then
  ok
else
  bad "multi-line QA was not written into the PR body rc=$rc out=$out edited<<EOF
$edited
EOF"
fi

# shellcheck source=../../core/scripts/lib/seed-relentless-docs.sh
source "$ROOT/core/scripts/lib/seed-relentless-docs.sh"
doc="$TMP/AGENTS.md"
cat >"$doc" <<'EOF'
# keep before

<!-- relentless:start -->
old block line
<!-- relentless:end -->

# keep after
EOF
block="$(cat <<'EOF'
<!-- relentless:start -->
First line of the managed block.
Second line with: a colon.

- bullet after a blank line
A literal backslash \ stays.
<!-- relentless:end -->
EOF
)"
upsert_relentless_block "$doc" "$block" >/dev/null
got="$(cat "$doc")"
if [[ "$got" == *"# keep before"* \
  && "$got" == *"# keep after"* \
  && "$got" == *"First line of the managed block."* \
  && "$got" == *"Second line with: a colon."* \
  && "$got" == *"- bullet after a blank line"* \
  && "$got" == *"A literal backslash \ stays."* \
  && "$got" == *"<!-- relentless:end -->"* \
  && "$got" != *"old block line"* ]]; then
  ok
else
  bad "multi-line relentless block was not kept<<EOF
$got
EOF"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
