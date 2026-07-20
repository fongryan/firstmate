#!/usr/bin/env bash
# fm-ocpool.sh - the headless opencode worker-pool loop: an autopilot-sibling
# driver that dispatches queued backlog items to disposable opencode workers
# through the flowstate bridge (bin/fm-ocpool-dispatch.mjs), so a captain can
# spin off many parallel disconnected workstreams that stay alive and do the
# work without a resident interactive pane per task and without killing the
# machine.
#
# WHY THIS EXISTS
# fm-autopilot.sh drives interactive-harness crewmates (tmux panes, real
# adapters) up to a small concurrency cap. This loop is a second, independent
# driver for a different shape of work: short, disposable opencode runs with
# no pane, admitted through flowstate's resource-guardian in ENFORCE mode
# (the single capacity authority for the guardian's own process-count cap;
# this loop's own FM_OCPOOL_MAX_CONCURRENT is a distinct, smaller cap counted
# from durable lifecycle state). It reuses the existing queue
# (data/backlog.md via tasks-axi), the existing closed-loop lifecycle ledger
# (bin/fm-lifecycle.sh) for state truth, and the existing lock primitives
# (bin/fm-wake-lib.sh) - it does not reimplement any of them.
#
# QUEUE MARKER: a backlog item opts into this pool by carrying a
# "(pool: opencode)" parenthetical field, the same bracket-field convention
# fm-autopilot.sh already uses for (repo: ...)/(kind: ...)/(priority: ...).
# fm-autopilot.sh's own field parser only recognizes repo/kind/priority, so a
# pool-marked item is invisible to it as a marker - but fm-autopilot.sh would
# still try to dispatch ANY "- [ ] ..." row it finds under "## Queued"
# regardless of this marker. This loop closes that race the same way
# fm-autopilot.sh's own parser already understands: the instant a pool item is
# claimed, its checkbox line is flipped from "- [ ] " to "- [~] " IN PLACE
# (still inside "## Queued"), which is the exact "already in flight, skip it"
# signal fm-autopilot.sh's parse_queued/tick loop already honors
# (`[ "$status" = " " ] || continue`). No fm-autopilot.sh change was needed or
# made. A residual race remains only for the brief window between a pool item
# appearing in Queued and this loop's next tick claiming it; keep pool-eligible
# projects out of fm-autopilot.sh's own dispatch path when that window matters
# (see docs/ocpool.md).
#
# LIFECYCLE, three orthogonal gates, all fail-closed - every entrypoint below
# refuses to mutate until all three allow it:
#   1. ARMED     - ships DISARMED. `arm` writes state/.ocpool-armed. The loop
#                  refuses every mutating action unless armed.
#   2. KILL      - state/.ocpool-kill, checked every tick. Present = no
#                  mutating action this or any tick until removed.
#   3. LOCK      - a mutating tick runs only when this loop holds the shared
#                  fleet lock (state/.lock) and no other live session holds
#                  it. This is the SAME fleet lock fm-autopilot.sh uses and
#                  the SAME preemption contract docs/autopilot.md and
#                  docs/autopilot-arming.md describe: a starting interactive
#                  fm-session-start.sh treats this loop's non-harness pid as
#                  stale and preempts it automatically, so an interactive
#                  captain session always outranks BOTH automated loops. This
#                  loop and fm-autopilot.sh each record their own ownership
#                  (state/.ocpool-owns-lock vs state/.autopilot-owns-lock), so
#                  they peacefully alternate brief per-tick holds of the same
#                  lock rather than fighting over it.
# A separate SINGLETON lock (state/.ocpool-singleton.lock, via
# bin/fm-wake-lib.sh's fm_lock_try_acquire/fm_lock_release primitives - never
# a hand-rolled mkdir loop) is orthogonal to all three: it only prevents two
# fm-ocpool.sh processes (e.g. a stray `once` and a running `start` loop) from
# running a mutating body at the same moment. It says nothing about captain
# precedence; the fleet lock above does that.
#
# CAPACITY: free slots = FM_OCPOOL_MAX_CONCURRENT minus active pool tasks,
# counted by reading each in-flight task's `state=` field out of its
# bin/fm-lifecycle.sh ledger file (never from `ps`, never from a private
# duplicate ledger). A small marker file per claimed key
# (state/.ocpool-attempt-<key>) records which lifecycle id to read; that
# marker is the "gate/marker touch-file" this loop is allowed to keep, not a
# second source of truth. FM_OCPOOL_MAX_ACTIVE_AGENTS is a SEPARATE, larger
# cap forwarded to the bridge as FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS -
# flowstate's resource-guardian in ENFORCE mode is the single authority for
# that one; this loop never second-guesses a guardian admission refusal.
#
# BRIDGE EXIT-CODE CONTRACT (bin/fm-ocpool-dispatch.mjs, run once per attempt,
# in the background, stdout+stderr captured to data/ocpool/<key>.log):
#   0  verified        -> lifecycle closeout(completed), backlog item moved to
#                          Done (tasks-axi when available/compatible, else a
#                          hand-edit fallback), receipt line.
#   2  blocked         -> machine admission refused (not this task's fault).
#                          Backlog item unclaimed back to "- [ ] " so it is
#                          re-picked next tick; does NOT consume an attempt;
#                          receipt line names the reason.
#   3/4 failed         -> attempts < FM_OCPOOL_MAX_ATTEMPTS (default 2):
#                          unclaimed for a retry, with a handoff note appended
#                          to the task's brief. Attempts exhausted: escalated
#                          to data/ocpool/needs-captain.md, left claimed so
#                          nothing silently retries it forever.
#   5  config bug      -> escalated to needs-captain.md immediately, no retry.
#   anything else      -> treated as a failed attempt (conservative).
#
# RECEIPTS: one line per mutating action appended to data/ocpool/log.md
# (timestamp, action, target, detail), mirroring fm-autopilot.sh's receipt
# shape. Anything needing a human lands in data/ocpool/needs-captain.md.
# state/.ocpool-heartbeat is touched every tick, armed or not.
#
# ENV KNOBS (all optional):
#   FM_OCPOOL_TICK_SECONDS         loop cadence seconds (default 60)
#   FM_OCPOOL_MAX_CONCURRENT       max active pool tasks before dispatch stops (default 3)
#   FM_OCPOOL_MAX_ATTEMPTS         max attempts per task before needs-captain (default 2)
#   FM_OCPOOL_MAX_ACTIVE_AGENTS    forwarded to the bridge as FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS (default 5)
#   FM_OCPOOL_DONE_KEEP            Done-section prune target for the hand-edit fallback (default 10)
#   FM_OCPOOL_DISPATCH_BIN         the bridge command to exec (default $FM_ROOT/bin/fm-ocpool-dispatch.mjs)
#   FM_OCPOOL_SESSION              tmux session name for start/stop (default "fm-ocpool")
#   FLOWSTATE_ROOT / FM_FLOWSTATE_ROOT   passed through unchanged to the bridge when set in this loop's own environment
#
# SUBCOMMANDS: start | stop | status | once | arm | disarm
#   start    launch the loop as a detached tmux session
#   stop     kill the loop session and release the fleet + singleton locks
#   status   print ARMED/KILL/lock/queue-depth/active-count one-liners
#   once     run exactly one tick in the foreground and exit (tests; a
#            captain who wants to watch a single supervised pass)
#   arm      write state/.ocpool-armed with an optional captain note
#   disarm   remove state/.ocpool-armed
#
# Honors FM_ROOT_OVERRIDE / FM_HOME / FM_STATE_OVERRIDE / FM_DATA_OVERRIDE /
# FM_CONFIG_OVERRIDE / FM_PROJECTS_OVERRIDE like every other fm script, so a
# temp fixture home is fully isolated. Portable bash for macOS; shellcheck-clean.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

