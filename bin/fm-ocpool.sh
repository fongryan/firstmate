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
# from durable lifecycle state). It reuses the existing queue (data/backlog.md
# via tasks-axi), the existing closed-loop lifecycle ledger (bin/fm-lifecycle.sh)
# for state truth - it does not reimplement any of them.
#
# QUEUE MARKER: a backlog item opts into this pool by carrying a
# "(pool: opencode)" parenthetical field, the same bracket-field convention
# fm-autopilot.sh already uses for (repo: ...)/(kind: ...)/(priority: ...).
# NOT "(kind: ocpool)": fm-autopilot.sh's dispatch_item() only branches on
# kind to decide whether to pass --scout (`[ "$kind" = scout ] && args+=(--scout)`);
# every other kind value, including "ocpool", is dispatched as an ordinary
# ship task via fm-spawn.sh. A `(kind: ocpool)` marker would therefore NOT be
# ignored by fm-autopilot.sh - it would get dispatched through the crew
# harness path too. "pool" is a field name fm-autopilot.sh's field() extractor
# never queries at all, so it is provably ignored. No fm-autopilot.sh change
# was needed or made.
#
# COEXISTENCE RACE: fm-autopilot.sh's own tick still scans every row under
# "## Queued" regardless of this marker, and nothing here changes that. This
# loop closes the double-dispatch hole by claiming through `tasks-axi start`,
# which physically MOVES the item out of "## Queued" into "## In flight" -
# fm-autopilot.sh's parse_queued only scans the Queued section
# (`inq = ($0 ~ /^## Queued/)`), so a claimed item is invisible to it, not
# merely deprioritized. A residual race remains only for the brief window
# between a pool item first appearing in Queued and this loop's next tick
# claiming it (see docs/ocpool.md).
#
# LOCK MODEL: this loop does NOT use the shared fleet lock (state/.lock) that
# fm-autopilot.sh and an interactive captain session contend over. It is
# subordinate gruntwork dispatch, not captain-acting on the fleet, so it runs
# even while an interactive session is live - fm-autopilot.sh's
# stand-down-for-the-captain rule deliberately does not apply here. It has its
# own private lock, state/.ocpool.lock + state/.ocpool.owns-lock, a literal
# copy of fm-autopilot.sh's acquire_fleet_lock/release_fleet_lock/
# lock_held_by_other trio (fm-autopilot.sh:230-247) on renamed paths; the same
# trio doubles as this loop's singleton guard, since only one fm-ocpool.sh
# process can hold state/.ocpool.lock at a time. The one way a captain pauses
# it explicitly is state/.ocpool-preempt (`touch`/`rm`), checked first in
# every tick, mirroring fm-autopilot.sh's own preempt flag shape.
#
# GATES, all fail-closed, checked in this order every tick - preempt, armed,
# kill, own-lock (mirrors fm-autopilot.sh:690-753):
#   1. PREEMPT   - state/.ocpool-preempt present -> release the own lock and
#                  stand by immediately.
#   2. ARMED     - ships DISARMED. `arm` writes state/.ocpool-armed. The loop
#                  refuses every mutating action unless armed.
#   3. KILL      - state/.ocpool-kill, checked every tick. Present = no
#                  mutating action this or any tick until removed.
#   4. OWN LOCK  - a mutating tick runs only when this loop holds
#                  state/.ocpool.lock (acquired fresh each tick; held across
#                  the sleep interval until released by preempt, a one-shot
#                  `once`, or process exit).
#
# SAFETY GUARDS (ported from fm-autopilot.sh's dispatch_item(),
# fm-autopilot.sh:441-487, non-negotiable - a pool without these reopens a
# closed safety hole): the same destructive/security-sensitive text guard
# (DANGER_RE) and the same excluded-project hard exclusion, reusing
# FM_AUTOPILOT_EXCLUDE_PROJECTS (default armalo-fi,poly-sdk) so one captain
# configuration covers both loops.
#
# CAPACITY: free slots = FM_OCPOOL_MAX_CONCURRENT minus active pool tasks.
# Mirrors fm-autopilot.sh's count_active_crew() (fm-autopilot.sh:370-388):
# scan state/*.meta, filter kind=ocpool-worker (written by this loop at
# dispatch, the same state/<id>.meta convention every other Firstmate direct
# report uses), and for each meta whose recorded lifecycle_id has
# `state=active` in its bin/fm-lifecycle.sh ledger file, count it - never via
# `ps`, never via a private duplicate ledger. Known cross-system caveat: see
# docs/ocpool.md "Known limitations" for the fm-autopilot.sh capacity
# interaction this introduces. FM_OCPOOL_MAX_ACTIVE_AGENTS is a SEPARATE,
# larger cap forwarded to the bridge as
# FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS - flowstate's resource-guardian
# in ENFORCE mode is the single authority for that one; this loop never
# second-guesses a guardian admission refusal.
#
# BACKLOG MUTATION: exclusively through tasks-axi ops (`start`, `reopen`,
# `done`), gated on bin/fm-tasks-axi-lib.sh's fm_tasks_axi_backend_available -
# never a raw sed/awk hand-edit. When the backend is unavailable (tasks-axi
# missing/incompatible, or config/backlog-backend=manual), this loop refuses
# to dispatch rather than hand-edit data/backlog.md itself. See docs/ocpool.md
# for the captain-concurrency caveat this implies.
#
# BRIDGE EXIT-CODE CONTRACT (bin/fm-ocpool-dispatch.mjs, run once per attempt,
# in the background; stdout captured to data/ocpool/<key>.receipt.json - the
# bridge's own printed receipt JSON - stderr to data/ocpool/<key>.log):
#   0  verified        -> lifecycle closeout(completed), backlog item moved to
#                          Done via `tasks-axi done`, receipt line.
#   2  blocked         -> machine admission refused (not this task's fault).
#                          Backlog item requeued via `tasks-axi reopen`; does
#                          NOT consume an attempt; receipt line names the
#                          reason.
#   3/4 failed         -> attempts < FM_OCPOOL_MAX_ATTEMPTS (default 2):
#                          requeued via `tasks-axi reopen` for a retry, with a
#                          handoff note appended to the task's brief. Attempts
#                          exhausted: escalated to data/ocpool/needs-captain.md,
#                          left claimed so nothing silently retries it forever.
#   5  config bug      -> escalated to needs-captain.md immediately, no retry.
#   anything else      -> treated as a failed attempt (conservative).
# heartbeat: every tick, this loop calls `bin/fm-lifecycle.sh heartbeat
# <attempt-id> --owner ocpool` for every still-running attempt (its exit
# marker not yet present) so the ledger's heartbeat never goes stale while the
# bridge process is genuinely alive; a task already at a terminal lifecycle
# state is never heartbeat (fm-lifecycle.sh itself refuses that).
#
# RECEIPTS: one line per mutating action appended to data/ocpool/log.md
# (timestamp, action, target, detail), mirroring fm-autopilot.sh's receipt
# shape. Anything needing a human lands in data/ocpool/needs-captain.md.
# state/.ocpool-heartbeat is touched every tick, armed or not.
#
# ENV KNOBS (all optional):
#   FM_OCPOOL_TICK_SECS            loop cadence seconds (default 60)
#   FM_OCPOOL_MAX_CONCURRENT       max active pool tasks before dispatch stops (default 3)
#   FM_OCPOOL_MAX_ATTEMPTS         max attempts per task before needs-captain (default 2)
#   FM_OCPOOL_MAX_ACTIVE_AGENTS    forwarded to the bridge as FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS (default 5)
#   FM_AUTOPILOT_EXCLUDE_PROJECTS  shared with fm-autopilot.sh; never-touch projects (default "armalo-fi,poly-sdk")
#   FM_OCPOOL_DISPATCH_BIN         the bridge command to exec (default $FM_ROOT/bin/fm-ocpool-dispatch.mjs)
#   FM_OCPOOL_SESSION              tmux session name for start/stop (default "fm-ocpool")
#   FLOWSTATE_ROOT / FM_FLOWSTATE_ROOT   passed through unchanged to the bridge when set in this loop's own environment
#
# SUBCOMMANDS: start | stop | status | once | arm | disarm
#   start    launch the loop as a detached tmux session
#   stop     kill the loop session and release the own lock
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

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

