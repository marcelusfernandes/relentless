#!/usr/bin/env bash
# pretool-protect-main.sh — PreToolUse Bash: block commit/push directly to main/master
# and destructive git (force-push, reset --hard, clean -f).
#
# The branch check follows the command's target (git -C / --work-tree / cd),
# not only the hook's cwd. Force-push is any spelling: --force, --force-with-lease,
# a short option cluster that contains -f, or a +refspec.
#
# Runs on every Bash call, so it must also run on macOS: bash 3.2 and BSD tools
# (no `declare -A`, `mapfile`, `;&`, or GNU-only flags).
set -euo pipefail
INPUT="$(cat 2>/dev/null || true)"  # intentional: empty stdin ok
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)"  # intentional fail-soft
fi
[[ -z "$CMD" ]] && exit 0

deny() { printf 'protect-main: BLOCKED — %s\n' "$*" >&2; exit 2; }

# Whole-command fast path (also covers parsers missing a weird quoting edge).
if printf '%s\n' "$CMD" | grep -qiE '(^|[;|&[:space:]])git[[:space:]]+reset[[:space:]]+[^;|&]*(--hard|--merge)'; then
  deny "git reset --hard/--merge is forbidden (destructive)"
fi
if printf '%s\n' "$CMD" | grep -qiE '(^|[;|&[:space:]])git[[:space:]]+clean[[:space:]]+[^;|&]*-f'; then
  deny "git clean -f is forbidden (destructive)"
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../core/scripts/lib/realpath.sh
source "${HOOK_DIR}/../../core/scripts/lib/realpath.sh"