# --- tunables ---------------------------------------------------------------
TICK_SECONDS=${FM_OCPOOL_TICK_SECONDS:-60}
MAX_CONCURRENT=${FM_OCPOOL_MAX_CONCURRENT:-3}
MAX_ATTEMPTS=${FM_OCPOOL_MAX_ATTEMPTS:-2}
MAX_ACTIVE_AGENTS=${FM_OCPOOL_MAX_ACTIVE_AGENTS:-5}
DONE_KEEP=${FM_OCPOOL_DONE_KEEP:-10}
DISPATCH_BIN=${FM_OCPOOL_DISPATCH_BIN:-$FM_ROOT/bin/fm-ocpool-dispatch.mjs}
SESSION=${FM_OCPOOL_SESSION:-fm-ocpool}
LIFECYCLE_BIN="$FM_ROOT/bin/fm-lifecycle.sh"

# state / data paths (state/ and data/ are gitignored, so these are all local)
ARMED_FLAG="$STATE/.ocpool-armed"
KILL_FLAG="$STATE/.ocpool-kill"
HEARTBEAT="$STATE/.ocpool-heartbeat"
OWNS_LOCK="$STATE/.ocpool-owns-lock"
FLEET_LOCK="$STATE/.lock"
SINGLETON_LOCK="$STATE/.ocpool-singleton.lock"
OC_DATA="$DATA/ocpool"
LOG_MD="$OC_DATA/log.md"
NEEDS_CAPTAIN_MD="$OC_DATA/needs-captain.md"

