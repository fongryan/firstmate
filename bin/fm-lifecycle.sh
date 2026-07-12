#!/usr/bin/env bash
# Durable closed-loop lifecycle ledger for Firstmate tasks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-lifecycle-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK_WAIT="${FM_LIFECYCLE_LOCK_WAIT:-20}"

usage() {
  cat <<'EOF'
usage:
  fm-lifecycle.sh register <id> --repo <repo> --owner <owner> --branch <branch> --worktree <path> --objective <text> [--state queued|active]
  fm-lifecycle.sh transition <id> <state> --reason <text> [--evidence <path>]
  fm-lifecycle.sh heartbeat <id> [--owner <owner>]
  fm-lifecycle.sh closeout <id> <terminal-state> --reason <text> --evidence <path>
  fm-lifecycle.sh inspect <id> [--json]
EOF
}

die() { printf 'fm-lifecycle: %s\n' "$1" >&2; exit 1; }
meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
require_id() { fm_lifecycle_valid_id "$1" || die "invalid task id: $1"; }
require_state() { fm_lifecycle_is_state "$1" || die "invalid lifecycle state: $1"; }

acquire_lock() {
  local lock="$STATE/$1.lifecycle.lock" attempts=0 max_attempts=$((LOCK_WAIT * 20))
  mkdir -p "$STATE"
  while ! mkdir "$lock" 2>/dev/null; do
    [ "$attempts" -ge "$max_attempts" ] && die "lifecycle lock busy for $1"
    sleep 0.05
    attempts=$((attempts + 1))
  done
  printf '%s\n' "$$" > "$lock/pid"
  LIFECYCLE_LOCK="$lock"
  trap 'rm -rf "$LIFECYCLE_LOCK" 2>/dev/null || true' EXIT
}

write_atomic() {
  local path=$1 tmp
  tmp=$(mktemp "$STATE/.lifecycle.XXXXXX") || die "cannot allocate atomic state file"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
}

append_event() {
  local id=$1 seq=$2 now=$3 from=$4 to=$5 reason=$6 evidence=$7
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$seq" "$now" "$from" "$to" \
    "$(fm_lifecycle_clean_field "$reason")" \
    "$(fm_lifecycle_clean_field "$evidence")" \
    "$(fm_lifecycle_clean_field "${FM_LIFECYCLE_ACTOR:-$(hostname):$$}")" \
    >> "$STATE/$id.events"
}

register_task() {
  local id=$1 repo= owner= branch= worktree= objective= desired=queued now seq=1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=${2:-}; shift 2 ;;
      --owner) owner=${2:-}; shift 2 ;;
      --branch) branch=${2:-}; shift 2 ;;
      --worktree) worktree=${2:-}; shift 2 ;;
      --objective) objective=${2:-}; shift 2 ;;
      --state) desired=${2:-}; shift 2 ;;
      *) die "unknown register option: $1" ;;
    esac
  done
  require_id "$id"
  require_state "$desired"
  [ -n "$repo" ] || die "register requires --repo"
  [ -n "$owner" ] || die "register requires --owner"
  [ -n "$branch" ] || die "register requires --branch"
  [ -n "$worktree" ] || die "register requires --worktree"
  [ -n "$objective" ] || die "register requires --objective"
  if [ -e "$STATE/$id.lifecycle" ]; then
    if [ "$desired" = active ] && [ "${FM_LIFECYCLE_RESTORE:-}" = 1 ]; then
      transition_task "$id" active --reason runtime-restart --evidence "$STATE/$id.lifecycle"
      return 0
    fi
    die "task already registered: $id"
  fi
  [ "$desired" != active ] || {
    # Direct active registration is allowed only for adapters restoring a task;
    # the caller must make the owner explicit and this is still receipt-backed.
    [ -n "${FM_LIFECYCLE_RESTORE:-}" ] || die "active registration requires FM_LIFECYCLE_RESTORE=1"
  }
  acquire_lock "$id"
  now=$(fm_lifecycle_now)
  write_atomic "$STATE/$id.lifecycle" <<EOF
schema=$FM_LIFECYCLE_SCHEMA
id=$id
state=$desired
created_at=$now
updated_at=$now
heartbeat_at=$now
heartbeat_seq=0
transition_seq=$seq
owner=$(fm_lifecycle_clean_field "$owner")
repo=$(fm_lifecycle_clean_field "$repo")
branch=$(fm_lifecycle_clean_field "$branch")
worktree=$(fm_lifecycle_clean_field "$worktree")
objective=$(fm_lifecycle_clean_field "$objective")
heartbeat_ttl=$(fm_lifecycle_default_heartbeat_ttl)
heartbeat_grace=$(fm_lifecycle_default_grace)
last_reason=registered
last_evidence=
EOF
  : > "$STATE/$id.events"
  append_event "$id" "$seq" "$now" none "$desired" registered ""
  printf 'registered %s state=%s\n' "$id" "$desired"
}

