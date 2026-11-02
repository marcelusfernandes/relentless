#!/usr/bin/env bash
# merge-if-ready.sh — orchestrator final step after isolated review.
# Resolves merge mode: merge.default, unless allow_issue_override lets a merge:* label win.
# auto: require CI green on head SHA + review:approved → merge commit, state:done, close issue.
# The latest relentless:review-verdict comment must record that same full headRefOid.
# No SHA refuses the merge (older approvals are not kept). A different SHA drops review:approved.
# human: post 🤖 ready-to-merge and exit 0 without merging.
#
# Before either of those, refuses (exit 1, no merge) unless the PR
# body has exactly one ADRs: line:
#   ADRs: docs/decisions/adr/NNNN-slug.md[, …]   (each path must exist at the PR head)
#   ADRs: none (<reason>)
# An accepted ADR in the diff needs a decide.sh record on the linked issue or its
# native sub-issue parent (not body text, and not an issue cited only in the ADR).
# Otherwise the script posts
# "blocked: ADR accepted without a verified decision-request" and exits 1.
# It does not merge in either merge mode.
#
# CI: exit 0 green, 1 real failure, 3 pending, 4 quota with no local test command.
# Quota (wait-ci exit 4 only) runs checks.install/lint/typecheck/test/build in a
# clean worktree at the PR head. Local check failure is exit 1. With merge:auto,
# a pass and a stable head SHA may merge without a human (ADR 0003).
# merge:human waits. Agents do not supply this result.
#
# Before deleting the merged head branch, retargets open PRs that used it as base
# (avoids GitHub closing dependents with base_ref_deleted).
#
# Usage:
#   merge-if-ready.sh --repo OWNER/NAME --pr N [--issue N] [--config PATH] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="" PR="" ISSUE="" CONFIG="" DRY=0 CLEANUP_WT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --cleanup-worktree) CLEANUP_WT="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") --repo OWNER/NAME --pr N [--issue N] [--config PATH] [--cleanup-worktree PATH] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "need --repo --pr" >&2; exit 2; }

RESOLVED="$(resolve_config "${CONFIG:-.relentless/config.json}" "$REPO" || true)"  # intentional fail-soft
CONFIG="${RESOLVED:-}"

# layers.merge false: do not merge. A missing config keeps the previous behavior.
# No layers object means an install from before layers, so merge stays on.
if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
  if ! layer_enabled merge "$CONFIG"; then
    echo "merge layer is off; merge:auto has no effect" >&2
    exit 1
  fi
fi

if [[ -z "$ISSUE" ]]; then
  ISSUE="$(gh pr view "$PR" --repo "$REPO" --json closingIssuesReferences -q '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)"  # intentional fail-soft
  if [[ -z "$ISSUE" ]]; then
    ISSUE="$(gh pr view "$PR" --repo "$REPO" --json body -q .body | grep -oiE 'closes[[:space:]]+#([0-9]+)' | head -1 | grep -oE '[0-9]+' || true)"  # intentional fail-soft
  fi
fi
[[ -n "$ISSUE" ]] || { echo "error: could not resolve linked issue; pass --issue N" >&2; exit 1; }

MODE="$(resolve_merge_mode "$REPO" "$ISSUE" "$CONFIG")"
echo "merge mode: $MODE (issue #$ISSUE, PR #$PR)"

LABELS="$(gh api "repos/${REPO}/issues/${ISSUE}" --jq '[.labels[].name] | join("\n")')"
if ! echo "$LABELS" | grep -Fxq "review:approved"; then
  echo "error: issue #$ISSUE missing review:approved — run isolated reviewer first" >&2
  exit 1
fi

PR_JSON="$(gh pr view "$PR" --repo "$REPO" --json headRefOid,headRefName,baseRefName,state)"
HEAD_SHA="$(jq -r .headRefOid <<<"$PR_JSON")"
HEAD_REF="$(jq -r .headRefName <<<"$PR_JSON")"
BASE_REF="$(jq -r .baseRefName <<<"$PR_JSON")"
echo "head SHA: $HEAD_SHA (branch=$HEAD_REF → $BASE_REF)"