mkdir -p "$STATE" "$OC_DATA" 2>/dev/null || true

# --- small utilities (mirrors bin/fm-autopilot.sh) --------------------------
now_epoch() { date +%s; }
now_iso()   { date '+%Y-%m-%dT%H:%M:%S%z'; }

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}
file_age() {
  local m; m=$(file_mtime "$1") || { echo 999999; return; }
  [ -n "$m" ] || { echo 999999; return; }
  echo $(( $(now_epoch) - m ))
}

pid_alive() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

meta_get() {  # <key=value file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

log_line() { printf '[ocpool %s] %s\n' "$(now_iso)" "$*"; }

# receipt <action> <target> <detail>: one compact line per mutating action.
receipt() {
  mkdir -p "$OC_DATA" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$1" "$2" "${3:-}" >> "$LOG_MD"
}

needs_captain() {  # <key> <reason> <detail>
  mkdir -p "$OC_DATA" 2>/dev/null || true
  printf '%s | %s | %s | %s\n' "$(now_iso)" "$1" "$2" "${3:-}" >> "$NEEDS_CAPTAIN_MD"
  receipt escalate "$1" "$2"
}

# --- gates --------------------------------------------------------------
is_armed()     { [ -f "$ARMED_FLAG" ]; }
kill_present() { [ -e "$KILL_FLAG" ]; }

# lock_held_by_other / acquire_fleet_lock / release_fleet_lock: the SAME
# preemption contract as bin/fm-autopilot.sh, against the SAME state/.lock,
# using this loop's own ownership marker so the two loops alternate brief
# holds instead of permanently locking each other out (see header comment).
lock_held_by_other() {
  [ -f "$FLEET_LOCK" ] || return 1
  local pid owner
  pid=$(cat "$FLEET_LOCK" 2>/dev/null || true)
  owner=$(cat "$OWNS_LOCK" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  [ "$pid" = "$owner" ] && return 1   # we hold it
  pid_alive "$pid"
}

acquire_fleet_lock() {
  lock_held_by_other && return 1
  printf '%s\n' "$$" > "$FLEET_LOCK"
  printf '%s\n' "$$" > "$OWNS_LOCK"
  return 0
}

release_fleet_lock() {
  local owner
  owner=$(cat "$OWNS_LOCK" 2>/dev/null || true)
  if [ -f "$FLEET_LOCK" ]; then
    local pid; pid=$(cat "$FLEET_LOCK" 2>/dev/null || true)
    [ "$pid" = "$owner" ] && rm -f "$FLEET_LOCK" 2>/dev/null || true
  fi
  rm -f "$OWNS_LOCK" 2>/dev/null || true
}

# --- backlog parsing (mirrors bin/fm-autopilot.sh's parse_queued, plus a
# pool-marker filter fm-autopilot.sh's own parser is blind to) ---------------
parse_pool_queued() {
  local backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || return 0
  awk '
    function field(line, name,   re, m) {
      re = "\\(" name ": [^)]*\\)"
      if (match(line, re)) {
        m = substr(line, RSTART, RLENGTH)
        gsub("\\(" name ": ", "", m); gsub(/\)$/, "", m)
        return m
      }
      return ""
    }
    /^## / { inq = ($0 ~ /^## Queued/); next }
    inq && /^- \[[ ~]\] / {
      pool = field($0, "pool")
      if (pool != "opencode") next
      status = substr($0, 4, 1)
      rest = substr($0, 7)
      key = rest; sub(/ .*/, "", key)
      repo = field($0, "repo")
      prio = field($0, "priority")
      if (prio == "" || prio ~ /[^0-9]/) prio = 9999
      printf "%s\t%s\t%s\t%s\t%s\n", status, key, repo, prio, $0
    }
  ' "$backlog"
}

count_pool_queued() {  # count of unclaimed '[ ]' pool items in Queued
  parse_pool_queued | awk -F '\t' '$1==" "{n++} END{print n+0}'
}

# --- capacity: read lifecycle state, never ps --------------------------------
count_active_pool() {
  local f id n=0
  for f in "$STATE"/.ocpool-attempt-*; do
    [ -f "$f" ] || continue
    id=$(cat "$f" 2>/dev/null || true)
    [ -n "$id" ] || continue
    [ "$(meta_get "$STATE/$id.lifecycle" state)" = active ] && n=$((n + 1))
  done
  echo "$n"
}

# --- once_marker <tag> <key>: idempotency guard, same contract as
# fm-autopilot.sh's once_marker. --------------------------------------------
once_marker() {
  local f="$STATE/.ocpool-$1-$2"
  [ -f "$f" ] && return 1
  : > "$f"
  return 0
}

retry_count() {  # <key>
  local f="$STATE/.ocpool-retry-$1" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}
bump_retry() {  # <key>
  local f="$STATE/.ocpool-retry-$1" n
  n=$(retry_count "$1"); n=$((n + 1))
  printf '%s\n' "$n" > "$f"
  echo "$n"
}

# --- backlog mutation: claim/unclaim in place (mirrors fm-autopilot.sh's
# own "[~] means already in flight" reading), and a Done-section mover used
# only when the tasks-axi backend is unavailable/manual. -----------------
pool_claim_item() {  # <key>
  local key=$1 backlog="$DATA/backlog.md" tmp
  [ -f "$backlog" ] || return 1
  tmp=$(mktemp "$STATE/.ocpool-backlog.XXXXXX") || return 1
  awk -v key="$key" '
    BEGIN { done = 0 }
    !done && $0 ~ ("^- \\[ \\] " key "([[:space:]]|$)") { sub(/^- \[ \]/, "- [~]"); done = 1 }
    { print }
  ' "$backlog" > "$tmp" && mv "$tmp" "$backlog"
}

pool_unclaim_item() {  # <key>
  local key=$1 backlog="$DATA/backlog.md" tmp
  [ -f "$backlog" ] || return 1
  tmp=$(mktemp "$STATE/.ocpool-backlog.XXXXXX") || return 1
  awk -v key="$key" '
    BEGIN { done = 0 }
    !done && $0 ~ ("^- \\[~\\] " key "([[:space:]]|$)") { sub(/^- \[~\]/, "- [ ]"); done = 1 }
    { print }
  ' "$backlog" > "$tmp" && mv "$tmp" "$backlog"
}

_ocpool_prune_done() {  # <file> <keep>
  local file=$1 keep=$2 tmp
  [ -f "$file" ] || return 0
  tmp=$(mktemp "$STATE/.ocpool-prune.XXXXXX") || return 0
  awk -v keep="$keep" '
    BEGIN { insection = 0; count = 0; keepit = 1 }
    /^## / {
      insection = ($0 ~ /^## Done([[:space:]]|$)/)
      print
      next
    }
    insection && /^- \[x\] / {
      count++
      keepit = (count <= keep)
      if (keepit) print
      next
    }
    insection && /^[[:space:]]/ {
      if (keepit) print
      next
    }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# pool_backlog_done_manual <key> <note>: move the item (wherever it currently
# sits, claimed or not) to the "## Done" section, checked, dated, with <note>
# as an indented continuation line, then prune Done to FM_OCPOOL_DONE_KEEP.
# Used only when fm_tasks_axi_backend_available reports the tasks-axi CLI
# path is unavailable or config/backlog-backend=manual.
pool_backlog_done_manual() {  # <key> <note>
  local key=$1 note=$2 backlog="$DATA/backlog.md" date item rest tmp
  [ -f "$backlog" ] || return 1
  date=$(date +%Y-%m-%d)
  item=$(mktemp "$STATE/.ocpool-done-item.XXXXXX") || return 1
  rest=$(mktemp "$STATE/.ocpool-done-rest.XXXXXX") || { rm -f "$item"; return 1; }
  awk -v key="$key" -v itemfile="$item" -v restfile="$rest" '
    {
      if (initem) {
        if ($0 ~ /^[[:space:]]/) { print >> itemfile; next }
        initem = 0
      }
      if (!found && $0 ~ ("^- \\[[ ~]\\] " key "([[:space:]]|$)")) {
        sub(/^- \[[ ~]\]/, "- [x]")
        print >> itemfile
        initem = 1
        found = 1
        next
      }
      print >> restfile
    }
  ' "$backlog"
  if [ ! -s "$item" ]; then
    rm -f "$item" "$rest"
    return 1
  fi
  { sed "1 s/\$/ (done $date)/" "$item"; printf '  %s\n' "$note"; } > "$item.final"

  tmp=$(mktemp "$STATE/.ocpool-backlog.XXXXXX") || { rm -f "$item" "$item.final" "$rest"; return 1; }
  if grep -q '^## Done' "$rest"; then
    awk -v itemfile="$item.final" '
      { print }
      /^## Done/ && !inserted {
        while ((getline line < itemfile) > 0) print line
        inserted = 1
      }
    ' "$rest" > "$tmp"
  else
    cat "$rest" > "$tmp"
    { printf '\n## Done\n'; cat "$item.final"; } >> "$tmp"
  fi
  mv "$tmp" "$backlog"
  rm -f "$item" "$item.final" "$rest"
  _ocpool_prune_done "$backlog" "$DONE_KEEP"
}

pool_backlog_done() {  # <key> <note>: tasks-axi when available, else hand-edit
  local key=$1 note=$2
  if fm_tasks_axi_backend_available "$CONFIG" && command -v tasks-axi >/dev/null 2>&1; then
    if ( cd "$FM_HOME" 2>/dev/null && tasks-axi "done" "$key" --note "$note" ) >/dev/null 2>&1; then
      return 0
    fi
  fi
  pool_backlog_done_manual "$key" "$note"
}

# --- brief scaffold -----------------------------------------------------
ensure_pool_brief() {  # <key> <text>
  local key=$1 text=$2
  local brief="$DATA/$key/brief.md"
  [ -f "$brief" ] && return 0
  mkdir -p "$DATA/$key" 2>/dev/null || true
  {
    printf '# Opencode pool dispatch: %s\n\n' "$key"
    printf 'You are an opencode worker dispatched autonomously by the Firstmate\n'
    printf 'opencode worker pool (bin/fm-ocpool.sh via bin/fm-ocpool-dispatch.mjs).\n'
    printf 'Deliver the backlog item below through the bridge contract. Crewmates\n'
    printf 'never address the captain directly; report through the run''s own\n'
    printf 'proof/receipt path instead.\n\n'
    printf '## Backlog item\n\n%s\n' "$text"
  } > "$brief"
}

append_handoff_note() {  # <key> <note>
  local key=$1 note=$2
  local brief="$DATA/$key/brief.md"
  [ -f "$brief" ] || return 0
  {
    printf '\n## Handoff note (%s)\n\n%s\n' "$(now_iso)" "$note"
  } >> "$brief"
}

# --- dispatch -------------------------------------------------------------
dispatch_pool_item() {  # <key> <repo> <text>
  local key=$1 repo=$2 text=$3 n attempt aid depth brief log

  n=$(retry_count "$key")
  attempt=$((n + 1))
  aid="$key-a$attempt"
  # Guards only against re-dispatching the same in-flight attempt (e.g. a
  # duplicate row in one tick's already-buffered queue read); triage_pool_tasks
  # removes this marker when the attempt concludes so a legitimate later retry
  # of the same attempt number (a blocked outcome does not bump retry_count)
  # is never permanently locked out.
  once_marker "dispatch" "$aid" || return 1

  if [ -z "$repo" ]; then
    needs_captain "$key" "no-repo" "pool item has no (repo: ...) - cannot dispatch autonomously"
    return 1
  fi
  local proj="$PROJECTS/$repo"
  if [ ! -d "$proj" ]; then
    needs_captain "$key" "missing-clone" "no project clone at $proj"
    return 1
  fi

  depth=${AGENT_ORCH_DEPTH:-0}
  if [ "$depth" -ge 2 ]; then
    needs_captain "$key" "orch-depth-exceeded" "AGENT_ORCH_DEPTH=$depth at or above max 2; refusing to spawn"
    return 1
  fi

  ensure_pool_brief "$key" "$text"
  brief="$DATA/$key/brief.md"
  log="$OC_DATA/$key.log"
  mkdir -p "$OC_DATA" 2>/dev/null || true

  "$LIFECYCLE_BIN" register "$aid" --repo "$repo" --owner ocpool \
    --branch "opencode-pool/$key" --worktree "$proj" --objective "$text" >/dev/null 2>&1 \
    || { needs_captain "$key" "lifecycle-register-failed" "attempt=$aid"; return 1; }
  "$LIFECYCLE_BIN" transition "$aid" active --reason dispatch --evidence "$log" >/dev/null 2>&1 \
    || { needs_captain "$key" "lifecycle-transition-failed" "attempt=$aid"; return 1; }

  printf '%s\n' "$aid" > "$STATE/.ocpool-attempt-$key"
  pool_claim_item "$key"
  receipt dispatch "$key" "attempt=$attempt repo=$repo"

  (
    export AGENT_ORCH_DEPTH=$((depth + 1))
    export FLOWSTATE_RESOURCE_GUARD_MODE=enforce
    export FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS="$MAX_ACTIVE_AGENTS"
    [ -n "${FLOWSTATE_ROOT:-}" ] && export FLOWSTATE_ROOT
    [ -n "${FM_FLOWSTATE_ROOT:-}" ] && export FM_FLOWSTATE_ROOT
    "$DISPATCH_BIN" --task-id "$key" --repo "$proj" --prompt-file "$brief" --json \
      >"$log" 2>&1
    printf '%s\n' "$?" > "$STATE/.ocpool-exit-$key"
  ) &
  disown 2>/dev/null || true
  return 0
}

# --- outcome handling ------------------------------------------------------
handle_pool_verified() {  # <key> <aid> <log>
  local key=$1 aid=$2 log=$3
  "$LIFECYCLE_BIN" closeout "$aid" completed --reason verified --evidence "$log" >/dev/null 2>&1 || true
  pool_backlog_done "$key" "opencode pool: verified (log data/ocpool/$key.log)"
  receipt "done" "$key" "attempt=$aid verified"
}

handle_pool_blocked() {  # <key> <aid> <log>
  local key=$1 aid=$2 log=$3 reason
  reason=$(tail -c 2000 "$log" 2>/dev/null | tail -1)
  "$LIFECYCLE_BIN" closeout "$aid" interrupted --reason "blocked: machine admission refused" --evidence "$log" >/dev/null 2>&1 || true
  pool_unclaim_item "$key"
  receipt blocked "$key" "attempt=$aid ${reason:-admission refused}"
}

handle_pool_failed() {  # <key> <aid> <log>
  local key=$1 aid=$2 log=$3 n reason
  reason=$(tail -c 2000 "$log" 2>/dev/null | tail -1)
  n=$(bump_retry "$key")
  if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
    "$LIFECYCLE_BIN" closeout "$aid" interrupted --reason "failed-retry $n/$MAX_ATTEMPTS: ${reason:-non-zero exit}" --evidence "$log" >/dev/null 2>&1 || true
    pool_unclaim_item "$key"
    append_handoff_note "$key" "attempt $n failed: ${reason:-see data/ocpool/$key.log}"
    receipt requeue "$key" "attempt=$aid failed, retry $n/$MAX_ATTEMPTS"
  else
    "$LIFECYCLE_BIN" closeout "$aid" abandoned --reason "failed-exhausted $n/$MAX_ATTEMPTS: ${reason:-non-zero exit}" --evidence "$log" >/dev/null 2>&1 || true
    needs_captain "$key" "failed-exhausted" "attempt=$aid $n/$MAX_ATTEMPTS attempts failed: ${reason:-see data/ocpool/$key.log}"
  fi
}

handle_pool_config_bug() {  # <key> <aid> <log>
  local key=$1 aid=$2 log=$3 reason
  reason=$(tail -c 2000 "$log" 2>/dev/null | tail -1)
  "$LIFECYCLE_BIN" closeout "$aid" abandoned --reason "config-bug: ${reason:-exit 5}" --evidence "$log" >/dev/null 2>&1 || true
  needs_captain "$key" "config-bug" "attempt=$aid bridge exited 5 (config bug): ${reason:-see data/ocpool/$key.log}"
}

triage_pool_tasks() {
  local f key aid exitfile code log
  for f in "$STATE"/.ocpool-attempt-*; do
    [ -f "$f" ] || continue
    key=${f#"$STATE"/.ocpool-attempt-}
    aid=$(cat "$f" 2>/dev/null || true)
    if [ -z "$aid" ]; then
      rm -f "$f"
      continue
    fi
    exitfile="$STATE/.ocpool-exit-$key"
    [ -f "$exitfile" ] || continue  # still running
    code=$(cat "$exitfile" 2>/dev/null || true)
    log="$OC_DATA/$key.log"
    [ -e "$log" ] || : > "$log"  # closeout requires existing evidence
    case "$code" in
      0) handle_pool_verified "$key" "$aid" "$log" ;;
      2) handle_pool_blocked "$key" "$aid" "$log" ;;
      3|4) handle_pool_failed "$key" "$aid" "$log" ;;
      5) handle_pool_config_bug "$key" "$aid" "$log" ;;
      *) handle_pool_failed "$key" "$aid" "$log" ;;
    esac
    rm -f "$f" "$exitfile" "$STATE/.ocpool-dispatch-$aid"
  done
}

