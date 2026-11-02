#!/usr/bin/env bash
# Reviewer findings are posted on the PR, and the verdict is only the last line.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

export GH_LOG="$TMP/gh.log"
export GH_COMMENT="$TMP/comment.md"

cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '%s\n' "${GH_HEAD_SHA:-0123456789abcdef0123456789abcdef01234567}"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--body-file" ]]; then
      cp "$arg" "$GH_COMMENT"
    elif [[ "$prev" == "--body" ]]; then
      printf '%s\n' "$arg" >"$GH_COMMENT"
    fi
    prev="$arg"
  done
  if [[ "${GH_COMMENT_FAIL:-}" == "1" ]]; then
    echo "comment failed" >&2
    exit 1
  fi
  exit 0
fi
if [[ "$1" == "api" ]]; then
  if [[ "$*" == *"-X"* ]]; then
    exit 0
  fi
  printf '%s\n' '["state:review"]'
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 99
EOF
chmod +x "$TMP/gh"
export GH_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"

reset_gh() {
  : >"$GH_LOG"
  rm -f "$GH_COMMENT"
}

run_from() {
  local work="$1" file="$2"
  PATH="$TMP:$PATH" "$ROOT/core/scripts/run-isolated-review.sh" \
    --repo o/r --pr 7 --issue 7 \
    --workdir "$work" \
    --from-output "$file"
}

# findings + marker + last line changes_requested
reset_gh
work="$TMP/cr"
mkdir -p "$work"
cat >"$work/review.md" <<'EOF'
## Findings
1. **[blocker]** session cookie is dropped on refresh (`src/auth.ts:40`)
2. **[major]** ADR line missing from the PR body
3. **[minor]** name the timeout constant
4. **[nit]** trailing space in the comment

Verdict: changes_requested
EOF
out="$(run_from "$work" "$work/review.md" 2>"$work/err")"
rc=$?
body="$(cat "$GH_COMMENT" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$body" == *"[blocker]"* && "$body" == *"[major]"* && "$body" == *"[minor]"* && "$body" == *"[nit]"* && "$body" == *"session cookie is dropped on refresh"* ]]; then
  ok
else
  bad "findings in comment rc=$rc body=$body err=$(cat "$work/err")"
fi
if [[ "$rc" -eq 0 && "$body" == *"relentless:review-verdict"* && "$body" == *"verdict=\"changes_requested\""* && "$body" == *"sha=\"${GH_HEAD_SHA}\""* ]]; then
  ok
else
  bad "marker missing rc=$rc body=$body"
fi
if [[ "$rc" -eq 0 && "$out" == *"verdict: changes_requested"* && "$body" != *"review:approved"* && "$(cat "$GH_LOG")" == *"state:in-progress"* ]]; then
  ok
else
  bad "last line changes_requested rc=$rc out=$out"
fi

# last line approved, earlier text quotes changes_requested
reset_gh
work="$TMP/ap"
mkdir -p "$work"
cat >"$work/review.md" <<'EOF'
## Findings
1. **[nit]** rename the helper

A quoted rule says blockers mean `changes_requested`.

Verdict: approved
EOF
out="$(run_from "$work" "$work/review.md" 2>"$work/err")"
rc=$?
log="$(cat "$GH_LOG")"
body="$(cat "$GH_COMMENT" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$out" == *"verdict: approved"* && "$log" == *"review:approved"* && "$log" != *"state:in-progress"* && "$body" == *"verdict=\"approved\""* && "$body" == *"sha=\"${GH_HEAD_SHA}\""* && "$body" != *"sha=\"${GH_HEAD_SHA:0:7}\""* ]]; then
  ok
else
  bad "last line approved rc=$rc out=$out log=$log body=$body err=$(cat "$work/err")"
fi

# A failed verdict comment must exit before any label write.
reset_gh
export GH_COMMENT_FAIL=1
out="$(
  PATH="$TMP:$PATH" \
    "$ROOT/core/scripts/apply-review-verdict.sh" --repo o/r --issue 7 --pr 7 --verdict approved \
    --workdir "$TMP" 2>"$TMP/fail-comment.err"
)"
rc=$?
unset GH_COMMENT_FAIL
log="$(cat "$GH_LOG")"
err="$(cat "$TMP/fail-comment.err")"
if [[ "$rc" -ne 0 && "$err" == *"review:approved was not applied"* && "$log" == *"pr comment"* && "$log" != *"gh api"* && "$log" != *"labels[]=review:approved"* ]]; then
  ok
