#!/usr/bin/env bash
# F46/F47/F48 — bootstrap --upgrade refreshes owned files, preserves checks + CI.
# --upgrade also retires the v1.4.11 Codex marketplace pin.
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

# Legacy Codex pin. The two pin comments and the two relentless tables go.
# Every other line stays byte for byte. A file that is only the pin is removed.
# Dry-run prints the retire line and does not write. No pin leaves the file.
write_pin_consumer() { # dest
  mkdir -p "$1/.relentless" "$1/.codex"
  cat >"$1/.relentless/config.json" <<'JSON'
{
  "decider": { "name": "Ada", "github": "ada" },
  "merge": { "default": "human" },
  "workers": { "default": { "github": "ada" } },
  "checks": { "test": "npm test" },
  "layers": {
    "merge": false, "review": false, "qa": false, "worktrees": false,
    "decisions": false, "templates": false, "ci": false, "githooks": false, "docs": false
  }
}
JSON
}

run_pin_boot() { # workdir [bootstrap args...]
  local dir="$1"
  shift
  PATH="$TMP/bin:$PATH" bash "$BOOT" --repo o/r --workdir "$dir" \
    --harness codex --merge-default human --decider Ada --decider-github ada \
    --no-init-empty "$@" 2>&1
}

# Unrelated lines, including trailing spaces and a table between the two pin tables.
pin_mixed_input() {
  printf '%s\n' \
    '# kept top comment' \
    'model = "kept"' \
    'top_key = "value"  ' \
    'hint = "re-run bootstrap --upgrade or edit ref= below."' \
    '' \
    '# Relentless Codex pin (no native per-project plugin lockfile on 0.165.x).' \
    '# After bumping the plugin, re-run bootstrap --upgrade or edit ref= below.' \
    '# kept beside the pin' \
    '[marketplaces.relentless]' \
    'source_type = "git"' \
    'source = "https://github.com/example/relentless"' \
    'ref = "v1.4.11"' \
    '' \
    '[kept.middle]' \
    'middle = "stay"' \
    '# middle comment stays' \
    '' \
    '[plugins."relentless@relentless"]' \
    'enabled = true' \
    '' \
    '[kept.tail]' \
    'tail = "stay"' \
    '# tail comment'
}

pin_mixed_expected() {
  printf '%s\n' \
    '# kept top comment' \
    'model = "kept"' \
    'top_key = "value"  ' \
    'hint = "re-run bootstrap --upgrade or edit ref= below."' \
    '' \
    '# kept beside the pin' \
    '[kept.middle]' \
    'middle = "stay"' \
    '# middle comment stays' \
    '' \
    '[kept.tail]' \
    'tail = "stay"' \
    '# tail comment'
}

pin_only_input() {
  printf '%s\n' \
    '# Relentless Codex pin (no native per-project plugin lockfile on 0.165.x).' \
    '# After bumping the plugin, re-run bootstrap --upgrade or edit ref= below.' \
    '[marketplaces.relentless]' \
    'source_type = "git"' \
    'source = "https://github.com/example/relentless"' \
    'ref = "v1.4.11"' \
    '' \
    '[plugins."relentless@relentless"]' \
    'enabled = true'
}

# The upgrade-append writer used one comment and a leading blank line.
pin_append_only_input() {
  printf '%s\n' \
    '' \
    '# Relentless Codex pin (added by bootstrap --upgrade)' \
    '[marketplaces.relentless]' \
    'source_type = "git"' \
    'source = "https://github.com/example/relentless"' \
    'ref = "v1.4.11"' \
    '' \
    '[plugins."relentless@relentless"]' \
    'enabled = true'
}

pin_plain_input() {
  printf '%s\n' \
    '# ordinary comment' \
    'model = "kept"' \
    '' \
    '[other]' \
    'key = "value"' \
    '# still here'
}

MIX="$TMP/pin-mix"
write_pin_consumer "$MIX"
pin_mixed_input >"$MIX/.codex/config.toml"
pin_mixed_expected >"$TMP/pin-expected"
set +e
out_pin="$(run_pin_boot "$MIX" --upgrade --apply)"
rc_pin=$?
set -e
if [[ $rc_pin -eq 0 ]] && printf '%s\n' "$out_pin" | grep -Fqx 'retire: .codex/config.toml legacy marketplace pin'; then
  ok "apply upgrade prints the retire line"
else
  bad "apply upgrade retire line missing (rc=$rc_pin)"
fi
if cmp -s "$MIX/.codex/config.toml" "$TMP/pin-expected" \
  && ! grep -q '# Relentless Codex pin' "$MIX/.codex/config.toml" \
  && ! grep -q '\[marketplaces\.relentless\]' "$MIX/.codex/config.toml" \
  && ! grep -q '\[plugins\."relentless@relentless"\]' "$MIX/.codex/config.toml"; then
  ok "legacy pin removed and other lines byte-preserved"
