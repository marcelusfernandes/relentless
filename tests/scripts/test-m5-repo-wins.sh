#!/usr/bin/env bash
# M5 — the repo wins. Base is the repo default branch, the merge method is one
# the repo allows, and checks are the repo's. The cut's scan
# `rg 'origin/main|--merge'` is empty outside config and tests.
# `--merge` is the whole flag, so `--merge-default` (merge.default) is not a hit.
#
# Fixture: default branch develop, squash only, its own CI command.
# Expected red on v1.4.11. Later minimal-cut PRs turn it green.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export HEAD_SHA

# --- scan: origin/main and the --merge flag, outside tests and config files ---
# Whole-flag --merge. A trailing "-" keeps --merge-default out of the scan.
: >"$TMP/hits"
find "$ROOT" \( -path '*/.git' -o -path '*/.git/*' \) -prune -o -type f -print >"$TMP/files"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
    "$ROOT"/tests/*) continue ;;
  esac
  base="$(basename "$f")"
  case "$base" in
    config.json|config.example.json|config.schema.json) continue ;;
  esac
  rel="${f#"$ROOT"/}"
  # grep exits 1 when this file has no hit; that is a clean file, not a scan error.
  grep -nE -e 'origin/main' -e '--merge([^A-Za-z0-9_-]|$)' "$f" 2>/dev/null | sed "s|^|${rel}:|" >>"$TMP/hits" || true
done <"$TMP/files"
sort -o "$TMP/hits" "$TMP/hits"
if [[ -s "$TMP/hits" ]]; then
  n="$(wc -l <"$TMP/hits" | tr -d ' ')"
  first="$(head -n 1 "$TMP/hits")"
  bad "M5 rg 'origin/main|--merge' is not empty outside config and tests (${n} hits); first: ${first}"
else
  ok
fi

# --- base: worktree plan uses the repo default branch, develop ---
mkdir -p "$TMP/bin" "$TMP/wt"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$*" == *"defaultBranchRef"* ]]; then
  echo develop
  exit 0
fi
if [[ "$*" == *"isEmpty"* ]]; then
  echo false
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"
# command -v exits 1 when gh is absent; that miss is the guard, not a crash.
require_stub_gh() {
  local got
  got="$(PATH="$TMP/bin:$PATH" command -v gh 2>/dev/null || true)"
  if [[ "$got" != "$TMP/bin/gh" ]]; then
    bad "M5: gh on PATH is '${got:-missing}', not stub $TMP/bin/gh; refusing to call gh"
    return 1
  fi
  return 0
}
: >"$TMP/gh-wt.log"
if ! require_stub_gh; then
  wt_rc=99
  wt_out="stub guard failed"
else
wt_out="$(PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh-wt.log" \
  bash "$ROOT/core/scripts/worktree-create.sh" --repo acme/consumer --issue 9 --slug login \
    --workdir "$TMP/wt" --dry-run 2>&1)"
wt_rc=$?
fi
if [[ "$wt_rc" -ne 0 ]]; then
  bad "M5 worktree-create dry-run exited $wt_rc before the base check: $wt_out"
elif printf '%s\n' "$wt_out" | grep -q 'origin/develop' && ! printf '%s\n' "$wt_out" | grep -q 'origin/main'; then
  ok
else
  bad "M5 base: repo default branch is develop; plan was: $(printf '%s\n' "$wt_out" | grep -F 'origin/' | head -n 1)"
fi

# --- merge method: squash is the only method the repo allows ---
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  printf '%s\n' "$*" >>"${GH_MERGE:?}"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  if [[ "$*" == *"-q"* && "$*" == *"body"* ]]; then
    printf '%s\n' 'ADRs: none (consumer policy)'
    exit 0
  fi
  printf '%s\n' "{\"headRefOid\":\"${HEAD_SHA:?}\",\"headRefName\":\"feat/9-login\",\"baseRefName\":\"develop\",\"state\":\"OPEN\"}"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "checks" ]]; then
  echo "consumer-test pass"
  exit 0
fi
if [[ "$1" == "run" ]]; then
  echo '[]'
  exit 0
fi
if [[ "$1" == "issue" ]]; then
  exit 0
fi
if [[ "$1" == "api" ]]; then
  # The fixture is squash-only. Answer the repo merge-settings query with that.
  if [[ "$*" == *"allow_squash_merge"* || "$*" == *"allow_merge_commit"* || "$*" == *"squashMergeAllowed"* ]]; then
    printf '%s\n' '{"allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":false}'
    exit 0
  fi
  if [[ "$*" == *"check-runs"* ]]; then
    printf '%s\n' "{\"check_runs\":[{\"name\":\"consumer-test\",\"status\":\"completed\",\"conclusion\":\"success\",\"started_at\":\"2026-11-02T00:00:00Z\",\"details_url\":\"https://github.com/acme/consumer/actions/runs/99\"}]}"
    exit 0
  fi
  if [[ "$*" == *"/files"* ]]; then
    exit 0
  fi
  if [[ "$*" == *"comments"* ]]; then
    printf '%s\n' "[{\"body\":\"<!-- relentless:review-verdict sha=\\\"${HEAD_SHA:?}\\\" -->\",\"created_at\":\"2026-11-02T00:00:00Z\"}]"
    exit 0
  fi
  if [[ "$*" == *"join"* ]]; then
    printf '%s\n' 'review:approved'
    exit 0
  fi
  if [[ "$*" == *".state"* ]]; then
    echo closed
    exit 0
  fi
  if [[ "$*" == *"PATCH"* || "$*" == *"-X"* ]]; then
    echo '{"html_url":"https://example.test/7"}'
    exit 0
  fi
  if [[ "$*" == *"[.labels[].name]"* ]]; then
    echo '["review:approved","state:done"]'
    exit 0
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

if ! require_stub_gh; then
  merge_rc=99
  merge_out="stub guard failed"
  merge_call=""
else
jq -n '{
  decider: {name: "Ada", github: "ada"},
  workers: {default: {github: "ada"}},
  merge: {default: "auto", allow_issue_override: false}
}' >"$TMP/merge-config.json"
: >"$TMP/gh-merge.log"
: >"$TMP/gh-merge-call.log"
merge_out="$(
  PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh-merge.log" GH_MERGE="$TMP/gh-merge-call.log" \
  MERGE_CI_WAIT_TIMEOUT=2 MERGE_CI_TRIES=1 MERGE_CI_SLEEP=0 \
  bash "$ROOT/core/scripts/merge-if-ready.sh" --repo acme/consumer --pr 4 --issue 7 \
    --config "$TMP/merge-config.json" 2>&1
)"
merge_rc=$?
merge_call="$(cat "$TMP/gh-merge-call.log" 2>/dev/null || true)"
fi
if [[ -z "$merge_call" ]]; then
  bad "M5 merge-if-ready exited ${merge_rc} before choosing a merge method: $(printf '%s\n' "$merge_out" | tail -n 3 | tr '\n' ' ')"
elif printf '%s\n' "$merge_call" | grep -q -- '--squash' && ! printf '%s\n' "$merge_call" | grep -E -q -- '--merge([^A-Za-z0-9_-]|$)'; then
  ok
else
  bad "M5 merge method: repo allows only squash; gh pr merge used: ${merge_call}"
fi

# --- checks: the repo's workflow command, not a detected script and not relentless-ci ---
REPO="$TMP/checks-repo"
mkdir -p "$REPO/.github/workflows" "$REPO/.github/ISSUE_TEMPLATE"
printf '%s\n' 'name: consumer' 'on:' '  push:' '    branches: [develop]' '  pull_request:' 'jobs:' '  test:' \
  '    runs-on: ubuntu-latest' '    steps:' '      - run: npm run test:consumer' \
  >"$REPO/.github/workflows/consumer.yml"
printf '%s\n' '{"scripts":{"test":"vitest","lint":"eslint","build":"vite build"}}' >"$REPO/package.json"
printf '%s\n' 'name: Consumer bug' >"$REPO/.github/ISSUE_TEMPLATE/bug.yml"
# Consumer-owned Codex briefs. --harness both must leave these alone.
mkdir -p "$REPO/.codex/agents"
for agent in planner implementer qa reviewer orchestrator documenter; do
  printf '%s\n' "consumer ${agent} brief" >"$REPO/.codex/agents/${agent}.toml"
done
ci_before="$(cksum "$REPO/.github/workflows/consumer.yml" | awk '{print $1}')"
git -C "$REPO" init -q -b develop
git -C "$REPO" add .
git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit -q -m init
codex_sums() {
  local agent sum=""
  for agent in planner implementer qa reviewer orchestrator documenter; do
    sum="${sum} $(cksum "$REPO/.codex/agents/${agent}.toml" | awk '{print $1}')"
  done
  printf '%s' "$sum"
}
codex_before="$(codex_sums)"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "auth" ]]; then
  echo "Token scopes: 'repo', 'workflow'"
  exit 0
fi
if [[ "$1" == "repo" ]]; then
  if [[ "$*" == *"isEmpty"* ]]; then
    echo false
    exit 0
  fi
  if [[ "$*" == *"defaultBranchRef"* ]]; then
    echo develop
    exit 0
  fi
  exit 0
fi
if [[ "$1" == "label" && "$2" == "list" ]]; then
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo ada
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"
: >"$TMP/gh-boot.log"
if ! require_stub_gh; then
  boot_rc=99
  boot_out="stub guard failed"
else
boot_out="$(PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh-boot.log" \
  bash "$ROOT/core/scripts/bootstrap.sh" --repo acme/consumer --workdir "$REPO" \
    --merge-default human --decider Ada --decider-github ada \
    --harness both --no-init-empty --apply 2>&1)"
boot_rc=$?
fi
if [[ "$boot_rc" -ne 0 ]]; then
  bad "M5 bootstrap exited $boot_rc before the checks assertion: $(printf '%s\n' "$boot_out" | tail -n 3 | tr '\n' ' ')"
else
  ok
fi
ci_after="$(cksum "$REPO/.github/workflows/consumer.yml" | awk '{print $1}')"
if [[ "$ci_after" == "$ci_before" ]]; then
  ok
else
  bad "M5 checks: bootstrap rewrote the repo workflow .github/workflows/consumer.yml"
fi
if [[ -e "$REPO/.github/workflows/relentless-ci.yml" ]]; then
  bad "M5 checks: bootstrap wrote .github/workflows/relentless-ci.yml; the repo already has consumer CI"
else
  ok
fi
got_test=""
if [[ -f "$REPO/.relentless/config.json" ]]; then
  got_test="$(jq -r '.checks.test // empty' "$REPO/.relentless/config.json")"
fi
if [[ "$got_test" == "npm run test:consumer" ]]; then
  ok
else
  bad "M5 checks: config checks.test is '${got_test:-<missing>}'; the repo CI runs 'npm run test:consumer'"
fi
if [[ "$(codex_sums)" == "$codex_before" ]]; then
  ok
else
  bad "M5 bootstrap rewrote a consumer .codex/agents/*.toml"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