# --- tunables ---------------------------------------------------------------
TICK_SECS=${FM_OCPOOL_TICK_SECS:-60}
MAX_CONCURRENT=${FM_OCPOOL_MAX_CONCURRENT:-3}
MAX_ATTEMPTS=${FM_OCPOOL_MAX_ATTEMPTS:-2}
MAX_ACTIVE_AGENTS=${FM_OCPOOL_MAX_ACTIVE_AGENTS:-5}
EXCLUDE_PROJECTS=${FM_AUTOPILOT_EXCLUDE_PROJECTS:-armalo-fi,poly-sdk}
DISPATCH_BIN=${FM_OCPOOL_DISPATCH_BIN:-$FM_ROOT/bin/fm-ocpool-dispatch.mjs}
SESSION=${FM_OCPOOL_SESSION:-fm-ocpool}
LIFECYCLE_BIN="$FM_ROOT/bin/fm-lifecycle.sh"

# Same destructive/security-sensitive guard as fm-autopilot.sh (fm-autopilot.sh:132).
DANGER_RE='(--no-verify|--force|force[- ]push|rm -rf|DROP TABLE|delete .*(secret|key)|private key|credential|kill.?switch|LIVE_TRADING|autonomy.?tier|--hard\b)'

# state / data paths (state/ and data/ are gitignored, so these are all local)
ARMED_FLAG="$STATE/.ocpool-armed"
KILL_FLAG="$STATE/.ocpool-kill"
PREEMPT_FLAG="$STATE/.ocpool-preempt"
HEARTBEAT="$STATE/.ocpool-heartbeat"
OWN_LOCK="$STATE/.ocpool.lock"
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

