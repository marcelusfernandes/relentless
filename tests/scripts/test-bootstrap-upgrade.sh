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

# Marker-gated refresh. An owned file still carrying the marker is refreshed.
# A file the repo edited (marker removed) stays byte-identical. Same pair for
# a layer file. A config with no layers key keeps the 1.4.11 layers on.
MARK="$TMP/marked"
mkdir -p "$MARK/.codex/agents" "$MARK/.relentless/layers" "$MARK/.github/workflows"
cat >"$MARK/.relentless/config.json" <<'JSON'
{
  "decider": { "name": "Ada", "github": "ada" },
  "merge": { "default": "human" },
  "workers": { "default": { "github": "ada" } },
  "checks": { "test": "npm run test:unit && npx playwright test" }
}
JSON
printf '%s\n' 'name: other' 'jobs:' '  test:' '    steps:' '      - run: npm run test:detected' \
  >"$MARK/.github/workflows/consumer.yml"
printf '%s\n' '# <!-- relentless:owned -->' 'OLD ORCH BRIEF' >"$MARK/.codex/agents/orchestrator.toml"
printf '%s\n' 'EDITED IMPLEMENTER without marker' >"$MARK/.codex/agents/implementer.toml"
impl_before="$(cksum "$MARK/.codex/agents/implementer.toml" | awk '{print $1}')"
printf '%s\n' '<!-- relentless:owned -->' 'OLD MERGE LAYER' >"$MARK/.relentless/layers/merge.md"
printf '%s\n' 'EDITED QA LAYER' >"$MARK/.relentless/layers/qa.md"
qa_before="$(cksum "$MARK/.relentless/layers/qa.md" | awk '{print $1}')"
git -C "$MARK" init -q -b main
git -C "$MARK" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
set +e
out_mark="$(
  PATH="$TMP/bin:$PATH" \
  bash "$BOOT" --repo o/r --workdir "$MARK" \
    --harness codex --upgrade --apply --merge-default human --decider Ada --decider-github ada \
    --no-init-empty 2>&1
)"
rc_mark=$?
set -e
if [[ $rc_mark -ne 0 ]]; then
  bad "marked refresh apply exit $rc_mark: $out_mark"
else
  ok "marked refresh apply exits 0"
fi
if printf '%s\n' "$out_mark" | grep -q 'refreshed: .codex/agents/orchestrator.toml' \
  && grep -q 'Never add `human:decided`' "$MARK/.codex/agents/orchestrator.toml" \
  && grep -q 'relentless:owned' "$MARK/.codex/agents/orchestrator.toml" \
  && ! grep -q 'OLD ORCH BRIEF' "$MARK/.codex/agents/orchestrator.toml"; then
  ok "marked orchestrator.toml refreshed with the new brief"
else
  bad "marked orchestrator.toml was not refreshed: $(head -n 2 "$MARK/.codex/agents/orchestrator.toml")"
fi
if printf '%s\n' "$out_mark" | grep -q 'skipped: .codex/agents/implementer.toml' \
  && [[ "$(cksum "$MARK/.codex/agents/implementer.toml" | awk '{print $1}')" == "$impl_before" ]]; then
  ok "edited implementer.toml without the marker stayed byte-identical"
else
  bad "edited implementer.toml changed"
fi
if printf '%s\n' "$out_mark" | grep -q 'refreshed: .relentless/layers/merge.md' \
  && [[ "$(cksum "$ROOT/agents/layers/merge.md" | awk '{print $1}')" == "$(cksum "$MARK/.relentless/layers/merge.md" | awk '{print $1}')" ]]; then
  ok "marked layer file refreshed"
else
  bad "marked layer file was not refreshed"
fi
if printf '%s\n' "$out_mark" | grep -q 'skipped: .relentless/layers/qa.md' \
  && [[ "$(cksum "$MARK/.relentless/layers/qa.md" | awk '{print $1}')" == "$qa_before" ]]; then
  ok "edited layer file without the marker stayed byte-identical"
else
  bad "edited layer file changed"
fi
if [[ -f "$MARK/.relentless/githooks/pre-commit" && -f "$MARK/.relentless/githooks/pre-push" ]]; then
  ok "config with no layers key still installs githooks"
else
  bad "config with no layers key did not install githooks"
fi
if grep -q 'npm run test:unit && npx playwright test' "$MARK/AGENTS.md" \
  && ! grep -q 'npm run test:detected' "$MARK/AGENTS.md"; then
  ok "AGENTS.md shows the config test command, not the detected one"
else
  bad "AGENTS.md checks did not follow config"
fi

# Empty checks.test is filled from the repo workflow, and the docs block matches.
EMPTY="$TMP/empty-checks"
mkdir -p "$EMPTY/.relentless" "$EMPTY/.github/workflows"
printf '%s\n' '{"decider":{"name":"Ada","github":"ada"},"merge":{"default":"human"},"workers":{"default":{"github":"ada"}},"checks":{"test":""}}' \
  >"$EMPTY/.relentless/config.json"
printf '%s\n' 'name: fill' 'jobs:' '  test:' '    steps:' '      - run: npm run test:filled' \
  >"$EMPTY/.github/workflows/consumer.yml"
set +e
out_empty="$(
  PATH="$TMP/bin:$PATH" \
  bash "$BOOT" --repo o/r --workdir "$EMPTY" \
    --harness claude --apply --merge-default human --decider Ada --decider-github ada \
    --no-init-empty 2>&1
)"
rc_empty=$?
set -e
filled="$(jq -r '.checks.test // empty' "$EMPTY/.relentless/config.json")"
if [[ $rc_empty -eq 0 && "$filled" == "npm run test:filled" \
  && "$out_empty" == *"config fill: checks.test"* ]] \
  && grep -q 'npm run test:filled' "$EMPTY/AGENTS.md"; then
  ok "empty checks.test filled from the repo workflow"
else
  bad "empty checks.test not filled (rc=$rc_empty got='$filled')"
fi

# A fresh bootstrap still writes every layer false and does not install githooks.
FRESH="$TMP/layers-off"
mkdir -p "$FRESH"
git -C "$FRESH" init -q -b main
git -C "$FRESH" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
set +e
out_off="$(
  PATH="$TMP/bin:$PATH" \
  bash "$BOOT" --repo o/r --workdir "$FRESH" \
    --harness both --apply --merge-default human --decider Ada --decider-github ada \
    --no-init-empty 2>&1
)"
rc_off=$?
set -e
if [[ $rc_off -eq 0 \
  && "$(jq -r '.layers.merge' "$FRESH/.relentless/config.json")" == "false" \
  && "$(jq -r '.layers.githooks' "$FRESH/.relentless/config.json")" == "false" \
  && "$(jq -r '.layers.review' "$FRESH/.relentless/config.json")" == "false" \
  && ! -e "$FRESH/.relentless/githooks/pre-commit" ]] \
  && grep -q 'state:review' "$FRESH/AGENTS.md" \
  && ! grep -q 'merge-if-ready' "$FRESH/AGENTS.md"; then
  ok "fresh bootstrap writes every layer false and the docs block ends at state:review"
else
  bad "fresh layers were not all false: $(jq -c '.layers // empty' "$FRESH/.relentless/config.json" 2>/dev/null || true) rc=$rc_off"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
