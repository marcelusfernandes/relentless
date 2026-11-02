#!/usr/bin/env bash
# wait-ci.sh — bounded foreground poll for PR checks.
# Does not start a run watcher. A watcher blocks until the run ends, so agents
# background it, and headless Claude then stops the session when that task is
# still running after the turn (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS).
#
# The verdict is the checks on the PR head SHA, by check name (for example
# tests-ok). A newer green run of a different workflow on the same branch
# does not cover a red check on that SHA. A green check list is not enough
# on its own: jobs appear only after a workflow creates them, so the workflow
# runs on that SHA are judged too. Green requires both. A run still queued,
# pending, or in progress stays pending. failure, startup_failure, and
# cancelled are red.
#
# One invocation polls until --timeout-sec (default 30), then returns:
#   0  CI green
#   1  CI failed (a test or other real job ran and failed)
#   2  usage error
#   3  CI pending — re-run this script in the foreground on the next step
#   4  CI unavailable (quota) — billing, spending limit, minutes exhausted,
#      startup_failure, or a completed run whose jobs executed no steps.
#      Not a test failure. Do not retry this script in a loop.
#
# Usage: wait-ci.sh --repo OWNER/NAME --pr N [--timeout-sec 30]
set -euo pipefail
REPO="" PR="" TIMEOUT=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --timeout-sec) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $(basename "$0") --repo OWNER/NAME --pr N [--timeout-sec 30]"
      echo "Exit 0 green, 1 failed, 3 pending (re-run in the foreground), 4 CI unavailable (quota)."
      exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "need --repo --pr" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 2; }

INTERVAL=5
run_id=""
status=""
HEAD_JSON="$(gh pr view "$PR" --repo "$REPO" --json headRefOid,headRefName 2>/dev/null || true)"  # intentional fail-soft: no PR payload yet is pending
SHA=""
BRANCH=""
if [[ -n "$HEAD_JSON" ]]; then
  SHA="$(jq -r '.headRefOid // empty' <<<"$HEAD_JSON" 2>/dev/null || true)"  # intentional fail-soft
  BRANCH="$(jq -r '.headRefName // empty' <<<"$HEAD_JSON" 2>/dev/null || true)"  # intentional fail-soft
fi
deadline=$((SECONDS + TIMEOUT))

pending() {
  local detail="${1:-}"
  echo "CI: pending${detail} — re-run wait-ci.sh in the foreground on the next step (exit 3)."
  exit 3
}

quota_exit() {
  echo "CI unavailable (quota)" >&2
  exit 4
}

# True when text mentions Actions billing / quota rather than a test assertion.
text_is_quota() {
  grep -qiE 'billing|spending[[:space:]]+limit|minutes[[:space:]]+exhausted|out of minutes|minute quota'
}