# --- one tick ---------------------------------------------------------------
tick() {
  touch "$HEARTBEAT" 2>/dev/null || true

  if ! is_armed; then
    log_line "standby: DISARMED (no state/.ocpool-armed); run 'fm-ocpool.sh arm' to enable"
    return 0
  fi
  if kill_present; then
    log_line "standby: KILL SWITCH present (state/.ocpool-kill); no mutating action"
    return 0
  fi
  if ! acquire_fleet_lock; then
    local holder; holder=$(cat "$FLEET_LOCK" 2>/dev/null || true)
    log_line "standby: fleet lock held by another live session (pid ${holder:-?})"
    return 0
  fi

  log_line "armed tick: holding fleet lock (pid $$)"

  triage_pool_tasks

  local active free
  active=$(count_active_pool)
  free=$(( MAX_CONCURRENT - active ))
  if [ "$free" -gt 0 ]; then
    local status key repo prio text
    # shellcheck disable=SC2034  # prio drives the external sort key below, not the loop body
    while IFS=$'\t' read -r status key repo prio text; do
      [ "$free" -gt 0 ] || break
      [ "$status" = " " ] || continue
      [ -n "$key" ] || continue
      if dispatch_pool_item "$key" "$repo" "$text"; then
        free=$((free - 1))
      fi
    done < <(parse_pool_queued | sort -t"$(printf '\t')" -k4,4n -k2,2)
  else
    log_line "dispatch skipped: $active active >= cap $MAX_CONCURRENT"
  fi

  return 0
}

