#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Default behavior (no flags): acquire the legacy monolithic session lock. This
# is exactly the pre-scoped-keys contract - one PID file at $STATE/.lock, fail
# closed when another live harness holds it, stale owner self-recovers. Existing
# session-start, spawn paths, and every test keep working unchanged.
#
# Scoped keys (opt-in, additive):
#
#   fm-lock.sh --keys <csv>           acquire only the listed lock keys
#   fm-lock.sh status                 print holder for the legacy monolithic lock
#   fm-lock.sh status --keys <csv>    print holders for each listed key
#   fm-lock.sh keys                   list the default key set
#   fm-lock.sh keys list              same as above
#   fm-lock.sh --includes <K>         exit 0 if K is in the requested key set
#
# Keys live in $STATE/.locks/<key>.lock, each a PID file with the same
# harness-PID + liveness + process-identity semantics as the legacy lock.
# Stale per-key locks self-recover on next acquire. Two callers can hold
# disjoint subsets simultaneously (e.g. a crew spawn holding "queue" while the
# session-start holds "lifecycle" + "fleet"), so parallel workflows no longer
# serially bottleneck on one PID file.
#
# Why a key set, not always-all-keys: a crew spawn only mutates the wake queue
# and task state/, so it needs "queue" at most. A bootstrap secondmate-sync
# sweep only mutates secondmate homes, so it needs "secondmate-sync". Splitting
# them lets the captain fire crews in parallel with secondmate refreshes
# without either side blocking the other.
#
# Set the env var FM_LOCK_DEFAULT_KEYS to a CSV to change the default key set
# at acquisition time without passing --keys explicitly. Unset / blank =
# default key set below.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK_DIR="$STATE/.locks"
LEGACY_LOCK="$STATE/.lock"
mkdir -p "$STATE" "$LOCK_DIR"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|hermes|^pi$'

# Default key set. Every mutating sweep that previously required the legacy
# monolithic lock is now expressed as a key. The legacy monolithic lock is
# represented as "fleet" in this set so existing call paths that gate on the
# monolithic lock can opt in to just "fleet" and behave like before.
#
# Adding a key here is a one-liner; pairing it with a consumer is a separate
# change. Only keys that appear in this default set are required for any
# default-path acquisition - opt-in keys (e.g. a future "promotion" key) only
# run when a consumer explicitly names them.
DEFAULT_KEYS_CSV='fleet,queue,lifecycle,secondmate-sync,x-mode'

# --- argument parsing -------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: fm-lock.sh [--keys <csv>] [--includes <key>] [status|keys] [keys list]

  (no args)                acquire the default key set; fail if any held live
  --keys <csv>             acquire only the listed keys (legacy-compatible subset)
  status                   print holders of the legacy monolithic lock
  status --keys <csv>      print holders for each listed key
  keys [list]              print the default key set
  --includes <K>           exit 0 if K is in the requested set, 1 otherwise
USAGE
}

unset KEYS || true
MODE="acquire"
INCLUDE_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keys) KEYS="$2"; shift 2 ;;
    --keys=*) KEYS="${1#--keys=}"; shift ;;
    --includes) INCLUDE_KEY="$2"; MODE="includes"; shift 2 ;;
    --includes=*) INCLUDE_KEY="${1#--includes=}"; shift ;;
    status) MODE="status"; shift ;;
    keys) MODE="keys"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "fm-lock.sh: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
    *) echo "fm-lock.sh: unexpected positional '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

default_keys() {
  if [ -n "${FM_LOCK_DEFAULT_KEYS+x}" ] && [ -n "${FM_LOCK_DEFAULT_KEYS:-}" ]; then
    csv_to_lines "$FM_LOCK_DEFAULT_KEYS"
  else
    csv_to_lines "$DEFAULT_KEYS_CSV"
  fi
}

csv_to_lines() {
  # Print one CSV key per line, de-duplicated, validated.
  local input=$1
  [ -n "$input" ] || { echo "fm-lock.sh: --keys csv is empty" >&2; return 2; }
  printf '%s\n' "$input" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | LC_ALL=C sort -u
  # ShellCheck wants the validation pass to actually run; the next expression
  # is what enforces "lowercase letters, digits, dashes, underscores only".
  if printf '%s\n' "$input" | tr ',' '\n' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -v '^$' \
      | grep -Ev '^[a-z][a-z0-9_-]*$' >/dev/null; then
    echo "fm-lock.sh: --keys contains invalid tokens (allowed: lowercase, digits, '-', '_')" >&2
    return 2
  fi
  return 0
}

requested_keys() {
  # Resolve the active key set. Emit one key per line on stdout.
  if [ -n "${KEYS+x}" ]; then
    csv_to_lines "${KEYS:-}" || return $?
  else
    default_keys
  fi
}

