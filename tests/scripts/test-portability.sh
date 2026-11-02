#!/usr/bin/env bash
# The scripts also run on macOS, which ships bash 3.2 and BSD tools, while CI
# runs bash 5 with GNU tools. This test keeps them portable:
#   1. no bash 4+ syntax or GNU-only flags in the shell sources
#   2. every shell source parses with the bash running the test (3.2 on macOS)
#   3. realpath_m answers the same with and without GNU `realpath -m`
#   4. create-issue.sh runs with no --label and no --milestone (empty arrays
#      under `set -u` abort bash 3.2)
# Checks 2 to 4 use the bash running this file ($BASH), not the first bash in
# PATH, so on macOS run it as `/bin/bash tests/scripts/test-portability.sh`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

FILES=()
for f in "$ROOT"/hooks/scripts/*.sh "$ROOT"/core/scripts/*.sh "$ROOT"/core/scripts/lib/*.sh \
  "$ROOT"/core/templates/githooks/* "$ROOT"/tests/hooks/*.sh "$ROOT"/tests/scripts/*.sh; do
  [[ "$f" == "$ROOT/tests/scripts/test-portability.sh" ]] && continue
  FILES+=("$f")
done

# 1. Matches outside full-line comments. The third argument skips one file.
scan() { # label ere [skip]
  local label="$1" ere="$2" skip="${3:-}" f out hits=""
  for f in "${FILES[@]}"; do
    [[ -n "$skip" && "$f" == "$ROOT/$skip" ]] && continue
    out="$(grep -nE -- "$ere" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|${f#"$ROOT"/}:|")"
    [[ -n "$out" ]] && hits+="${out}"$'\n'
  done
  if [[ -z "$hits" ]]; then
    ok
  else
    bad "$label"$'\n'"$hits"
  fi
}

scan 'declare -A (bash 4)' '(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A'
scan 'mapfile/readarray (bash 4)' '(^|[[:space:];&|(])(mapfile|readarray)([[:space:]]|$)'
scan 'case fallthrough ;& or ;;& (bash 4)' ';;?&[[:space:]]*(#.*)?$'
scan 'case conversion in an expansion (bash 4)' '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,|\^)'
scan 'realpath -m (GNU only, use realpath_m)' 'realpath[[:space:]]+-m' core/scripts/lib/realpath.sh
scan 'base64 -w (GNU only)' 'base64[[:space:]]+(-[a-zA-Z]*w|--wrap)'

# 2. Syntax, file by file (`bash -n a b` would only parse a).
syntax=""
for f in "${FILES[@]}"; do
  out="$("$BASH" -n "$f" 2>&1)" || syntax+="${f#"$ROOT"/}: ${out}"$'\n'
done
if [[ -z "$syntax" ]]; then ok; else bad "bash ${BASH_VERSION} cannot parse:"$'\n'"$syntax"; fi

# 3. realpath_m. A realpath without -m forces the by-hand path anywhere. BSD
# realpath prints an error, BusyBox prints what it could resolve, and both exit
# 1; the stub does both, and none of it may reach the answer. Without the stub,
# GNU realpath answers when present.
mkdir -p "$TMP/bsd" "$TMP/real/repo/sub"
cat >"$TMP/bsd/realpath" <<'EOF'
#!/bin/sh
echo "/not/the/answer"
echo "realpath: illegal option -- m" >&2
exit 1
EOF
chmod +x "$TMP/bsd/realpath"
ln -s "$TMP/real" "$TMP/link"
PHYS="$(cd "$TMP/real" && pwd -P)"

realpath_from_link() { # bsd|native path
  local path_env="$PATH"
  [[ "$1" == "bsd" ]] && path_env="$TMP/bsd:$PATH"
  (
    set -e
    cd "$TMP/link/repo"
    # shellcheck source=../../core/scripts/lib/realpath.sh
    source "$ROOT/core/scripts/lib/realpath.sh"
    PATH="$path_env" realpath_m "$2"
  )
}

expect_path() { # input expected
  local mode got
  for mode in bsd native; do
    got="$(realpath_from_link "$mode" "$1")"
    if [[ "$got" == "$2" ]]; then
      ok
    else
      bad "realpath_m ($mode) $1: expected $2 got $got"
    fi
  done
}

expect_path "$TMP/link/repo/sub" "$PHYS/repo/sub"
expect_path "$TMP/link/repo/../other/new" "$PHYS/other/new"
expect_path "$TMP/link/missing/../repo" "$PHYS/repo"
expect_path "../x/./y//z/" "$PHYS/x/y/z"
expect_path "." "$PHYS/repo"
expect_path "a b/../c d" "$PHYS/repo/c d"
expect_path "/" "/"
expect_path "/.." "/"

# Symlinks inside the path: to a directory, to a file, to nothing. GNU follows
# all three, and `..` after a symlink leaves from the target, not the link.
mkdir -p "$TMP/real/out" "$TMP/elsewhere"
echo x >"$TMP/real/out/file"
ln -s ../out "$TMP/real/repo/outdir"
ln -s ../out/file "$TMP/real/repo/file-link"
ln -s ../gone/file "$TMP/real/repo/dangling"
ln -s "$TMP/real/repo" "$TMP/elsewhere/l"
expect_path "outdir/../y" "$PHYS/y"
expect_path "$TMP/elsewhere/l/../x" "$PHYS/x"
expect_path "file-link" "$PHYS/out/file"
expect_path "missing/../file-link" "$PHYS/out/file"
expect_path "dangling" "$PHYS/gone/file"
expect_path "-x" "$PHYS/repo/-x"

# 4. create-issue.sh with only the defaults, then with a label and a milestone.
mkdir -p "$TMP/gh-stub"
cat >"$TMP/gh-stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
echo "https://github.com/o/r/issues/12"
EOF
chmod +x "$TMP/gh-stub/gh"
body="$TMP/body.md"
echo body >"$body"

create_issue() {
  : >"$TMP/gh.log"
  out="$(PATH="$TMP/gh-stub:$PATH" GH_LOG="$TMP/gh.log" \
    "$BASH" "$ROOT/core/scripts/create-issue.sh" --repo o/r --title t --body-file "$body" "$@" 2>&1)"
  rc=$?
  log="$(cat "$TMP/gh.log")"
}

create_issue
if [[ $rc -eq 0 && "$log" == *"--label state:todo"* && "$log" != *"--milestone"* ]]; then
  ok
else
  bad "create-issue.sh defaults rc=$rc out=$out log=$log"
fi

create_issue --label state:review --milestone "Theme: subtitle"
if [[ $rc -eq 0 && "$log" == *"--milestone Theme: subtitle --label state:review"* && "$log" != *"state:todo"* ]]; then
  ok
else
  bad "create-issue.sh label + milestone rc=$rc out=$out log=$log"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
