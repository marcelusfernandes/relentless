#!/usr/bin/env bash
# Re-running bootstrap adds what is missing and leaves customizations alone.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

BOOT="$ROOT/core/scripts/bootstrap.sh"
REPO_DIR="$TMP/repo"
mkdir -p "$REPO_DIR/.relentless" "$REPO_DIR/.github/ISSUE_TEMPLATE" "$REPO_DIR/.github/workflows" "$TMP/bin"

cat >"$REPO_DIR/.relentless/config.json" <<'JSON'
{
  "decider": { "name": "Lipe", "github": "lipedesign" },
  "merge": { "default": "human", "allow_issue_override": false },
  "workers": {
    "default": { "github": "lipedesign" },
    "qa": { "github": "someone" }
  },
  "stack": "node",
  "package_manager": "pnpm",
  "checks": {
    "install": "pnpm install --frozen-lockfile",
    "lint": "pnpm run lint",
    "typecheck": "pnpm run typecheck",
    "test": "pnpm run test:unit && pnpm exec playwright test",
    "build": "pnpm run build"
  },
  "hexgym": { "studio": "lipe", "note": "do not clobber" },
  "layers": {
    "merge": false, "review": false, "qa": false, "worktrees": false,
    "decisions": false, "templates": false, "ci": false, "githooks": false, "docs": false
  }
}
JSON
printf '%s\n' '{"scripts":{"test":"vitest","lint":"eslint","build":"vite build"}}' >"$REPO_DIR/package.json"

# Edited forms. investigation.yml is absent. layers.templates is not set, so
# bootstrap must leave it absent and must not rewrite the forms that exist.
sed 's/Product outcome/Product outcome HEXGYM/' \
  "$ROOT/core/templates/github/ISSUE_TEMPLATE/epic.yml" >"$REPO_DIR/.github/ISSUE_TEMPLATE/epic.yml"
printf '%s\n' 'blank_issues_enabled: false' 'contact_links:' '  - name: HexGym custom' \
  >"$REPO_DIR/.github/ISSUE_TEMPLATE/config.yml"
printf '%s\n' 'name: HexGym relentless form' \
  >"$REPO_DIR/.github/ISSUE_TEMPLATE/relentless.yml"
# Deleted workflow stays deleted.
rm -f "$REPO_DIR/.github/workflows/relentless-ci.yml"

# Remote label state. bug was recolored; bootstrap must not edit it.
printf '%s\n' 'bug ffffff Custom bug label from HexGym' >"$TMP/label-state"
printf '%s\n' 'bug' >"$TMP/label-names"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
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
if [[ "$1" == "label" && "$2" == "list" ]]; then
  cat "${LABEL_NAMES:?}"
  exit 0
fi
if [[ "$1" == "label" && "$2" == "edit" ]]; then
  echo "$*" >>"${LABEL_EDITS:?}"
  exit 0
fi
if [[ "$1" == "label" && "$2" == "create" ]]; then
  printf '%s\n' "$3" >>"${LABEL_NAMES:?}"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo lipedesign
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

sum_file() {
  if [[ -f "$1" ]]; then
    # checksum without depending on GNU cksum flags
    cksum "$1" | awk '{print $1}'
  else
    echo MISSING
  fi
}

epic_sum="$(sum_file "$REPO_DIR/.github/ISSUE_TEMPLATE/epic.yml")"
config_yml_sum="$(sum_file "$REPO_DIR/.github/ISSUE_TEMPLATE/config.yml")"
form_sum="$(sum_file "$REPO_DIR/.github/ISSUE_TEMPLATE/relentless.yml")"
label_sum="$(sum_file "$TMP/label-state")"

