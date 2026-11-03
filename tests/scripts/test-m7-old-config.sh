#!/usr/bin/env bash
# M7 — a 1.4.11 config with no layers key keeps every 1.4.11 layer on.
# The checked-in fixture is core/schemas/config.example.json from v1.4.11
# (ee722b8). gh api could not read marcelusfernandes/teste-relentless-claude
# or marcelusfernandes/Teste-relentless (HTTP 404 with this token).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

FIXTURE="$ROOT/tests/fixtures/m7/v1.4.11-config.example.json"
[[ -f "$FIXTURE" ]] || { echo "missing fixture"; exit 1; }
if jq -e 'has("layers")' "$FIXTURE" >/dev/null; then
  bad "M7 fixture must not have a layers key"
else
  ok
fi

# shellcheck source=../../core/scripts/lib/common.sh
source "$ROOT/core/scripts/lib/common.sh"
for name in merge review qa worktrees decisions templates ci githooks docs; do
  if layer_enabled "$name" "$FIXTURE"; then
    ok
  else
    bad "M7 layer $name is off for a config with no layers key"
  fi
done

REPO="$TMP/repo"
mkdir -p "$REPO/.relentless" "$TMP/bin"
cp "$FIXTURE" "$REPO/.relentless/config.json"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then
  echo "Token scopes: 'repo', 'workflow'"
  exit 0
fi
if [[ "$1" == "repo" ]]; then
  if [[ "$*" == *"isEmpty"* ]]; then echo false; exit 0; fi
  if [[ "$*" == *"defaultBranchRef"* ]]; then echo main; exit 0; fi
  exit 0
fi
if [[ "$1" == "label" ]]; then exit 0; fi
if [[ "$1" == "api" ]]; then echo marcelus; exit 0; fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

out="$(PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/bootstrap.sh" --repo acme/old --workdir "$REPO" \
  --merge-default human --decider Ada --decider-github ada --harness both --no-init-empty --apply 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "M7 bootstrap exited $rc: $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
else
  ok
fi

for name in merge review qa worktrees decisions templates ci githooks docs; do
  if [[ -f "$REPO/.relentless/layers/${name}.md" ]]; then
    ok
  else
    bad "M7 bootstrap did not copy layer $name"
  fi
done
if [[ -f "$REPO/.relentless/githooks/pre-commit" && -f "$REPO/.relentless/githooks/pre-push" ]]; then
  ok
else
  bad "M7 githooks were not installed"
fi
if [[ -f "$REPO/docs/decisions/README.md" && -f "$REPO/.github/ISSUE_TEMPLATE/investigation.yml" ]]; then
  ok
else
  bad "M7 decisions or templates layer did not seed"
fi
if [[ -f "$REPO/.codex/agents/reviewer.toml" ]]; then
  ok
else
  bad "M7 review layer did not seed the reviewer brief"
fi
hook_rc="$(cd "$REPO" && bash .relentless/githooks/pre-commit </dev/null >/dev/null 2>&1; echo $?)"
if [[ "$hook_rc" -ne 0 ]]; then
  ok
else
  bad "M7 pre-commit did not refuse a commit on main"
fi

payload="$(jq -n --arg cwd "$REPO" --arg f "$TMP/outside.txt" '{cwd:$cwd, tool_input:{file_path:$f}}')"
wt_rc="$(cd "$REPO" && printf '%s' "$payload" | env RELENTLESS_ROLE=implementer \
  bash "$ROOT/hooks/scripts/pretool-protect-worktree-write.sh" >/dev/null 2>&1; echo $?)"
if [[ "$wt_rc" -eq 2 ]]; then
  ok
else
  bad "M7 worktrees hook did not block an outside write (rc=$wt_rc)"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