# --- long-lived loop --------------------------------------------------------
loop() {
  printf '%s\n' "$$" > "$STATE/.ocpool.pid"
  trap 'fm_lock_release "$SINGLETON_LOCK"; release_fleet_lock; rm -f "$STATE/.ocpool.pid"; exit 0' TERM INT EXIT
  fm_lock_acquire_wait "$SINGLETON_LOCK"
  log_line "loop starting (pid $$, tick ${TICK_SECONDS}s)"
  while true; do
    tick || true
    sleep "$TICK_SECONDS"
  done
}

# --- subcommands -------------------------------------------------------
cmd_start() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "error: tmux is required for 'start'; use 'once' in a loop, or run in a tmux-capable environment" >&2
    exit 1
  fi
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "ocpool already running in tmux session '$SESSION'"
    return 0
  fi
  tmux new-session -d -s "$SESSION" \
    "FM_HOME=$(printf %q "$FM_HOME") FM_ROOT_OVERRIDE=$(printf %q "$FM_ROOT") exec bash $(printf %q "$SELF") _loop"
  echo "ocpool started in tmux session '$SESSION' (tick ${TICK_SECONDS}s)"
  is_armed || echo "note: ocpool is DISARMED - run 'fm-ocpool.sh arm' to enable mutating actions"
}

