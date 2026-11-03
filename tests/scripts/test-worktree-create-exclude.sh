#!/usr/bin/env bash
# worktree-create writes .relentless/worktree.json and appends that path to
# the common git dir's info/exclude. The line is written once. No tracked
# consumer file (.gitignore) is changed, so the marker does not show up in
# git status and a later commit cannot land it on main.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

REAL_GIT="$(command -v git)"
export REAL_GIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "issue" && "$2" == "develop" ]]; then
  name=""
  base=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--name" ]]; then name="$arg"; fi
    if [[ "$prev" == "--base" ]]; then base="$arg"; fi
    prev="$arg"
  done
  "${REAL_GIT:?}" -C "${REPO_DIR:?}" branch "$name" "origin/$base"
  "${REAL_GIT:?}" -C "${REPO_DIR:?}" push -q origin "$name"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

"$REAL_GIT" init -q -b main "$TMP/repo"
"$REAL_GIT" -C "$TMP/repo" config user.email t@example.com
"$REAL_GIT" -C "$TMP/repo" config user.name Test
printf '%s\n' 'consumer' >"$TMP/repo/README.md"
"$REAL_GIT" -C "$TMP/repo" add README.md
"$REAL_GIT" -C "$TMP/repo" commit -q -m init
"$REAL_GIT" init -q --bare -b main "$TMP/origin.git"
"$REAL_GIT" -C "$TMP/repo" remote add origin "$TMP/origin.git"
"$REAL_GIT" -C "$TMP/repo" push -q -u origin main

run_create() { # issue
  PATH="$TMP/bin:$PATH" REPO_DIR="$TMP/repo" \
    bash "$ROOT/core/scripts/worktree-create.sh" \
      --repo acme/consumer --issue "$1" --slug login --type feat \
      --workdir "$TMP/repo" --parent "$TMP" --base main --no-push
}

if run_create 7 >"$TMP/c7.out" 2>"$TMP/c7.err" && run_create 8 >"$TMP/c8.out" 2>"$TMP/c8.err"; then
  ok
else
  bad "worktree-create failed for issue 7 or 8"
  # One of the two logs may be missing when the first create fails.
  cat "$TMP/c7.err" "$TMP/c8.err" >&2 || true
  echo "pass=$PASS fail=$FAIL"
  exit 1
fi

wt7="$TMP/consumer-wt-7"
wt8="$TMP/consumer-wt-8"
st7="$("$REAL_GIT" -C "$wt7" status --porcelain)"
st8="$("$REAL_GIT" -C "$wt8" status --porcelain)"
if [[ "$st7" != *worktree.json* && -f "$wt7/.relentless/worktree.json" ]]; then
  ok
else
  bad "issue 7 worktree status shows the marker: $(printf '%s' "$st7" | tr '\n' ' ')"
fi
if [[ "$st8" != *worktree.json* && -f "$wt8/.relentless/worktree.json" ]]; then
  ok
else
  bad "issue 8 worktree status shows the marker: $(printf '%s' "$st8" | tr '\n' ' ')"
fi

common="$("$REAL_GIT" -C "$wt7" rev-parse --git-common-dir)"
case "$common" in
  /*) ;;
  *) common="${wt7}/${common}" ;;
esac
exclude="${common}/info/exclude"
count="$(grep -c -x -F '.relentless/worktree.json' "$exclude" || true)"
if [[ "$count" -eq 1 ]]; then
  ok
else
  bad "info/exclude has the marker line ${count} times, want 1"
fi

if [[ ! -e "$TMP/repo/.gitignore" && ! -e "$wt7/.gitignore" && ! -e "$wt8/.gitignore" ]]; then
  ok
else
  bad "worktree-create wrote a tracked .gitignore"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
