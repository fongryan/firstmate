#!/usr/bin/env bash
# fm-autopilot.sh - the headless captain loop: the never-stopping "software
# factory" driver that keeps Firstmate making forward progress when no
# interactive captain session is holding the fleet lock.
#
# WHY THIS EXISTS
# Firstmate today is event-driven and captain-in-the-loop: an interactive
# harness session holds the fleet lock (state/.lock), a watcher classifies
# crewmate wakes, and an away-mode daemon injects escalations into the
# lock-holder's pane. When that interactive session idles (the captain stops
# prompting), the loop stalls: drained wake records queue undrained, finished
# crewmate work sits at "needs captain review/merge" (no project is +yolo by
# default), and nothing dispatches the next backlog item. fm-autopilot is the
# missing headless driver that, ONLY WHEN EXPLICITLY ARMED and ONLY WHEN NO
# interactive session holds the lock, drains wakes, promotes/merges green
# yolo-authorized work, dispatches the next backlog items up to a concurrency
# cap, refills the backlog with a scout, and leaves a receipt for every action.
#
# IT DOES NOT REPLACE THE CAPTAIN. The interactive human session always
# outranks autopilot. Autopilot marks its own lock ownership
# (state/.autopilot-owns-lock) so a starting interactive fm-session-start.sh
# treats autopilot's non-harness lock as stale and preempts it; autopilot also
# watches state/.autopilot-preempt and releases within one tick when asked.
#
# LIFECYCLE, three orthogonal gates, all fail-closed:
#   1. ARMED     - ships DISARMED. `arm` writes state/.autopilot-armed. The loop
#                  refuses every mutating action unless armed.
#   2. KILL      - state/.autopilot-kill, checked every tick. Present = no
#                  mutating action this or any tick until removed. (Operator
#                  sets it with `touch state/.autopilot-kill`, clears with `rm`.)
#   3. LOCK      - a mutating tick runs only when autopilot holds the fleet lock
#                  and no other live session holds it. Standby otherwise.
#
# SAFETY HARD RULES (encoded as code below, not just documented):
#   - Never push with --no-verify and never force-merge: autopilot never pushes;
#     it merges only through fm-pr-merge.sh / fm-merge-local.sh, both of which
#     fast-forward or squash through the sanctioned gate and never force.
#   - Never merge un-green work: a no-mistakes/direct-PR merge requires a
#     recorded pr= AND a green proof marker in the crew's status; otherwise the
#     work is escalated to the captain, never merged.
#   - Never touch a live-trading / local-only-money project: FM_AUTOPILOT_EXCLUDE_PROJECTS
#     (default "armalo-fi,poly-sdk") is a hard dispatch AND merge exclusion, and
#     any backlog item whose text trips the destructive/security guard is
#     escalated + skipped rather than dispatched.
#   - Never delete or reset another agent's worktree: autopilot never runs
#     teardown, git reset, or git clean.
#   - yolo=off means ask the captain: finished work in a yolo=off project is
#     written as a needs-captain receipt, never merged.
#
# RECEIPTS: every mutating action appends one compact line to
# data/autopilot/log.md (timestamp, action, target, proof ref). Anything that
# needs the captain lands in data/autopilot/needs-captain.md. Backlog-refill
# proposals land in data/autopilot/proposals.md. state/.autopilot-heartbeat is
# touched every tick (even in standby) so a cockpit can project autopilot
# liveness.
#
# ENV KNOBS (all optional; defaults chosen for a conservative first arm):
#   FM_AUTOPILOT_TICK_SECS            loop cadence seconds (default 120)
#   FM_AUTOPILOT_MAX_CONCURRENT       max active crewmates before dispatch stops (default 3)
#   FM_AUTOPILOT_MIN_QUEUE            refill a scout when queued backlog < this (default 5)
#   FM_AUTOPILOT_MAX_RETRIES          max auto-handled retries of a blocked/failed task (default 1)
#   FM_AUTOPILOT_MAX_BRAIN_CALLS_PER_HOUR  bounded LLM judgment calls per hour (default 6)
#   FM_AUTOPILOT_EXCLUDE_PROJECTS     comma list of never-touch projects (default "armalo-fi,poly-sdk")
#   FM_AUTOPILOT_BRAIN                harness used for bounded judgment turns (default "claude")
#   FM_AUTOPILOT_BRAIN_CMD            full override of the brain invocation (testing/harness swap)
#   FM_AUTOPILOT_SPAWN_CMD           dispatch command (default $FM_ROOT/bin/fm-spawn.sh)
#   FM_AUTOPILOT_MERGE_PR_CMD        PR merge command (default $FM_ROOT/bin/fm-pr-merge.sh)
#   FM_AUTOPILOT_MERGE_LOCAL_CMD     local-only merge command (default $FM_ROOT/bin/fm-merge-local.sh)
#   FM_AUTOPILOT_CLAUDE_PROFILES     colon-separated CLAUDE_CONFIG_DIR list for account cycling
#   FM_AUTOPILOT_CODEX_PROFILES      colon-separated CODEX_HOME list for account cycling
#   FM_AUTOPILOT_SESSION             tmux session name for start/stop (default "fm-autopilot")
#
# SUBCOMMANDS: start | stop | status | once | arm | disarm
#   start    launch the loop as a detached tmux session
#   stop     kill the loop session and release the fleet lock
#   status   print the arm/kill/preempt/lock/heartbeat picture
#   once     run exactly one tick in the foreground and exit (used by tests and
#            by an operator who wants a single supervised pass)
#   arm      write state/.autopilot-armed with an optional captain note
#   disarm   remove state/.autopilot-armed
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