else
  bad "failed comment must not apply review:approved rc=$rc err=$err log=$log out=$out"
fi

# rule quoted earlier ends on the other word; the final line wins
reset_gh
work="$TMP/quote"
mkdir -p "$work"
cat >"$work/review.md" <<'EOF'
Verdict: approved

## Findings
1. **[blocker]** refresh drops the session cookie

Verdict rule: any blocker or major finding, any unmet acceptance criterion, a missing ADRs line, or failing QA → `changes_requested`. Only minor/nit findings → `approved`; list them as follow-ups.

Verdict: changes_requested
EOF
out="$(run_from "$work" "$work/review.md" 2>"$work/err")"
rc=$?
body="$(cat "$GH_COMMENT" 2>/dev/null || true)"
log="$(cat "$GH_LOG")"
if [[ "$rc" -eq 0 && "$out" == *"verdict: changes_requested"* && "$out" != *"verdict: approved"* && "$log" == *"state:in-progress"* && "$log" != *"labels[]=review:approved"* && "$body" == *"[blocker]"* && "$body" == *"refresh drops the session cookie"* ]]; then
  ok
else
  bad "quoted rule must not flip verdict rc=$rc out=$out log=$log body=$body err=$(cat "$work/err")"
fi

# missing verdict line (no non-empty line)
reset_gh
work="$TMP/miss"
mkdir -p "$work"
printf '\n\n' >"$work/review.md"
out="$(run_from "$work" "$work/review.md" 2>"$work/err")"
rc=$?
if [[ "$rc" -ne 0 && "$(cat "$work/err")" == *"missing verdict line"* && ! -s "$GH_LOG" ]]; then
  ok
else
  bad "missing verdict rc=$rc out=$out err=$(cat "$work/err") log=$(cat "$GH_LOG")"
fi

# malformed: quoted rule is the last line, so the old last-token parse would flip to approved
reset_gh
work="$TMP/bad"
mkdir -p "$work"
cat >"$work/review.md" <<'EOF'
## Verdict
`changes_requested`

## Findings
1. **[blocker]** session cookie is dropped

Verdict rule: any blocker or major finding → `changes_requested`. Only minor/nit findings → `approved`.
EOF
out="$(run_from "$work" "$work/review.md" 2>"$work/err")"
rc=$?
if [[ "$rc" -ne 0 && "$(cat "$work/err")" == *"malformed verdict line"* && ! -s "$GH_LOG" ]]; then
  ok
else
  bad "malformed verdict rc=$rc out=$out err=$(cat "$work/err") log=$(cat "$GH_LOG")"
fi

# the brief's example placeholder is not a verdict
reset_gh
work="$TMP/placeholder"
mkdir -p "$work"
cat >"$work/review.md" <<'EOF'
## Findings
1. **[nit]** rename the helper

Verdict: <approved|changes_requested>
EOF
out="$(run_from "$work" "$work/review.md" 2>"$work/err")"
rc=$?
err="$(cat "$work/err")"
if [[ "$rc" -ne 0 && "$err" == *"refusing placeholder verdict line"* && "$err" == *"Verdict: <approved|changes_requested>"* && "$err" == *"No labels changed"* && ! -s "$GH_LOG" ]]; then
  ok
else
  bad "placeholder verdict rc=$rc out=$out err=$err log=$(cat "$GH_LOG")"
fi

