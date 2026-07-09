#!/usr/bin/env bash
# tests/autopilot-test.sh - behavior tests for bin/fm-autopilot.sh, the headless
# captain loop. Every test runs against a throwaway FM_HOME fixture (state/,
# data/, config/, projects/) and stubs the dispatch/merge commands via the
# FM_AUTOPILOT_*_CMD env knobs, so NO live fleet state is ever touched and no
# real crewmate is ever launched.
#
# Coverage:
#   - disarmed `once`: a standby receipt, zero mutations (no lock, no dispatch,
#     heartbeat still touched)
#   - armed `once` with the lock free: capacity-gated dispatch via a stub spawn,
#     priority ordering, excluded-project hard skip, destructive-item escalation
#   - kill switch: armed but state/.autopilot-kill present -> standby
#   - lock held by another live session -> standby, no mutation
#   - dispatch startup: a child harness retains the autopilot loop PID as the
#     fleet-lock owner before, during, and after the child runs fm-lock.sh
#   - yolo=on green done -> sanctioned merge via a stub merge command, with a
#     merged marker that prevents a double merge on the next tick
#   - yolo=off done -> needs-captain escalation, never merged
#   - capacity cap: no dispatch when active crew >= FM_AUTOPILOT_MAX_CONCURRENT
#   - arm / disarm subcommands
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AP="$ROOT/bin/fm-autopilot.sh"
TMP_ROOT=$(fm_test_tmproot fm-autopilot-tests)
fm_git_identity fmtest fmtest@example.invalid

# Disable backlog refill by default so a tick never reaches the real fm-spawn.sh
# through the refill scout. The dedicated refill test re-enables it with a stub
# spawn, so refill is still exercised - just never against a live spawn.
export FM_AUTOPILOT_MIN_QUEUE=0

# --- world builder ----------------------------------------------------------
# new_home <name>: a throwaway FM_HOME with state/, data/, config/, projects/,
# a demo clone, and a crew-harness pin (so harness resolution needs no ps walk).
# Echoes the home dir.
new_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/demo"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' '# Projects' '- demo [no-mistakes] - a demo (added 2026-07-09)' > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# stub_spawn <home>: a fake dispatch command that records a meta + status for the
# key so capacity counting and in-flight dedup behave like a real spawn, without
# launching anything. Echoes the command path (set as FM_AUTOPILOT_SPAWN_CMD).
stub_spawn() {
  local home=$1
  local cmd="$home/stub-spawn.sh"
  cat > "$cmd" <<'SH'
#!/usr/bin/env bash
key=$1; proj=$2
state="$FM_HOME/state"
mkdir -p "$state"
printf 'window=fm:%s\nkind=ship\nproject=%s\nmode=no-mistakes\nyolo=off\n' "$key" "$proj" > "$state/$key.meta"
printf 'working: dispatched\n' > "$state/$key.status"
echo "spawned $key"
SH
  chmod +x "$cmd"
  printf '%s\n' "$cmd"
}

# stub_dispatch_lock_probe <home>: a dispatch-shaped child that runs the real
# fm-lock.sh as a starting Codex harness would. The fake ps reports the lock
# script itself as Codex while leaving its live Bash autopilot ancestor as a
# non-harness process. This reproduces the ownership-attribution boundary
# without launching a real agent or touching live fleet state.
stub_dispatch_lock_probe() {
  local home=$1
  local fakebin="$home/fakebin"
  local cmd="$home/stub-dispatch-lock-probe.sh"
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
requested=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then
    requested=$argument
    break
  fi
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$requested" = "${FM_TEST_HARNESS_PID:-}" ]; then
      printf '%s\n' '/usr/local/bin/codex'
    else
      printf '%s\n' 'bash'
    fi
    ;;
  *"args="*)
    if [ "$requested" = "${FM_TEST_HARNESS_PID:-}" ]; then
      printf '%s\n' 'codex'
    else
      printf '%s\n' 'bash fm-autopilot.sh _loop'
    fi
    ;;
  *"ppid="*) printf '%s\n' '1' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$cmd" <<'SH'
#!/usr/bin/env bash
set -eu
key=$1
proj=$2
state="$FM_HOME/state"
trace="$FM_HOME/dispatch-lock-trace.txt"
owner=$(cat "$state/.autopilot-owns-lock")
before=$(cat "$state/.lock")
printf 'owner=%s\nbefore=%s\n' "$owner" "$before" > "$trace"
PATH="$FM_HOME/fakebin:$PATH" bash -c '
  export FM_TEST_HARNESS_PID=$BASHPID
  exec bash "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"