is_excluded_project() {  # <repo>
  local repo=$1 IFS=,
  local ex
  for ex in $EXCLUDE_PROJECTS; do
    [ "$ex" = "$repo" ] && return 0
  done
  return 1
}

is_dangerous_text() {  # <text>
  printf '%s' "$1" | grep -qiE "$DANGER_RE"
}

# --- gates --------------------------------------------------------------
is_armed()        { [ -f "$ARMED_FLAG" ]; }
kill_present()     { [ -e "$KILL_FLAG" ]; }
preempt_present()  { [ -e "$PREEMPT_FLAG" ]; }

# lock_held_by_other / acquire_own_lock / release_own_lock: this loop's own
# private lock. Started as a literal copy of fm-autopilot.sh's
# acquire_fleet_lock/release_fleet_lock/lock_held_by_other trio
# (fm-autopilot.sh:230-247), but that trio's pid==owner "we hold it" check
# only works when the lock has two DISTINCT classes of writer (autopilot vs.
# an interactive captain session touching the shared state/.lock) - autopilot
# never writes state/.autopilot-owns-lock for a foreign holder, so pid==owner
# there really does mean "the current holder is autopilot itself". This
# loop's private lock has exactly one writer class (fm-ocpool.sh itself), so
# whichever ocpool process most recently acquired it wrote the SAME pid to
# both a lock file and a second "owner" file; a literal copy of the trio would
# make pid==owner true for ANY live holder, self or other, and a second
# concurrent ocpool process would wrongly conclude "we hold it" and steal the
# lock out from under a live first process. Verified by
# tests/fm-ocpool.test.sh's own-lock test before this fix landed. Compare
# directly against this process's own $$ instead - correct for a
# single-writer-class lock, and the same pattern bin/fm-lifecycle.sh's own
# acquire_lock() uses (a bare pid file, no owner indirection).
lock_held_by_other() {
  [ -f "$OWN_LOCK" ] || return 1
  local pid
  pid=$(cat "$OWN_LOCK" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  [ "$pid" = "$$" ] && return 1   # this exact process already holds it
  pid_alive "$pid"
}

acquire_own_lock() {
  lock_held_by_other && return 1
  printf '%s\n' "$$" > "$OWN_LOCK"
  return 0
}

release_own_lock() {
  local pid
  pid=$(cat "$OWN_LOCK" 2>/dev/null || true)
  [ "$pid" = "$$" ] && rm -f "$OWN_LOCK" 2>/dev/null || true
}

# --- backlog parsing: a literal copy of fm-autopilot.sh's parse_queued()
# (fm-autopilot.sh:339-364), plus a pool-marker filter fm-autopilot.sh's own
# parser is blind to. Row shape and sort key match fm-autopilot.sh's own
# (status, key, repo, kind, priority, text). ---------------------------------
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
      kind = field($0, "kind")
      prio = field($0, "priority")
      if (prio == "" || prio ~ /[^0-9]/) prio = 9999
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", status, key, repo, kind, prio, $0
    }
  ' "$backlog"
}

