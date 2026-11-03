#!/usr/bin/env bash
# M9 — with layers.review on, an implementer cannot apply the verdict or merge.
# The hook script is the one both harnesses register. It is not stubbed.
#
# Real harness contract:
# - hooks/hooks.json command (Claude plugin.json and Codex .codex-plugin/plugin.json
#   and plugin.json com.openai.hooks all point at this file):
#   bash "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-.}}/hooks/scripts/pretool-reviewer-isolation.sh"
# - The hook reads RELENTLESS_ROLE, else CODEX_THREAD_ROLE, plus CLAUDE_AGENT and AGENT_NAME.
# - The worktrees layer sets RELENTLESS_ROLE=implementer and RELENTLESS_WORKTREE.
#
# Simulated (no Claude or Codex process is started):
# - Claude stdin is the PreToolUse shape this hook parses: tool_input.command,
#   plus hook_event_name and tool_name.
# - Codex uses the same registered command. This repo does not record a second
#   payload schema, so the Codex case sends the same tool_input.command object
#   and sets PLUGIN_ROOT plus CODEX_THREAD_ROLE (RELENTLESS_ROLE unset) so the
#   hook's Codex role variable is what identifies the implementer.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command' "$ROOT/hooks/hooks.json" | grep reviewer-isolation)"
if [[ "$cmd" != *'pretool-reviewer-isolation.sh'* ]]; then
  bad "M9 could not read the registered hook command: $cmd"
  echo "pass=$PASS fail=$FAIL"
  exit 1
fi

git -C "$TMP" init -q -b develop repo
git -C "$TMP/repo" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
mkdir -p "$TMP/repo/.relentless"
printf '%s\n' '{"layers":{"review":true,"worktrees":true}}' >"$TMP/repo/.relentless/config.json"

run_hook() { # env-prefix command-string
  local envline="$1" command_text="$2"
  local payload
  payload="$(jq -n --arg c "$command_text" '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$TMP/repo"
    printf '%s' "$payload" | env $envline bash -c "$cmd" >/dev/null 2>&1
    echo $?
  )
}

claude_env="CLAUDE_PLUGIN_ROOT=$ROOT RELENTLESS_ROLE=implementer RELENTLESS_WORKTREE=$TMP/repo"
codex_env="-u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT=$ROOT CODEX_THREAD_ROLE=implementer RELENTLESS_WORKTREE=$TMP/repo"

for pair in \
  "claude|$claude_env|core/scripts/apply-review-verdict.sh --pr 3 --verdict approved" \
  "claude|$claude_env|gh pr merge 3 --squash" \
  "codex|$codex_env|core/scripts/apply-review-verdict.sh --pr 3 --verdict approved" \
  "codex|$codex_env|gh pr merge 3 --merge"; do
  IFS='|' read -r harness envline command_text <<<"$pair"
  rc="$(run_hook "$envline" "$command_text")"
  if [[ "$rc" -eq 2 ]]; then
    ok
  else
    bad "M9 $harness '$command_text' exited $rc, want 2"
  fi
done

rc="$(run_hook "$claude_env" "git push -u origin feat/1-x")"
if [[ "$rc" -eq 0 ]]; then
  ok
else
  bad "M9 claude git push should stay allowed, exited $rc"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