' > "$FM_HOME/dispatch-lock-output.txt" 2>&1
during=$(cat "$state/.lock")
printf 'during=%s\n' "$during" >> "$trace"
printf 'window=fm:%s\nkind=ship\nproject=%s\nmode=no-mistakes\nyolo=off\n' "$key" "$proj" > "$state/$key.meta"
printf 'working: dispatch startup complete\n' > "$state/$key.status"
after=$(cat "$state/.lock")
printf 'after=%s\n' "$after" >> "$trace"
printf 'spawned %s\n' "$key"
SH
  chmod +x "$cmd"
  printf '%s\n' "$cmd"
}

# stub_merge <home> <name>: a fake merge command that records the call to a
# sidecar file so a test can assert it ran. Echoes the command path.
stub_merge() {
  local home=$1 name=$2
  local cmd="$home/stub-$name.sh"
  cat > "$cmd" <<SH
#!/usr/bin/env bash
echo "\$1 \$2" >> "$home/$name-calls.txt"
echo "merged \$1"
SH
  chmod +x "$cmd"
  printf '%s\n' "$cmd"
}

run_once() {  # <home> [extra env assignments already exported by caller]
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" once 2>&1
}

log_of()  { cat "$1/data/autopilot/log.md" 2>/dev/null || true; }
needs_of() { cat "$1/data/autopilot/needs-captain.md" 2>/dev/null || true; }

# --- disarmed once: standby, zero mutation ----------------------------------
test_disarmed_once_is_inert() {
  local home; home=$(new_home disarmed)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] fix-a - do a thing (repo: demo) (kind: ship) (priority: 1)' > "$home/data/backlog.md"

  local out; out=$(run_once "$home")
  assert_contains "$out" "standby: DISARMED" "disarmed once did not report DISARMED standby"
  assert_present "$home/state/.autopilot-heartbeat" "heartbeat was not touched on a disarmed tick"
  assert_absent "$home/state/.lock" "disarmed once acquired the fleet lock (must not mutate)"
  assert_absent "$home/state/fix-a.meta" "disarmed once dispatched a task (must not mutate)"
  [ ! -s "$home/data/autopilot/log.md" ] || fail "disarmed once wrote a mutating receipt: $(log_of "$home")"

  pass "a disarmed once tick stands by: heartbeat only, no lock, no dispatch, no receipt"
}

# --- armed once: dispatch, priority, exclusion, danger ----------------------
test_armed_once_dispatches_with_guards() {
  local home spawn out
  home=$(new_home armed)
  spawn=$(stub_spawn "$home")
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] fix-a - do a thing (repo: demo) (kind: ship) (priority: 2)' \
    '- [ ] scout-b - investigate (repo: demo) (kind: scout) (priority: 1)' \
    '- [ ] danger-d - please rm -rf everything (repo: demo) (kind: ship) (priority: 3)' \
    '- [ ] money-e - trade (repo: armalo-fi) (kind: ship) (priority: 1)' \
    '- [~] busy-c - already in flight (repo: demo) (kind: ship)' > "$home/data/backlog.md"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once 2>&1)

  # Both eligible items dispatched; excluded + danger not.
  assert_present "$home/state/fix-a.meta" "armed once did not dispatch fix-a"
  assert_present "$home/state/scout-b.meta" "armed once did not dispatch scout-b"
  assert_absent "$home/state/money-e.meta" "armed once dispatched an excluded-project item"
  assert_absent "$home/state/danger-d.meta" "armed once dispatched a destructive item"

  local log; log=$(log_of "$home")
  assert_contains "$log" "dispatch	fix-a" "no dispatch receipt for fix-a"
  assert_contains "$log" "dispatch	scout-b" "no dispatch receipt for scout-b"
  assert_contains "$log" "skip-dispatch	money-e" "no hard-exclusion receipt for money-e"
  assert_contains "$(needs_of "$home")" "danger-d | destructive/security-sensitive" "danger item not escalated to captain"

  # Priority ordering: scout-b (priority 1) dispatched before fix-a (priority 2).
  local sb fa
  sb=$(printf '%s\n' "$log" | grep -n 'dispatch	scout-b' | head -1 | cut -d: -f1)
  fa=$(printf '%s\n' "$log" | grep -n 'dispatch	fix-a' | head -1 | cut -d: -f1)
  [ -n "$sb" ] && [ -n "$fa" ] && [ "$sb" -lt "$fa" ] || fail "priority ordering wrong: scout-b(line $sb) not before fix-a(line $fa)"

  pass "an armed once tick dispatches queued items by priority, hard-skips excluded projects, and escalates destructive items"
}