# --- tunables ---------------------------------------------------------------
TICK_SECS=${FM_AUTOPILOT_TICK_SECS:-120}
MAX_CONCURRENT=${FM_AUTOPILOT_MAX_CONCURRENT:-3}
MIN_QUEUE=${FM_AUTOPILOT_MIN_QUEUE:-5}
MAX_RETRIES=${FM_AUTOPILOT_MAX_RETRIES:-1}
MAX_BRAIN_CALLS=${FM_AUTOPILOT_MAX_BRAIN_CALLS_PER_HOUR:-6}
EXCLUDE_PROJECTS=${FM_AUTOPILOT_EXCLUDE_PROJECTS:-armalo-fi,poly-sdk}
BRAIN=${FM_AUTOPILOT_BRAIN:-claude}
SPAWN_CMD=${FM_AUTOPILOT_SPAWN_CMD:-$FM_ROOT/bin/fm-spawn.sh}
MERGE_PR_CMD=${FM_AUTOPILOT_MERGE_PR_CMD:-$FM_ROOT/bin/fm-pr-merge.sh}
MERGE_LOCAL_CMD=${FM_AUTOPILOT_MERGE_LOCAL_CMD:-$FM_ROOT/bin/fm-merge-local.sh}
PROFILE_ROUTER=${FM_AUTOPILOT_PROFILE_ROUTER:-$FM_ROOT/bin/fm-agent-profile-route.mjs}
PROFILE_BRAIN_ROOT=${FM_AUTOPILOT_BRAIN_ROOT:-${BRAIN_ROOT:-/Users/ryanfong/workspace/brain}}
SESSION=${FM_AUTOPILOT_SESSION:-fm-autopilot}

# state / data paths (state/ and data/ are gitignored, so these are all local)
ARMED_FLAG="$STATE/.autopilot-armed"
KILL_FLAG="$STATE/.autopilot-kill"
PREEMPT_FLAG="$STATE/.autopilot-preempt"
HEARTBEAT="$STATE/.autopilot-heartbeat"
OWNS_LOCK="$STATE/.autopilot-owns-lock"
FLEET_LOCK="$STATE/.lock"
BRAIN_CALLS="$STATE/.autopilot-brain-calls"
AP_DATA="$DATA/autopilot"
LOG_MD="$AP_DATA/log.md"
NEEDS_CAPTAIN_MD="$AP_DATA/needs-captain.md"
PROPOSALS_MD="$AP_DATA/proposals.md"

# Verb sets. Terminal = a crew that is finished or dead for capacity purposes.
# Done = ready-to-promote signals. Green = proof that a PR is safe to merge.
TERMINAL_RE='(^|[[:space:]])(done:|failed:|merged\b|PR ready|checks green|checks-passed|ready in branch)'
DONE_RE='(done:|PR ready|checks green|checks-passed|ready in branch|merged\b)'
BLOCKED_RE='(blocked:|failed:)'
GREEN_RE='(checks green|checks-passed|PR ready|ready in branch|CI green|checks passed)'
# Anything matching this in a backlog item's text is escalated, never
# autonomously dispatched: destructive, irreversible, or security-sensitive.
DANGER_RE='(--no-verify|--force|force[- ]push|rm -rf|DROP TABLE|delete .*(secret|key)|private key|credential|kill.?switch|LIVE_TRADING|autonomy.?tier|--hard\b)'

mkdir -p "$STATE" "$AP_DATA" 2>/dev/null || true

# --- small utilities --------------------------------------------------------
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

