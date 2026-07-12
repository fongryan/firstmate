#!/usr/bin/env bash
# Backend-neutral closed-loop task lifecycle contract.
#
# This file is intentionally pure: it owns vocabulary, transition policy, and
# receipt-field hygiene. Durable mutation belongs to fm-lifecycle.sh.

FM_LIFECYCLE_SCHEMA=${FM_LIFECYCLE_SCHEMA:-fm-lifecycle.v1}

fm_lifecycle_is_state() {
  case "${1:-}" in
    queued|active|blocked|needs-decision|ready-for-review|interrupted|completed|superseded|abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

fm_lifecycle_is_terminal() {
  case "${1:-}" in
    interrupted|completed|superseded|abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

fm_lifecycle_valid_id() {
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_lifecycle_clean_field() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

fm_lifecycle_now() {
  if [ -n "${FM_LIFECYCLE_NOW:-}" ]; then
    printf '%s\n' "$FM_LIFECYCLE_NOW"
  else
    date +%s
  fi
}

fm_lifecycle_transition_allowed() {
  local from=${1:-} to=${2:-}
  fm_lifecycle_is_state "$from" || return 1
  fm_lifecycle_is_state "$to" || return 1
  [ "$from" != "$to" ] || return 0
  case "$from:$to" in
    queued:active|queued:abandoned|queued:superseded) return 0 ;;
    active:blocked|active:needs-decision|active:ready-for-review|active:interrupted|active:completed|active:superseded|active:abandoned) return 0 ;;
    blocked:active|blocked:needs-decision|blocked:interrupted|blocked:superseded|blocked:abandoned) return 0 ;;
    needs-decision:active|needs-decision:blocked|needs-decision:interrupted|needs-decision:superseded|needs-decision:abandoned) return 0 ;;
    ready-for-review:active|ready-for-review:completed|ready-for-review:interrupted|ready-for-review:superseded|ready-for-review:abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

fm_lifecycle_default_heartbeat_ttl() {
  printf '%s\n' "${FM_LIFECYCLE_HEARTBEAT_TTL:-900}"
}

fm_lifecycle_default_grace() {
  printf '%s\n' "${FM_LIFECYCLE_HEARTBEAT_GRACE:-300}"
}