cmd_stop() {
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    echo "ocpool tmux session '$SESSION' killed"
  else
    echo "no ocpool tmux session '$SESSION' running"
  fi
  fm_lock_release "$SINGLETON_LOCK"
  release_fleet_lock
  rm -f "$STATE/.ocpool.pid" 2>/dev/null || true
}

cmd_status() {
  printf 'ocpool status @ %s\n' "$(now_iso)"
  if is_armed; then printf '  armed:      YES (%s)\n' "$(head -1 "$ARMED_FLAG" 2>/dev/null)"; else printf '  armed:      no (DISARMED)\n'; fi
  kill_present && printf '  kill:       PRESENT (mutating actions suspended)\n' || printf '  kill:       absent\n'
  if lock_held_by_other; then
    printf '  fleet lock: held by ANOTHER session (pid %s) - ocpool standby\n' "$(cat "$FLEET_LOCK" 2>/dev/null)"
  elif [ -f "$OWNS_LOCK" ] && [ "$(cat "$FLEET_LOCK" 2>/dev/null || true)" = "$(cat "$OWNS_LOCK" 2>/dev/null || true)" ]; then
    printf '  fleet lock: ocpool-owned (pid %s)\n' "$(cat "$OWNS_LOCK" 2>/dev/null)"
  else
    printf '  fleet lock: free/stale (available)\n'
  fi
  if [ -e "$SINGLETON_LOCK" ]; then printf '  singleton lock: held\n'; else printf '  singleton lock: free\n'; fi
  if [ -f "$HEARTBEAT" ]; then printf '  heartbeat:  %ss ago\n' "$(file_age "$HEARTBEAT")"; else printf '  heartbeat:  none yet\n'; fi
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
    printf '  loop:       running (tmux session %s)\n' "$SESSION"
  else
    printf '  loop:       not running\n'
  fi
  printf '  active pool tasks: %s (cap %s)\n' "$(count_active_pool)" "$MAX_CONCURRENT"
  printf '  queued pool tasks: %s\n' "$(count_pool_queued)"
  if [ -f "$NEEDS_CAPTAIN_MD" ]; then printf '  needs-captain receipts: %s\n' "$(grep -c '|' "$NEEDS_CAPTAIN_MD" 2>/dev/null || echo 0)"; fi
}