count_pool_queued() {  # count of unclaimed '[ ]' pool items in Queued
  parse_pool_queued | awk -F '\t' '$1==" "{n++} END{print n+0}'
}

# --- capacity: scan state/*.meta filtering kind=ocpool-worker, read
# fm-lifecycle state, never ps. Mirrors fm-autopilot.sh's count_active_crew().
count_active_pool() {
  local f kind lcid n=0
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    kind=$(meta_get "$f" kind)
    [ "$kind" = ocpool-worker ] || continue
    lcid=$(meta_get "$f" lifecycle_id)
    [ -n "$lcid" ] || continue
    [ "$(meta_get "$STATE/$lcid.lifecycle" state)" = active ] && n=$((n + 1))
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

# --- backlog mutation: exclusively via tasks-axi ops, never a raw hand-edit.
# tasks_axi_ready gates every mutating call; a caller that cannot mutate
# escalates instead of falling back to sed/awk. -----------------------------
tasks_axi_ready() {
  fm_tasks_axi_backend_available "$CONFIG" && command -v tasks-axi >/dev/null 2>&1
}

pool_backlog_start() {  # <key>: Queued -> In flight (tasks-axi start, idempotent)
  ( cd "$FM_HOME" 2>/dev/null && tasks-axi start "$1" ) >/dev/null 2>&1
}

pool_backlog_reopen() {  # <key>: In flight/Done -> Queued (tasks-axi reopen, idempotent)
  ( cd "$FM_HOME" 2>/dev/null && tasks-axi reopen "$1" ) >/dev/null 2>&1
}

pool_backlog_done() {  # <key> <note>: -> Done (tasks-axi done)
  ( cd "$FM_HOME" 2>/dev/null && tasks-axi "done" "$1" --note "$2" ) >/dev/null 2>&1
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
  local key=$1 repo=$2 text=$3 n attempt aid depth brief rcpt log proj

  n=$(retry_count "$key")
  attempt=$((n + 1))
  aid="$key-a$attempt"
  # Guards only against re-dispatching the same in-flight attempt (e.g. a
  # duplicate row in one tick's already-buffered queue read); triage_pool_tasks
  # removes this marker when the attempt concludes so a legitimate later retry
  # of the same attempt number (a blocked outcome does not bump retry_count)
  # is never permanently locked out.
  once_marker "dispatch" "$aid" || return 1

  # The four guards below mirror fm-autopilot.sh's dispatch_item() exactly
  # (fm-autopilot.sh:441-487): no-repo and destructive-text escalate, an
  # excluded project is a hard skip (receipt only, no escalation).
  if [ -z "$repo" ]; then
    once_marker norepo "$key" && needs_captain "$key" "no-repo" "pool item has no (repo: ...) - cannot dispatch autonomously"
    return 1
  fi
  if is_excluded_project "$repo"; then
    once_marker skipdispatch "$key" && receipt skip-dispatch "$key" "excluded project $repo (hard exclusion)"
    return 1
  fi
  if is_dangerous_text "$text"; then
    once_marker danger "$key" && needs_captain "$key" "destructive/security-sensitive" "matched danger guard; not auto-dispatched"
    return 1
  fi
  proj="$PROJECTS/$repo"
  if [ ! -d "$proj" ]; then
    needs_captain "$key" "missing-clone" "no project clone at $proj"
    return 1
  fi

  depth=${AGENT_ORCH_DEPTH:-0}
  if [ "$depth" -ge 2 ]; then
    needs_captain "$key" "orch-depth-exceeded" "AGENT_ORCH_DEPTH=$depth at or above max 2; refusing to spawn"
    return 1
  fi

  if ! tasks_axi_ready; then
    needs_captain "$key" "tasks-axi-unavailable" "backlog backend unavailable/manual; refusing to hand-edit data/backlog.md"
    return 1
  fi
  if ! pool_backlog_start "$key"; then
    needs_captain "$key" "backlog-start-failed" "tasks-axi start $key failed"
    return 1
  fi

  ensure_pool_brief "$key" "$text"
  brief="$DATA/$key/brief.md"
  rcpt="$OC_DATA/$key.receipt.json"
  log="$OC_DATA/$key.log"
  mkdir -p "$OC_DATA" 2>/dev/null || true

  "$LIFECYCLE_BIN" register "$aid" --repo "$repo" --owner ocpool \
    --branch "opencode-pool/$key" --worktree "$proj" --objective "$text" >/dev/null 2>&1 \
    || { pool_backlog_reopen "$key"; needs_captain "$key" "lifecycle-register-failed" "attempt=$aid"; return 1; }
  "$LIFECYCLE_BIN" transition "$aid" active --reason dispatch --evidence "$rcpt" >/dev/null 2>&1 \
    || { pool_backlog_reopen "$key"; needs_captain "$key" "lifecycle-transition-failed" "attempt=$aid"; return 1; }

  fm_write_pool_meta "$key" "$aid" "$attempt" "$repo" "$proj"
  receipt dispatch "$key" "attempt=$attempt repo=$repo"

  (
    export AGENT_ORCH_DEPTH=$((depth + 1))
    export FLOWSTATE_RESOURCE_GUARD_MODE=enforce
    export FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS="$MAX_ACTIVE_AGENTS"
    [ -n "${FLOWSTATE_ROOT:-}" ] && export FLOWSTATE_ROOT
    [ -n "${FM_FLOWSTATE_ROOT:-}" ] && export FM_FLOWSTATE_ROOT
    "$DISPATCH_BIN" --task-id "$key" --repo "$proj" --prompt-file "$brief" --json \
      >"$rcpt" 2>"$log"
    printf '%s\n' "$?" > "$STATE/.ocpool-exit-$key"
  ) &
  disown 2>/dev/null || true
  return 0
}

# fm_write_pool_meta <key> <aid> <attempt> <repo> <proj>: the same
# state/<id>.meta convention every other Firstmate direct report uses
# (AGENTS.md section 2), so fleet-visibility tooling can see pool tasks too.
# kind=ocpool-worker (not any of fm-autopilot.sh's recognized kinds) is the
# capacity-counting filter for count_active_pool(); lifecycle_id= is the
# pointer into bin/fm-lifecycle.sh's ledger.
fm_write_pool_meta() {
  local key=$1 aid=$2 attempt=$3 repo=$4 proj=$5
  {
    printf 'window=ocpool:%s\n' "$key"
    printf 'kind=ocpool-worker\n'
    printf 'project=%s\n' "$proj"
    printf 'repo=%s\n' "$repo"
    printf 'harness=opencode\n'
    printf 'mode=ocpool\n'
    printf 'yolo=off\n'
    printf 'lifecycle_id=%s\n' "$aid"
    printf 'attempt=%s\n' "$attempt"
  } > "$STATE/$key.meta"
}

# --- outcome handling ------------------------------------------------------
handle_pool_verified() {  # <key> <aid> <rcpt> <log>
  local key=$1 aid=$2 rcpt=$3
  "$LIFECYCLE_BIN" closeout "$aid" completed --reason verified --evidence "$rcpt" >/dev/null 2>&1 || true
  if pool_backlog_done "$key" "opencode pool: verified (log data/ocpool/$key.log)"; then
    receipt "done" "$key" "attempt=$aid verified"
  else
    needs_captain "$key" "backlog-done-failed" "attempt=$aid verified but tasks-axi done failed; backlog needs manual update"
  fi
}

handle_pool_blocked() {  # <key> <aid> <rcpt> <log>
  local key=$1 aid=$2 rcpt=$3 log=$4 reason
  reason=$(tail -c 2000 "$log" 2>/dev/null | tail -1)
  "$LIFECYCLE_BIN" closeout "$aid" interrupted --reason "blocked: machine admission refused" --evidence "$rcpt" >/dev/null 2>&1 || true
  if pool_backlog_reopen "$key"; then
    receipt blocked "$key" "attempt=$aid ${reason:-admission refused}"
  else
    needs_captain "$key" "backlog-reopen-failed" "attempt=$aid blocked but tasks-axi reopen failed; backlog needs manual update"
  fi
}

handle_pool_failed() {  # <key> <aid> <rcpt> <log>
  local key=$1 aid=$2 rcpt=$3 log=$4 n reason
  reason=$(tail -c 2000 "$log" 2>/dev/null | tail -1)
  n=$(bump_retry "$key")
  if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
    "$LIFECYCLE_BIN" closeout "$aid" interrupted --reason "failed-retry $n/$MAX_ATTEMPTS: ${reason:-non-zero exit}" --evidence "$rcpt" >/dev/null 2>&1 || true
    if pool_backlog_reopen "$key"; then
      append_handoff_note "$key" "attempt $n failed: ${reason:-see data/ocpool/$key.log}"
      receipt requeue "$key" "attempt=$aid failed, retry $n/$MAX_ATTEMPTS"
    else
      needs_captain "$key" "backlog-reopen-failed" "attempt=$aid failed but tasks-axi reopen failed; backlog needs manual update"
    fi
  else
    "$LIFECYCLE_BIN" closeout "$aid" abandoned --reason "failed-exhausted $n/$MAX_ATTEMPTS: ${reason:-non-zero exit}" --evidence "$rcpt" >/dev/null 2>&1 || true
    needs_captain "$key" "failed-exhausted" "attempt=$aid $n/$MAX_ATTEMPTS attempts failed: ${reason:-see data/ocpool/$key.log}"
  fi
}

handle_pool_config_bug() {  # <key> <aid> <rcpt> <log>
  local key=$1 aid=$2 rcpt=$3 log=$4 reason
  reason=$(tail -c 2000 "$log" 2>/dev/null | tail -1)
  "$LIFECYCLE_BIN" closeout "$aid" abandoned --reason "config-bug: ${reason:-exit 5}" --evidence "$rcpt" >/dev/null 2>&1 || true
  needs_captain "$key" "config-bug" "attempt=$aid bridge exited 5 (config bug): ${reason:-see data/ocpool/$key.log}"
}

triage_pool_tasks() {
  local f key kind aid exitfile code rcpt log
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    kind=$(meta_get "$f" kind)
    [ "$kind" = ocpool-worker ] || continue
    key=$(basename "$f" .meta)
    aid=$(meta_get "$f" lifecycle_id)
    if [ -z "$aid" ]; then
      rm -f "$f"
      continue
    fi
    exitfile="$STATE/.ocpool-exit-$key"
    [ -f "$exitfile" ] || continue  # still running
    code=$(cat "$exitfile" 2>/dev/null || true)
    rcpt="$OC_DATA/$key.receipt.json"
    log="$OC_DATA/$key.log"
    [ -e "$rcpt" ] || : > "$rcpt"  # closeout requires existing evidence
    [ -e "$log" ] || : > "$log"
    case "$code" in
      0) handle_pool_verified "$key" "$aid" "$rcpt" "$log" ;;
      2) handle_pool_blocked "$key" "$aid" "$rcpt" "$log" ;;
      3|4) handle_pool_failed "$key" "$aid" "$rcpt" "$log" ;;
      5) handle_pool_config_bug "$key" "$aid" "$rcpt" "$log" ;;
      *) handle_pool_failed "$key" "$aid" "$rcpt" "$log" ;;
    esac
    rm -f "$f" "$exitfile" "$STATE/.ocpool-dispatch-$aid"
  done
}

