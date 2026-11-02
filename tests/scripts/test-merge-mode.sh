#!/usr/bin/env bash
# allow_issue_override false ignores merge:* labels. true lets the label win.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GH_LABELS:?}"
EOF
chmod +x "$TMP/bin/gh"

# shellcheck source=../../core/scripts/lib/common.sh
source "$ROOT/core/scripts/lib/common.sh"

write_cfg() { # default override
  jq -n --arg d "$1" --argjson o "$2" '{merge:{default:$d, allow_issue_override:$o}}' >"$TMP/config.json"
}

run_mode() {
  PATH="$TMP/bin:$PATH" GH_LABELS="$1" resolve_merge_mode o/r 9 "$TMP/config.json"
}

write_cfg human false
got="$(run_mode "merge:auto")"
if [[ "$got" == "human" ]]; then
  ok
else
  bad "override false should ignore merge:auto and use human, got $got"
fi

write_cfg human true
got="$(run_mode "merge:auto")"
if [[ "$got" == "auto" ]]; then
  ok
else
  bad "override true should let merge:auto win, got $got"
fi

echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
