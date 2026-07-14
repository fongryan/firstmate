#!/usr/bin/env bash
# Import legacy state/<id>.meta records into the canonical lifecycle ledger.
# This is idempotent and never deletes or rewrites legacy runtime metadata.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NOW="${FM_LIFECYCLE_IMPORT_NOW:-$(date +%s)}"

meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
[ -d "$STATE" ] || exit 0
imported=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ -f "$STATE/$id.lifecycle" ] && continue
  worktree=$(meta_get "$meta" worktree)
  project=$(meta_get "$meta" project)
  repo=$(basename "${project:-$id}")
  branch=detached
  if [ -d "$worktree" ]; then
    branch=$(git -C "$worktree" branch --show-current 2>/dev/null || printf detached)
    [ -n "$branch" ] || branch=detached
  fi
  objective=$(grep -m1 -v '^[[:space:]]*#\|^[[:space:]]*$' "$DATA/$id/brief.md" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  [ -n "$objective" ] || objective="legacy task $id"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_RESTORE=1 FM_LIFECYCLE_NOW="$NOW" \
    "$SCRIPT_DIR/fm-lifecycle.sh" register "$id" --state active --repo "$repo" \
    --owner "$id" --branch "$branch" --worktree "${worktree:-$project}" \
    --objective "$objective" >/dev/null || continue
  imported=$((imported + 1))
done
printf 'lifecycle-imported=%s\n' "$imported"