includes_set() {
  # For --includes: 0 if the key is in the requested set, 1 otherwise. Also
  # considers the default set when --keys is empty, so callers can ask "is
  # 'queue' part of what I would acquire?" without naming the key set.
  [ -n "$INCLUDE_KEY" ] || return 2
  local k
  while IFS= read -r k; do
    [ "$k" = "$INCLUDE_KEY" ] && return 0
  done < <(requested_keys)
  return 1
}

# --- identity helpers (unchanged from previous version) ---------------------

is_shared_codex_app_server() {
  local comm=$1 args=$2
  case "${comm##*/} $args" in
    *codex*app-server*|*app-server*codex*) return 0 ;;
  esac
  return 1
}

process_looks_like_harness() {
  local comm=$1 args=$2 base
  base="${comm##*/}"
  printf '%s' "$base" | grep -qE "$HARNESS_RE" && return 0
  printf '%s' "$args" | grep -qE '^([^[:space:]]*/)?(claude|codex|opencode|grok|pi|hermes)([[:space:]]|$)' && return 0
  case "$comm" in
    *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" ;;
    *) return 1 ;;
  esac
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    is_shared_codex_app_server "$comm" "$args" && {
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
      continue
    }
    if process_looks_like_harness "$comm" "$args"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {
  # true if $1 is a live process that looks like a harness
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  is_shared_codex_app_server "$comm" "$args" && return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  process_looks_like_harness "$comm" "$args"
}

process_identity() {
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  identity=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  identity=$(printf '%s' "$identity" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

# --- legacy autopilot ownership (unchanged) ---------------------------------

autopilot_dispatch_owns_lock() {
  local inherited=${FM_AUTOPILOT_LOCK_OWNER_PID:-}
  local inherited_identity=${FM_AUTOPILOT_LOCK_OWNER_IDENTITY:-}
  local current_identity lock_owner recorded_owner
  case "$inherited" in ''|*[!0-9]*) return 1 ;; esac
  [ "$inherited" -gt 1 ] || return 1
  [ -n "$inherited_identity" ] || return 1
  [ -f "$LEGACY_LOCK" ] && [ -f "$STATE/.autopilot-owns-lock" ] || return 1
  lock_owner=$(cat "$LEGACY_LOCK" 2>/dev/null || true)
  recorded_owner=$(cat "$STATE/.autopilot-owns-lock" 2>/dev/null || true)
  [ "$lock_owner" = "$inherited" ] || return 1
  [ "$recorded_owner" = "$inherited" ] || return 1
  kill -0 "$inherited" 2>/dev/null || return 1
  current_identity=$(process_identity "$inherited") || return 1
  [ "$current_identity" = "$inherited_identity" ]
}

# --- legacy status (no --keys) ----------------------------------------------

legacy_status() {
  if [ ! -f "$LEGACY_LOCK" ]; then echo "lock: free"; return 0; fi
  local old
  old=$(cat "$LEGACY_LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  return 0
}

# --- per-key status --------------------------------------------------------

key_status_line() {
  # One line per key, table-style. Always exits 0 (status is informational).
  local key=$1 file="$LOCK_DIR/$1.lock"
  if [ ! -f "$file" ]; then
    printf 'key %s: free\n' "$key"
    return 0
  fi
  local pid
  pid=$(cat "$file" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    printf 'key %s: stale (empty)\n' "$key"
    return 0
  fi
  if holder_alive "$pid"; then
    printf 'key %s: held by live harness pid %s\n' "$key" "$pid"
  else
    printf 'key %s: stale (pid %s dead or not a harness)\n' "$key" "$pid"
  fi
}

# Try to acquire one specific key. Returns 0 on acquire and 1 if a live holder
# blocks. Refuses keys whose name contains characters outside [a-z0-9_-].
key_file_for() { printf '%s\n' "$LOCK_DIR/$1.lock"; }

# Some keys are represented in legacy locations (one key, fleet, used to be
# the only key and lived at $STATE/.lock). Their holder check and update
# must consult BOTH the per-key file and the legacy file for that key, or
# the two representations would disagree and unmigrated consumers would see
# stale legacy entries masking live scoped holders.
key_legacy_target() {
  case "$1" in
    fleet) printf '%s\n' "$LEGACY_LOCK" ;;
    *) return 1 ;;
  esac
}

acquire_one_key() {
  # Returns 0 on acquire (and writes both per-key and, if mapped, legacy
  # representations in lockstep), 1 if a live holder blocks, 2 on invalid
  # key syntax. A key with both a per-key file and a legacy target
  # canonicalizes on whichever entry the live holder is recorded in: the
  # existing per-key pid wins for the read; if the per-key pid is stale and
  # the legacy pid is live, the legacy pid wins.
  local key=$1 lock_file legacy_target holder legacy
  case "$key" in ''|*[!a-z0-9_-]*) return 2 ;; esac
  lock_file=$(key_file_for "$key")
  if legacy_target=$(key_legacy_target "$key"); then :; fi
  holder=$(cat "$lock_file" 2>/dev/null || true)
  if [ -n "$legacy_target" ]; then
    legacy=$(cat "$legacy_target" 2>/dev/null || true)
  else
    legacy=""
  fi
  if [ -n "$holder" ] && [ "$holder" != "$me" ] && holder_alive "$holder"; then
    return 1
  fi
  if [ -n "$legacy" ] && [ "$legacy" != "$me" ] && holder_alive "$legacy"; then
    return 1
  fi
  printf '%s\n' "$me" > "$lock_file"
  if [ -n "$legacy_target" ]; then
    printf '%s\n' "$me" > "$legacy_target"
  fi
  return 0
}