run_boot() { # extra args
  : >"$TMP/gh.log"
  : >"$TMP/label-edits"
  out="$(
    PATH="$TMP/bin:$PATH" \
    GH_LOG="$TMP/gh.log" \
    LABEL_NAMES="$TMP/label-names" \
    LABEL_EDITS="$TMP/label-edits" \
    bash "$BOOT" --repo o/r --workdir "$REPO_DIR" \
      --merge-default auto --decider Other --decider-github other \
      --harness both --no-init-empty "$@" 2>&1
  )"
  rc=$?
}

assert_kept() {
  local phase="$1"
  local now_epic now_cfg now_form now_label
  now_epic="$(sum_file "$REPO_DIR/.github/ISSUE_TEMPLATE/epic.yml")"
  now_cfg="$(sum_file "$REPO_DIR/.github/ISSUE_TEMPLATE/config.yml")"
  now_form="$(sum_file "$REPO_DIR/.github/ISSUE_TEMPLATE/relentless.yml")"
  now_label="$(sum_file "$TMP/label-state")"
  if [[ "$rc" -ne 0 ]]; then
    bad "$phase exit $rc: $out"
    return
  fi
  if [[ -s "$TMP/label-edits" ]]; then
    bad "$phase edited a label: $(cat "$TMP/label-edits")"
    return
  fi
  if [[ "$now_epic" != "$epic_sum" || "$now_cfg" != "$config_yml_sum" || "$now_form" != "$form_sum" ]]; then
    bad "$phase rewrote a form or config.yml"
    return
  fi
  if [[ "$now_label" != "$label_sum" ]]; then
    bad "$phase changed label color or description"
    return
  fi
  if [[ -e "$REPO_DIR/.github/workflows/relentless-ci.yml" ]]; then
    bad "$phase recreated relentless-ci.yml"
    return
  fi
  local stack pm test_cmd merge_default override studio
  stack="$(jq -r '.stack' "$REPO_DIR/.relentless/config.json")"
  pm="$(jq -r '.package_manager' "$REPO_DIR/.relentless/config.json")"
  test_cmd="$(jq -r '.checks.test' "$REPO_DIR/.relentless/config.json")"
  merge_default="$(jq -r '.merge.default' "$REPO_DIR/.relentless/config.json")"
  override="$(jq -r '.merge.allow_issue_override' "$REPO_DIR/.relentless/config.json")"
  studio="$(jq -r '.hexgym.studio' "$REPO_DIR/.relentless/config.json")"
  if [[ "$stack" == "node" && "$pm" == "pnpm" && "$merge_default" == "human" \
    && "$override" == "false" && "$studio" == "lipe" \
    && "$test_cmd" == "pnpm run test:unit && pnpm exec playwright test" \
    && "$(jq -r '.workers.qa.github' "$REPO_DIR/.relentless/config.json")" == "someone" \
    && "$(jq -r '.decider.name' "$REPO_DIR/.relentless/config.json")" == "Lipe" ]]; then
    ok
  else
    bad "$phase config changed: $(cat "$REPO_DIR/.relentless/config.json")"
  fi
}

run_boot --apply
assert_kept "apply 1"
if [[ -f "$REPO_DIR/.github/ISSUE_TEMPLATE/investigation.yml" ]]; then
  bad "apply 1 created investigation.yml while layers.templates is not true"
else
  ok
fi
cfg_after_first="$(jq -S . "$REPO_DIR/.relentless/config.json")"

run_boot --apply
assert_kept "apply 2"
run_boot --upgrade --apply
assert_kept "upgrade apply 1"
run_boot --upgrade --apply
assert_kept "upgrade apply 2"

if [[ -f "$REPO_DIR/.github/ISSUE_TEMPLATE/investigation.yml" ]]; then
  bad "later runs created the investigation form"
else
  ok
fi
if [[ "$(jq -S . "$REPO_DIR/.relentless/config.json")" == "$cfg_after_first" ]]; then
  ok
else
  bad "config changed after the first apply"
fi
if ! grep -q 'bug' "$TMP/label-names"; then
  bad "bug label disappeared"
else
  ok
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
