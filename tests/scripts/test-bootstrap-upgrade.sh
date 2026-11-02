#!/usr/bin/env bash
# F46/F47/F48 — bootstrap --upgrade refreshes owned files, preserves checks + CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0 FAIL=0
ok() { echo "ok $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }

BOOT="$ROOT/core/scripts/bootstrap.sh"
[[ -x "$BOOT" || -f "$BOOT" ]] || { echo "missing bootstrap"; exit 1; }
bash -n "$BOOT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/relentless-upgrade-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Minimal fake consumer repo
mkdir -p "$TMP/repo/.codex/agents" "$TMP/repo/.github/workflows" "$TMP/repo/.relentless"
cat > "$TMP/repo/.relentless/config.json" <<'JSON'
{
  "decider": { "name": "Ada", "github": "ada" },
  "merge": { "default": "human" },
  "workers": { "default": { "github": "ada" } },
  "stack": "node",
  "checks": {
    "install": "npm ci",
    "lint": "npm run lint",
    "typecheck": "",
    "test": "npm run test:unit && npx playwright test",
    "build": "npm run build"
  }
}
JSON
echo 'name: custom-ci-with-playwright' > "$TMP/repo/.github/workflows/relentless-ci.yml"
echo '# old orchestrator brief' > "$TMP/repo/.codex/agents/orchestrator.toml"
echo '# old implementer' > "$TMP/repo/.codex/agents/implementer.toml"
# Pretend other agents exist so seed_write has targets; copy real ones as "old"
for a in planner qa reviewer documenter; do
  echo "# old $a" > "$TMP/repo/.codex/agents/${a}.toml"
done

# Stub gh. This test checks files on disk and must not call the real GitHub API.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then
  echo "Token scopes: 'repo', 'workflow'"
  exit 0
fi
if [[ "$1" == "repo" ]]; then
  if [[ "$*" == *"isEmpty"* ]]; then
    echo false
    exit 0
  fi
  if [[ "$*" == *"defaultBranchRef"* ]]; then
    echo main
    exit 0
  fi
  exit 0
fi
if [[ "$1" == "label" ]]; then
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo ada
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

set +e
out="$(
  PATH="$TMP/bin:$PATH" \
  bash "$BOOT" --repo o/r --workdir "$TMP/repo" \
    --harness codex --upgrade --merge-default human --decider Ada --decider-github ada \
    --no-init-empty 2>&1
)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  bad "dry-run upgrade exit $rc: $out"
else
  ok "dry-run upgrade exits 0"
fi

printf '%s\n' "$out" | grep -q 'kept existing' && ok "dry-run keeps the existing config" || bad "dry-run did not keep the existing config"
if printf '%s\n' "$out" | grep -q 'seed write: .codex/agents/orchestrator.toml'; then
  bad "dry-run planned to rewrite orchestrator.toml"
else
  ok "dry-run does not rewrite an existing orchestrator.toml"
fi

# Apply upgrade (labels may fail-soft; files on disk are what we check)
set +e
out_apply="$(
  PATH="$TMP/bin:$PATH" \
  bash "$BOOT" --repo o/r --workdir "$TMP/repo" \
    --harness codex --upgrade --apply --merge-default human --decider Ada --decider-github ada \
    --no-init-empty 2>&1
)"
rc_apply=$?
set -e
if [[ $rc_apply -ne 0 ]]; then
  bad "apply upgrade exit $rc_apply: $out_apply"
else
  ok "apply upgrade exits 0"
fi
if printf '%s\n' "$out_apply" | grep -q 'seed write: .codex/agents/orchestrator.toml'; then
  bad "apply rewrote orchestrator.toml"
else
  ok "apply does not rewrite an existing orchestrator.toml"
fi

# checks preserved
test_cmd="$(jq -r '.checks.test' "$TMP/repo/.relentless/config.json")"
if [[ "$test_cmd" == "npm run test:unit && npx playwright test" ]]; then
  ok "checks.test preserved through upgrade"
else
  bad "checks.test overwritten: $test_cmd"
fi

# CI file preserved
ci_head="$(head -n 1 "$TMP/repo/.github/workflows/relentless-ci.yml")"
if [[ "$ci_head" == "name: custom-ci-with-playwright" ]]; then
  ok "relentless-ci.yml preserved through upgrade"
else
  bad "CI regenerated: $ci_head"
fi

# Existing Codex files stay. Bootstrap does not edit them and does not add a pin.
if grep -q 'old orchestrator brief' "$TMP/repo/.codex/agents/orchestrator.toml"; then
  ok "orchestrator.toml left as the consumer wrote it"
else
  bad "orchestrator.toml was rewritten"
fi
if [[ -e "$TMP/repo/.codex/config.toml" ]]; then
  bad "bootstrap wrote .codex/config.toml"
else
  ok "bootstrap did not add a Codex marketplace pin"
fi

# First-install path still skips existing agent file without --upgrade
mkdir -p "$TMP/fresh/.codex/agents" "$TMP/fresh/.relentless"
echo 'STALE' > "$TMP/fresh/.codex/agents/orchestrator.toml"
set +e
out_fresh="$(
  PATH="$TMP/bin:$PATH" \
  bash "$BOOT" --repo o/r --workdir "$TMP/fresh" \
    --harness codex --merge-default human --decider Ada --decider-github ada \
    --no-init-empty --apply 2>&1
)"
set -e
if grep -q 'STALE' "$TMP/fresh/.codex/agents/orchestrator.toml"; then
  ok "without --upgrade, seed_copy still skips existing agent toml"
else
  bad "seed_copy overwrote without --upgrade"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