# Inspect a completed non-success run. Returns 0 when it is quota, 1 otherwise.
# A jobs-API miss is not quota: merge-if-ready must not run local checks unless
# this script classified the run.
run_is_quota() {
  local id="$1"
  local view="" sha="" blob="" ann="" job_id="" rc=0
  set +e
  view="$(gh run view "$id" --repo "$REPO" --json jobs,headSha,conclusion 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$view" ]]; then
    return 1
  fi
  set +e
  jq -e '
    (.jobs // []) as $j
    | if ($j | length) == 0 then true
      elif any($j[]; .conclusion == "startup_failure") then true
      elif all($j[]; ((.steps // []) | length) == 0) then true
      else false end
  ' <<<"$view" >/dev/null
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  sha="$(jq -r '.headSha // empty' <<<"$view" 2>/dev/null || true)"  # intentional fail-soft: missing head SHA skips check-run text
  blob=""
  if [[ -n "$sha" ]]; then
    set +e
    blob="$(gh api "repos/${REPO}/commits/${sha}/check-runs" 2>/dev/null)"
    set -e
  fi
  while IFS= read -r job_id; do
    [[ "$job_id" =~ ^[0-9]+$ ]] || continue
    set +e
    ann="$(gh api "repos/${REPO}/check-runs/${job_id}/annotations" 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 && -n "$ann" ]]; then
      blob+="$ann"$'\n'
    fi
  done < <(jq -r '.jobs[]?.databaseId // empty' <<<"$view" 2>/dev/null || true)  # intentional fail-soft: no job ids means no annotations to read
  if printf '%s\n' "$blob" | text_is_quota; then
    return 0
  fi
  return 1
}

# JSON array of the latest check per name: {name,status,conclusion,run_id}.
# Workflow runs on the same SHA are judged as well once these look green.
# When this list is empty, the workflow runs are the whole verdict, latest
# per workflow, not only the newest run on the branch.
latest_check_runs() {
  local sha="$1" raw="" out=""
  [[ -n "$sha" ]] || { printf '%s\n' '[]'; return 0; }
  raw="$(gh api "repos/${REPO}/commits/${sha}/check-runs?per_page=100" 2>/dev/null || true)"  # intentional fail-soft: no checks yet is pending
  [[ -n "$raw" ]] || { printf '%s\n' '[]'; return 0; }
  out="$(jq -c '
    if type != "object" or (.check_runs | type) != "array" then []
    else
      [ .check_runs
        | group_by(.name)
        | .[]
        | sort_by(.started_at // "")
        | last
        | {
            name,
            status: (.status // ""),
            conclusion: (.conclusion // ""),
            run_id: (
              (.details_url // "") as $u
              | if ($u | test("/actions/runs/[0-9]+")) then ($u | capture("/actions/runs/(?<id>[0-9]+)").id) else "" end
            )
          }
      ]
    end
  ' <<<"$raw" 2>/dev/null || true)"  # intentional fail-soft: a non-check payload is no checks
  [[ -n "$out" ]] || out='[]'
  printf '%s\n' "$out"
}

latest_workflow_runs() {
  local sha="$1" branch="$2" raw="" out=""
  if [[ -n "$sha" ]]; then
    raw="$(gh run list --repo "$REPO" --commit "$sha" --limit 50 --json databaseId,status,conclusion,name,headSha,workflowName,createdAt 2>/dev/null || true)"  # intentional fail-soft: no run yet is pending, not a failure
  elif [[ -n "$branch" ]]; then
    raw="$(gh run list --repo "$REPO" --branch "$branch" --limit 50 --json databaseId,status,conclusion,name,headSha,workflowName,createdAt 2>/dev/null || true)"  # intentional fail-soft: no run yet is pending, not a failure
  else
    printf '%s\n' '[]'
    return 0
  fi
  [[ -n "$raw" && "$raw" != "null" && "$raw" != "[]" ]] || { printf '%s\n' '[]'; return 0; }
  out="$(jq -c --arg sha "$sha" '
    if type != "array" then []
    else
      [ .[]
        | select(($sha == "") or ((.headSha // "") == "") or (.headSha == $sha))
        | {
            name: (.name // .workflowName // (.databaseId | tostring)),
            status: (.status // ""),
            conclusion: (.conclusion // ""),
            run_id: (.databaseId | tostring),
            ord: (.createdAt // (.databaseId | tostring))
          }
      ]
      | group_by(.name)
      | [ .[] | sort_by(.ord) | last | del(.ord) ]
    end
  ' <<<"$raw" 2>/dev/null || true)"  # intentional fail-soft: unexpected run-list JSON is no runs
  [[ -n "$out" ]] || out='[]'
  printf '%s\n' "$out"
}

# Prints "verdict<TAB>run_id<TAB>status". The caller reads it in this shell;
# a command substitution would drop assignments made here.
judge_checks() {
  local json="$1" count="" failed_n="" pending_n="" all_quota=1 row="" cid="" conc="" rid="" st=""
  count="$(jq 'length' <<<"$json" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 0 ]]; then
    printf 'none\t\t\n'
    return 0
  fi
  failed_n="$(jq '[.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure"))] | length' <<<"$json")"
  pending_n="$(jq '[.[] | select(.status != "completed")] | length' <<<"$json")"
  if [[ "$failed_n" -gt 0 ]]; then
    rid=""
    st="completed"
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      cid="$(jq -r '.run_id // empty' <<<"$row")"
      conc="$(jq -r '.conclusion // empty' <<<"$row")"
      rid="$cid"
      if [[ "$conc" == "startup_failure" ]]; then
        continue
      fi
      if [[ -z "$cid" ]] || ! run_is_quota "$cid"; then
        all_quota=0
        break
      fi
    done < <(jq -c '.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure"))' <<<"$json")
    if [[ "$all_quota" -eq 1 ]]; then
      printf 'quota\t%s\t%s\n' "$rid" "$st"
    else
      printf 'failed\t%s\t%s\n' "$rid" "$st"
    fi
    return 0
  fi
  if [[ "$pending_n" -gt 0 ]]; then
    rid="$(jq -r '[.[] | select(.status != "completed") | .run_id] | map(select(. != "")) | .[0] // empty' <<<"$json")"
    st="$(jq -r '[.[] | select(.status != "completed") | .status] | .[0] // "pending"' <<<"$json")"
    printf 'pending\t%s\t%s\n' "$rid" "$st"
    return 0
  fi
  rid="$(jq -r '[.[].run_id] | map(select(. != "")) | .[0] // empty' <<<"$json")"
  printf 'green\t%s\tcompleted\n' "$rid"
}

# Workflow runs on the SHA, latest per workflow. Used when the check list
# already looks green. Prints verdict<TAB>run_id<TAB>status.
# failure / startup_failure / cancelled are red here: a startup_failure
# creates no job, so the check list cannot see it.
judge_workflow_runs() {
  local json="$1" line=""
  line="$(jq -r '
    def bad: .status == "completed" and (
      .conclusion == "failure" or .conclusion == "startup_failure" or .conclusion == "cancelled"
      or .conclusion == "timed_out" or .conclusion == "action_required"
    );
    def waiting: .status == "pending" or .status == "in_progress" or .status == "queued"
      or .status == "waiting" or .status == "requested";
    if any(.[]; bad) then
      first(.[] | select(bad)) | "failed\t\(.run_id)\tcompleted"
    elif any(.[]; waiting) then
      first(.[] | select(waiting)) | "pending\t\(.run_id)\t\(.status)"
    else
      "green\t\((.[0].run_id // ""))\tcompleted"
    end
  ' <<<"$json" 2>/dev/null || true)"  # intentional fail-soft: unreadable runs are not a green signal
  [[ -n "$line" ]] || line=$'failed\t\tcompleted'
  printf '%s\n' "$line"
}

while (( SECONDS < deadline )); do
  verdict="none"
  run_id=""
  status=""
  checks="[]"
  runs="[]"
  parsed=""
  checks_green=0
  if [[ -n "$SHA" ]]; then
    checks="$(latest_check_runs "$SHA")"
  fi
  [[ -n "$checks" ]] || checks="[]"
  if [[ "$(jq 'length' <<<"$checks")" -gt 0 ]]; then
    parsed="$(judge_checks "$checks")"
    if [[ "${parsed%%$'\t'*}" == "green" ]]; then
      checks_green=1
    fi
  else
    runs="$(latest_workflow_runs "$SHA" "$BRANCH")"
    [[ -n "$runs" ]] || runs="[]"
    if [[ "$(jq 'length' <<<"$runs")" -gt 0 ]]; then
      parsed="$(judge_checks "$runs")"
    fi
  fi
  if [[ -n "$parsed" ]]; then
    verdict="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    run_id="${parsed%%$'\t'*}"
    status="${parsed#*$'\t'}"
  fi
  # Green checks can exist before another workflow has created its jobs.
  if [[ "$checks_green" -eq 1 ]]; then
    runs="$(latest_workflow_runs "$SHA" "$BRANCH")"
    [[ -n "$runs" ]] || runs="[]"
    if [[ "$(jq 'length' <<<"$runs")" -gt 0 ]]; then
      parsed="$(judge_workflow_runs "$runs")"
      verdict="${parsed%%$'\t'*}"
      parsed="${parsed#*$'\t'}"
      run_id="${parsed%%$'\t'*}"
      status="${parsed#*$'\t'}"
    fi
  fi

  case "$verdict" in
    green)
      if [[ -n "$run_id" ]]; then
        echo "CI green (run $run_id)"
      else
        echo "CI green"
      fi
      exit 0
      ;;
    quota)
      quota_exit
      ;;
    failed)
      echo "CI failed (run ${run_id:-unknown} conclusion=failure)" >&2
      exit 1
      ;;
    pending)
      echo "CI: pending (run ${run_id:-unknown} ${status:-unknown}) — still in this foreground poll"
      ;;
    none)
      set +e
      out="$(gh pr checks "$PR" --repo "$REPO" 2>&1)"
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        echo "CI green"
        exit 0
      fi
      # Quota before the generic fail match: "startup_failure" contains "fail".
      if printf '%s\n' "$out" | grep -qiE 'startup_failure' || printf '%s\n' "$out" | text_is_quota; then
        quota_exit
      fi
      if echo "$out" | grep -qiE 'fail|error|cancelled'; then
        echo "CI failed" >&2
        echo "$out" >&2
        exit 1
      fi
      if [[ -n "$run_id" ]]; then
        echo "CI: pending (run $run_id ${status:-unknown}) — still in this foreground poll"
      else
        echo "CI: pending — no checks yet (${out:0:80})"
      fi
      ;;
  esac

  remaining=$((deadline - SECONDS))
  if (( remaining <= 0 )); then
    break
  fi
  if (( remaining < INTERVAL )); then
    sleep "$remaining"
  else
    sleep "$INTERVAL"
  fi
done

if [[ -n "${run_id:-}" ]]; then
  pending " (run $run_id ${status:-unknown})"
fi
pending ""
