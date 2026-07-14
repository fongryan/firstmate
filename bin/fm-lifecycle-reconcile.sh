#!/usr/bin/env bash
# Read-only worktree ownership reconciliation. It never removes worktrees.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-lifecycle-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
JSON=0
case "${1:-}" in --json) JSON=1 ;; ''|--dry-run) : ;; -h|--help) echo "usage: fm-lifecycle-reconcile.sh [--json]"; exit 0 ;; *) echo "unknown option: $1" >&2; exit 2 ;; esac
meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
emit() {
  local id=$1 state=$2 action=$3 worktree=$4 detail=$5
  if [ "$JSON" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || { echo "jq required for --json" >&2; exit 1; }
    jq -cn --arg id "$id" --arg state "$state" --arg action "$action" --arg worktree "$worktree" --arg detail "$detail" '{id:$id,state:$state,action:$action,worktree:$worktree,detail:$detail}'
  else
    printf '%s state=%s action=%s worktree=%s detail=%s\n' "$id" "$state" "$action" "$worktree" "$detail"
  fi
}

for record in "$STATE"/*.lifecycle; do
  [ -f "$record" ] || continue
  id=$(basename "$record" .lifecycle)
  state=$(meta_get "$record" state); worktree=$(meta_get "$record" worktree); lease=$(meta_get "$record" lease)
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    emit "$id" "$state" protected-missing "$worktree" "worktree absent; preserve lifecycle evidence"
    continue
  fi
  if [ -n "$lease" ] && [ "$lease" != 0 ]; then
    emit "$id" "$state" protected-leased "$worktree" "explicit lease marker present"
    continue
  fi
  if ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    emit "$id" "$state" protected-unknown "$worktree" "not a git worktree"
    continue
  fi
  dirty=$(git -C "$worktree" status --porcelain 2>/dev/null || printf '?')
  if [ -n "$dirty" ]; then
    emit "$id" "$state" protected-dirty "$worktree" "uncommitted work present"
    continue
  fi
  if fm_lifecycle_is_terminal "$state"; then
    emit "$id" "$state" eligible-return "$worktree" "terminal and clean; caller may perform explicit return"
  else
    emit "$id" "$state" protected-active "$worktree" "non-terminal owner still required"
  fi
done
