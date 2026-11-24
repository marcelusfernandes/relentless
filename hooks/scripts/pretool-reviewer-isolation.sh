#!/usr/bin/env bash
# PreToolUse: block an implementer from applying review:approved / apply-review-verdict / merge-if-ready.
# The signal that reaches this process is an untracked .relentless/worktree.json at the git toplevel
# (this process cwd, the payload cwd, the directory a leading `cd <dir> &&` / `cd <dir>;` enters,
# or RELENTLESS_WORKTREE when the command assigns it).
# Before that cd check, skip leading assignment prefixes: `export NAME=value …;` / `export … &&`,
# a bare `NAME=value …;` segment, `NAME=value` words on the same simple command, and
# `env NAME=value … cmd`. A backslash-newline between those assignments is whitespace.
# RELENTLESS_ROLE=implementer in that prefix is an implementer signal even with no marker.
# Role env vars are an extra signal. Reviewer, qa, planner, and documenter stay on their own path.
# An inherited orchestrator role does not override a marker or a command that sets implementer.
# Claude/Codex: exit 2 = block.
#
# Avoid false positives on docs/heredocs that merely *mention* approval or merge:
# strip heredoc bodies before matching, and require command-like patterns.
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../core/scripts/lib/common.sh
source "${HOOK_DIR}/../../core/scripts/lib/common.sh"

INPUT="$(cat || true)"  # intentional: empty stdin ok
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)"  # intentional fail-soft
[[ -n "$CMD" ]] || exit 0

# Strip heredoc bodies so prose inside cat >file <<'EOF' … EOF does not match.
strip_heredocs() {
  awk '
    BEGIN { in_h=0; tag="" }
    {
      if (in_h) {
        close_re = "^[[:space:]]*" tag "[[:space:]]*$"
        if ($0 ~ close_re) { in_h=0; tag=""; next }
        next
      }
      if ($0 ~ /<<[-]?[[:space:]]*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/) {
        line = $0
        sub(/^.*<<[-]?[[:space:]]*/, "", line)
        gsub(/['\''"]/, "", line)
        split(line, a, /[^A-Za-z0-9_]/)
        tag = a[1]
        if (tag != "") {
          in_h = 1
          keep = $0
          sub(/<<.*/, "", keep)
          if (keep ~ /[^[:space:]]/) print keep
          next
        }
      }
      print
    }
  '
}

CMD_SCAN="$(printf '%s\n' "$CMD" | strip_heredocs)"

# Drop quoted regions so a message that only mentions gh api is not an invocation.
strip_quoted_regions() {
  local s="$1"
  local i=0 len=${#s} quote="" out="" c
  while [[ $i -lt $len ]]; do
    c="${s:i:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$c" == "$quote" ]]; then quote=""; fi
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == "'" || "$c" == '"' ]]; then
      quote="$c"
      i=$((i + 1))
      continue
    fi
    out+="$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# 0 when this gh api argv has more than one method flag or any --input.
