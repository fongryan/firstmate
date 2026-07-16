#!/usr/bin/env bash
# Admission gate: reject duplicate active objectives and enforce per-repo WIP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-lifecycle-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID='' REPO='' OBJECTIVE='' WIP=${FM_LIFECYCLE_WIP_LIMIT:-3}

die() { echo "fm-lifecycle-admit: $1" >&2; exit 1; }
meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) ID=${2:-}; shift 2 ;;
    --repo) REPO=${2:-}; shift 2 ;;
    --objective) OBJECTIVE=${2:-}; shift 2 ;;
    --wip) WIP=${2:-}; shift 2 ;;
    -h|--help) echo "usage: fm-lifecycle-admit.sh [--id <task-id>] --repo <repo> --objective <text> [--wip N]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$REPO" ] || die "--repo is required"
[ -n "$OBJECTIVE" ] || die "--objective is required"
[ -z "$ID" ] || fm_lifecycle_valid_id "$ID" || die "invalid task id: $ID"
case "$WIP" in ''|*[!0-9]*) die "--wip must be a non-negative integer" ;; esac

active=0
for record in "$STATE"/*.lifecycle; do
  [ -f "$record" ] || continue
  state=$(meta_get "$record" state); repo=$(meta_get "$record" repo); objective=$(meta_get "$record" objective)
  case "$state" in active|blocked|needs-decision|ready-for-review) ;; *) continue ;; esac
  record_id=$(basename "$record" .lifecycle)
  if [ -n "$ID" ] && [ "$record_id" = "$ID" ]; then
    [ "$repo" = "$REPO" ] && [ "$objective" = "$OBJECTIVE" ] \
      || die "task id $ID is already active for a different repo or objective"
    continue
  fi
  [ "$repo" = "$REPO" ] || continue
  if [ "$objective" = "$OBJECTIVE" ]; then
    die "duplicate active objective for repo=$REPO (task=$record_id)"
  fi
  active=$((active + 1))
done
[ "$active" -lt "$WIP" ] || die "wip limit exhausted for repo=$REPO active=$active limit=$WIP"
printf 'admitted repo=%s active=%s limit=%s objective=%s\n' "$REPO" "$active" "$WIP" "$(fm_lifecycle_clean_field "$OBJECTIVE")"
