#!/usr/bin/env bash
# M1 — bootstrap writes only .relentless/config.json, the docs block, and the
# missing core labels. A customized consumer (default branch develop, its own
# labels including bug with its own color and description, its own CI workflow,
# its own issue and PR templates, squash-only merge) keeps everything else.
#
# Expected red on v1.4.11. Later minimal-cut PRs turn it green.
# The fixture is built in this test. It does not read or write any real repo.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

BOOT="$ROOT/core/scripts/bootstrap.sh"
REPO="$TMP/repo"
mkdir -p "$REPO/.github/ISSUE_TEMPLATE" "$REPO/.github/workflows" "$TMP/bin"

# Consumer-owned tree. Not a copy of any real project.
printf '%s\n' 'Consumer app. Default branch is develop. Merges are squash.' >"$REPO/README.md"
printf '%s\n' 'Consumer handbook stays.' >"$REPO/AGENTS.md"
printf '%s\n' 'node_modules/' >"$REPO/.gitignore"
printf '%s\n' '{"scripts":{"test":"vitest","lint":"eslint","build":"vite build"}}' >"$REPO/package.json"
printf '%s\n' 'name: consumer' 'on: [push, pull_request]' 'jobs:' '  test:' '    runs-on: ubuntu-latest' \
  '    steps:' '      - run: npm run test:consumer' >"$REPO/.github/workflows/consumer.yml"
printf '%s\n' 'name: Consumer bug' 'description: Filed by the consumer.' 'body:' '  - type: textarea' \
  >"$REPO/.github/ISSUE_TEMPLATE/bug.yml"
printf '%s\n' 'blank_issues_enabled: true' 'contact_links:' '  - name: Consumer handbook' \
  >"$REPO/.github/ISSUE_TEMPLATE/config.yml"
printf '%s\n' '## Consumer pull request' 'Squash when merging.' >"$REPO/.github/PULL_REQUEST_TEMPLATE.md"

# bug keeps a custom color and description. state:todo is already present.
# Core labels still missing: the rest of state:*, human:pending, human:decided, epic.
printf '%s\t%s\t%s\n' \
  'bug' 'c0ffee' 'Consumer-owned bug label' \
  'wontfix' 'ffffff' 'Consumer wontfix' \
  'state:todo' '111111' 'Consumer ready' >"$TMP/labels.tsv"
cp "$TMP/labels.tsv" "$TMP/labels-before.tsv"
: >"$TMP/label-edits"
printf '%s\n' '{"allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":false}' \
  >"$TMP/merge-settings.json"
cp "$TMP/merge-settings.json" "$TMP/merge-settings-before.json"

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
    echo develop
    exit 0
  fi
  exit 0
fi
if [[ "$1" == "label" && "$2" == "list" ]]; then
  cut -f1 "${LABEL_STATE:?}"
  exit 0
fi
if [[ "$1" == "label" && "$2" == "edit" ]]; then
  printf '%s\n' "$*" >>"${LABEL_EDITS:?}"
  exit 0
fi
if [[ "$1" == "label" && "$2" == "create" ]]; then
  name="$3"
  color=""
  desc=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--color" ]]; then color="$arg"; fi
    if [[ "$prev" == "--description" ]]; then desc="$arg"; fi
    prev="$arg"
  done
  printf '%s\t%s\t%s\n' "$name" "$color" "$desc" >>"${LABEL_STATE:?}"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  case "$*" in
    *user*) echo ada; exit 0 ;;
  esac
  if [[ -f "${MERGE_SETTINGS:-}" ]]; then
    cat "$MERGE_SETTINGS"
    exit 0
  fi
  echo ada
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

# Refuse to continue if PATH would reach a real gh. The stub must be the only gh.
require_stub_gh() {
  local got
  # command -v exits 1 when gh is absent; that miss is the guard, not a crash.
  got="$(PATH="$TMP/bin:$PATH" command -v gh 2>/dev/null || true)"
  if [[ "$got" != "$TMP/bin/gh" ]]; then
    bad "M1: gh on PATH is '${got:-missing}', not stub $TMP/bin/gh; refusing to call gh"
    return 1
  fi
  return 0
}
if ! require_stub_gh; then
  echo "pass=$PASS fail=$FAIL"
  exit 1
fi

git -C "$REPO" init -q -b develop
git -C "$REPO" add README.md AGENTS.md .gitignore package.json .github
git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit -q -m 'consumer baseline'
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
  bad "M1 fixture was not clean before bootstrap"
else
  ok
fi

sum_file() {
  if [[ -f "$1" ]]; then
    cksum "$1" | awk '{print $1}'
  else
    echo MISSING
  fi
}

# AGENTS.md is allowed to gain the docs block. Snapshot the rest.
before_readme="$(sum_file "$REPO/README.md")"
before_ignore="$(sum_file "$REPO/.gitignore")"
before_pkg="$(sum_file "$REPO/package.json")"
before_ci="$(sum_file "$REPO/.github/workflows/consumer.yml")"
before_bug="$(sum_file "$REPO/.github/ISSUE_TEMPLATE/bug.yml")"
before_form_cfg="$(sum_file "$REPO/.github/ISSUE_TEMPLATE/config.yml")"
before_pr="$(sum_file "$REPO/.github/PULL_REQUEST_TEMPLATE.md")"
before_merge="$(sum_file "$TMP/merge-settings.json")"

