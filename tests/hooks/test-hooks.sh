#!/usr/bin/env bash
# Regression tests for relentless PreToolUse hooks.
# Each case pipes a Bash tool event and expects exit 2 (block) or 0 (allow).
# Every dangerous command has a nearby legitimate command that must still pass.
#
# Usage: bash tests/hooks/test-hooks.sh
#    or: RELENTLESS_ROOT=/path/to/relentless bash tests/hooks/test-hooks.sh
set -uo pipefail
ROOT="${RELENTLESS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q -b main repo
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP/repo" branch feat/1-x
REPO="$TMP/repo"

PASS=0
FAIL=0
run() { # hook branch env expected cmd
  local hook="$1" br="$2" envs="$3" exp="$4" cmd="$5" got
  git -C "$REPO" checkout -q "$br"
  got=$(
    cd "$REPO" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' |
      env $envs bash "$ROOT/hooks/scripts/$hook" >/dev/null 2>&1
    echo $?
  )
  if [[ "$got" == "$exp" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-32s [%s, %s] expected %s got %s: %s\n' \
      "$hook" "$br" "${envs:-no-role}" "$exp" "$got" "$cmd"
  fi
}

R=pretool-reviewer-isolation.sh
G=pretool-gh-workflow.sh
N="X=1"

# pretool-protect-main is gone. Branch protection and the githooks layer are the lock.
if [[ -e "$ROOT/hooks/scripts/pretool-protect-main.sh" ]] || grep -q 'pretool-protect-main' "$ROOT/hooks/hooks.json"; then
  FAIL=$((FAIL + 1))
  printf 'FAIL pretool-protect-main still registered\n'
else
  PASS=$((PASS + 1))
fi

# reviewer isolation
run $R feat/1-x "RELENTLESS_ROLE=implementer" 2 'gh pr edit 3 --add-label review:approved'
run $R feat/1-x "RELENTLESS_ROLE=implementer" 2 './core/scripts/merge-if-ready.sh --pr 3'
run $R feat/1-x "RELENTLESS_ROLE=implementer" 2 'gh pr merge 3 --squash'
run $R feat/1-x "RELENTLESS_ROLE=implementer" 0 'git push -u origin feat/1-x'
run $R feat/1-x "RELENTLESS_ROLE=implementer" 0 'gh pr create --title x --body "waiting for review:approved"'
run $R feat/1-x "$N" 2 'gh pr edit 3 --add-label review:approved && gh pr merge 3'
run $R feat/1-x "RELENTLESS_ROLE=orchestrator" 0 './core/scripts/merge-if-ready.sh --pr 3'

# Reviewer gh api: one method flag is allowed, including -f/-F on an explicit GET.
# A second -X/--method, or any --input, is blocked. Other roles are not.
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api -X GET repos/o/r/issues/1'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api --method GET repos/o/r/pulls/1'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api -XGET repos/o/r/issues/1'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api --method=GET repos/o/r/issues/1'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api -X GET repos/o/r/issues/1 -f state=open'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api -X GET repos/o/r/issues/1 -F per_page=1'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api --method GET repos/o/r/issues/1 -f state=open'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api --method GET repos/o/r/issues/1 -F per_page=1'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'gh api -X GET foo -f a=1 && gh api --method GET bar -F b=2'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -X GET foo -X POST'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api --method GET foo --method POST'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -X GET foo --method POST'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -XGET foo -XPOST'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api --method=GET foo --method=POST'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -XPOST foo --method=GET'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -X GET foo --input body.json'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api --method GET foo --input body.json'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -X GET foo --input=body.json'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api --input=body.json -X GET foo'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 2 'gh api -X GET foo && gh api -X GET bar -X POST'
run $R feat/1-x "CLAUDE_AGENT=reviewer" 2 'gh api -X GET foo -X POST'
run $R feat/1-x "CLAUDE_AGENT=reviewer" 2 'gh api --method GET foo --input=body.json'
run $R feat/1-x "RELENTLESS_ROLE=reviewer" 0 'git commit -m "docs: gh api -X GET foo -X POST and --input are not a call"'
run $R feat/1-x "RELENTLESS_ROLE=implementer" 0 'gh api -X GET foo -X POST'
run $R feat/1-x "RELENTLESS_ROLE=implementer" 0 'gh api -X GET foo --input body.json'
run $R feat/1-x "RELENTLESS_ROLE=orchestrator" 0 'gh api --method GET foo --method POST'
run $R feat/1-x "RELENTLESS_ROLE=orchestrator" 0 'gh api --input=body.json -X GET foo'
run $R feat/1-x "RELENTLESS_ROLE=qa" 0 'gh api -XGET foo -XPOST'
run $R feat/1-x "$N" 0 'gh api -X GET foo -X POST --input body.json'

# human decision scripts: agents cannot invoke them; quoting the name in a message is not an invocation
run $G feat/1-x "RELENTLESS_ROLE=implementer" 2 'core/scripts/decide.sh --repo o/n --issue 1 --option 1'
run $G feat/1-x "RELENTLESS_ROLE=orchestrator" 2 'core/scripts/accept-adr.sh --file a.md --option 1 --decider Ada'
run $G feat/1-x "RELENTLESS_ROLE=planner" 2 'core/scripts/new-adr.sh --title T --slug s --status accepted'
run $G feat/1-x "RELENTLESS_ROLE=planner" 0 'core/scripts/new-adr.sh --title T --slug s --status proposed'
run $G feat/1-x "RELENTLESS_ROLE=implementer" 2 'env -u RELENTLESS_ROLE core/scripts/decide.sh --repo o/n --issue 1 --option 1'
run $G feat/1-x "RELENTLESS_ROLE=implementer" 2 'RELENTLESS_HUMAN=1 RELENTLESS_DECISION_TOKEN=forge core/scripts/decide.sh --repo o/n --issue 1 --option 1'
run $G feat/1-x "RELENTLESS_ROLE=implementer" 2 'bash hooks/scripts/userprompt-decide.sh'
run $G feat/1-x "CODEX_THREAD_ROLE=implementer" 2 'core/scripts/decide.sh --repo o/n --issue 1 --option 1'
# request-decision.sh is not role-locked. Opening a request is reversible; decide.sh stays blocked.
# Workers are instructed not to run it. The hook still allows every role, including the implementer.
run $G feat/1-x "RELENTLESS_ROLE=implementer" 0 'core/scripts/request-decision.sh --repo o/n --issue 1 --body-file req.md'
run $G feat/1-x "RELENTLESS_ROLE=orchestrator" 0 'core/scripts/request-decision.sh --repo o/n --issue 1 --body-file req.md'
run $G feat/1-x "RELENTLESS_ROLE=qa" 0 'core/scripts/request-decision.sh --repo o/n --issue 1 --body-file req.md'
run $G feat/1-x "RELENTLESS_ROLE=planner" 0 'core/scripts/request-decision.sh --repo o/n --issue 1 --body-file req.md'
run $G feat/1-x "RELENTLESS_ROLE=documenter" 0 'core/scripts/request-decision.sh --repo o/n --issue 1 --body-file req.md'
run $G feat/1-x "RELENTLESS_ROLE=reviewer" 0 'core/scripts/request-decision.sh --repo o/n --issue 1 --body-file req.md'
run $G feat/1-x "RELENTLESS_ROLE=implementer" 0 'git commit -m "docs: tell the decider to run decide.sh themselves"'

# The Stop hook is gone. hooks.json must not register it.
if grep -q 'stop-gate' "$ROOT/hooks/hooks.json" || [[ -e "$ROOT/hooks/scripts/stop-gate.sh" ]]; then
  FAIL=$((FAIL + 1))
  printf 'FAIL stop-gate still registered\n'
else
  PASS=$((PASS + 1))
fi

# Reviewer launch exports the env names the isolation hooks read, before Claude is spawned.
review="$ROOT/core/scripts/run-isolated-review.sh"
role_line="$(grep -n '^export RELENTLESS_ROLE=reviewer$' "$review" | head -1 | cut -d: -f1)"
agent_line="$(grep -n '^export CLAUDE_AGENT=reviewer$' "$review" | head -1 | cut -d: -f1)"
claude_line="$(grep -n 'claude -p' "$review" | head -1 | cut -d: -f1)"
if [[ -n "$role_line" && -n "$agent_line" && -n "$claude_line" \
  && "$role_line" -lt "$claude_line" && "$agent_line" -lt "$claude_line" ]]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL reviewer env export (role=%s agent=%s claude=%s)\n' \
    "${role_line:-missing}" "${agent_line:-missing}" "${claude_line:-missing}"
fi

# Broken config must fail closed (exit 2). Exit 1 does not block PreToolUse.
BAD="$TMP/badcfg"
git -C "$TMP" init -q -b feat/1-x badcfg
git -C "$BAD" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$BAD/.relentless"
printf '%s\n' '{bad' >"$BAD/.relentless/config.json"

wt_err="$(
  cd "$BAD" && jq -n --arg cwd "$BAD" --arg f /etc/x '{cwd:$cwd, tool_input:{file_path:$f}}' |
    env RELENTLESS_ROLE=implementer bash "$ROOT/hooks/scripts/pretool-protect-worktree-write.sh" >/dev/null 2>&1
  echo $?
)"
wt_msg="$(
  cd "$BAD" && jq -n --arg cwd "$BAD" --arg f /etc/x '{cwd:$cwd, tool_input:{file_path:$f}}' |
    env RELENTLESS_ROLE=implementer bash "$ROOT/hooks/scripts/pretool-protect-worktree-write.sh" 2>&1 >/dev/null || true
)"
if [[ "$wt_err" -eq 2 && "$wt_msg" == *"error: ${BAD}/.relentless/config.json failed to parse:"* ]]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL protect-worktree bad config rc=%s msg=%s\n' "$wt_err" "$wt_msg"
fi

rv_err="$(
  cd "$BAD" && jq -n --arg c 'gh api -X POST --input body.json' '{tool_input:{command:$c}}' |
    env RELENTLESS_ROLE=reviewer bash "$ROOT/hooks/scripts/pretool-reviewer-isolation.sh" >/dev/null 2>&1
  echo $?
)"
rv_msg="$(
  cd "$BAD" && jq -n --arg c 'gh api -X POST --input body.json' '{tool_input:{command:$c}}' |
    env RELENTLESS_ROLE=reviewer bash "$ROOT/hooks/scripts/pretool-reviewer-isolation.sh" 2>&1 >/dev/null || true
)"
if [[ "$rv_err" -eq 2 && "$rv_msg" == *"error: ${BAD}/.relentless/config.json failed to parse:"* ]]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL reviewer-isolation bad config rc=%s msg=%s\n' "$rv_err" "$rv_msg"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