# --- kill switch ------------------------------------------------------------
test_kill_switch_suspends() {
  local home spawn out
  home=$(new_home kill)
  spawn=$(stub_spawn "$home")
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] fix-a - do a thing (repo: demo) (kind: ship) (priority: 1)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null
  : > "$home/state/.autopilot-kill"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once 2>&1)
  assert_contains "$out" "KILL SWITCH present" "kill switch did not force standby"
  assert_absent "$home/state/fix-a.meta" "kill switch did not prevent dispatch"
  assert_absent "$home/state/.lock" "kill switch tick acquired the fleet lock"

  pass "an armed tick with the kill switch present suspends all mutating actions"
}

# --- lock held by another session -------------------------------------------
test_lock_held_standby() {
  local home spawn out holder
  home=$(new_home lockheld)
  spawn=$(stub_spawn "$home")
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] fix-a - do a thing (repo: demo) (kind: ship) (priority: 1)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null

  # A live process (not autopilot) holds the fleet lock.
  sleep 30 & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once 2>&1)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_contains "$out" "held by another live session" "lock-held tick did not stand by"
  assert_absent "$home/state/fix-a.meta" "lock-held tick dispatched work"
  assert_present "$home/state/.autopilot-heartbeat" "lock-held tick did not touch the heartbeat"
  # The other session's lock file is untouched.
  assert_grep "$holder" "$home/state/.lock" "autopilot overwrote another session's fleet lock"

  pass "when another live session holds the fleet lock, autopilot stands by and never overwrites it"
}

# --- dispatched child retains the autopilot loop's lock ownership ------------
test_dispatch_child_retains_autopilot_owner() {
  local home spawn out trace owner
  home=$(new_home dispatch-lock-owner)
  spawn=$(stub_dispatch_lock_probe "$home")
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] child-a - exercise dispatch startup (repo: demo) (kind: ship) (priority: 1)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once 2>&1)
  trace=$(cat "$home/dispatch-lock-trace.txt")
  owner=$(printf '%s\n' "$trace" | sed -n 's/^owner=//p')
  case "$owner" in ''|*[!0-9]*) fail "dispatch probe did not capture a numeric autopilot owner: $trace" ;; esac
  assert_contains "$trace" "before=$owner" "fleet lock was not owned by the autopilot loop before dispatch startup"
  assert_contains "$trace" "during=$owner" "dispatched child reattributed the fleet lock while fm-lock.sh started"
  assert_contains "$trace" "after=$owner" "fleet lock owner changed after dispatch startup"
  assert_contains "$out" "dispatched child-a" "dispatch-shaped lock probe did not complete through autopilot"

  pass "a dispatched harness keeps the autopilot loop PID as lock owner before, during, and after startup"
}

# --- yolo=on green done -> merge, and no double merge ------------------------
test_yolo_on_merges_green_done_once() {
  local home merge_pr out
  home=$(new_home yolo-on)
  merge_pr=$(stub_merge "$home" merge-pr)
  printf '%s\n' '# Backlog' '## Queued' > "$home/data/backlog.md"
  # A finished crew: done + green + recorded PR, yolo on.
  printf 'window=fm:ship-x\nkind=ship\nproject=%s\nmode=no-mistakes\nyolo=on\npr=https://github.com/o/r/pull/7\n' \
    "$home/projects/demo" > "$home/state/ship-x.meta"
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$home/state/ship-x.status"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_MERGE_PR_CMD="$merge_pr" bash "$AP" once 2>&1)
  assert_grep "ship-x https://github.com/o/r/pull/7" "$home/merge-pr-calls.txt" "green yolo=on done was not merged via the merge command"
  assert_contains "$(log_of "$home")" "merge-pr	ship-x" "no merge-pr receipt recorded"
  assert_present "$home/state/.autopilot-merged-ship-x" "merged marker not written"

  # Second tick: the status still reads done, but the merged marker must prevent
  # a second merge call.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_MERGE_PR_CMD="$merge_pr" bash "$AP" once >/dev/null 2>&1
  local calls; calls=$(grep -c . "$home/merge-pr-calls.txt" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "merge command was called $calls times; the merged marker did not prevent a double merge"

  pass "a green yolo=on done task is merged through the sanctioned command exactly once"
}

# --- yolo=off done -> escalate, never merge ---------------------------------
test_yolo_off_done_escalates() {
  local home merge_pr out
  home=$(new_home yolo-off)
  merge_pr=$(stub_merge "$home" merge-pr)
  printf '%s\n' '# Backlog' '## Queued' > "$home/data/backlog.md"
  printf 'window=fm:ship-y\nkind=ship\nproject=%s\nmode=no-mistakes\nyolo=off\npr=https://github.com/o/r/pull/9\n' \
    "$home/projects/demo" > "$home/state/ship-y.meta"
  printf 'done: PR https://github.com/o/r/pull/9 checks green\n' > "$home/state/ship-y.status"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_MERGE_PR_CMD="$merge_pr" bash "$AP" once 2>&1)
  assert_absent "$home/merge-pr-calls.txt" "a yolo=off task was merged (must escalate instead)"
  assert_contains "$(needs_of "$home")" "ship-y | done-needs-merge" "yolo=off done was not escalated to the captain"

  pass "a yolo=off finished task is escalated for captain merge, never merged autonomously"
}

