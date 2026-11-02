#!/usr/bin/env bash
# M10 — a branch for an issue is created with
#   gh issue develop N --name <branch> --base <base>
# If that command fails, the flow stops, the gh error stays visible, and
# nothing falls back to `git worktree add -b`.
#
# The live `gh issue develop --list N` check on a real issue is out of scope
# for this suite. Two stubs: one records a successful call, one fails.
# Expected red on v1.4.11 (the failure stub). Later minimal-cut PRs turn it green.
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

cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_LOG:?}"
exec "${REAL_GIT:?}" "$@"
EOF
chmod +x "$TMP/bin/git"

make_repo() { # dest
  local dest="$1" origin="$2"
  "$REAL_GIT" init -q -b develop "$dest"
  "$REAL_GIT" -C "$dest" config user.email t@example.com
  "$REAL_GIT" -C "$dest" config user.name Test
  printf '%s\n' 'consumer' >"$dest/README.md"
  "$REAL_GIT" -C "$dest" add README.md
  "$REAL_GIT" -C "$dest" commit -q -m init
  "$REAL_GIT" init -q --bare -b develop "$origin"
  "$REAL_GIT" -C "$dest" remote add origin "$origin"
  "$REAL_GIT" -C "$dest" push -q -u origin develop
}

run_create() { # workdir parent
  local workdir="$1" parent="$2"
  PATH="$TMP/bin:$PATH" \
    GH_LOG="$TMP/gh.log" GIT_LOG="$TMP/git.log" REPO_DIR="$workdir" \
    bash "$ROOT/core/scripts/worktree-create.sh" \
      --repo acme/consumer --issue 7 --slug login --type feat \
      --workdir "$workdir" --parent "$parent" --base develop --no-push
}

# Success stub: gh issue develop creates the branch, and the call is recorded.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "issue" && "$2" == "develop" ]]; then
  if [[ "$*" == *"--help"* ]]; then
    exit 0
  fi
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

mkdir -p "$TMP/ok-parent"
make_repo "$TMP/ok-repo" "$TMP/ok-origin.git"
: >"$TMP/gh.log"
: >"$TMP/git.log"
ok_out="$(run_create "$TMP/ok-repo" "$TMP/ok-parent" 2>&1)"
ok_rc=$?
ok_gh="$(cat "$TMP/gh.log")"
ok_git="$(cat "$TMP/git.log")"
if [[ "$ok_rc" -eq 0 \
  && "$ok_gh" == *"issue develop 7"* \
  && "$ok_gh" == *"--name feat/7-login"* \
  && "$ok_gh" == *"--base develop"* \
  && "$ok_git" != *"worktree add -b"* ]]; then
  ok
else
  bad "M10 success path did not go through gh issue develop 7 --name feat/7-login --base develop (rc=$ok_rc) gh=$(printf '%s' "$ok_gh" | tr '\n' ' ') git=$(printf '%s' "$ok_git" | tr '\n' ' ') out=$(printf '%s' "$ok_out" | tr '\n' ' ')"
fi

# Failure stub: gh issue develop prints an error and exits 1.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "issue" && "$2" == "develop" ]]; then
  if [[ "$*" == *"--help"* ]]; then
    exit 0
  fi
  echo "error: gh issue develop failed: GraphQL: Resource not accessible by integration" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

mkdir -p "$TMP/bad-parent"
make_repo "$TMP/bad-repo" "$TMP/bad-origin.git"
: >"$TMP/gh.log"
: >"$TMP/git.log"
bad_out="$(run_create "$TMP/bad-repo" "$TMP/bad-parent" 2>&1)"
bad_rc=$?
bad_git="$(cat "$TMP/git.log")"
if [[ "$bad_rc" -ne 0 ]]; then
  ok
else
  bad "M10 flow exited 0 after gh issue develop failed"
fi
if printf '%s\n' "$bad_out" | grep -q 'Resource not accessible'; then
  ok
else
  bad "M10 gh error was not visible in the flow output: $(printf '%s' "$bad_out" | tr '\n' ' ')"
fi
if printf '%s\n' "$bad_git" | grep -q 'worktree add -b' \
  || "$REAL_GIT" -C "$TMP/bad-repo" show-ref --verify --quiet refs/heads/feat/7-login; then
  bad "M10 fell back to git worktree add -b after gh issue develop failed: $(printf '%s\n' "$bad_git" | grep 'worktree add' | tr '\n' ' ')"
else
  ok
fi

# gh issue develop is not available (--help fails). The flow still must call it
# and stop, not skip straight to git worktree add -b.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [[ "$1" == "issue" && "$2" == "develop" ]]; then
  echo "error: gh issue develop failed: GraphQL: Resource not accessible by integration" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

mkdir -p "$TMP/help-parent"
make_repo "$TMP/help-repo" "$TMP/help-origin.git"
: >"$TMP/gh.log"
: >"$TMP/git.log"
help_out="$(run_create "$TMP/help-repo" "$TMP/help-parent" 2>&1)"
help_rc=$?
help_gh="$(cat "$TMP/gh.log")"
help_git="$(cat "$TMP/git.log")"
# grep exits 1 when the create call was never made; that is the failure we assert below.
printf '%s\n' "$help_gh" | grep -F 'issue develop' | grep -F -- '--name' >"$TMP/help-create" || true
help_named=0
help_visible=0
help_fallback=0
[[ -s "$TMP/help-create" ]] && help_named=1
printf '%s\n' "$help_out" | grep -q 'Resource not accessible' && help_visible=1
printf '%s\n' "$help_git" | grep -q 'worktree add -b' && help_fallback=1
if [[ "$help_rc" -ne 0 && "$help_named" -eq 1 && "$help_visible" -eq 1 && "$help_fallback" -eq 0 ]]; then
  ok
else
  bad "M10 when gh issue develop fails at --help the flow skipped gh issue develop --name --base and fell back to git worktree add -b (rc=$help_rc fallback=$help_fallback) git=$(printf '%s\n' "$help_git" | grep 'worktree add' | tr '\n' ' ')"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
