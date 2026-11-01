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

# Dry-run upgrade should mention preserve CI and owned refresh (no network labels if repo fake — use a dry path)
# bootstrap needs a real --repo for gh label list; use dry-run against this repo name but expect gh calls.
# Isolate: exercise the seed functions by sourcing is hard. Instead run with a known public repo
# and --no... Actually labels need gh. Use marcelusfernandes/relentless itself as --repo (read-only labels).

set +e
out="$(
  bash "$BOOT" --repo marcelusfernandes/relentless --workdir "$TMP/repo" \
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

printf '%s\n' "$out" | grep -q 'upgrade preserves CI' && ok "dry-run mentions preserve CI" || bad "dry-run missing preserve CI note"
printf '%s\n' "$out" | grep -q 'seed write: .codex/agents/orchestrator.toml (owned)' && ok "dry-run refreshes orchestrator.toml" || bad "dry-run did not plan owned orchestrator refresh: $(printf '%s\n' "$out" | grep -F '.codex/agents' || true)"

# Apply upgrade (labels may fail-soft; files on disk are what we check)
set +e
out_apply="$(
  bash "$BOOT" --repo marcelusfernandes/relentless --workdir "$TMP/repo" \
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
printf '%s\n' "$out_apply" | grep -q 'upgrade preserves CI' \
  && ok "apply mentions preserve CI" || bad "apply missing preserve CI note"
printf '%s\n' "$out_apply" | grep -q 'seed write: .codex/agents/orchestrator.toml (owned)' \
  && ok "apply refreshes orchestrator.toml" || bad "apply did not refresh orchestrator: $out_apply"

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

# orchestrator.toml refreshed from plugin (should no longer be the stub)
if grep -q 'old orchestrator brief' "$TMP/repo/.codex/agents/orchestrator.toml"; then
  bad "orchestrator.toml not refreshed"
else
  if grep -qi 'orchestrator\|Human decisions\|docs/decisions' "$TMP/repo/.codex/agents/orchestrator.toml"; then
    ok "orchestrator.toml refreshed from plugin"
  else
    bad "orchestrator.toml content unexpected"
  fi
fi

# Codex pin seeded
if [[ -f "$TMP/repo/.codex/config.toml" ]] && grep -q 'marketplaces.relentless' "$TMP/repo/.codex/config.toml"; then
  if grep -q 'ref = "v1.4.9"' "$TMP/repo/.codex/config.toml"; then
    ok "Codex marketplace pin seeded at v1.4.9"
  else
    bad "Codex pin missing v1.4.9 ref"
  fi
else
  bad "Codex config.toml pin not seeded"
fi

# First-install path still skips existing agent file without --upgrade
mkdir -p "$TMP/fresh/.codex/agents" "$TMP/fresh/.relentless"
echo 'STALE' > "$TMP/fresh/.codex/agents/orchestrator.toml"
set +e
out_fresh="$(
  bash "$BOOT" --repo marcelusfernandes/relentless --workdir "$TMP/fresh" \
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