else
  bad "legacy pin mix was not byte-preserved"
  diff -u "$TMP/pin-expected" "$MIX/.codex/config.toml" >&2 || true  # intentional: diff exits 1 when the files differ
fi
set +e
out_pin2="$(run_pin_boot "$MIX" --upgrade --apply)"
rc_pin2=$?
set -e
if [[ $rc_pin2 -eq 0 ]] && cmp -s "$MIX/.codex/config.toml" "$TMP/pin-expected" \
  && ! printf '%s\n' "$out_pin2" | grep -q 'legacy marketplace pin'; then
  ok "retiring the pin is idempotent"
else
  bad "second upgrade changed the retired config (rc=$rc_pin2)"
fi

ONLY="$TMP/pin-only"
write_pin_consumer "$ONLY"
pin_only_input >"$ONLY/.codex/config.toml"
set +e
out_only="$(run_pin_boot "$ONLY" --upgrade --apply)"
rc_only=$?
set -e
if [[ $rc_only -eq 0 && ! -e "$ONLY/.codex/config.toml" ]] \
  && printf '%s\n' "$out_only" | grep -Fqx 'retire: .codex/config.toml legacy marketplace pin'; then
  ok "config that is only the legacy pin is removed"
else
  bad "pin-only config.toml was not removed (rc=$rc_only)"
fi
set +e
out_only2="$(run_pin_boot "$ONLY" --upgrade --apply)"
rc_only2=$?
set -e
if [[ $rc_only2 -eq 0 && ! -e "$ONLY/.codex/config.toml" ]]; then
  ok "removing a pin-only config is idempotent"
else
  bad "second upgrade on a removed pin recreated config.toml (rc=$rc_only2)"
fi

APPEND="$TMP/pin-append"
write_pin_consumer "$APPEND"
pin_append_only_input >"$APPEND/.codex/config.toml"
set +e
out_append="$(run_pin_boot "$APPEND" --upgrade --apply)"
rc_append=$?
set -e
if [[ $rc_append -eq 0 && ! -e "$APPEND/.codex/config.toml" ]]; then
  ok "upgrade-append pin with only whitespace left is removed"
else
  bad "upgrade-append pin file was not removed (rc=$rc_append)"
fi

DRY="$TMP/pin-dry"
write_pin_consumer "$DRY"
pin_mixed_input >"$DRY/.codex/config.toml"
cp "$DRY/.codex/config.toml" "$TMP/pin-dry-before"
set +e
out_dry="$(run_pin_boot "$DRY" --upgrade)"
rc_dry=$?
set -e
if [[ $rc_dry -eq 0 ]] && cmp -s "$DRY/.codex/config.toml" "$TMP/pin-dry-before" \
  && printf '%s\n' "$out_dry" | grep -Fqx 'retire (dry-run): .codex/config.toml legacy marketplace pin' \
  && grep -q '# Relentless Codex pin' "$DRY/.codex/config.toml"; then
  ok "dry-run prints the retire line and leaves the pin file untouched"
else
  bad "dry-run changed the pin file or skipped the retire line (rc=$rc_dry)"
fi

PLAIN="$TMP/pin-plain"
write_pin_consumer "$PLAIN"
pin_plain_input >"$PLAIN/.codex/config.toml"
cp "$PLAIN/.codex/config.toml" "$TMP/pin-plain-before"
set +e
out_plain="$(run_pin_boot "$PLAIN" --upgrade --apply)"
rc_plain=$?
set -e
if [[ $rc_plain -eq 0 ]] && cmp -s "$PLAIN/.codex/config.toml" "$TMP/pin-plain-before" \
  && ! printf '%s\n' "$out_plain" | grep -q 'legacy marketplace pin'; then
  ok "config with no legacy pin is left untouched"
else
  bad "config without a pin was changed (rc=$rc_plain)"
fi

HOLD="$TMP/pin-hold"
write_pin_consumer "$HOLD"
pin_mixed_input >"$HOLD/.codex/config.toml"
cp "$HOLD/.codex/config.toml" "$TMP/pin-hold-before"
set +e
out_hold="$(run_pin_boot "$HOLD" --apply)"
rc_hold=$?
set -e
if [[ $rc_hold -eq 0 ]] && cmp -s "$HOLD/.codex/config.toml" "$TMP/pin-hold-before" \
  && ! printf '%s\n' "$out_hold" | grep -q 'legacy marketplace pin'; then
  ok "without --upgrade the legacy pin stays"
else
  bad "bootstrap without --upgrade edited the legacy pin (rc=$rc_hold)"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
