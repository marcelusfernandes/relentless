#!/usr/bin/env bash
# M7 — a 1.4.11 config with no layers key keeps every 1.4.11 layer on.
# Fixtures:
# - v1.4.11-config.example.json is core/schemas/config.example.json from ee722b8
# - claude-1.4.11.json is teste-relentless-claude @1393c94
# - codex-1.4.11.json is Teste-relentless @98a6b71
# GitHub logins in the two repo fixtures are example-user.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

# shellcheck source=../../core/scripts/lib/common.sh
source "$ROOT/core/scripts/lib/common.sh"

mkdir -p "$TMP/bin"
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
if [[ "$1" == "api" ]]; then echo example-user; exit 0; fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

exercise() { # label fixture
  local label="$1" fixture="$2" repo name hook_rc wt_rc payload out rc
  repo="$TMP/$label"
  [[ -f "$fixture" ]] || { bad "M7 $label missing fixture $fixture"; return; }
  if jq -e 'has("layers")' "$fixture" >/dev/null; then
    bad "M7 $label fixture must not have a layers key"
  else
    ok
  fi
  for name in merge review qa worktrees decisions templates ci githooks docs; do
    if layer_enabled "$name" "$fixture"; then
      ok
    else
      bad "M7 $label layer $name is off for a config with no layers key"
    fi
  done

  mkdir -p "$repo/.relentless"
  cp "$fixture" "$repo/.relentless/config.json"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init

  out="$(PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/bootstrap.sh" --repo acme/old --workdir "$repo" \
    --merge-default human --decider Ada --decider-github ada --harness both --no-init-empty --apply 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "M7 $label bootstrap exited $rc: $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
  else
    ok
  fi

  for name in merge review qa worktrees decisions templates ci githooks docs; do
    if [[ -f "$repo/.relentless/layers/${name}.md" ]]; then
      ok
    else
      bad "M7 $label bootstrap did not copy layer $name"
    fi
  done
  if [[ -f "$repo/.relentless/githooks/pre-commit" && -f "$repo/.relentless/githooks/pre-push" ]]; then
    ok
  else
    bad "M7 $label githooks were not installed"
  fi
  if [[ -f "$repo/docs/decisions/README.md" && -f "$repo/.github/ISSUE_TEMPLATE/investigation.yml" ]]; then
    ok
  else
    bad "M7 $label decisions or templates layer did not seed"
  fi
  if [[ -f "$repo/.codex/agents/reviewer.toml" ]]; then
    ok
  else
    bad "M7 $label review layer did not seed the reviewer brief"
  fi
  hook_rc="$(cd "$repo" && bash .relentless/githooks/pre-commit </dev/null >/dev/null 2>&1; echo $?)"
  if [[ "$hook_rc" -ne 0 ]]; then
    ok
  else
    bad "M7 $label pre-commit did not refuse a commit on main"
  fi

  payload="$(jq -n --arg cwd "$repo" --arg f "$TMP/outside-$label.txt" '{cwd:$cwd, tool_input:{file_path:$f}}')"
  wt_rc="$(cd "$repo" && printf '%s' "$payload" | env RELENTLESS_ROLE=implementer \
    bash "$ROOT/hooks/scripts/pretool-protect-worktree-write.sh" >/dev/null 2>&1; echo $?)"
  if [[ "$wt_rc" -eq 2 ]]; then
    ok
  else
    bad "M7 $label worktrees hook did not block an outside write (rc=$wt_rc)"
  fi
}

for fixture in "$ROOT/tests/fixtures/m7/claude-1.4.11.json" "$ROOT/tests/fixtures/m7/codex-1.4.11.json"; do
  if grep -q 'marcelusfernandes' "$fixture"; then
    bad "M7 $(basename "$fixture") still has a GitHub login"
  else
    ok
  fi
done
exercise example "$ROOT/tests/fixtures/m7/v1.4.11-config.example.json"
exercise claude "$ROOT/tests/fixtures/m7/claude-1.4.11.json"
exercise codex "$ROOT/tests/fixtures/m7/codex-1.4.11.json"

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
