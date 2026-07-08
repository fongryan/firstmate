#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
#        fm-merge-local.sh --all-ready [--repo <name>] [--dry-run]
#   --all-ready: scan every local-only ship task whose fm/<id> branch exists in
#     its project clone, and rebase-and-merge each in sequence. After each merge
#     advances the default branch, the next task's branch is rebased onto the
#     new default before its merge, so a batch of branches originally forked
#     from the same base all land cleanly without manual inter-merge rebasing.
#     --repo limits to one project; --dry-run reports what would happen.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

default_branch() {
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

merge_one() {
  local id=$1 proj=$2 dry_run=${3:-0}
  local meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  local mode kind
  mode=$(grep '^mode=' "$meta" | cut -d= -f2- || true)
  kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
  [ "$mode" = local-only ] || return 0
  [ "$kind" = ship ] || return 0

  local branch="fm/$id"
  git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 || return 0

  local default cur
  default=$(default_branch "$proj") || { echo "SKIP $id: cannot determine default branch for $proj" >&2; return 0; }

  # Already merged?
  if git -C "$proj" merge-base --is-ancestor "$branch" "$default" 2>/dev/null; then
    echo "SKIP $id: $branch already merged into $default"
    return 0
  fi

  cur=$(git -C "$proj" symbolic-ref --short HEAD 2>/dev/null || echo "")
  [ "$cur" = "$default" ] || { echo "SKIP $id: $proj is on '$cur', not '$default'" >&2; return 0; }

  if [ -n "$(git -C "$proj" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "SKIP $id: $proj has dirty working tree" >&2
    return 0
  fi

  # FF already?
  if git -C "$proj" merge-base --is-ancestor "$default" "$branch" 2>/dev/null; then
    if [ "$dry_run" = 1 ]; then
      echo "DRY-RUN: would merge $branch into $default (already FF)"
      return 0
    fi
    local before after
    before=$(git -C "$proj" rev-parse --short "$default")
    git -C "$proj" merge --ff-only "$branch" >/dev/null
    after=$(git -C "$proj" rev-parse --short "$default")
    echo "merged $branch into local $default ($before -> $after) in $proj"
    return 0
  fi

  # Not FF — rebase onto current default, then merge.
  if [ "$dry_run" = 1 ]; then
    echo "DRY-RUN: would rebase $branch onto $default, then merge"
    return 0
  fi
  echo "rebasing $branch onto $default..."
  if ! git -C "$proj" rebase "$default" "$branch" >/dev/null 2>&1; then
    git -C "$proj" rebase --abort 2>/dev/null || true
    echo "SKIP $id: rebase $branch onto $default failed (conflicts); needs manual attention" >&2
    return 0
  fi
  git -C "$proj" checkout "$default" >/dev/null 2>&1
  local before after
  before=$(git -C "$proj" rev-parse --short "$default")
  git -C "$proj" merge --ff-only "$branch" >/dev/null
  after=$(git -C "$proj" rev-parse --short "$default")
  echo "merged $branch into local $default ($before -> $after) in $proj (after rebase)"
}

if [ "${1:-}" = "--all-ready" ]; then
  shift
  FILTER_REPO=""
  DRY_RUN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) FILTER_REPO=$2; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
  done
  merged=0; skipped=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    proj=$(grep '^project=' "$meta" | cut -d= -f2- || true)
    [ -n "$proj" ] || continue
    [ -d "$proj" ] || continue
    if [ -n "$FILTER_REPO" ]; then
      case "$proj" in */"$FILTER_REPO") ;; *) continue ;; esac
    fi
    before_tips=$(git -C "$proj" rev-parse --short HEAD 2>/dev/null || echo "?")
    merge_one "$id" "$proj" "$DRY_RUN"
  done
  exit 0
fi

ID=${1:?usage: fm-merge-local.sh <task-id> [--all-ready [--repo <name>] [--dry-run]]}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch "$PROJ") || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
