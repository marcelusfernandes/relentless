#!/usr/bin/env bash
# Every YAML file under core/templates/github/ must load.
# The unquoted "Theme: subtitle" line used to make epic.yml invalid.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

if ! command -v ruby >/dev/null 2>&1; then
  echo "ruby is required to parse the GitHub templates" >&2
  exit 1
fi

parse() {
  ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" >/dev/null 2>"$TMP/err"
}

bad_yaml="$TMP/bad.yml"
cat >"$bad_yaml" <<'EOF'
description: Same outcome as the milestone (Theme: subtitle).
EOF
if parse "$bad_yaml"; then
  bad "parser accepted an unquoted colon-space scalar"
else
  ok
fi

found=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  found=$((found + 1))
  if parse "$f"; then
    ok
  else
    bad "$f: $(cat "$TMP/err")"
  fi
done < <(find "$ROOT/core/templates/github" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

if [[ "$found" -eq 0 ]]; then
  bad "no YAML files under core/templates/github"
else
  ok
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