# Reviewer gh allowlist is read-only: no pattern may allow a write.
allows() {
  local pat="$1" cmd="$2" re
  re="$(printf '%s' "$pat" | sed -e 's/[.[\^$()+?{|]/\\&/g' -e 's/\*/.*/g')"
  [[ "$cmd" =~ ^${re}$ ]]
}
allow_src="$(grep -n 'REVIEWER_ALLOWED_TOOLS=' "$ROOT/core/scripts/run-isolated-review.sh" || true)"
allow_line="$(sed -n 's/.*REVIEWER_ALLOWED_TOOLS="\([^"]*\)".*/\1/p' "$ROOT/core/scripts/run-isolated-review.sh")"
patterns=()
while IFS= read -r pat; do
  [[ -n "$pat" ]] || continue
  patterns+=("$pat")
done < <(printf '%s\n' "$allow_line" | grep -oE 'Bash\([^)]*\)' | sed -e 's/^Bash(//' -e 's/)$//')
writes=(
  "gh pr comment 1 --body x"
  "gh pr edit 1 --title x"
  "gh pr merge 1 --merge"
  "gh pr review 1 --approve"
  "gh issue comment 1 --body x"
  "gh issue edit 1 --add-label bug"
  "gh label create foo"
  "gh api -X POST repos/o/r/issues/1/comments"
  "gh api -X PATCH repos/o/r/issues/1"
  "gh api -X DELETE repos/o/r/issues/1"
  "gh api --method POST repos/o/r/issues/1/comments"
  "gh api --method PATCH repos/o/r/issues/1"
  "gh api --method DELETE repos/o/r/issues/1"
)
reads=(
  "gh pr view 1 --repo o/r"
  "gh pr diff 1"
  "gh pr checks 1"
  "gh issue view 1 --repo o/r"
  "gh api --method GET repos/o/r/pulls/1"
  "gh api -X GET repos/o/r/issues/1"
)
write_hit=""
for cmd in "${writes[@]}"; do
  for pat in "${patterns[@]}"; do
    if allows "$pat" "$cmd"; then
      write_hit="$pat allows $cmd"
      break
    fi
  done
  [[ -z "$write_hit" ]] || break
done
read_miss=""
for cmd in "${reads[@]}"; do
  hit=0
  for pat in "${patterns[@]}"; do
    if allows "$pat" "$cmd"; then
      hit=1
      break
    fi
  done
  if [[ "$hit" -eq 0 ]]; then
    read_miss="$cmd"
    break
  fi
done
docs_tools="$(sed -n '/--allowedTools/,/\\$/p' "$ROOT/docs/harness-profiles.md" | tr -d '\n\\')"
if [[ -z "$allow_line" ]]; then
  bad "reviewer allowlist missing"
elif printf '%s\n' "$allow_line" | grep -q 'Bash(gh \*)'; then
  bad "reviewer allowlist still has Bash(gh *)"
elif grep -q 'Bash(gh \*)' "$ROOT/core/scripts/run-isolated-review.sh"; then
  bad "run-isolated-review.sh still contains Bash(gh *)"
elif [[ -n "$write_hit" ]]; then
  bad "write-capable gh pattern: $write_hit"
elif [[ -n "$read_miss" ]]; then
  bad "read command not allowed: $read_miss (patterns=${patterns[*]})"
elif printf '%s\n' "$docs_tools" | grep -q 'Bash(gh \*)'; then
  bad "harness-profiles still documents Bash(gh *)"
elif ! printf '%s\n' "$docs_tools" | grep -q 'gh pr view'; then
  bad "harness-profiles does not document the read-only gh allowlist"
else
  ok
fi
unset allow_src

# -f/-F with an explicit GET stay allowed: gh sends them as query parameters.
query_reads=(
  "gh api -X GET repos/o/r/issues/1 -f state=open"
  "gh api -X GET repos/o/r/issues/1 -F per_page=1"
  "gh api --method GET repos/o/r/issues/1 -f state=open"
  "gh api --method GET repos/o/r/issues/1 -F per_page=1"
)
query_miss=""
for cmd in "${query_reads[@]}"; do
  hit=0
  for pat in "${patterns[@]}"; do
    if allows "$pat" "$cmd"; then
      hit=1
      break
    fi
  done
  if [[ "$hit" -eq 0 ]]; then
    query_miss="$cmd"
    break
  fi
done
if [[ -n "$query_miss" ]]; then
  bad "GET query flag not allowed: $query_miss"
else
  ok
fi

# Repeated method flags and --input are fail-closed in tests/hooks/test-hooks.sh
# (pretool-reviewer-isolation.sh, exit 2): `gh api -X GET foo -X POST` and
# `gh api --method GET foo --input body.json`, plus the attached and mixed forms.
# REVIEWER_ALLOWED_TOOLS is unchanged. This file only checks that one explicit
# GET with -f/-F still matches the allowlist.

# merge-if-ready: the latest verdict SHA must equal the full headRefOid.
FULL="0123456789abcdef0123456789abcdef01234567"
OTHER="fedcba9876543210fedcba9876543210fedcba98"
SHORT="0123456"
cat >"$TMP/merge-config.json" <<'EOF'
{"decider":{"name":"Ada","github":"ada"},"workers":{"default":{"github":"ada"}},"merge":{"default":"human","allow_issue_override":true}}
EOF
cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "api" ]]; then
  if [[ "$*" == *"issues/7/comments"* ]]; then
    cat "${GH_VERDICT_JSON:?}"
    exit 0
  fi
  if [[ "$*" == *"-X DELETE"* ]]; then
    exit 0
  fi
  if [[ "$*" == *"join"* ]]; then
    printf '%s\n' "review:approved"
    printf '%s\n' "merge:human"
    exit 0
  fi
  if [[ "$*" == *"pulls/7/files"* ]]; then
    echo README.md
    exit 0
  fi
  echo '[]'
  exit 0