transition_task() {
  local id=$1 to=$2 reason= evidence= now from seq
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      *) die "unknown transition option: $1" ;;
    esac
  done
  require_id "$id"; require_state "$to"
  [ -f "$STATE/$id.lifecycle" ] || die "task not registered: $id"
  [ -n "$reason" ] || die "transition requires --reason"
  acquire_lock "$id"
  from=$(meta_get "$STATE/$id.lifecycle" state)
  seq=$(meta_get "$STATE/$id.lifecycle" transition_seq)
  [ -n "$seq" ] || seq=0
  if [ "$from" = "$to" ]; then
    printf 'unchanged %s state=%s\n' "$id" "$to"
    return 0
  fi
  FM_LIFECYCLE_RESTORE="${FM_LIFECYCLE_RESTORE:-}" \
    fm_lifecycle_transition_allowed "$from" "$to" || die "transition not allowed: $from -> $to"
  now=$(fm_lifecycle_now)
  seq=$((seq + 1))
  awk -v state="$to" -v now="$now" -v seq="$seq" \
      -v reason="$(fm_lifecycle_clean_field "$reason")" \
      -v evidence="$(fm_lifecycle_clean_field "$evidence")" '
    BEGIN { OFS="=" }
    /^state=/ { print "state", state; next }
    /^updated_at=/ { print "updated_at", now; next }
    /^transition_seq=/ { print "transition_seq", seq; next }
    /^last_reason=/ { print "last_reason", reason; next }
    /^last_evidence=/ { print "last_evidence", evidence; next }
    { print }
  ' "$STATE/$id.lifecycle" | write_atomic "$STATE/$id.lifecycle"
  append_event "$id" "$seq" "$now" "$from" "$to" "$reason" "$evidence"
  printf 'transitioned %s %s->%s\n' "$id" "$from" "$to"
}

heartbeat_task() {
  local id=$1 owner= now previous seq
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner) owner=${2:-}; shift 2 ;;
      *) die "unknown heartbeat option: $1" ;;
    esac
  done
  require_id "$id"; [ -f "$STATE/$id.lifecycle" ] || die "task not registered: $id"
  acquire_lock "$id"
  [ "$(meta_get "$STATE/$id.lifecycle" state)" != "$(printf '%s' completed)" ] || die "cannot heartbeat terminal task"
  [ "$(meta_get "$STATE/$id.lifecycle" state)" != interrupted ] || die "cannot heartbeat terminal task"
  if [ -n "$owner" ] && [ "$owner" != "$(meta_get "$STATE/$id.lifecycle" owner)" ]; then
    die "heartbeat owner mismatch for $id"
  fi
  now=$(fm_lifecycle_now); previous=$(meta_get "$STATE/$id.lifecycle" heartbeat_at); seq=$(meta_get "$STATE/$id.lifecycle" heartbeat_seq)
  [ -n "$seq" ] || seq=0
  case "$previous" in ''|*[!0-9]*) die "invalid heartbeat clock" ;; esac
  case "$now" in ''|*[!0-9]*) die "invalid heartbeat clock" ;; esac
  [ "$now" -ge "${previous:-0}" ] || { printf 'ignored-old-heartbeat %s\n' "$id"; return 0; }
  seq=$((seq + 1))
  awk -v now="$now" -v seq="$seq" 'BEGIN{OFS="="} /^heartbeat_at=/{print "heartbeat_at",now;next} /^heartbeat_seq=/{print "heartbeat_seq",seq;next} /^updated_at=/{print "updated_at",now;next} {print}' "$STATE/$id.lifecycle" | write_atomic "$STATE/$id.lifecycle"
  printf 'heartbeat %s seq=%s\n' "$id" "$seq"
}

closeout_task() {
  local id=$1 to=$2 reason= evidence=
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      *) die "unknown closeout option: $1" ;;
    esac
  done
  require_id "$id"; require_state "$to"; fm_lifecycle_is_terminal "$to" || die "closeout requires terminal state"
  [ -n "$reason" ] || die "closeout requires --reason"
  [ -n "$evidence" ] && [ -e "$evidence" ] || die "closeout requires existing --evidence"
  transition_task "$id" "$to" --reason "$reason" --evidence "$evidence"
}

inspect_task() {
  local id=$1 json=0
  [ "${2:-}" = --json ] && json=1
  require_id "$id"; [ -f "$STATE/$id.lifecycle" ] || die "task not registered: $id"
  if [ "$json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq required for --json"
    jq -Rn 'reduce inputs as $line ({}; ($line|split("=")|select(length>=2)) as $p | .[$p[0]] = ($p[1:]|join("=")))' < "$STATE/$id.lifecycle"
  else
    cat "$STATE/$id.lifecycle"
  fi
}

case "${1:-}" in
  register) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; register_task "$2" "${@:3}" ;;
  transition) [ "$#" -ge 3 ] || { usage >&2; exit 2; }; transition_task "$2" "$3" "${@:4}" ;;
  heartbeat) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; heartbeat_task "$2" "${@:3}" ;;
  closeout) [ "$#" -ge 3 ] || { usage >&2; exit 2; }; closeout_task "$2" "$3" "${@:4}" ;;
  inspect) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; inspect_task "$2" "${3:-}" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
