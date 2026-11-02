#!/usr/bin/env bash
# wait-ci.sh polls in the foreground and never starts a run watcher.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *watch* ]]; then
  echo "watcher invoked: $*" >&2
  exit 99
fi
case "$1 $2" in
  "pr view")
    printf '%s\n' '{"headRefName":"feat/1-x","headRefOid":"abc1111"}'
    ;;
  "run list")
    echo list >> "${GH_CALLS:-/dev/null}"
    cat "$GH_RUN_LIST"
    ;;
  "run view")
    if [[ -n "${GH_RUN_VIEW:-}" && -f "$GH_RUN_VIEW" ]]; then
      cat "$GH_RUN_VIEW"
      exit 0
    fi
    echo "unexpected gh: $*" >&2
    exit 99
    ;;
  "pr checks")
    cat "$GH_CHECKS_OUT"
    exit "${GH_CHECKS_RC:-8}"
    ;;
  *)
    if [[ "$1" == "api" ]]; then
      if [[ "$*" == *"/commits/"* && "$*" == *"check-runs"* && "$*" != *"annotations"* ]]; then
        if [[ -n "${GH_CHECK_RUNS:-}" && -f "$GH_CHECK_RUNS" ]]; then
          cat "$GH_CHECK_RUNS"
        else
          echo '{"check_runs":[]}'
        fi
        exit 0
      fi
      if [[ -n "${GH_API_BODY:-}" && -f "$GH_API_BODY" ]]; then
        cat "$GH_API_BODY"
        exit 0
      fi
    fi
    echo "unexpected gh: $*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$TMP/gh"

run_wait() {
  PATH="$TMP:$PATH" "$ROOT/core/scripts/wait-ci.sh" --repo o/r --pr 1 --timeout-sec 1
}

export GH_CHECKS_OUT="$TMP/checks.txt"
export GH_CHECKS_RC=8
export GH_RUN_LIST="$TMP/runs.json"
export GH_RUN_VIEW="$TMP/run-view.json"
export GH_API_BODY="$TMP/api.json"
export GH_CHECK_RUNS="$TMP/check-runs.json"
export GH_CALLS="$TMP/gh-calls"
: >"$GH_CALLS"
printf '%s\n' 'no checks reported' >"$GH_CHECKS_OUT"

printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"success"}]' >"$GH_RUN_LIST"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 0 && "$out" == *"CI green"* && ! -s "$TMP/err" ]]; then ok; else bad "success run rc=$rc out=$out err=$(cat "$TMP/err")"; fi

printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"failure"}]' >"$GH_RUN_LIST"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 1 && "$(cat "$TMP/err")" == *"CI failed"* ]]; then ok; else bad "failed run rc=$rc out=$out err=$(cat "$TMP/err")"; fi

printf '%s\n' '[{"databaseId":9,"status":"in_progress","conclusion":null}]' >"$GH_RUN_LIST"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 3 && "$out" == *"CI: pending"* && "$out" == *"exit 3"* && "$out" == *"foreground"* && "$out" == *"run 9"* ]]; then
  ok
else
  bad "pending run rc=$rc out=$out err=$(cat "$TMP/err")"
fi

printf '%s\n' '[]' >"$GH_RUN_LIST"
GH_CHECKS_RC=0
printf '%s\n' 'all passed' >"$GH_CHECKS_OUT"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 0 && "$out" == *"CI green"* ]]; then ok; else bad "checks pass rc=$rc out=$out"; fi

GH_CHECKS_RC=1
printf '%s\n' 'test fail' >"$GH_CHECKS_OUT"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 1 && "$(cat "$TMP/err")" == *"CI failed"* ]]; then ok; else bad "checks fail rc=$rc err=$(cat "$TMP/err")"; fi

GH_CHECKS_RC=8
printf '%s\n' 'no checks reported' >"$GH_CHECKS_OUT"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 3 && "$out" == *"CI: pending"* && "$out" == *"next step"* ]]; then ok; else bad "no run pending rc=$rc out=$out"; fi