fi
if [[ "$1" == "pr" ]]; then
  if [[ "$*" == *"headRefOid"* ]]; then
    printf '{"headRefOid":"%s","headRefName":"feat/1-x","baseRefName":"main","state":"open"}\n' "${GH_HEAD_SHA:?}"
    exit 0
  fi
  if [[ "$*" == *"-q .body"* || "$*" == *"--json body"* ]]; then
    printf '%s\n' "ADRs: none (readme only)"
    exit 0
  fi
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 99
EOF
chmod +x "$TMP/gh"

run_merge() {
  local dry=(--dry-run)
  if [[ "${1:-}" == "live" ]]; then
    dry=()
  fi
  : >"$TMP/gh.log"
  out="$(
    PATH="$TMP:$PATH" \
    GH_LOG="$TMP/gh.log" \
    GH_HEAD_SHA="$FULL" \
    GH_VERDICT_JSON="$GH_VERDICT_JSON" \
    "$ROOT/core/scripts/merge-if-ready.sh" --repo o/r --pr 7 --issue 9 \
      --config "$TMP/merge-config.json" ${dry[@]+"${dry[@]}"} 2>&1
  )"
  rc=$?
  log="$(cat "$TMP/gh.log")"
}

one_verdict() { # sha
  jq -n --arg sha "$1" '[{created_at:"2026-02-01T00:00:00Z", body: ("<!-- relentless:review-verdict verdict=\"approved\" sha=\"" + $sha + "\" -->")}]' >"$TMP/verdicts.json"
  export GH_VERDICT_JSON="$TMP/verdicts.json"
}

one_verdict "$FULL"
run_merge
if [[ "$rc" -eq 0 && "$out" == *"dry-run: would comment ready-to-merge"* && "$log" != *"-X DELETE"* ]]; then
  ok
else
  bad "matching SHA should pass rc=$rc out=$out log=$log"
fi

one_verdict "$OTHER"
run_merge
if [[ "$rc" -ne 0 && "$out" == *"dry-run: would remove review:approved"* && "$out" == *"does not match reviewed SHA ${OTHER}"* && "$log" != *"-X DELETE"* && "$log" != *"review%3Aapproved"* ]]; then
  ok
else
  bad "dry-run SHA mismatch must not remove the label rc=$rc out=$out log=$log"
fi

one_verdict "$OTHER"
run_merge live
if [[ "$rc" -ne 0 && "$out" == *"Removed review:approved"* && "$out" == *"does not match reviewed SHA ${OTHER}"* && "$log" == *"-X DELETE"* && "$log" == *"review%3Aapproved"* ]]; then
  ok
else
  bad "live SHA mismatch should remove the label rc=$rc out=$out log=$log"
fi

jq -n '[{created_at:"2026-02-01T00:00:00Z", body:"<!-- relentless:review-verdict verdict=\"approved\" -->"}]' >"$TMP/verdicts.json"
run_merge
if [[ "$rc" -ne 0 && "$out" == *"dry-run: would remove review:approved"* && "$out" == *"has no reviewed SHA"* && "$out" == *"Run a fresh review"* && "$log" != *"-X DELETE"* && "$log" != *"review%3Aapproved"* ]]; then
  ok
else
  bad "dry-run missing SHA must not remove the label rc=$rc out=$out log=$log"
fi

jq -n '[{created_at:"2026-02-01T00:00:00Z", body:"<!-- relentless:review-verdict verdict=\"approved\" -->"}]' >"$TMP/verdicts.json"
run_merge live
if [[ "$rc" -ne 0 && "$out" == *"Removed review:approved"* && "$out" == *"has no reviewed SHA"* && "$out" == *"Run a fresh review"* && "$log" == *"-X DELETE"* && "$log" == *"review%3Aapproved"* ]]; then
  ok
else
  bad "live missing SHA should remove the label rc=$rc out=$out log=$log"
fi

one_verdict "$SHORT"
run_merge
if [[ "$rc" -ne 0 && "$out" == *"dry-run: would remove review:approved"* && "$out" == *"does not match reviewed SHA ${SHORT}"* && "$log" != *"-X DELETE"* ]]; then
  ok
else
  bad "abbreviated SHA must not match rc=$rc out=$out log=$log"