abspath() {
  local base="$1" rel="$2"
  if [[ "$rel" == /* ]]; then
    realpath_m "$rel"
  else
    realpath_m "${base}/${rel}"
  fi
}

# Null-delimited segments on &&, ||, ;, |, and newlines. Quotes are respected.
split_segments() {
  local s="$1"
  local i=0 len=${#s} cur="" quote="" c two
  while [[ $i -lt $len ]]; do
    c="${s:i:1}"
    two="${s:i:2}"
    if [[ -n "$quote" ]]; then
      cur+="$c"
      if [[ "$c" == "$quote" ]]; then quote=""; fi
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == "'" || "$c" == '"' ]]; then
      quote="$c"
      cur+="$c"
      i=$((i + 1))
      continue
    fi
    if [[ "$two" == "&&" || "$two" == "||" ]]; then
      printf '%s\0' "$cur"
      cur=""
      i=$((i + 2))
      continue
    fi
    if [[ "$c" == ";" || "$c" == $'\n' || "$c" == "|" ]]; then
      printf '%s\0' "$cur"
      cur=""
      i=$((i + 1))
      continue
    fi
    cur+="$c"
    i=$((i + 1))
  done
  printf '%s\0' "$cur"
}

tokenize() {
  local s="$1"
  local i=0 len=${#s} cur="" quote="" c
  while [[ $i -lt $len ]]; do
    c="${s:i:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$c" == "$quote" ]]; then
        quote=""
      else
        cur+="$c"
      fi
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == "'" || "$c" == '"' ]]; then
      quote="$c"
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == " " || "$c" == $'\t' ]]; then
      if [[ -n "$cur" ]]; then
        printf '%s\n' "$cur"
        cur=""
      fi
      i=$((i + 1))
      continue
    fi
    cur+="$c"
    i=$((i + 1))
  done
  [[ -n "$cur" ]] && printf '%s\n' "$cur"
  return 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

push_is_force() {
  local a
  for a in "$@"; do
    case "$a" in
      --force|--force=*|--force-with-lease|--force-with-lease=*|--force-if-includes|--force-if-includes=*)
        return 0
        ;;
      --*)
        ;;
      -*)
        if [[ "$a" =~ ^-[A-Za-z]*f[A-Za-z]*$ ]]; then
          return 0
        fi
        ;;
      +*)
        return 0
        ;;
    esac
  done
  return 1
}

push_targets_protected() {
  local a
  for a in "$@"; do
    case "$a" in
      -*) continue ;;
    esac
    case "$a" in
      main|master|refs/heads/main|refs/heads/master) return 0 ;;
      *:main|*:master|*:refs/heads/main|*:refs/heads/master) return 0 ;;
    esac
  done
  return 1
}

reset_is_destructive() {
  local a
  for a in "$@"; do
    case "$a" in
      --hard|--merge) return 0 ;;
    esac
  done
  return 1
}

clean_is_forced() {
  local a
  for a in "$@"; do
    case "$a" in
      --force|--force=*) return 0 ;;
      --*) ;;
      -*)
        if [[ "$a" =~ ^-[A-Za-z]*f ]]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# Branch a directory was switched to earlier in this command (checkout/switch).
# Two parallel arrays, newest last, because bash 3.2 has no `declare -A`.
VBRANCH_DIRS=()
VBRANCH_NAMES=()
sim_cwd="$(realpath_m "$(pwd)")"

remember_branch() { # dir branch
  VBRANCH_DIRS+=("$1")
  VBRANCH_NAMES+=("$2")
}

branch_of() {
  local dir="$1" b="" j=${#VBRANCH_DIRS[@]}
  while [[ $j -gt 0 ]]; do
    j=$((j - 1))
    if [[ "${VBRANCH_DIRS[$j]}" == "$dir" ]]; then
      printf '%s' "${VBRANCH_NAMES[$j]}"
      return 0
    fi
  done
  if [[ -d "$dir" ]] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    b="$(git -C "$dir" branch --show-current 2>/dev/null || true)"  # intentional fail-soft
    printf '%s' "$b"
  fi
  return 0
}

note_checkout() {
  local target="$1"
  shift
  local args=("$@") j=0 a
  while [[ $j -lt ${#args[@]} ]]; do
    a="${args[$j]}"
    if [[ "$a" == "--" ]]; then
      return 0
    fi
    if [[ "$a" == "-b" || "$a" == "-B" || "$a" == "-c" || "$a" == "-C" || "$a" == "--orphan" ]]; then
      j=$((j + 1))
      remember_branch "$target" "${args[$j]:-}"
      return 0
    fi
    if [[ "$a" == -* ]]; then
      j=$((j + 1))
      continue
    fi
    remember_branch "$target" "$a"
    return 0
  done
  return 0
}

scan_segment() {
  local seg="$1"
  local -a tokens=()
  local tok
  while IFS= read -r tok; do
    tokens+=("$tok")
  done < <(tokenize "$seg")
  [[ ${#tokens[@]} -eq 0 ]] && return 0

  if [[ "${tokens[0]}" == "cd" ]]; then
    local dest=""
    if [[ "${tokens[1]:-}" == "--" ]]; then
      dest="${tokens[2]:-}"
    else
      dest="${tokens[1]:-}"
    fi
    if [[ -z "$dest" ]]; then
      [[ -n "${HOME:-}" ]] && sim_cwd="$(realpath_m "$HOME")"
    elif [[ "$dest" != "-" ]]; then
      sim_cwd="$(abspath "$sim_cwd" "$dest")"
    fi
    return 0
  fi

  local gi=-1 i t base
  for i in "${!tokens[@]}"; do
    t="${tokens[$i]}"
    base="${t##*/}"
    if [[ "$base" == "git" ]]; then
      gi=$i
      break
    fi
  done
  [[ $gi -ge 0 ]] || return 0

  local target="$sim_cwd" sub="" iarg
  i=$((gi + 1))
  while [[ $i -lt ${#tokens[@]} ]]; do
    t="${tokens[$i]}"
    if [[ "$t" == "-C" ]]; then
      i=$((i + 1))
      target="$(abspath "$sim_cwd" "${tokens[$i]:-}")"
      i=$((i + 1))
      continue
    fi
    if [[ "$t" == -C* && ${#t} -gt 2 ]]; then
      target="$(abspath "$sim_cwd" "${t#-C}")"
      i=$((i + 1))
      continue
    fi
    if [[ "$t" == "--work-tree" ]]; then
      i=$((i + 1))
      target="$(abspath "$sim_cwd" "${tokens[$i]:-}")"
      i=$((i + 1))
      continue
    fi
    if [[ "$t" == --work-tree=* ]]; then
      target="$(abspath "$sim_cwd" "${t#--work-tree=}")"
      i=$((i + 1))
      continue
    fi
    if [[ "$t" == "-c" || "$t" == "--git-dir" || "$t" == "--namespace" ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ "$t" == -c* || "$t" == --git-dir=* || "$t" == --namespace=* ]]; then
      i=$((i + 1))
      continue
    fi
    if [[ "$t" == --* || "$t" == -* ]]; then
      i=$((i + 1))
      continue
    fi
    sub="$t"
    i=$((i + 1))
    break
  done
  [[ -n "$sub" ]] || return 0

  local -a args=()
  local b=""
  if [[ $i -lt ${#tokens[@]} ]]; then
    args=("${tokens[@]:$i}")
  fi

  case "$sub" in
    checkout|switch)
      note_checkout "$target" ${args[@]+"${args[@]}"}
      ;;
    reset)
      if [[ ${#args[@]} -gt 0 ]] && reset_is_destructive "${args[@]}"; then
        deny "git reset --hard/--merge is forbidden (destructive)"
      fi
      ;;
    clean)
      if [[ ${#args[@]} -gt 0 ]] && clean_is_forced "${args[@]}"; then
        deny "git clean -f is forbidden (destructive)"
      fi
      ;;
    push|commit)
      if [[ "$sub" == "push" ]]; then
        if [[ ${#args[@]} -gt 0 ]] && push_is_force "${args[@]}"; then
          deny "force-push is forbidden"
        fi
        if [[ ${#args[@]} -gt 0 ]] && push_targets_protected "${args[@]}"; then
          deny "git push of main/master is forbidden"
        fi
      fi
      b="$(branch_of "$target")"
      if [[ "$b" == "main" || "$b" == "master" ]]; then
        deny "commit/push on ${b} is forbidden — use a feature worktree (<type>/<n>-<slug>)"
      fi
      ;;
  esac
  return 0
}

while IFS= read -r -d '' seg || [[ -n "$seg" ]]; do
  seg="$(trim "$seg")"
  [[ -z "$seg" ]] && continue
  scan_segment "$seg"
done < <(split_segments "$CMD")

exit 0