if grep -n 'gh run watch' "$ROOT"/core/scripts/*.sh >/dev/null; then
  bad "a core script still invokes gh run watch"
else
  ok
fi

: >"$GH_CALLS"
printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"startup_failure"}]' >"$GH_RUN_LIST"
out="$(PATH="$TMP:$PATH" "$ROOT/core/scripts/wait-ci.sh" --repo o/r --pr 1 --timeout-sec 30 2>"$TMP/err")"
rc=$?
calls="$(wc -l <"$GH_CALLS" | tr -d ' ')"
if [[ "$rc" -eq 4 && "$(cat "$TMP/err")" == *"CI unavailable (quota)"* && "$(cat "$TMP/err")" != *"CI failed"* && "$calls" == "1" ]]; then
  ok
else
  bad "startup_failure rc=$rc calls=$calls out=$out err=$(cat "$TMP/err")"
fi

cat >"$GH_RUN_VIEW" <<'EOF'
{"headSha":"abc","conclusion":"failure","jobs":[{"databaseId":5,"conclusion":"failure","status":"completed","steps":[{"name":"Run tests","conclusion":"failure","status":"completed"}]}]}
EOF
printf '%s\n' '[{"message":"The job was not started because the spending limit was exceeded"}]' >"$GH_API_BODY"
printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"failure"}]' >"$GH_RUN_LIST"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 4 && "$(cat "$TMP/err")" == *"CI unavailable (quota)"* && "$(cat "$TMP/err")" != *"CI failed"* ]]; then
  ok
else
  bad "spending-limit annotation rc=$rc out=$out err=$(cat "$TMP/err")"
fi

cat >"$GH_RUN_VIEW" <<'EOF'
{"headSha":"abc","conclusion":"failure","jobs":[{"databaseId":5,"conclusion":"failure","status":"completed","steps":[]}]}
EOF
printf '%s\n' '[{"message":"Process completed with exit code 1"}]' >"$GH_API_BODY"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 4 && "$(cat "$TMP/err")" == *"CI unavailable (quota)"* ]]; then
  ok
else
  bad "no steps rc=$rc out=$out err=$(cat "$TMP/err")"
fi

cat >"$GH_RUN_VIEW" <<'EOF'
{"headSha":"abc","conclusion":"failure","jobs":[{"databaseId":5,"conclusion":"failure","status":"completed","steps":[{"name":"Run tests","conclusion":"failure","status":"completed"}]}]}
EOF
printf '%s\n' '[{"message":"Process completed with exit code 1"}]' >"$GH_API_BODY"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 1 && "$(cat "$TMP/err")" == *"CI failed"* && "$(cat "$TMP/err")" != *"CI unavailable (quota)"* ]]; then
  ok
else
  bad "real step failure rc=$rc out=$out err=$(cat "$TMP/err")"
fi

# Newest workflow run is green and belongs to another workflow. tests-ok on
# this head SHA is red, so the green run must not count as CI green.
printf '%s\n' '[{"databaseId":11,"status":"completed","conclusion":"success","name":"other","headSha":"abc1111"}]' >"$GH_RUN_LIST"
cat >"$GH_CHECK_RUNS" <<'EOF'
{"check_runs":[
  {"name":"other","status":"completed","conclusion":"success","started_at":"2026-11-02T00:00:02Z"},
  {"name":"tests-ok","status":"completed","conclusion":"failure","started_at":"2026-11-02T00:00:01Z"}
]}
EOF
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 1 && "$(cat "$TMP/err")" == *"CI failed"* && "$(cat "$TMP/err")" != *"CI unavailable (quota)"* ]]; then
  ok
else
  bad "tests-ok red under a newer green workflow rc=$rc out=$out err=$(cat "$TMP/err")"
fi

cat >"$GH_CHECK_RUNS" <<'EOF'
{"check_runs":[
  {"name":"other","status":"completed","conclusion":"success","started_at":"2026-11-02T00:00:02Z"},
  {"name":"tests-ok","status":"completed","conclusion":"success","started_at":"2026-11-02T00:00:01Z"}
]}
EOF
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 0 && "$out" == *"CI green"* && ! -s "$TMP/err" ]]; then
  ok
else
  bad "both checks green rc=$rc out=$out err=$(cat "$TMP/err")"
fi

# The only check run is a fast green workflow. CI has not created tests-ok yet.
printf '%s\n' '[{"databaseId":12,"status":"in_progress","conclusion":null,"name":"CI","headSha":"abc1111","workflowName":"CI"}]' >"$GH_RUN_LIST"
cat >"$GH_CHECK_RUNS" <<'EOF'
{"check_runs":[
  {"name":"other","status":"completed","conclusion":"success","started_at":"2026-11-02T00:00:02Z"}
]}
EOF
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 3 && "$out" == *"CI: pending"* && "$out" == *"exit 3"* && "$out" == *"foreground"* && "$out" == *"run 12"* && "$out" == *"in_progress"* ]]; then
  ok
else
  bad "green other check with CI still in progress rc=$rc out=$out err=$(cat "$TMP/err")"
fi

# startup_failure creates no job, so it is absent from the check list.
printf '%s\n' '[{"databaseId":13,"status":"completed","conclusion":"startup_failure","name":"CI","headSha":"abc1111","workflowName":"CI"}]' >"$GH_RUN_LIST"
out="$(run_wait 2>"$TMP/err")"
rc=$?
if [[ "$rc" -eq 1 && "$(cat "$TMP/err")" == *"CI failed"* && "$(cat "$TMP/err")" != *"CI unavailable (quota)"* ]]; then
  ok
else
  bad "startup_failure beside a green check rc=$rc out=$out err=$(cat "$TMP/err")"
fi
rm -f "$GH_CHECK_RUNS"
unset GH_CHECK_RUNS

unset GH_RUN_VIEW
rm -f "$GH_API_BODY"

# merge-if-ready: local checks only after wait-ci classifies quota.
REPO_DIR="$TMP/repo"
git init -b main "$REPO_DIR" >/dev/null
git -C "$REPO_DIR" config user.email "t@example.com"
git -C "$REPO_DIR" config user.name "Test"
git -C "$REPO_DIR" config core.hooksPath /dev/null
git -C "$REPO_DIR" config commit.gpgsign false
echo seed >"$REPO_DIR/README.md"
git -C "$REPO_DIR" add README.md
git -C "$REPO_DIR" commit -m "seed" >/dev/null
SHA_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo more >>"$REPO_DIR/README.md"
git -C "$REPO_DIR" add README.md
git -C "$REPO_DIR" commit -m "more" >/dev/null
SHA_NEXT="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf '%s\n' '{"scripts":{"test":"echo from-pkg"}}' >"$REPO_DIR/package.json"
git -C "$REPO_DIR" add package.json
git -C "$REPO_DIR" commit -m "pkg" >/dev/null
SHA_NPM="$(git -C "$REPO_DIR" rev-parse HEAD)"

cat >"$TMP/install.sh" <<'EOF'
#!/bin/sh
echo INSTALL_OK
exit 0
EOF
cat >"$TMP/test-ok.sh" <<'EOF'
#!/bin/sh
echo RAN >> "${RAN_FILE:?}"
echo LOCAL_OK
exit 0
EOF
cat >"$TMP/test-bad.sh" <<'EOF'
#!/bin/sh
echo RAN >> "${RAN_FILE:?}"
echo LOCAL_BAD
exit 1
EOF
cat >"$TMP/npm" <<'EOF'
#!/bin/sh
if [ "$1" = "test" ]; then
  echo NPM_OK
  exit 0
fi
echo "bad npm $*" >&2
exit 1
EOF
chmod +x "$TMP/install.sh" "$TMP/test-ok.sh" "$TMP/test-bad.sh" "$TMP/npm"

cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--body-file" && -f "$arg" ]]; then
    echo "---body-file---" >> "$GH_LOG"
    cat "$arg" >> "$GH_LOG"
  fi
  prev="$arg"
done
if [[ "$1" == "run" && "$2" == "list" ]]; then
  cat "${GH_RUN_LIST:?}"
  exit 0
fi
if [[ "$1" == "run" && "$2" == "view" ]]; then
  if [[ -n "${GH_RUN_VIEW:-}" && -f "$GH_RUN_VIEW" ]]; then
    cat "$GH_RUN_VIEW"
    exit 0
  fi
  echo "no run view" >&2
  exit 99
fi
if [[ "$1" == "api" ]]; then
  if [[ "$*" == *"/commits/"* && "$*" == *"check-runs"* && "$*" != *"annotations"* ]]; then
    echo '{"check_runs":[]}'
    exit 0
  fi
  if [[ "$*" == *"pulls/3/files"* ]]; then
    echo README.md
    exit 0
  fi
  if [[ "$*" == *".state"* ]]; then
    echo closed
    exit 0
  fi
  if [[ "$*" == *"join"* ]]; then
    printf '%s\n' "review:approved"
    printf '%s\n' "${GH_MERGE_LABEL:-merge:auto}"
    exit 0
  fi
  if [[ "$*" == *".labels"* || "$*" == *"-X"* || "$*" == *"PATCH"* ]]; then
    echo '["review:approved","merge:auto"]'
    exit 0
  fi
  if [[ "$*" == *"issues/3/comments"* && "$*" != *"--jq"* ]]; then
    if [[ -n "${GH_VERDICT_JSON:-}" ]]; then
      printf '%s\n' "$GH_VERDICT_JSON"
    else
      jq -n --arg sha "${GH_SHA1:?}" '[{created_at:"2026-01-01T00:00:00Z", body: ("<!-- relentless:review-verdict verdict=\"approved\" sha=\"" + $sha + "\" -->")}]'
    fi
    exit 0
  fi
  if [[ -n "${GH_API_BODY:-}" && -f "$GH_API_BODY" ]]; then
    cat "$GH_API_BODY"
    exit 0
  fi
  echo '[]'
  exit 0
fi
if [[ "$1" == "issue" ]]; then
  exit 0
fi
if [[ "$1" == "pr" ]]; then
  if [[ "$*" == *"-q .body"* || "$*" == *"--json body"* ]]; then
    printf '%s\n' "${GH_PR_BODY:-ADRs: none (test)}"
    exit 0
  fi
  if [[ "$*" == *"headRefName"* && "$*" != *"headRefOid"* ]]; then
    echo "feat/1-x"
    exit 0
  fi
  # wait-ci reads the head SHA without advancing the merge-if-ready counter.
  if [[ "$*" == *"headRefOid"* && "$*" == *"headRefName"* && "$*" != *"state"* ]]; then
    printf '{"headRefOid":"%s","headRefName":"feat/1-x"}\n' "${GH_SHA1:?}"
    exit 0
  fi
  if [[ "$*" == *"headRefOid"* ]]; then
    n=0
    [[ -f "${GH_SHA_COUNT:?}" ]] && n="$(cat "$GH_SHA_COUNT")"
    n=$((n + 1))
    printf '%s\n' "$n" > "$GH_SHA_COUNT"
    sha="${GH_SHA1:?}"
    if [[ "$n" -gt 1 && -n "${GH_SHA2:-}" ]]; then
      sha="$GH_SHA2"
    fi
    if [[ "$*" == *"headRefName"* ]]; then
      printf '{"headRefOid":"%s","headRefName":"feat/1-x","baseRefName":"main","state":"open"}\n' "$sha"
    else
      printf '{"headRefOid":"%s"}\n' "$sha"
    fi
    exit 0
  fi
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 99
EOF
chmod +x "$TMP/gh"

write_cfg() {
  jq -n --arg i "$1" --arg t "$2" '{
    decider:{name:"Ada", github:"ada"},
    workers:{default:{github:"ada"}},
    merge:{default:"auto", allow_issue_override:true},
    checks:{install:$i, lint:"", typecheck:"", test:$t, build:""}
  }' >"$TMP/merge-config.json"
}

printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"startup_failure"}]' >"$TMP/merge-runs.json"
USE_SHA="$SHA_BASE"
NEXT_SHA=""
MERGE_LABEL="merge:auto"
RUN_VIEW=""
API_BODY=""

run_merge() {
  rm -f "$TMP/sha-count" "$TMP/ran"
  : >"$TMP/gh.log"
  out="$(
    cd "$REPO_DIR" && \
    PATH="$TMP:$PATH" \
    MERGE_CI_TRIES=1 MERGE_CI_SLEEP=0 MERGE_CI_WAIT_TIMEOUT=5 \
    GH_LOG="$TMP/gh.log" \
    GH_SHA_COUNT="$TMP/sha-count" \
    GH_SHA1="$USE_SHA" \
    GH_SHA2="$NEXT_SHA" \
    GH_MERGE_LABEL="$MERGE_LABEL" \
    GH_RUN_LIST="$TMP/merge-runs.json" \
    GH_RUN_VIEW="$RUN_VIEW" \
    GH_API_BODY="$API_BODY" \
    GH_PR_BODY="ADRs: none (quota test)" \
    RAN_FILE="$TMP/ran" \
    "$ROOT/core/scripts/merge-if-ready.sh" --repo o/r --pr 3 --issue 9 --config "$TMP/merge-config.json" 2>&1
  )"
  rc=$?
}

# ADR 0003 (proposed): merge:auto may merge when local checks pass on a stable head SHA.
write_cfg "$TMP/install.sh" "$TMP/test-ok.sh"
run_merge
log="$(cat "$TMP/gh.log")"
if [[ "$rc" -eq 0 && "$log" == *"pr merge"* && "$log" == *"<!-- relentless:local-checks -->"* && "$log" == *"merge sem CI: CI unavailable (quota)"* && "$log" == *"$USE_SHA"* && "$log" == *"exit 0"* && "$log" == *"INSTALL_OK"* && "$log" == *"LOCAL_OK"* && "$log" == *"add-label"* && "$log" == *"ci:local"* && "$log" != *"remove-label"* && "$log" != *"human:pending"* ]]; then
  inst="${log%%LOCAL_OK*}"
  if [[ "$inst" == *"INSTALL_OK"* ]]; then ok; else bad "install did not run before test"; fi
else
  bad "quota local pass rc=$rc out=$out log=$log"
fi

write_cfg "$TMP/install.sh" "$TMP/test-bad.sh"
run_merge
log="$(cat "$TMP/gh.log")"
if [[ "$rc" -eq 1 && "$log" != *"pr merge"* && "$log" != *"ci:local"* && "$log" != *"relentless:local-checks"* && -s "$TMP/ran" && "$out" == *"CI: failed"* ]]; then
  ok
else
  bad "quota local fail rc=$rc out=$out log=$log"
fi

NEXT_SHA="$SHA_NEXT"
write_cfg "$TMP/install.sh" "$TMP/test-ok.sh"
run_merge
log="$(cat "$TMP/gh.log")"
NEXT_SHA=""
if [[ "$rc" -eq 1 && "$log" == *"add-label"* && "$log" == *"ci:local"* && "$log" == *"remove-label"* && "$log" != *"pr merge"* && "$out" == *"head SHA changed"* ]]; then
  ok
else
  bad "sha changed rc=$rc out=$out log=$log"
fi

printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"failure"}]' >"$TMP/merge-runs.json"
cat >"$TMP/real-view.json" <<'EOF'
{"headSha":"abc","conclusion":"failure","jobs":[{"databaseId":5,"conclusion":"failure","status":"completed","steps":[{"name":"Run tests","conclusion":"failure","status":"completed"}]}]}
EOF
printf '%s\n' '[{"message":"Process completed with exit code 1"}]' >"$TMP/real-api.json"
RUN_VIEW="$TMP/real-view.json"
API_BODY="$TMP/real-api.json"
write_cfg "$TMP/install.sh" "$TMP/test-ok.sh"
run_merge
log="$(cat "$TMP/gh.log")"
RUN_VIEW=""
API_BODY=""
printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"startup_failure"}]' >"$TMP/merge-runs.json"
if [[ "$rc" -eq 1 && ! -e "$TMP/ran" && "$log" != *"pr merge"* && "$log" != *"relentless:local-checks"* && "$log" != *"ci:local"* && "$out" == *"CI failed"* ]]; then
  ok
else
  bad "real failure no fallback rc=$rc out=$out log=$log ran=$(cat "$TMP/ran" 2>/dev/null)"
fi

write_cfg "" ""
USE_SHA="$SHA_BASE"
run_merge
log="$(cat "$TMP/gh.log")"
if [[ "$rc" -eq 4 && "$log" == *"human:pending"* && "$log" == *"CI indisponível: cota do Actions esgotada"* && "$log" == *"CI unavailable (quota), no local checks"* && "$log" == *"Ada"* && "$log" != *"pr merge"* ]]; then
  ok
else
  bad "no test command rc=$rc out=$out log=$log"
fi

# ADR 0003 (proposed): merge:human still waits even when local checks pass.
MERGE_LABEL="merge:human"
write_cfg "$TMP/install.sh" "$TMP/test-ok.sh"
run_merge
log="$(cat "$TMP/gh.log")"
MERGE_LABEL="merge:auto"
if [[ "$rc" -eq 0 && "$log" != *"pr merge"* && "$log" == *"Ready to merge"* && "$log" == *"relentless:local-checks"* ]]; then
  ok
else
  bad "merge:human rc=$rc out=$out log=$log"
fi

USE_SHA="$SHA_NPM"
write_cfg "" ""
run_merge
log="$(cat "$TMP/gh.log")"
USE_SHA="$SHA_BASE"
if [[ "$rc" -eq 0 && "$log" == *"pr merge"* && "$log" == *'npm test'* && "$log" == *"exit 0"* && "$log" == *"NPM_OK"* && "$log" == *"ci:local"* ]]; then
  ok
else
  bad "npm fallback rc=$rc out=$out log=$log"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