fi

# Chronologically latest wins even when it is not the last array element.
jq -n --arg full "$FULL" --arg other "$OTHER" '[
  {created_at:"2026-03-01T00:00:00Z", body: ("<!-- relentless:review-verdict verdict=\"approved\" sha=\"" + $other + "\" -->")},
  {created_at:"2026-01-01T00:00:00Z", body: ("<!-- relentless:review-verdict verdict=\"approved\" sha=\"" + $full + "\" -->")}
]' >"$TMP/verdicts.json"
run_merge
if [[ "$rc" -ne 0 && "$out" == *"dry-run: would remove review:approved"* && "$out" == *"does not match reviewed SHA ${OTHER}"* && "$log" != *"-X DELETE"* ]]; then
  ok
else
  bad "latest differing SHA should win rc=$rc out=$out log=$log"
fi

jq -n --arg full "$FULL" --arg other "$OTHER" '[
  {created_at:"2026-03-01T00:00:00Z", body: ("<!-- relentless:review-verdict verdict=\"approved\" sha=\"" + $full + "\" -->")},
  {created_at:"2026-01-01T00:00:00Z", body: ("<!-- relentless:review-verdict verdict=\"approved\" sha=\"" + $other + "\" -->")}
]' >"$TMP/verdicts.json"
run_merge
if [[ "$rc" -eq 0 && "$out" == *"dry-run: would comment ready-to-merge"* && "$log" != *"-X DELETE"* ]]; then
  ok
else
  bad "latest matching SHA should win rc=$rc out=$out log=$log"
fi

# fill-qa-section patches the PR body unless --no-patch-body is set.
cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
  echo "commented" >>"$GH_LOG"
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
  echo "edited" >>"$GH_LOG"
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 99
EOF
chmod +x "$TMP/gh"
printf '%s\n' 'exercised login' >"$TMP/qa.md"
export GH_PR_BODY=$'## Summary\nhello\n\n## QA / dogfood result\nold notes\n\n## Notes\nkeep'
export GH_EDIT_BODY="$TMP/edited.md"

run_qa() {
  rm -f "$GH_EDIT_BODY"
  : >"$TMP/gh.log"
  out="$(
    PATH="$TMP:$PATH" \
    GH_LOG="$TMP/gh.log" \
    GH_PR_BODY="$GH_PR_BODY" \
    GH_EDIT_BODY="$GH_EDIT_BODY" \
    "$ROOT/core/scripts/fill-qa-section.sh" --repo o/r --pr 7 --body-file "$TMP/qa.md" "$@" 2>&1
  )"
  rc=$?
  log="$(cat "$TMP/gh.log")"
}

run_qa
edited="$(cat "$GH_EDIT_BODY" 2>/dev/null || true)"
if [[ "$rc" -eq 0 && "$log" == *"commented"* && "$log" == *"edited"* && "$edited" == *"exercised login"* && "$edited" == *"## Notes"* && "$edited" != *"old notes"* ]]; then
  ok
else
  bad "default should patch the PR body rc=$rc out=$out log=$log edited=$edited"
fi

run_qa --patch-body
if [[ "$rc" -eq 0 && "$log" == *"edited"* ]]; then
  ok
else
  bad "explicit --patch-body should patch rc=$rc log=$log"
fi

run_qa --no-patch-body
if [[ "$rc" -eq 0 && "$log" == *"commented"* && "$log" != *"edited"* && ! -e "$GH_EDIT_BODY" ]]; then
  ok
else
  bad "no-patch-body should comment only rc=$rc log=$log"
fi

# Every plugin manifest and marketplace entry carries the same version.
manifests=(
  plugin.json
  .claude-plugin/plugin.json
  .codex-plugin/plugin.json
  marketplace/marketplace.json
  .claude-plugin/marketplace.json
  .agents/plugins/marketplace.json
)
seen=""
version_bad=""
for f in "${manifests[@]}"; do
  v="$(jq -r 'if .plugins then [.plugins[].version] | join(" ") else .version end' "$ROOT/$f")"
  if [[ -z "$v" || "$v" == "null" ]]; then
    version_bad="$f has no version"
    break
  fi
  if [[ -z "$seen" ]]; then
    seen="$v"
  elif [[ "$v" != "$seen" ]]; then
    version_bad="$f is $v, expected $seen"
    break
  fi
done
if [[ -n "$version_bad" || "$seen" != "1.4.10" ]]; then
  bad "manifest versions: ${version_bad:-seen=$seen}"
else
  ok
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