# heartbeat_active_pool_tasks: keep bin/fm-lifecycle.sh's heartbeat fresh for
# every attempt whose bridge process is still running (no exit marker yet).
# A task about to be triaged this same tick (exit marker present) is skipped,
# and a task already at a terminal lifecycle state is never reached here
# because triage_pool_tasks removes its meta the moment it goes terminal.
heartbeat_active_pool_tasks() {
  local f key kind aid
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    kind=$(meta_get "$f" kind)
    [ "$kind" = ocpool-worker ] || continue
    key=$(basename "$f" .meta)
    [ -f "$STATE/.ocpool-exit-$key" ] && continue
    aid=$(meta_get "$f" lifecycle_id)
    [ -n "$aid" ] || continue
    "$LIFECYCLE_BIN" heartbeat "$aid" --owner ocpool >/dev/null 2>&1 || true
  done
}

# --- one tick ---------------------------------------------------------------
tick() {
  touch "$HEARTBEAT" 2>/dev/null || true

  if preempt_present; then
    release_own_lock
    log_line "standby: preempt requested (state/.ocpool-preempt present); released own lock"
    return 0
  fi
  if ! is_armed; then
    log_line "standby: DISARMED (no state/.ocpool-armed); run 'fm-ocpool.sh arm' to enable"
    return 0
  fi
  if kill_present; then
    log_line "standby: KILL SWITCH present (state/.ocpool-kill); no mutating action"
    return 0
  fi
  if ! acquire_own_lock; then
    local holder; holder=$(cat "$OWN_LOCK" 2>/dev/null || true)
    log_line "standby: own lock held by another ocpool process (pid ${holder:-?})"
    return 0
  fi

  log_line "armed tick: holding own lock (pid $$)"

  triage_pool_tasks
  heartbeat_active_pool_tasks

  local active free
  active=$(count_active_pool)
  free=$(( MAX_CONCURRENT - active ))
  if [ "$free" -gt 0 ]; then
    local status key repo kind prio text
    # shellcheck disable=SC2034  # kind/prio mirror fm-autopilot.sh's row shape and
    # drive the external sort key above; kind has no ocpool-side branch (no scout
    # analog) and prio is consumed only by the sort, not the loop body.
    while IFS=$'\t' read -r status key repo kind prio text; do
      [ "$free" -gt 0 ] || break
      [ "$status" = " " ] || continue
      [ -n "$key" ] || continue
      if dispatch_pool_item "$key" "$repo" "$text"; then
        free=$((free - 1))
      fi
    done < <(parse_pool_queued | sort -t"$(printf '\t')" -k5,5n -k2,2)
  else
    log_line "dispatch skipped: $active active >= cap $MAX_CONCURRENT"
  fi

  return 0
}