# -X / --method count once each, including -XPOST and --method=POST.
# One explicit GET plus -f/-F is not denied here.
gh_api_args_denied() {
  local method=0 token next
  while [[ $# -gt 0 ]]; do
    token="$1"
    shift
    [[ "$token" == "--" ]] && break
    if [[ "$token" == "--input" || "$token" == --input=* ]]; then
      return 0
    fi
    if [[ "$token" == "-X" || "$token" == "--method" ]]; then
      method=$((method + 1))
      if [[ $# -gt 0 ]]; then
        next="$1"
        if [[ "$next" != -* ]]; then
          shift
        fi
      fi
      continue
    fi
    if [[ "$token" == -X?* || "$token" == --method=* ]]; then
      method=$((method + 1))
      continue
    fi
  done
  [[ "$method" -gt 1 ]]
}

# 0 when any gh api invocation in the command is denied.
reviewer_gh_api_unsafe() {
  local scan line base i j n
  local -a words args
  scan="$(strip_quoted_regions "$CMD_SCAN")"
  scan="${scan//||/$'\n'}"
  scan="${scan//&&/$'\n'}"
  scan="${scan//;/$'\n'}"
  scan="${scan//|/$'\n'}"
  scan="${scan//&/$'\n'}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    words=()
    read -r -a words <<< "$line" || true  # intentional: empty segment
    n=${#words[@]}
    i=0
    while [[ $i -lt $n ]]; do
      base="${words[$i]##*/}"
      if [[ "$base" == "gh" && $((i + 1)) -lt $n && "${words[$((i + 1))]}" == "api" ]]; then
        args=()
        j=$((i + 2))
        while [[ $j -lt $n ]]; do
          args+=("${words[$j]}")
          j=$((j + 1))
        done
        if [[ ${#args[@]} -gt 0 ]] && gh_api_args_denied "${args[@]}"; then
          return 0
        fi
      fi
      i=$((i + 1))
    done
  done <<< "$scan"
  return 1
}

ROLE="${RELENTLESS_ROLE:-${CODEX_THREAD_ROLE:-}}"
AGENT="${CLAUDE_AGENT:-${AGENT_NAME:-}}"

# worktree-create writes this marker. Claude does not export a role into the
# hook process; the worktree brief puts `export RELENTLESS_ROLE=implementer`
# on the command itself. A Codex child can inherit RELENTLESS_ROLE=orchestrator
# from the parent. An untracked marker is still the implementer signal in both
# cases. A tracked marker is on every checkout of that commit, including main, so it
# is not a role signal. protect-worktree-write still treats a present file as
# a worktree for path confinement; that check is not this role check.
worktree_marker_at() {
  local dir="$1" top=""
  [[ -n "$dir" && -d "$dir" ]] || return 1
  if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    top="$(git -C "$dir" rev-parse --show-toplevel)"
  else
    return 1
  fi
  [[ -f "$top/.relentless/worktree.json" ]] || return 1
  if git -C "$top" ls-files --error-unmatch .relentless/worktree.json >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Assignment-prefix scan. Globals: LEAD_ROLE, LEAD_WORKTREE, CMD_BODY,
# ASG_NAME, ASG_VALUE, ASG_REST, HSPACE_S, SEP_REST.
# Values are not evaluated. Quoted values may contain spaces and `;`.

# Spaces, tabs, CR, and a backslash-newline continuation. Not a per-character
# walk of a value: callers only hand this the gap between tokens.
skip_hspace() {
  local c="" n=""
  while [[ -n "$HSPACE_S" ]]; do
    c="${HSPACE_S:0:1}"
    if [[ "$c" == " " || "$c" == $'\t' || "$c" == $'\r' ]]; then
      HSPACE_S="${HSPACE_S:1}"
      continue
    fi
    if [[ "$c" == "\\" ]]; then
      n="${HSPACE_S:1:1}"
      if [[ "$n" == $'\n' ]]; then
        HSPACE_S="${HSPACE_S:2}"
        continue
      fi
      if [[ "$n" == $'\r' ]]; then
        HSPACE_S="${HSPACE_S:2}"
        if [[ "${HSPACE_S:0:1}" == $'\n' ]]; then
          HSPACE_S="${HSPACE_S:1}"
        fi
        continue
      fi
    fi
    break
  done
}

assignment_name_at() {
  local name="${1%%=*}"
  [[ "$1" == *=* ]] || return 1
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

note_lead_assignment() {
  case "$ASG_NAME" in
    RELENTLESS_ROLE) LEAD_ROLE="$ASG_VALUE" ;;
    RELENTLESS_WORKTREE) LEAD_WORKTREE="$ASG_VALUE" ;;
  esac
}

# One NAME=value at the front of $1. Sets ASG_NAME, ASG_VALUE, ASG_REST.
# Slice a value in one expansion. Walking it with rest="${rest:1}" is O(n^2)
# and a 50 KB quote blows the Claude hook timeout (the hook then fails open).
parse_one_assignment() {
  local s="$1" name="" rest="" value="" chunk="" pre_b="" pre_q="" esc="" q=""
  [[ -n "$s" && "$s" == *=* ]] || return 1
  name="${s%%=*}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  rest="${s#"$name"=}"
  if [[ "$rest" == \"* ]]; then
    rest="${rest:1}"
    value=""
    # ${var%%\"*} and ${var#"$long"} are quadratic in this bash. Cut with the
    # quote kept in a variable, then drop the prefix by index.
    q='"'
    while [[ -n "$rest" ]]; do
      if [[ "$rest" != *\\* ]]; then
        if [[ "$rest" == *"$q"* ]]; then
          chunk="${rest%%"$q"*}"
          value+="$chunk"
          rest="${rest:$((${#chunk} + 1))}"
        else
          value+="$rest"
          rest=""
        fi
        break
      fi
      # [\\] is one literal backslash. A bare backslash in the pattern escapes the next character.
      pre_b="${rest%%[\\]*}"
      pre_q="${rest%%"$q"*}"
      if [[ "$rest" == *"$q"* && ${#pre_q} -le ${#pre_b} ]]; then
        value+="$pre_q"
        rest="${rest:$((${#pre_q} + 1))}"
        break
      fi
      value+="$pre_b"
      rest="${rest:$((${#pre_b} + 1))}"
      if [[ -z "$rest" ]]; then
        value+='\'
        break
      fi
      esc="${rest:0:1}"
      rest="${rest:1}"
      if [[ "$esc" == $'\n' || "$esc" == $'\r' ]]; then
        if [[ "$esc" == $'\r' && "${rest:0:1}" == $'\n' ]]; then
          rest="${rest:1}"
        fi
        continue
      fi
      value+="$esc"
    done
  elif [[ "$rest" == \'* ]]; then
    rest="${rest:1}"
    q="'"
    if [[ "$rest" == *"$q"* ]]; then
      value="${rest%%"$q"*}"
      rest="${rest:$((${#value} + 1))}"
    else
      value="$rest"
      rest=""
    fi
  else
    # Leave a trailing backslash in the tail so \<newline> stays a separator.
    value="${rest%%[[:space:];&|\\]*}"
    rest="${rest:${#value}}"
  fi
  ASG_NAME="$name"
  ASG_VALUE="$value"
  ASG_REST="$rest"
}

# One or more NAME=value words. Sets ASG_REST to the unparsed tail.
parse_assignment_list() {
  local n=0
  HSPACE_S="$1"
  skip_hspace
  while assignment_name_at "$HSPACE_S"; do
    parse_one_assignment "$HSPACE_S" || return 1
    note_lead_assignment
    HSPACE_S="$ASG_REST"
    skip_hspace
    n=$((n + 1))
  done
  [[ "$n" -ge 1 ]] || return 1
  ASG_REST="$HSPACE_S"
}

# 0 when $1 begins a `;`, `&&`, or newline separator. Sets SEP_REST.
assignment_separator() {
  local s=""
  HSPACE_S="$1"
  skip_hspace
  s="$HSPACE_S"
  if [[ "$s" == ";"* ]]; then
    SEP_REST="${s#;}"
    return 0
  fi
  if [[ "$s" == "&&"* ]]; then
    SEP_REST="${s#&&}"
    return 0
  fi
  if [[ "$s" == $'\n'* ]]; then
    SEP_REST="${s:1}"
    return 0
  fi
  return 1
}

# Drop leading assignment commands and a same-command NAME=value prefix.
# Records RELENTLESS_ROLE and RELENTLESS_WORKTREE from that prefix only.
strip_leading_shell_assignments() {
  local s="$1" saved="" role_snap="" wt_snap=""
  LEAD_ROLE=""
  LEAD_WORKTREE=""
  while [[ -n "$s" ]]; do
    s="${s#"${s%%[![:space:]]*}"}"
    [[ -n "$s" ]] || break
    if [[ "$s" == export[[:space:]]* ]]; then
      saved="$s"
      role_snap="$LEAD_ROLE"
      wt_snap="$LEAD_WORKTREE"
      s="${s#export}"
      s="${s#"${s%%[![:space:]]*}"}"
      if ! parse_assignment_list "$s"; then
        LEAD_ROLE="$role_snap"
        LEAD_WORKTREE="$wt_snap"
        s="$saved"
        break
      fi
      if assignment_separator "$ASG_REST"; then
        s="$SEP_REST"
        continue
      fi
      LEAD_ROLE="$role_snap"
      LEAD_WORKTREE="$wt_snap"
      s="$saved"
      break
    fi
    # `env NAME=value cmd` applies those names to cmd. `env NAME=value; cmd` does not.
    if [[ "$s" == env[[:space:]]* ]]; then
      saved="$s"
      role_snap="$LEAD_ROLE"
      wt_snap="$LEAD_WORKTREE"
      s="${s#env}"
      s="${s#"${s%%[![:space:]]*}"}"
      if ! parse_assignment_list "$s"; then
        LEAD_ROLE="$role_snap"
        LEAD_WORKTREE="$wt_snap"
        s="$saved"
        break
      fi
      if assignment_separator "$ASG_REST"; then
        LEAD_ROLE="$role_snap"
        LEAD_WORKTREE="$wt_snap"
        s="$saved"
        break
      fi
      s="${ASG_REST#"${ASG_REST%%[![:space:]]*}"}"
      break
    fi
    if assignment_name_at "$s"; then
      saved="$s"
      role_snap="$LEAD_ROLE"
      wt_snap="$LEAD_WORKTREE"
      if ! parse_assignment_list "$s"; then
        LEAD_ROLE="$role_snap"
        LEAD_WORKTREE="$wt_snap"
        s="$saved"
        break
      fi
      if assignment_separator "$ASG_REST"; then
        s="$SEP_REST"
        continue
      fi
      s="${ASG_REST#"${ASG_REST%%[![:space:]]*}"}"
      break
    fi
    break
  done
  CMD_BODY="$s"
}

# Leading `cd <dir> &&` or `cd <dir>;` on the text after leading assignments.
# The path is not evaluated.
# Out of scope: pushd, bash -c, a subshell `(...)`, `export ... || true;`,
# `declare -x`, `FOO=a\ b`, and a cd later in the command.
# An inline or `env` assignment is the role for the whole line, so
# `RELENTLESS_ROLE=implementer codex exec ...; gh pr merge` on main blocks.
# No brief writes that.
command_cd_target() {
  local line="" rest="" dir="" base=""
  line="${CMD_BODY#"${CMD_BODY%%[![:space:]]*}"}"
  [[ "$line" == cd[[:space:]]* ]] || return 1
  rest="${line#cd}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  if [[ "$rest" == \"* ]]; then
    rest="${rest#\"}"
    dir="${rest%%\"*}"
    rest="${rest#*\"}"
  elif [[ "$rest" == \'* ]]; then
    rest="${rest#\'}"
    dir="${rest%%\'*}"
    rest="${rest#*\'}"
  else
    dir="$rest"
    dir="${dir%%[[:space:]]*}"
    dir="${dir%%;*}"
    dir="${dir%%&*}"
    rest="${rest#"$dir"}"
  fi
  [[ -n "$dir" ]] || return 1
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "$rest" == "&&"* || "$rest" == ";"* ]] || return 1
  case "$dir" in
    /*) ;;
    *)
      base=""
      if command -v jq >/dev/null 2>&1 && [[ -n "${INPUT:-}" ]]; then
        base="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"  # intentional fail-soft
      fi
      if [[ -z "$base" ]]; then
        base="$(pwd)" || return 1
      fi
      dir="${base%/}/${dir}"
      ;;
  esac
  printf '%s' "$dir"
}

# RELENTLESS_WORKTREE from the leading prefix. Relative paths use the payload cwd.
lead_worktree_marker() {
  local dir="$LEAD_WORKTREE" base=""
  [[ -n "$dir" ]] || return 1
  case "$dir" in
    /*) ;;
    *)
      base=""
      if command -v jq >/dev/null 2>&1 && [[ -n "${INPUT:-}" ]]; then
        base="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"  # intentional fail-soft
      fi
      if [[ -z "$base" ]]; then
        base="$(pwd)" || return 1
      fi
      dir="${base%/}/${dir}"
      ;;
  esac
  worktree_marker_at "$dir"
}

in_implementer_worktree() {
  local pcwd="" cd_dir=""
  if worktree_marker_at "$(pwd)"; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1 && [[ -n "${INPUT:-}" ]]; then
    pcwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"  # intentional fail-soft
  fi
  if [[ -n "$pcwd" ]] && worktree_marker_at "$pcwd"; then
    return 0
  fi
  if cd_dir="$(command_cd_target)"; then
    if worktree_marker_at "$cd_dir"; then
      return 0
    fi
  fi
  if lead_worktree_marker; then
    return 0
  fi
  return 1
}

# Env role is an extra signal. Reviewer, qa, planner, and documenter are not
# implementers, even inside a worktree. Orchestrator is not that exception:
# a Codex child inherits RELENTLESS_ROLE=orchestrator, and the untracked marker
# (process cwd, payload cwd, a leading cd target, or RELENTLESS_WORKTREE in the
# command) still means implementer. RELENTLESS_ROLE=implementer written on the
# command is the same signal when this process has no other role. With no
# marker and no implementer assignment, an orchestrator on the main checkout
# can merge.
LEAD_ROLE=""
LEAD_WORKTREE=""
CMD_BODY="$CMD"
strip_leading_shell_assignments "$CMD"
is_implementer=0
other_role=0
case "$ROLE" in
  reviewer|qa|planner|documenter) other_role=1 ;;
esac
case "$AGENT" in
  reviewer|qa|planner|documenter|*:reviewer|*:qa|*:planner|*:documenter) other_role=1 ;;
esac
if [[ "$ROLE" == "implementer" ]] || [[ "$AGENT" == *"implementer"* ]]; then
  is_implementer=1
elif [[ "$other_role" -eq 0 && "$LEAD_ROLE" == "implementer" ]]; then
  is_implementer=1
elif [[ "$other_role" -eq 0 ]] && in_implementer_worktree; then
  is_implementer=1
fi

# Label/verdict application (not merge-if-ready — orchestrator must run that)
looks_like_review_label() {
  echo "$CMD_SCAN" | grep -qE '(^|[[:space:];|&])(\./|[^[:space:]]*/)?apply-review-verdict\.sh([[:space:]]|$)' \
    || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+(label[[:space:]]+(add|create|edit)|issue[[:space:]]+edit|pr[[:space:]]+edit)[^|;]*review:approved' \
    || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+api[[:space:]][^|;]*review:approved'
}

looks_like_merge_if_ready() {
  echo "$CMD_SCAN" | grep -qE '(^|[[:space:];|&])(\./|[^[:space:]]*/)?merge-if-ready\.sh([[:space:]]|$)'
}

looks_like_push_or_pr_merge() {
  echo "$CMD_SCAN" | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)' \
    || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+pr[[:space:]]+(create|merge)([[:space:]]|$)'
}

if [[ "$is_implementer" -eq 1 ]]; then
  if looks_like_review_label || looks_like_merge_if_ready || looks_like_push_or_pr_merge; then
    # Allow git push during implement (needed); only block review + merge-if-ready + gh pr merge
    if looks_like_review_label || looks_like_merge_if_ready || echo "$CMD_SCAN" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
      echo "[relentless] BLOCKED: implementer role must stop at state:review. Do not apply review labels or merge. Orchestrator spawns isolated reviewer." >&2
      exit 2
    fi
  fi
  exit 0
fi

# Reviewer-side checks follow layers.review. The implementer block above does not.
# Missing config keeps the checks (they were always on before layers).
# No layers object keeps them on (1.4.11). A config that does not parse fails
# closed: PreToolUse treats exit 1 as a non-blocking error, so this hook
# exits 2 and names the file. Scripts still exit 1.
review_layer_active() {
  local top cfg err
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"  # intentional fail-soft: not every cwd is a checkout
  cfg=""
  if [[ -n "$top" && -f "${top}/.relentless/config.json" ]]; then
    cfg="${top}/.relentless/config.json"
  elif [[ -f .relentless/config.json ]]; then
    cfg="$(pwd)/.relentless/config.json"
  else
    return 0
  fi
  if ! err="$(jq empty "$cfg" 2>&1)"; then
    echo "error: ${cfg} failed to parse: ${err}" >&2
    exit 2
  fi
  layer_enabled review "$cfg"
}

# Reviewer only. The gh allowlist star matches the rest of the command, so a
# second method flag or --input still looks like an allowed GET. Deny those here.
# One -X/--method, including with -f/-F, stays allowed. Other roles are unchanged.
is_reviewer=0
if [[ "$ROLE" == "reviewer" || "$AGENT" == "reviewer" || "$AGENT" == *":reviewer" ]]; then
  is_reviewer=1
fi
if [[ "$is_reviewer" -eq 1 ]] && review_layer_active && reviewer_gh_api_unsafe; then
  echo "[relentless] BLOCKED: reviewer gh api may use one -X/--method and must not pass --input." >&2
  exit 2
fi

# Non-implementer heuristic: applying review:approved AND pushing/merging in one bash
# (self-review in same session). Orchestrator-only merge-if-ready is allowed.
if looks_like_review_label && looks_like_push_or_pr_merge; then
  echo "[relentless] BLOCKED: do not self-review and push/merge in the same session. Stop at state:review; orchestrator spawns isolated reviewer then merge-if-ready." >&2
  exit 2
fi

exit 0