# Match the lock-generation identity used by fm-lock.sh.  A PID alone is not
# enough because macOS/Linux may reuse it between an autopilot tick and a
# dispatched harness startup.
process_identity() {
  local pid=${1:-} identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  identity=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || identity=""
  [ -n "$identity" ] || identity="pid:$pid"
  identity=$(printf '%s' "$identity" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

meta_get() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

last_status_line() {  # <status-file>
  [ -e "$1" ] || return 0
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

# receipt <action> <target> <proof-ref>: one compact line per mutating action.
receipt() {
  mkdir -p "$AP_DATA" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$1" "$2" "${3:-}" >> "$LOG_MD"
}

needs_captain() {  # <id> <reason> <detail>
  mkdir -p "$AP_DATA" 2>/dev/null || true
  printf '%s | %s | %s | %s\n' "$(now_iso)" "$1" "$2" "${3:-}" >> "$NEEDS_CAPTAIN_MD"
  receipt escalate "$1" "$2"
}

log_line() { printf '[autopilot %s] %s\n' "$(now_iso)" "$*"; }

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

# --- gates ------------------------------------------------------------------
is_armed()      { [ -f "$ARMED_FLAG" ]; }
kill_present()  { [ -e "$KILL_FLAG" ]; }
preempt_present() { [ -e "$PREEMPT_FLAG" ]; }

# lock_held_by_other: 0 if state/.lock is held by a LIVE process that is not
# autopilot's own recorded owner. A dead/stale pid or our own pid is not
# "another session". This is deliberately simpler than fm-lock.sh's harness-ps
# heuristic: autopilot stands by for ANY live non-self holder, and because
# autopilot's own pid is not a harness, a starting interactive fm-session-start
# still treats autopilot's lock as stale and preempts it (the human always wins).
lock_held_by_other() {
  [ -f "$FLEET_LOCK" ] || return 1
  local pid owner
  pid=$(cat "$FLEET_LOCK" 2>/dev/null || true)
  owner=$(cat "$OWNS_LOCK" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  [ "$pid" = "$owner" ] && return 1   # we hold it
  pid_alive "$pid"
}

# acquire_fleet_lock: claim the lock when it is free, stale, or already ours.
# Returns 1 (standby) when another live session holds it. Records our owner pid
# so lock_held_by_other and a preempting interactive session can both tell it
# is autopilot-owned.
acquire_fleet_lock() {
  lock_held_by_other && return 1
  printf '%s\n' "$$" > "$FLEET_LOCK"
  printf '%s\n' "$$" > "$OWNS_LOCK"
  return 0
}

release_fleet_lock() {
  local owner
  owner=$(cat "$OWNS_LOCK" 2>/dev/null || true)
  # Only remove the fleet lock if it is (still) ours; never yank another
  # session's lock.
  if [ -f "$FLEET_LOCK" ]; then
    local pid; pid=$(cat "$FLEET_LOCK" 2>/dev/null || true)
    [ "$pid" = "$owner" ] && rm -f "$FLEET_LOCK" 2>/dev/null || true
  fi
  rm -f "$OWNS_LOCK" 2>/dev/null || true
}

# --- account cycling (v1 simple) --------------------------------------------
# On a detected rate-limit string, rotate to the next configured profile dir and
# export CLAUDE_CONFIG_DIR / CODEX_HOME for subsequent calls. No-op when unset.
looks_rate_limited() {  # <text>
  printf '%s' "$1" | grep -qiE 'rate.?limit|usage limit|quota exceeded|too many requests|http 429|resets? at|overloaded'
}

rotate_profile() {  # <vendor: claude|codex>
  local vendor=$1 list var envname idxfile idx count next
  case "$vendor" in
    claude) list=${FM_AUTOPILOT_CLAUDE_PROFILES:-}; envname=CLAUDE_CONFIG_DIR ;;
    codex)  list=${FM_AUTOPILOT_CODEX_PROFILES:-};  envname=CODEX_HOME ;;
    *) return 1 ;;
  esac
  [ -n "$list" ] || return 1
  local IFS=:
  # shellcheck disable=SC2206  # deliberate split on ':'
  local profiles=($list)
  count=${#profiles[@]}
  [ "$count" -gt 0 ] || return 1
  idxfile="$STATE/.autopilot-profile-idx-$vendor"
  idx=$(cat "$idxfile" 2>/dev/null || echo -1)
  case "$idx" in ''|*[!0-9-]*) idx=-1 ;; esac
  next=$(( (idx + 1) % count ))
  printf '%s\n' "$next" > "$idxfile"
  var=${profiles[$next]}
  export "$envname=$var"
  receipt rotate-profile "$vendor" "$envname=$var"
  log_line "rotated $vendor profile -> $envname=$var"
  return 0
}

# run_with_rotation <vendor> <cmd...>: run a command, and if its combined output
# looks rate-limited AND a profile list is configured, rotate once and retry.
run_with_rotation() {
  local vendor=$1; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && looks_rate_limited "$out"; then
    if rotate_profile "$vendor"; then
      out=$("$@" 2>&1); rc=$?
    fi
  fi
  printf '%s' "$out"
  return "$rc"
}

# --- bounded LLM judgment ---------------------------------------------------
# brain_turn <prompt>: a bounded, rate-limited headless judgment turn. The
# harness is swappable via FM_AUTOPILOT_BRAIN / FM_AUTOPILOT_BRAIN_CMD so a test
# or a different harness can stand in. Returns non-zero (and emits nothing) when
# the hourly budget is exhausted, so callers degrade instead of spinning.
brain_budget_ok() {
  local nowe kept line count=0
  nowe=$(now_epoch)
  kept=""
  if [ -f "$BRAIN_CALLS" ]; then
    while IFS= read -r line; do
      case "$line" in ''|*[!0-9]*) continue ;; esac
      if [ $(( nowe - line )) -lt 3600 ]; then
        kept="$kept$line"$'\n'
        count=$((count + 1))
      fi
    done < "$BRAIN_CALLS"
  fi
  printf '%s' "$kept" > "$BRAIN_CALLS"
  [ "$count" -lt "$MAX_BRAIN_CALLS" ]
}

