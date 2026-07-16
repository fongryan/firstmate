#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|hermes|^pi$'

# macOS truncates `ps -o comm=` for Codex Desktop's bundled executable to
# `/Applications/Ch`, so command-name matching alone cannot recognize the
# stable app-server process. Match an executable-position `codex` token in the
# full argv as well. Keeping the match anchored avoids treating a shell whose
# prompt merely mentions "codex" as a harness.
process_looks_like_harness() {
  local comm=$1 args=$2 base
  # Use shell parameter expansion (immune to flag parsing on macOS BSD basename).
  # macOS `basename -z` is illegal; on a login-shell comm like "-zsh" the BSD
  # tool refuses to run, killing the harness ancestry walk and falsely reporting
  # "cannot locate harness process in ancestry".
  base="${comm##*/}"
  printf '%s' "$base" | grep -qE "$HARNESS_RE" && return 0
  printf '%s' "$args" | grep -qE '^([^[:space:]]*/)?(claude|codex|opencode|grok|pi)([[:space:]]|$)' && return 0
  case "$comm" in
    *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" ;;
    *) return 1 ;;
  esac
}

is_shared_codex_app_server() {
  local comm=$1 args=$2
  case "$(basename "$comm") $args" in
    *codex*app-server*|*app-server*codex*) return 0 ;;
  esac
  return 1
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
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
    if process_looks_like_harness "$comm" "$args"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  is_shared_codex_app_server "$comm" "$args" && return 1
  printf '%s' "$(basename "$comm") $args" | grep -qE "$HARNESS_RE"
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  process_looks_like_harness "$comm" "$args"
}

process_identity() {  # stable for one PID generation; changes when a PID is reused
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  identity=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  identity=$(printf '%s' "$identity" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

# A harness dispatched by the Bash autopilot inherits the loop owner's PID and
# birth identity through fm-spawn.sh. It must not reattribute the fleet lock to
# itself. Retain the owner only while both owner files agree and the same PID
# generation is live; otherwise fall through to ordinary stale-owner recovery.
autopilot_dispatch_owns_lock() {
  local inherited=${FM_AUTOPILOT_LOCK_OWNER_PID:-}
  local inherited_identity=${FM_AUTOPILOT_LOCK_OWNER_IDENTITY:-}
  local current_identity lock_owner recorded_owner
  case "$inherited" in ''|*[!0-9]*) return 1 ;; esac
  [ "$inherited" -gt 1 ] || return 1
  [ -n "$inherited_identity" ] || return 1
  [ -f "$LOCK" ] && [ -f "$STATE/.autopilot-owns-lock" ] || return 1
  lock_owner=$(cat "$LOCK" 2>/dev/null || true)
  recorded_owner=$(cat "$STATE/.autopilot-owns-lock" 2>/dev/null || true)
  [ "$lock_owner" = "$inherited" ] || return 1
  [ "$recorded_owner" = "$inherited" ] || return 1
  kill -0 "$inherited" 2>/dev/null || return 1
  current_identity=$(process_identity "$inherited") || return 1
  [ "$current_identity" = "$inherited_identity" ]
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

if autopilot_dispatch_owns_lock; then
  echo "error: autopilot pid $FM_AUTOPILOT_LOCK_OWNER_PID retains the fleet lock; dispatched harness must operate read-only" >&2
  exit 1
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
