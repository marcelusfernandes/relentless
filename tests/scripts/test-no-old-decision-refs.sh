#!/usr/bin/env bash
# The old human-decision names stay only in the scripts PR 4 deletes, the tests
# of those scripts, and hooks.json (its command path ends in the same filename
# the pattern matches).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if ! command -v rg >/dev/null 2>&1; then
  echo "rg is required" >&2
  exit 1
fi

# Built so this file does not itself contain the searched text.
req=request
dec=decision
ds=decide
aa=accept
left=Decided
right=by
pattern="${req}-${dec}|${ds}\\.sh|${aa}-adr|${left} ${right}"

allow=(
  "core/scripts/${req}-${dec}.sh"
  "core/scripts/${ds}.sh"
  "core/scripts/lib/human-${dec}.sh"
  "hooks/scripts/userprompt-${ds}.sh"
  "hooks/scripts/pretool-gh-workflow.sh"
  "core/scripts/${aa}-adr.sh"
  "core/scripts/check-milestone-pending.sh"
  "tests/hooks/test-${ds}-guard.sh"
  "tests/hooks/test-hooks.sh"
  "hooks/hooks.json"
)

globs=()
for path in "${allow[@]}"; do
  globs+=(--glob "!${path}")
done

set +e
hits="$(rg -n --hidden --glob '!.git/**' "${globs[@]}" -e "$pattern" .)"
rc=$?
set -e
if [[ "$rc" -eq 1 && -z "$hits" ]]; then
  echo "rg clean outside the allowlist"
  printf 'allowlist:\n'
  printf '  %s\n' "${allow[@]}"
  exit 0
fi
if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
  echo "rg failed rc=$rc" >&2
  exit 1
fi
echo "rg hits outside the allowlist:"
printf '%s\n' "$hits"
exit 1
