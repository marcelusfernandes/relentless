#!/usr/bin/env bash
# M9 — an implementer worktree cannot apply the verdict or merge.
# The signal is .relentless/worktree.json, the marker worktree-create writes.
# Neither case sets RELENTLESS_ROLE, CODEX_THREAD_ROLE, CLAUDE_AGENT, or AGENT_NAME.
# The hook script is the one both harnesses register. It is not stubbed.
#
# Real harness contract:
# - hooks/hooks.json command (Claude plugin.json and Codex .codex-plugin/plugin.json
#   and plugin.json com.openai.hooks all point at this file):
#   bash "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-.}}/hooks/scripts/pretool-reviewer-isolation.sh"
# - Claude sets CLAUDE_PLUGIN_ROOT. Codex sets PLUGIN_ROOT.
#
# Simulated (no Claude or Codex process is started):
# - The live proof in each harness is the hexgym run, not this CI test.
# - Stdin is the PreToolUse shape this hook parses (tool_input.command plus cwd).
# - The worktree marker is written the same way worktree-create writes it.
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

git -C "$TMP" init -q -b main primary
git -C "$TMP/primary" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
git -C "$TMP/primary" worktree add -q -b feat/9-login "$TMP/wt" HEAD
mkdir -p "$TMP/wt/.relentless"
cat >"$TMP/wt/.relentless/worktree.json" <<JSON
{
  "issue": 9,
  "branch": "feat/9-login",
  "base": "main",
  "primary": "${TMP}/primary",
  "created_at": "2026-11-03T00:00:00Z"
}
JSON

run_hook() { # cwd env-prefix command-string
  local cwd="$1" envline="$2" command_text="$3" payload
  payload="$(jq -n --arg c "$command_text" --arg cwd "$cwd" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}')"
  (
    cd "$cwd" && printf '%s' "$payload" | env \
      -u RELENTLESS_ROLE -u CODEX_THREAD_ROLE -u CLAUDE_AGENT -u AGENT_NAME \
      $envline bash -c "$cmd" >/dev/null 2>&1
    echo $?
  )
}

claude_env="CLAUDE_PLUGIN_ROOT=$ROOT"
codex_env="-u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT=$ROOT"

for pair in \
  "claude-wt|$TMP/wt|$claude_env|core/scripts/apply-review-verdict.sh --pr 3 --verdict approved|2" \
  "claude-wt|$TMP/wt|$claude_env|gh pr merge 3 --squash|2" \
  "codex-wt|$TMP/wt|$codex_env|core/scripts/apply-review-verdict.sh --pr 3 --verdict approved|2" \
  "codex-wt|$TMP/wt|$codex_env|gh pr merge 3 --merge|2" \
  "claude-main|$TMP/primary|$claude_env|core/scripts/apply-review-verdict.sh --pr 3 --verdict approved|0" \
  "claude-main|$TMP/primary|$claude_env|gh pr merge 3 --squash|0" \
  "codex-main|$TMP/primary|$codex_env|core/scripts/apply-review-verdict.sh --pr 3 --verdict approved|0" \
  "codex-main|$TMP/primary|$codex_env|gh pr merge 3 --merge|0" \
  "claude-push|$TMP/wt|$claude_env|git push -u origin feat/9-login|0" \
  "codex-push|$TMP/wt|$codex_env|git push -u origin feat/9-login|0"; do
  IFS='|' read -r name cwd envline command_text want <<<"$pair"
  rc="$(run_hook "$cwd" "$envline" "$command_text")"
  if [[ "$rc" -eq "$want" ]]; then
    ok
  else
    bad "M9 $name '$command_text' exited $rc, want $want"
  fi
done

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