labels_via_gh() {
  PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh-list.log" LABEL_STATE="$TMP/labels.tsv" \
    LABEL_EDITS="$TMP/label-edits" MERGE_SETTINGS="$TMP/merge-settings.json" \
    "$TMP/bin/gh" label list --repo acme/consumer --limit 200 --json name -q '.[].name'
}

: >"$TMP/gh-list.log"
labels_via_gh | sort >"$TMP/names-before"

: >"$TMP/gh.log"
out="$(
  PATH="$TMP/bin:$PATH" \
  GH_LOG="$TMP/gh.log" \
  LABEL_STATE="$TMP/labels.tsv" \
  LABEL_EDITS="$TMP/label-edits" \
  MERGE_SETTINGS="$TMP/merge-settings.json" \
  bash "$BOOT" --repo acme/consumer --workdir "$REPO" \
    --merge-default human --decider Ada --decider-github ada \
    --harness both --no-init-empty --apply 2>&1
)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "M1 bootstrap exited $rc before the acceptance checks: $out"
  echo "pass=$PASS fail=$FAIL"
  exit 1
fi
ok

# git status and diff: only the config and the docs block.
{
  git -C "$REPO" diff --name-only HEAD
  git -C "$REPO" ls-files --others --exclude-standard
} | sed '/^$/d' | sort -u >"$TMP/changed"

unexpected=""
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    .relentless/config.json|AGENTS.md|CLAUDE.md) ;;
    *) unexpected="${unexpected} ${path}" ;;
  esac
done <"$TMP/changed"
if [[ -n "$unexpected" ]]; then
  bad "M1 bootstrap wrote paths other than config and the docs block:${unexpected}"
else
  ok
fi
if [[ ! -f "$REPO/.relentless/config.json" ]]; then
  bad "M1 bootstrap did not write .relentless/config.json"
else
  ok
fi
if grep -q 'relentless:start' "$REPO/AGENTS.md" && grep -q 'relentless:start' "$REPO/CLAUDE.md" \
  && grep -q 'Consumer handbook stays.' "$REPO/AGENTS.md"; then
  ok
else
  bad "M1 docs block missing, or consumer text in AGENTS.md was replaced"
fi

if [[ "$(sum_file "$REPO/README.md")" == "$before_readme" \
  && "$(sum_file "$REPO/.gitignore")" == "$before_ignore" \
  && "$(sum_file "$REPO/package.json")" == "$before_pkg" \
  && "$(sum_file "$REPO/.github/workflows/consumer.yml")" == "$before_ci" \
  && "$(sum_file "$REPO/.github/ISSUE_TEMPLATE/bug.yml")" == "$before_bug" \
  && "$(sum_file "$REPO/.github/ISSUE_TEMPLATE/config.yml")" == "$before_form_cfg" \
  && "$(sum_file "$REPO/.github/PULL_REQUEST_TEMPLATE.md")" == "$before_pr" \
  && "$(git -C "$REPO" diff -- README.md .gitignore package.json .github/workflows/consumer.yml .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/config.yml .github/PULL_REQUEST_TEMPLATE.md)" == "" ]]; then
  ok
else
  bad "M1 bootstrap changed a consumer file (CI, templates, or repo text)"
fi
if [[ "$(git -C "$REPO" symbolic-ref --quiet --short HEAD)" == "develop" ]]; then
  ok
else
  bad "M1 bootstrap moved the checkout off develop"
fi
if [[ "$(sum_file "$TMP/merge-settings.json")" == "$before_merge" ]]; then
  ok
else
  bad "M1 bootstrap changed squash-only merge settings"
fi
hooks_path="$(git -C "$REPO" config --get core.hooksPath || true)"
if [[ -n "$hooks_path" ]]; then
  bad "M1 bootstrap set core.hooksPath=${hooks_path}; only config, the docs block, and missing core labels may change"
else
  ok
fi

# Stubbed gh label list, before vs after. Core set is state:*, human:pending,
# human:decided, and epic. Existing labels, including bug, stay as they were.
printf '%s\n' \
  'state:todo' 'state:in-progress' 'state:blocked' 'state:review' 'state:done' \
  'human:pending' 'human:decided' 'epic' | sort >"$TMP/core-names"

labels_via_gh | sort >"$TMP/names-after"
comm -13 "$TMP/names-before" "$TMP/names-after" >"$TMP/added"
comm -23 "$TMP/added" "$TMP/core-names" >"$TMP/extras"
comm -23 "$TMP/core-names" "$TMP/names-after" >"$TMP/core-still-missing"

if [[ -s "$TMP/label-edits" ]]; then
  bad "M1 bootstrap edited an existing label: $(tr '\n' ' ' <"$TMP/label-edits")"
else
  ok
fi
gone=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if ! grep -Fxq "$line" "$TMP/labels.tsv"; then
    gone="${gone} ${line}"
  fi
done <"$TMP/labels-before.tsv"
if [[ -n "$gone" ]]; then
  bad "M1 bootstrap changed an existing label line:${gone}"
else
  ok
fi
if [[ -s "$TMP/extras" ]]; then
  bad "M1 labels added outside the core set: $(tr '\n' ' ' <"$TMP/extras")"
else
  ok
fi
if [[ -s "$TMP/core-still-missing" ]]; then
  bad "M1 missing core labels were not created: $(tr '\n' ' ' <"$TMP/core-still-missing")"
else
  ok
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