# --- capacity cap -----------------------------------------------------------
test_capacity_cap_blocks_dispatch() {
  local home spawn out i
  home=$(new_home capacity)
  spawn=$(stub_spawn "$home")
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] fix-new - do a thing (repo: demo) (kind: ship) (priority: 1)' > "$home/data/backlog.md"
  # Three active (non-terminal) crews already at the default cap of 3.
  for i in 1 2 3; do
    printf 'window=fm:busy%s\nkind=ship\nproject=%s\nmode=no-mistakes\nyolo=off\n' "$i" "$home/projects/demo" > "$home/state/busy$i.meta"
    printf 'working: mid-task\n' > "$home/state/busy$i.status"
  done
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once 2>&1)
  assert_contains "$out" "dispatch skipped" "capacity cap did not block dispatch"
  assert_absent "$home/state/fix-new.meta" "dispatch happened despite being at the concurrency cap"

  pass "dispatch is blocked when active crew count is at the concurrency cap"
}

# --- arm / disarm -----------------------------------------------------------
test_arm_disarm() {
  local home
  home=$(new_home arm-disarm)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "captain note here" >/dev/null
  assert_present "$home/state/.autopilot-armed" "arm did not write the armed flag"
  assert_grep "captain note here" "$home/state/.autopilot-armed" "arm did not record the captain note"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" disarm >/dev/null
  assert_absent "$home/state/.autopilot-armed" "disarm did not remove the armed flag"

  pass "arm writes the armed flag with the captain note; disarm removes it"
}

# --- backlog refill dispatches one scout when the queue is low ---------------
test_refill_dispatches_scout() {
  local home spawn
  home=$(new_home refill)
  spawn=$(stub_spawn "$home")
  # Empty queue, refill threshold high: refill should fire exactly one scout.
  printf '%s\n' '# Backlog' '## Queued' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$AP" arm "test" >/dev/null

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_MIN_QUEUE=5 \
    FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once >/dev/null 2>&1

  local scouts
  scouts=$(ls "$home"/state/autopilot-scout-*.meta 2>/dev/null | wc -l | tr -d ' ')
  [ "$scouts" -eq 1 ] || fail "refill dispatched $scouts scouts (expected exactly 1)"
  assert_contains "$(log_of "$home")" "dispatch	autopilot-scout" "no refill scout dispatch receipt"

  # A second tick while the scout is still in flight must NOT dispatch another.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOPILOT_MIN_QUEUE=5 \
    FM_AUTOPILOT_SPAWN_CMD="$spawn" bash "$AP" once >/dev/null 2>&1
  scouts=$(ls "$home"/state/autopilot-scout-*.meta 2>/dev/null | wc -l | tr -d ' ')
  [ "$scouts" -eq 1 ] || fail "refill dispatched a second scout while one was in flight ($scouts total)"

  pass "backlog refill dispatches exactly one scout when the queue is low, and not a second while it is in flight"
}

test_disarmed_once_is_inert
test_armed_once_dispatches_with_guards
test_refill_dispatches_scout
test_kill_switch_suspends
test_lock_held_standby
test_dispatch_child_retains_autopilot_owner
test_yolo_on_merges_green_done_once
test_yolo_off_done_escalates
test_capacity_cap_blocks_dispatch
test_arm_disarm