brain_turn() {  # <prompt>
  local prompt=$1 out rc
  if ! brain_budget_ok; then
    log_line "brain budget exhausted ($MAX_BRAIN_CALLS/hr); skipping judgment turn"
    return 1
  fi
  printf '%s\n' "$(now_epoch)" >> "$BRAIN_CALLS"
  if [ -n "${FM_AUTOPILOT_BRAIN_CMD:-}" ]; then
    out=$(run_with_rotation claude env FM_AUTOPILOT_PROMPT="$prompt" sh -c "$FM_AUTOPILOT_BRAIN_CMD"); rc=$?
  else
    out=$(run_with_rotation claude "$BRAIN" -p "$prompt" --max-turns 2); rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

# --- backlog parsing --------------------------------------------------------
# Emit one TSV row per top-level backlog item in the "## Queued" section:
#   <status>\t<key>\t<repo>\t<kind>\t<priority>\t<text>
# status is the checkbox char (' ' queued, '~' in flight). Continuation/indented
# note lines are ignored. A missing priority sorts last (9999).
parse_queued() {
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

count_queued() {  # count of '[ ]' items in Queued
  parse_queued | awk -F '\t' '$1==" "{n++} END{print n+0}'
}

# --- capacity ---------------------------------------------------------------
# count_active_crew: crewmates (kind ship/scout) whose last status is not a
# terminal verb. secondmates are persistent and excluded from the concurrency
# cap.
count_active_crew() {
  local meta id kind last n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    id=$(basename "$meta" .meta)
    last=$(last_status_line "$STATE/$id.status")
    if [ -n "$last" ] && printf '%s' "$last" | grep -qiE "$TERMINAL_RE"; then
      continue
    fi
    n=$((n + 1))
  done
  echo "$n"
}

task_in_flight() {  # <key>  -> 0 if a meta already exists for it
  [ -f "$STATE/$1.meta" ]
}

# --- dispatch ---------------------------------------------------------------
# resolve_dispatch_harness: an explicit harness satisfying fm-spawn's
# dispatch-profile backstop. Uses the crew-dispatch default profile when present
# (deterministic; richer per-task profile matching is a brain-delegated
# extension), else the static crew harness.
resolve_dispatch_harness() {
  local h=""
  if [ -f "$CONFIG/crew-dispatch.json" ] && command -v jq >/dev/null 2>&1; then
    h=$(jq -r '.default.harness // empty' "$CONFIG/crew-dispatch.json" 2>/dev/null || true)
  fi
  if [ -z "$h" ]; then
    h=$("$FM_ROOT/bin/fm-harness.sh" crew 2>/dev/null || true)
  fi
  [ -n "$h" ] || h=claude
  printf '%s' "$h"
}

ensure_brief() {  # <key> <text> <profile-json>
  local key=$1 text=$2 profile_json=${3:-'{}'}
  local brief="$DATA/$key/brief.md"
  [ -f "$brief" ] && return 0
  mkdir -p "$DATA/$key" 2>/dev/null || true
  {
    printf '# Autopilot dispatch: %s\n\n' "$key"
    printf 'You are a Firstmate crewmate dispatched autonomously by fm-autopilot.\n'
    printf 'Deliver the backlog item below through your project delivery mode. Run the\n'
    printf 'project proof gate, then report done with the exact proof and (for a PR\n'
    printf 'flow) the PR URL and CI-green status so the captain path can merge safely.\n\n'
    printf '## Execution profile selection\n\n```json\n%s\n```\n\n' "$profile_json"
    printf 'The selection is task-scoped metadata from Brain. It never widens the\n'
    printf 'outer authority; if the selected adapter cannot apply it, report that\n'
    printf 'as a blocker instead of fabricating a successful application.\n\n'
    printf '## Backlog item\n\n%s\n' "$text"
  } > "$brief"
}

# once_marker <tag> <key>: 0 (proceed) the first time this (tag,key) is seen,
# 1 (already handled) afterwards. Keeps a stuck backlog item from re-flooding
# receipts every tick; the marker is cleared naturally when the item leaves the
# queue and its state files are cleaned up.
once_marker() {  # <tag> <key>
  local f="$STATE/.autopilot-$1-$2"
  [ -f "$f" ] && return 1
  : > "$f"
  return 0
}

dispatch_item() {  # <key> <repo> <kind> <text>
  local key=$1 repo=$2 kind=$3 text=$4 proj harness out rc profile_json profile_id phase
  if [ -z "$repo" ]; then
    once_marker norepo "$key" && needs_captain "$key" "no-repo" "backlog item has no (repo: ...) - cannot dispatch autonomously"
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
  harness=$(resolve_dispatch_harness)
  phase=implement
  [ "$kind" = scout ] && phase=investigate
  if [ -x "$PROFILE_ROUTER" ] && command -v node >/dev/null 2>&1; then
    profile_json=$(BRAIN_ROOT="$PROFILE_BRAIN_ROOT" node "$PROFILE_ROUTER" "$key" "$repo" "$phase" "$harness" "$text" 2>/dev/null || printf '%s' '{"profileId":"plan","degraded":true,"reasonCodes":["profile-router-error"]}')
  else
    profile_json='{"profileId":"plan","degraded":true,"reasonCodes":["profile-router-missing"]}'
  fi
  profile_id=$(printf '%s' "$profile_json" | jq -r '.profileId // "plan"' 2>/dev/null || printf 'plan')
  printf '%s\n' "$profile_json" > "$STATE/$key.profile.json"
  receipt profile-route "$key" "profile=$profile_id"
  ensure_brief "$key" "$text" "$profile_json"
  local args=("$key" "$proj" --harness "$harness")
  [ "$kind" = scout ] && args+=(--scout)
  local owner_identity
  owner_identity=$(process_identity "$$" 2>/dev/null || printf 'pid:%s' "$$")
  out=$(FM_AUTOPILOT_LOCK_OWNER_PID="$$" \
    FM_AUTOPILOT_LOCK_OWNER_IDENTITY="$owner_identity" \
    run_with_rotation "$harness" "$SPAWN_CMD" "${args[@]}"
  ); rc=$?
  if [ "$rc" -eq 0 ]; then
    receipt dispatch "$key" "repo=$repo kind=${kind:-ship} harness=$harness"
    log_line "dispatched $key ($repo, ${kind:-ship}) on $harness"
    return 0
  fi
  needs_captain "$key" "dispatch-failed" "$(printf '%s' "$out" | tail -1)"
  return 1
}

# --- done / blocked handling ------------------------------------------------
# escalate_once <id> <status-line> <reason> <detail>: escalate to needs-captain,
# but at most once per distinct status line for this id. A stuck task therefore
# surfaces once, not on every tick; a genuinely new status re-surfaces.
escalate_once() {  # <id> <status> <reason> <detail>
  local id=$1 status=$2 reason=$3 detail=$4 marker sig prev
  marker="$STATE/.autopilot-escalated-$id"
  sig=$(printf '%s' "$status" | cksum | cut -d' ' -f1)
  prev=$(cat "$marker" 2>/dev/null || true)
  [ "$prev" = "$sig" ] && return 0
  printf '%s\n' "$sig" > "$marker"
  needs_captain "$id" "$reason" "$detail"
}

retry_count() {  # <id>
  local f="$STATE/.autopilot-retry-$1"
  local n; n=$(cat "$f" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}
bump_retry() {  # <id>
  local f="$STATE/.autopilot-retry-$1" n
  n=$(retry_count "$1"); n=$((n + 1))
  printf '%s\n' "$n" > "$f"
  echo "$n"
}

handle_done() {  # <id>
  local id=$1
  local meta="$STATE/$id.meta" mode yolo kind proj repo pr last
  [ -f "$meta" ] || return 0
  # Already merged by a prior tick: the crew status can still read done until
  # teardown, so guard against a double-merge attempt.
  [ -f "$STATE/.autopilot-merged-$id" ] && return 0
  kind=$(meta_get "$meta" kind)
  mode=$(meta_get "$meta" mode)
  yolo=$(meta_get "$meta" yolo)
  proj=$(meta_get "$meta" project)
  pr=$(meta_get "$meta" pr)
  repo=$(basename "${proj:-}")
  last=$(last_status_line "$STATE/$id.status")

  if is_excluded_project "$repo"; then
    receipt skip-merge "$id" "excluded project $repo - captain-only"
    return 0
  fi
  if [ "$kind" = scout ]; then
    escalate_once "$id" "$last" "scout-report-ready" "scout deliverable ready for captain review (data/$id/report.md)"
    return 0
  fi
  if [ "$yolo" != on ]; then
    escalate_once "$id" "$last" "done-needs-merge" "mode=$mode yolo=off; finished work awaiting captain merge"
    return 0
  fi

  # yolo=on: autopilot may drive the sanctioned merge path.
  case "$mode" in
    local-only)
      local out rc
      out=$(run_with_rotation claude "$MERGE_LOCAL_CMD" "$id" 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        : > "$STATE/.autopilot-merged-$id"
        receipt merge-local "$id" "$(printf '%s' "$out" | tail -1)"
      else
        escalate_once "$id" "$last" "merge-local-failed" "$(printf '%s' "$out" | tail -1)"
      fi
      ;;
    no-mistakes|direct-PR)
      if [ -z "$pr" ]; then
        escalate_once "$id" "$last" "no-pr-url" "mode=$mode done but no pr= recorded; cannot merge safely"
        return 0
      fi
      if [ "$mode" = no-mistakes ] && ! printf '%s' "$last" | grep -qiE "$GREEN_RE"; then
        escalate_once "$id" "$last" "no-green-proof" "mode=no-mistakes without a green proof marker in status; not merging"
        return 0
      fi
      local out rc
      out=$(run_with_rotation claude "$MERGE_PR_CMD" "$id" "$pr" 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        : > "$STATE/.autopilot-merged-$id"
        receipt merge-pr "$id" "$pr"
      else
        escalate_once "$id" "$last" "merge-pr-failed" "$(printf '%s' "$out" | tail -1)"
      fi
      ;;
    *)
      escalate_once "$id" "$last" "unknown-mode" "mode=${mode:-unset}; refusing to merge"
      ;;
  esac
}

handle_blocked() {  # <id> <last-status>
  local id=$1 last=$2 n
  # Dedupe on the status line: a stuck blocker escalates once, not every tick.
  # A distinct new blocker line re-surfaces and bumps the bounded retry counter.
  local marker="$STATE/.autopilot-escalated-$id" sig prev
  sig=$(printf '%s' "$last" | cksum | cut -d' ' -f1)
  prev=$(cat "$marker" 2>/dev/null || true)
  [ "$prev" = "$sig" ] && return 0
  printf '%s\n' "$sig" > "$marker"
  n=$(bump_retry "$id")
  if [ "$n" -gt "$MAX_RETRIES" ]; then
    needs_captain "$id" "blocked-hard" "exceeded FM_AUTOPILOT_MAX_RETRIES=$MAX_RETRIES: $last"
  else
    needs_captain "$id" "blocked" "$last"
  fi
}

# triage_crews: read each crew's current status and route done/blocked. Active
# crews are left alone. Excluded projects are never merged (handled in handle_done).
triage_crews() {
  local meta id kind last
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    id=$(basename "$meta" .meta)
    last=$(last_status_line "$STATE/$id.status")
    [ -n "$last" ] || continue
    if printf '%s' "$last" | grep -qiE "$BLOCKED_RE"; then
      handle_blocked "$id" "$last"
    elif printf '%s' "$last" | grep -qiE "$DONE_RE"; then
      handle_done "$id"
    fi
  done
}

# --- backlog refill ---------------------------------------------------------
# When the queue runs low, dispatch ONE scout briefed to propose the next
# highest-leverage items, writing to data/autopilot/proposals.md for a later
# tick to promote. Guarded so only one refill scout is ever in flight.
SCOUT_KEY_PREFIX="autopilot-scout"
refill_backlog() {
  local qn scout_id repo text existing
  qn=$(count_queued)
  [ "$qn" -lt "$MIN_QUEUE" ] || return 0
  # Only one refill scout in flight at a time.
  for existing in "$STATE/$SCOUT_KEY_PREFIX"-*.meta; do
    if [ -f "$existing" ]; then
      local eid elast
      eid=$(basename "$existing" .meta)
      elast=$(last_status_line "$STATE/$eid.status")
      if [ -z "$elast" ] || ! printf '%s' "$elast" | grep -qiE "$TERMINAL_RE"; then
        return 0  # a refill scout is still working
      fi
    fi
  done
  # Round-robin a non-excluded project from the registry for the scout to survey.
  repo=$(pick_refill_repo)
  [ -n "$repo" ] || { log_line "refill: no eligible project to survey"; return 0; }
  scout_id="$SCOUT_KEY_PREFIX-$repo-$(date +%H%M%S)"
  text=$(printf 'Scout: propose the next 3-5 highest-leverage backlog items for %s. Read the repo, its AGENTS.md, and open work. For each proposal write one backlog-ready line to %s in the standard format ("- [ ] <key> - <desc> (repo: %s) (kind: ship|scout) (priority: N)"). Read-only: no code changes.' \
    "$repo" "$PROPOSALS_MD" "$repo")
  # Write proposals target so the scout has the path; brief carries the rest.
  mkdir -p "$AP_DATA" 2>/dev/null || true
  dispatch_item "$scout_id" "$repo" scout "$text"
}

# pick_refill_repo: round-robin over registry projects, skipping excluded ones.
pick_refill_repo() {
  local reg="$DATA/projects.md" repos=() line name idxfile idx count
  [ -f "$reg" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        name=${line#- }; name=${name%% *}
        [ -n "$name" ] || continue
        is_excluded_project "$name" && continue
        repos+=("$name")
        ;;
    esac
  done < "$reg"
  count=${#repos[@]}
  [ "$count" -gt 0 ] || return 0
  idxfile="$STATE/.autopilot-refill-idx"
  idx=$(cat "$idxfile" 2>/dev/null || echo -1)
  case "$idx" in ''|*[!0-9-]*) idx=-1 ;; esac
  idx=$(( (idx + 1) % count ))
  printf '%s\n' "$idx" > "$idxfile"
  printf '%s' "${repos[$idx]}"
}

# promote_proposals: when a scout has written backlog-ready lines to
# proposals.md, use a bounded brain turn to decide which to promote into the
# backlog. v1 is conservative: it never edits data/backlog.md directly here
# (that is firstmate's queue); it records a needs-captain receipt pointing at the
# proposals so the captain (or a future armed promotion path) can adopt them.
promote_proposals() {
  [ -s "$PROPOSALS_MD" ] || return 0
  local n; n=$(grep -c '^- \[' "$PROPOSALS_MD" 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] || return 0
  # Marker so we only escalate a given proposals set once until it grows.
  local marker="$STATE/.autopilot-proposals-seen" seen
  seen=$(cat "$marker" 2>/dev/null || echo 0)
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
  [ "$n" -le "$seen" ] && return 0
  printf '%s\n' "$n" > "$marker"
  needs_captain "proposals" "backlog-refill" "$n proposed item(s) in data/autopilot/proposals.md await captain adoption"
}

# --- one tick ---------------------------------------------------------------
tick() {
  touch "$HEARTBEAT" 2>/dev/null || true

  # Preempt: release the lock immediately and stand by.
  if preempt_present; then
    release_fleet_lock
    log_line "standby: preempt requested (state/.autopilot-preempt present); released fleet lock"
    return 0
  fi
  # Disarmed: never mutate.
  if ! is_armed; then
    log_line "standby: DISARMED (no state/.autopilot-armed); run 'fm-autopilot.sh arm' to enable"
    return 0
  fi
  # Kill switch: never mutate.
  if kill_present; then
    log_line "standby: KILL SWITCH present (state/.autopilot-kill); no mutating action"
    return 0
  fi
  # Lock: only the session that holds the fleet lock mutates.
  if ! acquire_fleet_lock; then
    local holder; holder=$(cat "$FLEET_LOCK" 2>/dev/null || true)
    log_line "standby: fleet lock held by another live session (pid ${holder:-?})"
    return 0
  fi

  log_line "armed tick: holding fleet lock (pid $$)"

  # (a) Drain the durable wake queue (mutating): clears queued wakes and asserts
  # watcher liveness. Decisions below read current crew status directly, so a
  # drained record is never lost work - the status log it points at persists.
  "$FM_ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true

  # (b/c) Triage finished / blocked crews: merge green yolo work, escalate the rest.
  triage_crews

  # (d) Capacity-gated dispatch of the next queued items.
  local active free
  active=$(count_active_crew)
  free=$(( MAX_CONCURRENT - active ))
  if [ "$free" -gt 0 ]; then
    local row status key repo kind prio text
    # Priority order: lowest priority number first, then file order.
    while IFS=$'\t' read -r status key repo kind prio text; do
      [ "$free" -gt 0 ] || break
      [ "$status" = " " ] || continue
      [ -n "$key" ] || continue
      task_in_flight "$key" && continue
      if dispatch_item "$key" "$repo" "$kind" "$text"; then
        free=$((free - 1))
      fi
    done < <(parse_queued | sort -t"$(printf '\t')" -k5,5n -k2,2)
  else
    log_line "dispatch skipped: $active active >= cap $MAX_CONCURRENT"
  fi

  # (e) Backlog refill: keep the queue from draining to empty.
  refill_backlog

  # (f) Promote proposals via bounded judgment (conservative escalation in v1).
  promote_proposals

  return 0
}

# --- long-lived loop --------------------------------------------------------
loop() {
  printf '%s\n' "$$" > "$STATE/.autopilot.pid"
  trap 'release_fleet_lock; rm -f "$STATE/.autopilot.pid"; exit 0' TERM INT EXIT
  log_line "loop starting (pid $$, tick ${TICK_SECS}s)"
  while true; do
    tick || true
    sleep "$TICK_SECS"
  done
}

# --- subcommands ------------------------------------------------------------
cmd_start() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "error: tmux is required for 'start'; use 'once' in a loop, or run in a tmux-capable environment" >&2
    exit 1
  fi
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "autopilot already running in tmux session '$SESSION'"
    return 0
  fi
  tmux new-session -d -s "$SESSION" \
    "FM_HOME=$(printf %q "$FM_HOME") FM_ROOT_OVERRIDE=$(printf %q "$FM_ROOT") exec bash $(printf %q "$SELF") _loop"
  echo "autopilot started in tmux session '$SESSION' (tick ${TICK_SECS}s)"
  is_armed || echo "note: autopilot is DISARMED - run 'fm-autopilot.sh arm' to enable mutating actions"
}

cmd_stop() {
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    echo "autopilot tmux session '$SESSION' killed"
  else
    echo "no autopilot tmux session '$SESSION' running"
  fi
  release_fleet_lock
  rm -f "$STATE/.autopilot.pid" 2>/dev/null || true
}

cmd_status() {
  printf 'autopilot status @ %s\n' "$(now_iso)"
  if is_armed; then printf '  armed:      YES (%s)\n' "$(cat "$ARMED_FLAG" 2>/dev/null | head -1)"; else printf '  armed:      no (DISARMED)\n'; fi
  kill_present && printf '  kill:       PRESENT (mutating actions suspended)\n' || printf '  kill:       absent\n'
  preempt_present && printf '  preempt:    PRESENT (standby requested)\n' || printf '  preempt:    absent\n'
  if lock_held_by_other; then
    printf '  fleet lock: held by ANOTHER session (pid %s) - autopilot standby\n' "$(cat "$FLEET_LOCK" 2>/dev/null)"
  elif [ -f "$OWNS_LOCK" ] && [ "$(cat "$FLEET_LOCK" 2>/dev/null || true)" = "$(cat "$OWNS_LOCK" 2>/dev/null || true)" ]; then
    printf '  fleet lock: autopilot-owned (pid %s)\n' "$(cat "$OWNS_LOCK" 2>/dev/null)"
  else
    printf '  fleet lock: free/stale (available)\n'
  fi
  if [ -f "$HEARTBEAT" ]; then printf '  heartbeat:  %ss ago\n' "$(file_age "$HEARTBEAT")"; else printf '  heartbeat:  none yet\n'; fi
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
    printf '  loop:       running (tmux session %s)\n' "$SESSION"
  else
    printf '  loop:       not running\n'
  fi
  printf '  active crew: %s (cap %s)\n' "$(count_active_crew)" "$MAX_CONCURRENT"
  printf '  queued:     %s (refill < %s)\n' "$(count_queued)" "$MIN_QUEUE"
  if [ -f "$NEEDS_CAPTAIN_MD" ]; then printf '  needs-captain receipts: %s\n' "$(grep -c '|' "$NEEDS_CAPTAIN_MD" 2>/dev/null || echo 0)"; fi
}

cmd_arm() {
  local note=${1:-armed by operator}
  { printf '%s\n' "$note"; printf 'armed-at: %s\n' "$(now_iso)"; } > "$ARMED_FLAG"
  receipt arm "-" "$note"
  echo "autopilot ARMED: $note"
  kill_present && echo "warning: kill switch (state/.autopilot-kill) is present; remove it to allow mutating actions"
}

cmd_disarm() {
  rm -f "$ARMED_FLAG" 2>/dev/null || true
  receipt disarm "-" ""
  echo "autopilot DISARMED (state/.autopilot-armed removed)"
}

cmd_once() {
  tick
  # A one-shot pass releases the lock so it never strands a dead pid marker.
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
      sed -n '2,60p' "$SELF" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "usage: fm-autopilot.sh { start | stop | status | once | arm [note] | disarm }" >&2
      exit 2
      ;;
  esac
}

main "$@"
