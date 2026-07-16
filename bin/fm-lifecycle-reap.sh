#!/usr/bin/env bash
# Classify stale active lifecycle records. Dry-run is the default.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-lifecycle-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODE=dry-run
JSON=0

usage() { echo "usage: fm-lifecycle-reap.sh [--dry-run|--apply] [--json]"; }
die() { echo "fm-lifecycle-reap: $1" >&2; exit 1; }

protected_live_endpoint() {
  local candidate=$1
  case $'\n'"${FM_LIFECYCLE_PROTECTED_IDS:-}"$'\n' in
    *$'\n'"$candidate"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run; shift ;;
    --apply) MODE=apply; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -d "$STATE" ] || exit 0
if [ "$JSON" -eq 1 ]; then command -v jq >/dev/null 2>&1 || die "jq required for --json"; fi

emit() {
  local id=$1 state=$2 age=$3 action=$4 reason=$5
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg id "$id" --arg state "$state" --argjson age "$age" --arg action "$action" --arg reason "$reason" \
      '{id:$id,state:$state,age_seconds:$age,action:$action,reason:$reason}'
  else
    printf '%s state=%s age=%ss action=%s reason=%s\n' "$id" "$state" "$age" "$action" "$reason"
  fi
}

now=$(fm_lifecycle_now)
case "$now" in ''|*[!0-9]*) die "invalid clock" ;; esac
records=("$STATE"/*.lifecycle)
[ -e "${records[0]}" ] || exit 0

# One AWK pass handles the fleet-wide read. The apply branch still performs a
# separately locked mutation for each actual candidate, but healthy records do
# not spawn a shell pipeline or subprocess per field.
while IFS=$'\t' read -r id state age ttl grace heartbeat deadline; do
  [ -n "$id" ] || continue
  reason="heartbeat expired after ${ttl}s ttl + ${grace}s grace"
  if protected_live_endpoint "$id"; then
    emit "$id" "$state" "$age" protected "$reason; live endpoint observed during session start"
    continue
  fi
  if [ "$MODE" = dry-run ]; then
    emit "$id" "$state" "$age" would-interrupt "$reason"
    continue
  fi
  mkdir -p "$STATE/reaper-receipts"
  evidence="$STATE/reaper-receipts/$id.$now.txt"
  if [ ! -e "$evidence" ]; then
    printf 'reaper=%s\ntask=%s\nobserved_at=%s\nheartbeat_at=%s\ndeadline=%s\nreason=%s\n' \
      "${FM_LIFECYCLE_ACTOR:-reaper}" "$id" "$now" "$heartbeat" "$deadline" "$reason" > "$evidence"
  fi
  if FM_LIFECYCLE_ACTOR=reaper FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW="$now" \
    "$SCRIPT_DIR/fm-lifecycle.sh" closeout "$id" interrupted --reason "$reason" --evidence "$evidence" >/dev/null 2>&1; then
    emit "$id" "$state" "$age" interrupted "$reason"
  else
    emit "$id" "$state" "$age" needs-review "transition failed; evidence=$evidence"
  fi
done < <(awk -F= -v now="$now" '
  FNR == 1 {
    if (file != "" && state == "active" && heartbeat ~ /^[0-9]+$/ && ttl ~ /^[0-9]+$/ && grace ~ /^[0-9]+$/ && now > heartbeat + ttl + grace)
      print id "\t" state "\t" (now - heartbeat) "\t" ttl "\t" grace "\t" heartbeat "\t" (heartbeat + ttl + grace)
    file=FILENAME; id=FILENAME; sub(/^.*\//, "", id); sub(/\.lifecycle$/, "", id)
    state=heartbeat=ttl=grace=""
  }
  $1 == "state" { state=$2 }
  $1 == "heartbeat_at" { heartbeat=$2 }
  $1 == "heartbeat_ttl" { ttl=$2 }
  $1 == "heartbeat_grace" { grace=$2 }
  END {
    if (file != "" && state == "active" && heartbeat ~ /^[0-9]+$/ && ttl ~ /^[0-9]+$/ && grace ~ /^[0-9]+$/ && now > heartbeat + ttl + grace)
      print id "\t" state "\t" (now - heartbeat) "\t" ttl "\t" grace "\t" heartbeat "\t" (heartbeat + ttl + grace)
  }
' "${records[@]}")