# Exactly one ADRs: line, checked before merge:human and merge:auto.
# A refusal exits 1 and does not add, remove, or replace labels (including review:approved).
check_pr_adrs_line() {
  local body rc line trimmed rest reason path got n raw old_ifs
  local -a decl paths
  set +e
  body="$(gh pr view "$PR" --repo "$REPO" --json body -q .body 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "error: could not read PR #${PR} body; refusing merge (ADRs: line)." >&2
    exit 1
  fi
  body="${body//$'\r'/}"
  # gh --jq prints the JSON token null when the body field is JSON null.
  if [[ "$body" == "null" ]]; then
    body=""
  fi
  decl=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" == ADRs:* ]]; then
      decl+=("$trimmed")
    fi
  done <<<"$body"
  n=${#decl[@]}
  if [[ "$n" -eq 0 ]]; then
    echo "error: PR #${PR} body is missing the required ADRs: line. Refusing merge." >&2
    echo "Required exactly once: \`ADRs: docs/decisions/adr/NNNN-slug.md[, …]\` or \`ADRs: none (<reason>)\`." >&2
    exit 1
  fi
  if [[ "$n" -gt 1 ]]; then
    echo "error: PR #${PR} body contains the ADRs: line more than once (${n} lines). Refusing merge." >&2
    exit 1
  fi
  rest="${decl[0]#ADRs:}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  rest="${rest%"${rest##*[![:space:]]}"}"
  if [[ "$rest" == none || "$rest" == none\ * || "$rest" == none\(* ]]; then
    reason=""
    if [[ "$rest" =~ ^none[[:space:]]+\((.*)\)$ ]]; then
      reason="${BASH_REMATCH[1]}"
      reason="${reason#"${reason%%[![:space:]]*}"}"
      reason="${reason%"${reason##*[![:space:]]}"}"
    fi
    if [[ -z "$reason" ]]; then
      echo "error: PR #${PR} body has \`ADRs: none\` without a reason in parentheses. Refusing merge." >&2
      echo "Use \`ADRs: none (<reason>)\`." >&2
      exit 1
    fi
    return 0
  fi
  paths=()
  old_ifs="$IFS"
  IFS=','
  read -r -a paths <<< "$rest"
  IFS="$old_ifs"
  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "error: PR #${PR} ADRs: line lists no ADR paths. Refusing merge." >&2
    exit 1
  fi
  for raw in "${paths[@]}"; do
    path="${raw#"${raw%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    if [[ ! "$path" =~ ^docs/decisions/adr/[0-9]{4}-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]]; then
      echo "error: PR #${PR} ADRs: line lists invalid path \`${path}\`. Refusing merge." >&2
      echo "Expected \`docs/decisions/adr/NNNN-slug.md\` paths, or \`ADRs: none (<reason>)\`." >&2
      exit 1
    fi
    set +e
    got="$(gh api "repos/${REPO}/contents/${path}?ref=${HEAD_SHA}" --jq .path 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -ne 0 || "$got" != "$path" ]]; then
      echo "error: ADRs: path ${path} does not exist at PR head ${HEAD_SHA}. Refusing merge." >&2
      exit 1
    fi
  done
  return 0
}

# decide.sh writes author=human for decider.name plus relentless:decision option=.
# A decision-request marker, "Decided by" prose, or an agent comment is not enough.
# Issues named only inside the ADR are ignored: the agent writes that file.
issue_has_verified_decision() {
  local num="$1" comments="" decider_name="" needle=""
  if [[ -n "${CONFIG:-}" && -f "$CONFIG" ]]; then
    decider_name="$(jq -r '.decider.name // empty' "$CONFIG" 2>/dev/null || true)"  # intentional fail-soft
  fi
  [[ -n "$decider_name" && "$decider_name" != "null" ]] || return 1
  set +e
  comments="$(gh api --paginate "repos/${REPO}/issues/${num}/comments" --jq '.[].body' 2>/dev/null)"
  local crc=$?
  set -e
  if [[ $crc -ne 0 ]]; then
    return 1
  fi
  needle="relentless:author=human decider=\"${decider_name}\""
  printf '%s\n' "$comments" | grep -F -q -- "$needle" || return 1
  printf '%s\n' "$comments" | grep -E -q -- 'relentless:decision[[:space:]]+option=' || return 1
  return 0
}

# Parent epic: GitHub native sub-issue parent only.
# Parent:/Epic:/Part of lines are not read; agents write those.
collect_parent_issues() {
  local pnum=""
  # intentional fail-soft: 404 means this issue is not a sub-issue
  pnum="$(gh api "repos/${REPO}/issues/${ISSUE}/parent" --jq '.number // empty' 2>/dev/null)" || pnum=""
  if [[ "$pnum" == "null" ]]; then
    pnum=""
  fi
  if [[ "$pnum" =~ ^[0-9]+$ && "$pnum" != "$ISSUE" ]]; then
    printf '%s\n' "$pnum"
  fi
}

post_adr_decision_blocked() {
  local body="" f="" n=""
  body=$(cat <<EOF
🤖 blocked: ADR accepted without a verified decision-request

<!-- relentless:author=agent -->
<!-- relentless:adr-decision-blocked -->

blocked: ADR accepted without a verified decision-request

ADRs:
EOF
)
  for f in "$@"; do
    body+=$'\n'"- https://github.com/${REPO}/blob/${HEAD_SHA}/${f}"
  done
  body+=$'\n\n'"Issues checked:"
  for n in "${CHECKED_ISSUES[@]}"; do
    body+=$'\n'"- https://github.com/${REPO}/issues/${n}"
  done
  echo "blocked: ADR accepted without a verified decision-request" >&2
  echo "ADRs: $*" >&2
  echo "Issues checked: ${CHECKED_ISSUES[*]}" >&2
  echo "Agents must not accept ADRs. The decider runs decide.sh in their own terminal, outside the agent session." >&2
  if [[ "$DRY" -eq 0 ]]; then
    gh pr comment "$PR" --repo "$REPO" --body "$body"
  fi
  exit 1
}

# Accepted ADRs need a verified decide.sh record on the linked issue or its native sub-issue parent.
check_accepted_adr_decision_requests() {
  local files="" rc=0 f="" b64="" text="" status="" parent=""
  local -a accepted=()
  CHECKED_ISSUES=()
  set +e
  files="$(gh api --paginate "repos/${REPO}/pulls/${PR}/files" --jq '.[].filename' 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    # intentional fail-soft: a files-API outage must not block every merge; the guard runs when the list is available
    echo "warn: could not list PR files; skipped accepted-ADR decision-request check" >&2
    return 0
  fi
  while IFS= read -r f; do
    [[ "$f" == docs/decisions/adr/*.md ]] || continue
    set +e
    b64="$(gh api "repos/${REPO}/contents/${f}?ref=${HEAD_SHA}" --jq .content 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -ne 0 || -z "$b64" ]]; then
      echo "error: could not read ${f} at ${HEAD_SHA}; refusing merge (accepted-ADR check)" >&2
      exit 1
    fi
    # intentional fail-soft: undecodable content is not an accepted ADR
    text="$(printf '%s' "$b64" | tr -d '[:space:]' | base64 -d 2>/dev/null || true)"
    status="$(printf '%s\n' "$text" | sed -n 's/^- \*\*Status:\*\*[[:space:]]*//p' | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '\r')"
    [[ "$status" == "accepted" ]] || continue
    accepted+=("$f")
  done <<<"$files"
  if [[ ${#accepted[@]} -eq 0 ]]; then
    return 0
  fi
  CHECKED_ISSUES=("$ISSUE")
  if issue_has_verified_decision "$ISSUE"; then
    return 0
  fi
  while IFS= read -r parent; do
    [[ "$parent" =~ ^[0-9]+$ ]] || continue
    CHECKED_ISSUES+=("$parent")
    if issue_has_verified_decision "$parent"; then
      return 0
    fi
  done < <(collect_parent_issues)
  post_adr_decision_blocked "${accepted[@]}"
}

# Latest review-verdict comment only. Compare its sha attribute to the full headRefOid.
# No SHA, or a different SHA, refuses the merge and removes review:approved.
# --dry-run prints that removal and does not call the API.
drop_review_approved() {
  local why="$1"
  if [[ "$DRY" -eq 1 ]]; then
    echo "dry-run: would remove review:approved from issue #${ISSUE}. ${why} Refusing merge." >&2
    exit 1
  fi
  if ! gh api -X DELETE "repos/${REPO}/issues/${ISSUE}/labels/review%3Aapproved" >/dev/null; then
    echo "error: ${why} Could not remove review:approved. Refusing merge." >&2
    exit 1
  fi
  echo "error: ${why} Removed review:approved. Refusing merge." >&2
  exit 1
}

check_reviewed_head_sha() {
  local json="" rc=0 verdict_body="" sha="" sha_re=""
  set +e
  # intentional: stderr is replaced by the refusal below when comments cannot be read
  json="$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$json" ]]; then
    echo "error: could not read review verdict comments on PR #${PR}. Refusing merge. Run a fresh review." >&2
    exit 1
  fi
  set +e
  # intentional: a comments payload that is not a JSON array is a refused merge below
  verdict_body="$(printf '%s' "$json" | jq -r '[.[] | select((.body // "") | contains("relentless:review-verdict"))] | sort_by(.created_at // "") | last | .body // empty' 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "error: could not read review verdict comments on PR #${PR}. Refusing merge. Run a fresh review." >&2
    exit 1
  fi
  if [[ -z "$verdict_body" ]]; then
    drop_review_approved "PR #${PR} has no review verdict comment with a reviewed SHA. Run a fresh review."
  fi
  sha=""
  # Stored in a variable so the angle bracket is part of the regex, not a redirect.
  sha_re='relentless:review-verdict[^>]*sha="([0-9a-fA-F]+)"'
  if [[ "$verdict_body" =~ $sha_re ]]; then
    sha="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$sha" ]]; then
    drop_review_approved "Latest review verdict on PR #${PR} has no reviewed SHA. Run a fresh review."
  fi
  if [[ "$sha" != "$HEAD_SHA" ]]; then
    drop_review_approved "PR #${PR} head ${HEAD_SHA} does not match reviewed SHA ${sha}."
  fi
}

check_reviewed_head_sha
check_pr_adrs_line
check_accepted_adr_decision_requests

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

config_check_cmd() {
  local key="$1" cmd=""
  [[ -n "${CONFIG:-}" && -f "$CONFIG" ]] || return 0
  cmd="$(jq -r --arg k "$key" '.checks[$k] // empty' "$CONFIG" 2>/dev/null || true)"  # intentional fail-soft
  [[ "$cmd" == "null" ]] && cmd=""
  trim_ws "$cmd"
}

# checks.test when set; else npm test when the worktree package.json has scripts.test.
# Rooted at the PR head checkout. Used when Actions quota skips CI.
resolve_local_test_command() {
  local root="$1" cmd="" pkg=""
  cmd="$(config_check_cmd test)"
  if [[ -n "$cmd" ]]; then
    printf '%s' "$cmd"
    return 0
  fi
  if [[ -f "${root}/package.json" ]] && command -v jq >/dev/null 2>&1; then
    pkg="$(jq -r '.scripts.test // empty' "${root}/package.json" 2>/dev/null || true)"  # intentional fail-soft
    [[ "$pkg" == "null" ]] && pkg=""
    pkg="$(trim_ws "$pkg")"
    if [[ -n "$pkg" ]]; then
      printf '%s' "npm test"
    fi
  fi
}

LOCAL_WT=""
cleanup_local_wt() {
  local wt="${LOCAL_WT:-}"
  [[ -n "$wt" ]] || return 0
  LOCAL_WT=""
  if [[ -d "$wt" ]]; then
    # intentional fail-soft: the temp worktree may already have been removed
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "$wt"
  fi
}

mark_quota_no_local_checks() {
  local name="decider" f=""
  cleanup_local_wt
  if [[ -n "${CONFIG:-}" && -f "$CONFIG" ]]; then
    name="$(jq -r '.decider.name // "decider"' "$CONFIG" 2>/dev/null || echo decider)"  # intentional fail-soft
    [[ "$name" == "null" || -z "$name" ]] && name="decider"
  fi
  echo "CI unavailable (quota), no local checks" >&2
  if [[ "$DRY" -eq 1 ]]; then
    echo "would label human:pending for ${name}; not merging" >&2
    exit 4
  fi
  f="$(mktemp)"
  cat >"$f" <<EOF
🤖 CI indisponível: cota do Actions esgotada

<!-- relentless:author=agent -->
<!-- relentless:decision-request -->

## Question
${name}: Actions minutes are exhausted and this repo has no local test command. How should we proceed?

Reason: \`CI unavailable (quota), no local checks\`

CI indisponível: cota do Actions esgotada

## Context
\`wait-ci\` classified the run as CI unavailable (quota). \`checks.test\` is empty and there is no npm test fallback at the PR head, so merge-if-ready will not merge.

## Options

### 1. Wait for Actions minutes or raise the spending limit
- **Pros:** the next run is real CI
- **Cons:** this PR stays blocked until the quota returns

### 2. Add a self-hosted runner
- **Pros:** Actions CI keeps running without hosted minutes
- **Cons:** a machine to maintain

### 3. A person runs the checks and merges under merge:human
- **Pros:** unblocks this PR
- **Cons:** not an agent merge

## Recommendation
**Option 2** — a self-hosted runner is how to keep real CI. Decider: ${name}.
EOF
  if [[ -n "${CONFIG:-}" ]]; then
    "${SCRIPT_DIR}/request-decision.sh" --repo "$REPO" --issue "$ISSUE" --body-file "$f" --config "$CONFIG"
  else
    "${SCRIPT_DIR}/request-decision.sh" --repo "$REPO" --issue "$ISSUE" --body-file "$f"
  fi
  rm -f "$f"
  exit 4
}

# Runs only after wait-ci.sh exits 4. Never trusts an agent comment.
# Returns 0 when every configured check passed on this head SHA.
run_local_checks_for_quota() {
  local wt="" test_cmd="" key="" cmd="" log="" rc=0 failed=0
  local report="" trunc="" new_json="" new_sha="" comment=""
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: local checks need a git checkout; not merging" >&2
    exit 1
  fi
  if ! git cat-file -e "${HEAD_SHA}^{commit}" >/dev/null 2>&1; then
    git fetch --no-tags origin "$HEAD_SHA" \
      || git fetch --no-tags origin "pull/${PR}/head" \
      || {
        echo "error: PR head ${HEAD_SHA} is not available locally; not merging" >&2
        exit 1
      }
  fi
  wt="$(mktemp -d "${TMPDIR:-/tmp}/relentless-local-checks.XXXXXX")"
  LOCAL_WT="$wt"
  trap cleanup_local_wt RETURN
  if ! git worktree add --detach "$wt" "$HEAD_SHA" >/dev/null; then
    cleanup_local_wt
    echo "error: could not check out ${HEAD_SHA} for local checks; not merging" >&2
    exit 1
  fi
  test_cmd="$(resolve_local_test_command "$wt")"
  if [[ -z "$test_cmd" ]]; then
    mark_quota_no_local_checks
  fi
  report="$(mktemp)"
  for key in install lint typecheck test build; do
    if [[ "$key" == "test" ]]; then
      cmd="$test_cmd"
    else
      cmd="$(config_check_cmd "$key")"
    fi
    [[ -n "$cmd" ]] || continue
    log="$(mktemp)"
    set +e
    ( cd "$wt" && bash -c "$cmd" ) >"$log" 2>&1
    rc=$?
    set -e
    trunc="$(tail -n 20 "$log" | head -c 800)"
    {
      echo "- \`${cmd}\` exit ${rc}"
      echo
      echo '```'
      printf '%s\n' "$trunc"
      echo '```'
    } >>"$report"
    rm -f "$log"
    if [[ "$rc" -ne 0 ]]; then
      failed=1
      echo "local checks failed (exit ${rc}): ${cmd}" >&2
      printf '%s\n' "$trunc" >&2
      break
    fi
  done
  cleanup_local_wt
  if [[ "$failed" -ne 0 ]]; then
    rm -f "$report"
    echo "CI: failed" >&2
    exit 1
  fi
  comment=$(cat <<EOF
🤖 merge sem CI: CI unavailable (quota)

<!-- relentless:author=agent -->
<!-- relentless:local-checks -->

merge sem CI: CI unavailable (quota)

Tested head SHA: \`${HEAD_SHA}\`

$(cat "$report")
EOF
)
  rm -f "$report"
  if [[ "$DRY" -eq 1 ]]; then
    echo "local checks passed on ${HEAD_SHA}"
    echo "$comment"
    return 0
  fi
  gh pr comment "$PR" --repo "$REPO" --body "$comment"
  gh issue edit "$ISSUE" --repo "$REPO" --add-label "ci:local"
  new_json="$(gh pr view "$PR" --repo "$REPO" --json headRefOid)"
  new_sha="$(jq -r '.headRefOid // empty' <<<"$new_json")"
  if [[ -z "$new_sha" || "$new_sha" != "$HEAD_SHA" ]]; then
    # intentional: still refuse the merge when the label API fails
    if ! gh issue edit "$ISSUE" --repo "$REPO" --remove-label "ci:local"; then
      echo "warn: could not remove ci:local after the head SHA changed" >&2
    fi
    echo "error: head SHA changed (${HEAD_SHA} -> ${new_sha:-unknown}); local checks invalid; not merging" >&2
    exit 1
  fi
  echo "local checks passed on ${HEAD_SHA}"
  return 0
}

# Poll wait-ci.sh. Quota (4) and real failure (1) are not retried.
wait_ci() {
  local tries=0
  local max="${MERGE_CI_TRIES:-36}"
  local sleep_s="${MERGE_CI_SLEEP:-10}"
  local timeout="${MERGE_CI_WAIT_TIMEOUT:-20}"
  local rc=0
  while [[ $tries -lt $max ]]; do
    set +e
    "${SCRIPT_DIR}/wait-ci.sh" --repo "$REPO" --pr "$PR" --timeout-sec "$timeout"
    rc=$?
    # Keep set +e across a non-zero return. With set -e, `return 4` exits the shell
    # and the quota fallback in finish_ci never runs.
    if [[ "$rc" -ne 3 ]]; then
      return "$rc"
    fi
    set -e
    echo "CI: pending (try $((tries+1))/$max) — this poll stays in the foreground"
    tries=$((tries + 1))
    if [[ $tries -ge $max ]]; then
      break
    fi
    sleep "$sleep_s"
  done
  echo "CI: pending — checks not green yet. Re-run merge-if-ready.sh in the foreground on the next step (exit 3)." >&2
  set +e
  return 3
}

# Exit 1 on a real red run (no local fallback). On quota, run checks here.
finish_ci() {
  local rc=0
  set +e
  wait_ci
  rc=$?
  set -e
  case "$rc" in
    0) return 0 ;;
    4) run_local_checks_for_quota; return 0 ;;
    *) exit "$rc" ;;
  esac
}

# Retarget open PRs whose base is HEAD_REF onto new_base. Returns 1 if any remain.
retarget_dependents() {
  local head="$1" new_base="$2"
  local deps dep_num failed=0
  deps="$(gh pr list --repo "$REPO" --state open --base "$head" --json number -q '.[].number' 2>/dev/null || true)"  # intentional fail-soft
  if [[ -z "$deps" ]]; then
    echo "stacked PRs: none open with base=$head"
    return 0
  fi
  echo "stacked PRs: retargeting onto $new_base before deleting $head:"
  while IFS= read -r dep_num; do
    [[ -n "$dep_num" ]] || continue
    echo "  PR #$dep_num: base $head → $new_base"
    if [[ "$DRY" -eq 1 ]]; then
      echo "  dry-run: would gh pr edit $dep_num --base $new_base"
      continue
    fi
    if gh pr edit "$dep_num" --repo "$REPO" --base "$new_base"; then
      echo "  retargeted PR #$dep_num"
    else
      echo "warn: failed to retarget PR #$dep_num" >&2
      failed=1
    fi
  done <<<"$deps"
  return "$failed"
}

if [[ "$MODE" == "human" ]]; then
  BODY=$(cat <<COMMENT
🤖 Ready to merge (policy: human)

<!-- relentless:author=agent -->
<!-- relentless:ready-to-merge -->

PR #${PR} has \`review:approved\`. Merge mode is **human** — waiting for a person to merge.
Head: \`${HEAD_SHA}\`.
COMMENT
)
  if [[ "$DRY" -eq 1 ]]; then
    echo "dry-run: would comment ready-to-merge and wait"
    echo "$BODY"
    exit 0
  fi
  finish_ci
  gh pr comment "$PR" --repo "$REPO" --body "$BODY"
  echo "Posted ready-to-merge; not merging (merge:human)."
  exit 0
fi

finish_ci

if [[ "$DRY" -eq 1 ]]; then
  echo "dry-run: would retarget dependents of $HEAD_REF → $BASE_REF, then merge + delete-branch (if safe), state:done, close #$ISSUE"
  retarget_dependents "$HEAD_REF" "$BASE_REF" || true  # intentional fail-soft
  exit 0
fi

# One flag the repo allows. Merge commit when it is allowed, otherwise squash, otherwise rebase.
# If the repo's allowed methods cannot be read, exit. Never assume a merge commit.
choose_merge_flag() {
  local raw err merge squash rebase
  err="$(mktemp)"
  if ! raw="$(gh api "repos/${REPO}" --jq '{allow_merge_commit,allow_squash_merge,allow_rebase_merge}' 2>"$err")"; then
    echo "error: could not read allowed merge methods for ${REPO}: $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    exit 1
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "object" and has("allow_merge_commit") and has("allow_squash_merge") and has("allow_rebase_merge")' >/dev/null 2>&1; then
    echo "error: could not read allowed merge methods for ${REPO}: $(tr '\n' ' ' <"$err") ${raw}" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  merge="$(printf '%s' "$raw" | jq -r '.allow_merge_commit')"
  squash="$(printf '%s' "$raw" | jq -r '.allow_squash_merge')"
  rebase="$(printf '%s' "$raw" | jq -r '.allow_rebase_merge')"
  if [[ "$merge" == "true" ]]; then
    printf '%s\n' '--merge'
    return 0
  fi
  if [[ "$squash" == "true" ]]; then
    printf '%s\n' '--squash'
    return 0
  fi
  if [[ "$rebase" == "true" ]]; then
    printf '%s\n' '--rebase'
    return 0
  fi
  echo "error: could not read allowed merge methods for ${REPO}: repo allows none" >&2
  exit 1
}

# Retarget FIRST so --delete-branch cannot close dependents with base_ref_deleted
retarget_dependents "$HEAD_REF" "$BASE_REF" || true  # intentional fail-soft
remaining="$(gh pr list --repo "$REPO" --state open --base "$HEAD_REF" --json number -q '.[].number' 2>/dev/null || true)"  # intentional fail-soft
MERGE_FLAG="$(choose_merge_flag)"
if [[ -z "$remaining" ]]; then
  gh pr merge "$PR" --repo "$REPO" "$MERGE_FLAG" --delete-branch 2>/dev/null || \
    gh pr merge "$PR" --repo "$REPO" "$MERGE_FLAG"
else
  echo "warn: dependents still base=$HEAD_REF ($remaining) — merging WITHOUT --delete-branch" >&2
  gh pr merge "$PR" --repo "$REPO" "$MERGE_FLAG"
fi

set_issue_state "$REPO" "$ISSUE" "state:done" 1
STATE="$(gh api "repos/${REPO}/issues/${ISSUE}" --jq .state)"
if [[ "$STATE" == "open" ]]; then
  gh issue close "$ISSUE" --repo "$REPO" --comment "🤖 Closed after auto-merge of PR #${PR}

<!-- relentless:author=agent -->
<!-- relentless:merged -->
" || true  # intentional fail-soft
fi

gh pr comment "$PR" --repo "$REPO" --body "🤖 Auto-merged per policy \`auto\`

<!-- relentless:author=agent -->
<!-- relentless:merged mode=\"auto\" -->
" 2>/dev/null || true  # intentional fail-soft

echo "Merged PR #${PR}; issue #${ISSUE} → state:done"

if [[ -n "$CLEANUP_WT" ]]; then
  if [[ "$DRY" -eq 1 ]]; then
    echo "dry-run: would worktree-cleanup --path $CLEANUP_WT"
  else
    "${SCRIPT_DIR}/worktree-cleanup.sh" --path "$CLEANUP_WT" --repo "$REPO" || echo "warn: worktree cleanup failed for $CLEANUP_WT" >&2
  fi
fi
