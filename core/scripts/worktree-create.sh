#!/usr/bin/env bash
# worktree-create.sh — one writer per git worktree from the repo base branch.
# Branch naming: <type>/<issue>-<slug>  (e.g. feat/12-add-login)
# The branch is created with `gh issue develop` so it shows on the issue.
# If that command fails, this script exits with that error. It does not
# fall back to `git worktree add -b`.
#
# Usage:
#   worktree-create.sh --repo OWNER/NAME --issue N --slug SLUG [--type feat] \
#     [--workdir PATH] [--parent PATH] [--base BRANCH] [--dry-run]
#
# Creates: <parent>/<repo-basename>-wt-<N>  (or --path) checked out on the branch.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="" ISSUE="" SLUG="" TYPE="feat" WORKDIR="." PARENT="" BASE="" BASE_EXPLICIT=0 PATH_OUT="" DRY=0 NO_PUSH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --type) TYPE="${2:-}"; shift 2 ;;
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --parent) PARENT="${2:-}"; shift 2 ;;
    --path) PATH_OUT="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; BASE_EXPLICIT=1; shift 2 ;;
    --no-push) NO_PUSH=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | tr -d '#'
      exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" && -n "$ISSUE" && -n "$SLUG" ]] || { echo "need --repo --issue --slug" >&2; exit 2; }

# Normalize slug
SLUG="$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
BRANCH="${TYPE}/${ISSUE}-${SLUG}"

WORKDIR="$(cd "$WORKDIR" && pwd)"
PARENT="${PARENT:-$(dirname "$WORKDIR")}"
REPO_BASE="$(basename "$REPO")"
PATH_OUT="${PATH_OUT:-${PARENT}/${REPO_BASE}-wt-${ISSUE}}"

if [[ "$BASE_EXPLICIT" -eq 0 ]]; then
  if [[ -f "${WORKDIR}/.relentless/config.json" ]]; then
    BASE="$(jq -r '.base // empty' "${WORKDIR}/.relentless/config.json" 2>/dev/null || true)"  # intentional fail-soft: a broken config falls through to the repo
  fi
  if [[ -z "$BASE" ]]; then
    BASE="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name // empty' || true)"  # intentional fail-soft: the error is reported below
  fi
  if [[ -z "$BASE" ]]; then
    echo "error: could not resolve the base branch from .relentless/config.json or the repo" >&2
    exit 1
  fi
fi

echo "plan: worktree at $PATH_OUT"
echo "plan: branch $BRANCH from origin/${BASE} (the repo base, never another feature branch)"

if [[ "$DRY" -eq 1 ]]; then
  echo "dry-run: gh issue develop $ISSUE --repo $REPO --name $BRANCH --base $BASE"
  echo "dry-run: git fetch origin ${BRANCH} && git worktree add $PATH_OUT $BRANCH"
  exit 0
fi

(
  cd "$WORKDIR"
  git fetch origin "$BASE"
  if [[ -e "$PATH_OUT" ]]; then
    echo "error: path exists: $PATH_OUT — remove or pass --path" >&2
    exit 1
  fi
  # Link the branch to the issue. No other creation path: a failure stops here.
  gh issue develop "$ISSUE" --repo "$REPO" --base "$BASE" --name "$BRANCH"
  git fetch origin "$BRANCH"
  git worktree add "$PATH_OUT" "$BRANCH"
)

# Verify not based on another feature branch tip accidentally
(
  cd "$PATH_OUT"
  git merge-base --is-ancestor "origin/${BASE}" HEAD \
    || { echo "error: HEAD is not descended from origin/${BASE}" >&2; exit 1; }
)

if [[ "$NO_PUSH" -eq 0 ]]; then
  (
    cd "$PATH_OUT"
    # Push is the lock — fails if remote branch already exists with different history
    if ! git push -u origin "HEAD:${BRANCH}" 2>/tmp/relentless-wt-push.err; then
      if grep -qiE 'already exists|rejected|non-fast-forward' /tmp/relentless-wt-push.err; then
        echo "error: branch $BRANCH already claimed on remote (lock held). Do not steal." >&2
        cat /tmp/relentless-wt-push.err >&2
        exit 1
      fi
      cat /tmp/relentless-wt-push.err >&2
      exit 1
    fi
  )
fi

# Optional .worktreeinclude copy from primary workdir
if [[ -f "${WORKDIR}/.worktreeinclude" ]]; then
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -z "$rel" || "$rel" =~ ^# ]] && continue
    src="${WORKDIR}/${rel}"
    dest="${PATH_OUT}/${rel}"
    if [[ -e "$src" && ! -e "$dest" ]]; then
      mkdir -p "$(dirname "$dest")"
      cp -a "$src" "$dest"
      echo "copied from .worktreeinclude: $rel"
    fi
  done < "${WORKDIR}/.worktreeinclude"
fi

# Marker for hooks
mkdir -p "${PATH_OUT}/.relentless"
cat > "${PATH_OUT}/.relentless/worktree.json" <<JSON
{
  "issue": ${ISSUE},
  "branch": "${BRANCH}",
  "base": "${BASE}",
  "primary": "${WORKDIR}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

echo "export RELENTLESS_WORKTREE=\"${PATH_OUT}\""
echo "export RELENTLESS_ROLE=implementer"
echo "cd \"${PATH_OUT}\""
echo "ok: worktree ready for issue #${ISSUE} on ${BRANCH}"