# --- mode dispatch ---------------------------------------------------------

case "$MODE" in
  keys)
    default_keys
    exit 0
    ;;

  includes)
    # Helper: --includes K exits 0 iff K is in the requested set (or default
    # when --keys is empty). Useful for spawn callers that want to know "do I
    # need the autopilot read-only banner?" before doing harness-shape work.
    [ -n "$INCLUDE_KEY" ] || { echo "fm-lock.sh: --requires <key>" >&2; exit 2; }
    includes_set
    exit $?
    ;;

  status)
    if [ -n "${KEYS:-}" ]; then
      while IFS= read -r k; do
        [ -z "$k" ] && continue
        key_status_line "$k"
      done < <(requested_keys)
      exit 0
    fi
    legacy_status
    exit 0
    ;;

  acquire)
    # Preserve the legacy autopilot-ownership rule: a dispatched app-server
    # running under the Bash autopilot must NOT claim a lock key when the
    # autopilot already owns the legacy lock. The autopilot's read-only banner
    # still fires (and now extends to the request to claim the legacy key -
    # which a per-key request like --keys=queue explicitly bypasses; that is
    # fine, because the autopilot did not touch queue state, only legacy
    # monolith state).
    if [ -z "${KEYS+x}" ] && autopilot_dispatch_owns_lock; then
      echo "error: autopilot pid $FM_AUTOPILOT_LOCK_OWNER_PID retains the fleet lock; dispatched harness must operate read-only" >&2
      exit 1
    fi

    me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }

    requested_keys_file=$(mktemp "${TMPDIR:-/tmp}/fm-lock-keys.XXXXXX" 2>/dev/null) || { echo "error: cannot create temp file" >&2; exit 1; }
    trap 'rm -f "$requested_keys_file"' EXIT INT TERM
    requested_keys > "$requested_keys_file" || { echo "error: --keys csv is empty or invalid" >&2; exit 2; }
    if [ ! -s "$requested_keys_file" ]; then
      echo "error: --keys csv resolved to an empty set" >&2
      exit 2
    fi

    # Acquire each requested key. On the very first contention, capture which
    # key blocked us so the error is actionable (the captain can see whether
    # this is a fleet, queue, lifecycle, secondmate-sync, or x-mode holder).
    blocked=""
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      if ! acquire_one_key "$k"; then
        blocked="$k"
        break
      fi
    done < "$requested_keys_file"

    # acquire_one_key keeps the legacy entry (when the requested key has a
    # legacy target, currently only 'fleet') in lockstep with the per-key
    # file. No separate legacy write needed here.

    if [ -n "$blocked" ]; then
      pid=$(cat "$LOCK_DIR/$blocked.lock" 2>/dev/null || true)
      if [ -n "$pid" ] && [ "$blocked" = "fleet" ] && [ -z "$(cat "$LOCK_DIR/fleet.lock" 2>/dev/null)" ]; then
        pid=$(cat "$LEGACY_LOCK" 2>/dev/null || true)
      fi
      if [ "$blocked" = "fleet" ]; then
        echo "error: another live firstmate session holds the lock (pid $pid); operate read-only until resolved" >&2
      else
        echo "error: another live firstmate session holds the '$blocked' lock key (pid $pid); operate read-only until resolved" >&2
      fi
      exit 1
    fi
    echo "lock acquired: harness pid $me keys=$(tr '\n' ',' < "$requested_keys_file" | sed 's/,$//')"
    exit 0
    ;;

  *)
    echo "fm-lock.sh: unknown mode '$MODE'" >&2
    usage >&2
    exit 2
    ;;
esac
