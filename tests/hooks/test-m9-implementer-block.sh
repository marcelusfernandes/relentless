#!/usr/bin/env bash
# M9 — an implementer worktree cannot apply the verdict or merge.
# The signal is .relentless/worktree.json, the marker worktree-create writes.
# The cwd cases set no role env. The Codex cases set only inherited RELENTLESS_ROLE=orchestrator.
# A marker committed on the base is not a signal: gh pr merge from that main
# checkout stays allowed. The untracked marker inside the worktree still blocks.
# The hook script is the one both harnesses register. It is not stubbed.
#
# Live miss (Bash cwd stays on the main checkout):
# - `cd <worktree> && gh pr merge` and `cd "<worktree>"; gh pr merge`
#   must exit 2 and print BLOCKED. The directory is the cd target, not the
#   payload cwd. rc=1 with no BLOCKED line is the miss.
# - Codex can inherit RELENTLESS_ROLE=orchestrator from the parent. That role
#   must not skip the marker when the cwd or the cd target is the worktree.
#   The same role on the main checkout can still merge.
# pushd, bash -c, a subshell, and `gh pr merge -R` with no cd are out of scope.
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
# Options before assignments. run_hook unsets RELENTLESS_ROLE first; this sets
# the parent orchestrator role a Codex child inherits, then the plugin root.
codex_orch="-u CLAUDE_PLUGIN_ROOT RELENTLESS_ROLE=orchestrator PLUGIN_ROOT=$ROOT"

# want_block 1: stderr contains the implementer BLOCKED line. 0: it must not.
expect_rc() { # name cwd env-prefix command want-rc want-block
  local name="$1" cwd="$2" envline="$3" command_text="$4" want="$5" want_block="$6"
  local payload errf rc err blocked=0
  errf="$(mktemp)"
  payload="$(jq -n --arg c "$command_text" --arg cwd "$cwd" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}')"
  rc="$(
    cd "$cwd" && printf '%s' "$payload" | env \
      -u RELENTLESS_ROLE -u CODEX_THREAD_ROLE -u CLAUDE_AGENT -u AGENT_NAME \
      $envline bash -c "$cmd" >/dev/null 2>"$errf"
    echo $?
  )"
  err="$(cat "$errf")"
  rm -f "$errf"
  if printf '%s\n' "$err" | grep -q 'BLOCKED: implementer'; then
    blocked=1
  fi
  if [[ "$rc" -eq "$want" && "$blocked" -eq "$want_block" ]]; then
    ok
  else
    bad "M9 $name '$command_text' exited $rc (blocked=$blocked), want rc=$want blocked=$want_block; stderr=$err"
  fi
}

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
  "codex-push|$TMP/wt|$codex_env|git push -u origin feat/9-login|0" \
  "claude-tracked-main|$TMP/primary|$claude_env|gh pr merge 3 --merge|0" \
  "codex-tracked-main|$TMP/primary|$codex_env|gh pr merge 3 --merge|0"; do
  IFS='|' read -r name cwd envline command_text want <<<"$pair"
  # Commit the marker on the base once, before the two main-checkout cases.
  if [[ "$name" == "claude-tracked-main" ]]; then
    mkdir -p "$TMP/primary/.relentless"
    cat >"$TMP/primary/.relentless/worktree.json" <<JSON
{
  "issue": 1,
  "branch": "main",
  "base": "main",
  "primary": "${TMP}/primary",
  "created_at": "2026-11-03T00:00:00Z"
}
JSON
    git -C "$TMP/primary" add .relentless/worktree.json
    git -C "$TMP/primary" -c user.email=t@example.com -c user.name=Test commit -q -m marker
  fi
  rc="$(run_hook "$cwd" "$envline" "$command_text")"
  if [[ "$rc" -eq "$want" ]]; then
    ok
  else
    bad "M9 $name '$command_text' exited $rc, want $want"
  fi
done

# Bash cwd is the main checkout. The worktree is only the cd target.
expect_rc cd-and "$TMP/primary" "$claude_env" \
  "cd ${TMP}/wt && gh pr merge 3 --squash" 2 1
expect_rc cd-semi "$TMP/primary" "$claude_env" \
  "cd \"${TMP}/wt\"; gh pr merge 3 --squash" 2 1
expect_rc cd-rel "$TMP/primary" "$claude_env" \
  "cd ../wt && gh pr merge 3 --squash" 2 1

# Inherited orchestrator: marker at the cwd, and at the cd target.
expect_rc codex-orch-wt "$TMP/wt" "$codex_orch" \
  "gh pr merge 3 --merge" 2 1
expect_rc codex-orch-cd-and "$TMP/primary" "$codex_orch" \
  "cd ${TMP}/wt && gh pr merge 3 --merge" 2 1
expect_rc codex-orch-cd-semi "$TMP/primary" "$codex_orch" \
  "cd \"${TMP}/wt\"; gh pr merge 3 --merge" 2 1

# Orchestrator on the main checkout. The tracked marker committed above is not a signal.
expect_rc codex-orch-main "$TMP/primary" "$codex_orch" \
  "gh pr merge 3 --merge" 0 0
expect_rc codex-orch-cd-main "$TMP/primary" "$codex_orch" \
  "cd \"${TMP}/primary\" && gh pr merge 3 --merge" 0 0

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