# --- long-lived loop --------------------------------------------------------
loop() {
  printf '%s\n' "$$" > "$STATE/.ocpool.pid"
  trap 'release_own_lock; rm -f "$STATE/.ocpool.pid"; exit 0' TERM INT EXIT
  log_line "loop starting (pid $$, tick ${TICK_SECS}s)"
  while true; do
    tick || true
    sleep "$TICK_SECS"
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
  echo "ocpool started in tmux session '$SESSION' (tick ${TICK_SECS}s)"
  is_armed || echo "note: ocpool is DISARMED - run 'fm-ocpool.sh arm' to enable mutating actions"
}

cmd_stop() {
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    echo "ocpool tmux session '$SESSION' killed"
  else
    echo "no ocpool tmux session '$SESSION' running"
  fi
  release_own_lock
  rm -f "$STATE/.ocpool.pid" 2>/dev/null || true
}

cmd_status() {
  printf 'ocpool status @ %s\n' "$(now_iso)"
  if is_armed; then printf '  armed:      YES (%s)\n' "$(head -1 "$ARMED_FLAG" 2>/dev/null)"; else printf '  armed:      no (DISARMED)\n'; fi
  kill_present && printf '  kill:       PRESENT (mutating actions suspended)\n' || printf '  kill:       absent\n'
  preempt_present && printf '  preempt:    PRESENT (standby requested)\n' || printf '  preempt:    absent\n'
  # status is always a fresh, short-lived process, so it never legitimately
  # "holds" the lock itself; report an alive holder as held, full stop.
  if [ -f "$OWN_LOCK" ] && pid_alive "$(cat "$OWN_LOCK" 2>/dev/null || true)"; then
    printf '  own lock:   held (pid %s)\n' "$(cat "$OWN_LOCK" 2>/dev/null)"
  else
    printf '  own lock:   free/stale (available)\n'
  fi
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
  tick
  # A one-shot pass releases the own lock so it never strands a dead pid marker.
  release_own_lock
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
    _loop)   loop ;;   # internal: launched by 'start' inside tmux, and the
                        # correct direct entrypoint for a launchd/ECS
                        # supervisor - see bin/fm-ocpool-install.sh.
    -h|--help|help)
      sed -n '2,110p' "$SELF" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "usage: fm-ocpool.sh { start | stop | status | once | arm [note] | disarm }" >&2
      exit 2
      ;;
  esac
}

main "$@"