cmd_arm() {
  local note=${1:-armed by operator}
  { printf '%s\n' "$note"; printf 'armed-at: %s\n' "$(now_iso)"; } > "$ARMED_FLAG"
  receipt arm "-" "$note"
  echo "ocpool ARMED: $note"
  kill_present && echo "warning: kill switch (state/.ocpool-kill) is present; remove it to allow mutating actions"
}

cmd_disarm() {
  rm -f "$ARMED_FLAG" 2>/dev/null || true
  receipt disarm "-" ""
  echo "ocpool DISARMED (state/.ocpool-armed removed)"
}

cmd_once() {
  fm_lock_acquire_wait "$SINGLETON_LOCK"
  tick
  fm_lock_release "$SINGLETON_LOCK"
  # A one-shot pass releases the fleet lock so it never strands a dead pid marker.
  release_fleet_lock
}

main() {
  local sub=${1:-status}
  shift || true
  case "$sub" in
    start)   cmd_start "$@" ;;
    stop)    cmd_stop "$@" ;;
    status)  cmd_status "$@" ;;
    once)    cmd_once "$@" ;;
    arm)     cmd_arm "$@" ;;
    disarm)  cmd_disarm "$@" ;;
    _loop)   loop ;;   # internal: launched by 'start' inside tmux
    -h|--help|help)
      sed -n '2,90p' "$SELF" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "usage: fm-ocpool.sh { start | stop | status | once | arm [note] | disarm }" >&2
      exit 2
      ;;
  esac
}

main "$@"
