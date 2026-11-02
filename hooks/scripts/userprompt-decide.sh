#!/usr/bin/env bash
# UserPromptSubmit: if the human typed /decide, record the decision here.
# The agent never needs to call decide.sh. Invoking this script from a Bash
# tool is blocked by pretool-gh-workflow.sh when an agent role is set.
#
# Stdin is the Claude hook JSON. A prompt that is not /decide exits 0 with no output.
set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"  # intentional: empty stdin ok
PROMPT=""
CWD=""
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
  PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"  # intentional fail-soft
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"  # intentional fail-soft
fi

[[ -n "$CWD" && -d "$CWD" ]] && cd "$CWD"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

prompt="$(trim "$PROMPT")"
case "$prompt" in
  /decide|/decide\ *|/relentless:decide|/relentless:decide\ *) ;;
  *) exit 0 ;;
esac

emit() {
  local text="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg text "$text" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$text}}'
  else
    printf '%s\n' "$text" >&2
  fi
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HOOK_DIR}/../.." && pwd)"
# shellcheck source=../../core/scripts/lib/common.sh
source "${ROOT}/core/scripts/lib/common.sh"
# shellcheck source=../../core/scripts/lib/human-decision.sh
source "${ROOT}/core/scripts/lib/human-decision.sh"

tokenize() {
  local s="$1"
  local i=0 len=${#s} cur="" quote="" c
  while [[ $i -lt $len ]]; do
    c="${s:i:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$c" == "$quote" ]]; then quote=""; else cur+="$c"; fi
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == "'" || "$c" == '"' ]]; then
      quote="$c"
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == " " || "$c" == $'\t' ]]; then
      if [[ -n "$cur" ]]; then printf '%s\n' "$cur"; cur=""; fi
      i=$((i + 1))
      continue
    fi
    cur+="$c"
    i=$((i + 1))
  done
  [[ -n "$cur" ]] && printf '%s\n' "$cur"
  return 0
}

PARTS=()
while IFS= read -r part; do
  PARTS+=("$part")
done < <(tokenize "$prompt")
ISSUE="${PARTS[1]:-}"
OPTION="${PARTS[2]:-}"
if [[ -z "$ISSUE" || -z "$OPTION" ]]; then
  emit "Relentless did not record a decision: /decide needs an issue number and an option number. Example: /decide 12 1. The agent must not run decide.sh. From a terminal outside the agent session: core/scripts/decide.sh --repo OWNER/NAME --issue N --option K"
  exit 0
fi

NOTE=""
ADR=""
CREATE_ADR=0
TITLE=""
SLUG=""
NO_ADR=0
WORKDIR="$(pwd)"
CONFIG=""
REPO=""
i=3
while [[ $i -lt ${#PARTS[@]} ]]; do
  p="${PARTS[$i]}"
  case "$p" in
    --adr) i=$((i + 1)); ADR="${PARTS[$i]:-}" ;;
    --create-adr) CREATE_ADR=1 ;;
    --title) i=$((i + 1)); TITLE="${PARTS[$i]:-}" ;;
    --slug) i=$((i + 1)); SLUG="${PARTS[$i]:-}" ;;
    --no-adr) NO_ADR=1 ;;
    --note) i=$((i + 1)); NOTE="${PARTS[$i]:-}" ;;
    --repo) i=$((i + 1)); REPO="${PARTS[$i]:-}" ;;
    *) NOTE="${NOTE:+$NOTE }${p}" ;;
  esac
  i=$((i + 1))
done

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"  # intentional fail-soft
fi
if [[ -z "$REPO" ]]; then
  emit "Relentless did not record a decision: could not resolve OWNER/NAME. The agent must not run decide.sh. From a terminal outside the agent session: core/scripts/decide.sh --repo OWNER/NAME --issue ${ISSUE} --option ${OPTION}"
  exit 0
fi

set +e
msg="$(relentless_record_decision 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  emit "Relentless did not record the decision (${msg}). Do not retry from the agent. From a terminal outside the agent session: core/scripts/decide.sh --repo ${REPO} --issue ${ISSUE} --option ${OPTION}"
  exit 0
fi
emit "Relentless recorded this /decide from the human prompt. Do not run decide.sh, accept-adr.sh, or write Decided by. ${msg}"
