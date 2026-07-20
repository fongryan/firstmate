#!/usr/bin/env bash
# tests/fm-ocpool.test.sh - behavior tests for bin/fm-ocpool.sh, the headless
# opencode worker-pool loop. Every test runs against a throwaway FM_HOME
# fixture (state/, data/, config/, projects/) and stubs the dispatch bridge via
# FM_OCPOOL_DISPATCH_BIN, so no real opencode is ever launched and no live
# fleet state is ever touched. No launchctl is invoked (start/stop/the
# installer are not exercised here).
#
# Coverage:
#   - disarmed `once`: standby, zero mutation
#   - armed `once`: dispatches only (pool: opencode)-marked items, by
#     priority, claiming them in place ("- [ ] " -> "- [~] ") without touching
#     a non-pool-marked item
#   - kill switch: armed but state/.ocpool-kill present -> standby
#   - lock held by another live session -> standby, never overwrites it
#   - capacity math: dispatch is blocked when active pool tasks (read from
#     fm-lifecycle state) are at FM_OCPOOL_MAX_CONCURRENT
#   - verified (exit 0) -> lifecycle closeout(completed) + backlog item moved
#     to Done (hand-edit fallback, and separately via a compatible tasks-axi
#     stub)
#   - blocked (exit 2) -> item returns to queued, no attempt consumed
#   - failed (exit 3) -> requeues once with a handoff note, then escalates to
#     needs-captain on the second failure
#   - once_marker prevents a duplicate dispatch of the same attempt
#   - `status` output shape
#   - `arm` / `disarm`
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OCPOOL="$ROOT/bin/fm-ocpool.sh"
TMP_ROOT=$(fm_test_tmproot fm-ocpool-tests)
fm_git_identity fmtest fmtest@example.invalid

# --- world builder ----------------------------------------------------------
# new_home <name>: a throwaway FM_HOME with state/, data/, config/, projects/,
# a demo clone, and config/backlog-backend=manual so the hand-edit Done mover
# is exercised deterministically (a dedicated test opts back into the
# tasks-axi path with a fakebin stub). Echoes the home dir.
new_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/demo" "$home/stub-plan"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' "$home"
}

# stub_dispatch <home> <name>: a fake bridge that reads its planned exit code
# for --task-id <key> from <home>/stub-plan/<key>.rc (default 0), prints a
# one-line JSON-shaped receipt, and exits with that code. Echoes the path.
stub_dispatch() {
  local home=$1 name=$2
  local cmd="$home/$name.sh"
  cat > "$cmd" <<'SH'
#!/usr/bin/env bash
key=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id) key=$2; shift 2 ;;
    *) shift ;;
  esac
done
plan="$FM_HOME/stub-plan/$key.rc"
code=0
[ -f "$plan" ] && code=$(cat "$plan")
printf '{"status":"stub","taskId":"%s","exit":%s}\n' "$key" "${code:-0}"
exit "${code:-0}"
SH
  chmod +x "$cmd"
  printf '%s\n' "$cmd"
}

# fake_tasks_axi <home>: a fakebin tasks-axi reporting a compatible version
# and recording every `done <id> ...` call to a sidecar file, for the one test
# that exercises the tasks-axi-available path instead of the hand-edit
# fallback. Echoes the fakebin dir (prepend to PATH).
fake_tasks_axi() {
  local home=$1
  local fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "tasks-axi 0.2.2"; exit 0 ;;
  update) [ "${2:-}" = "--help" ] && { echo "flags: --archive-body"; exit 0; }; exit 1 ;;
  mv) [ "${2:-}" = "--help" ] && { echo "usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>"; exit 0; }; exit 1 ;;
  done)
    shift
    id=${1:-}; shift || true
    printf '%s %s\n' "$id" "$*" >> "$FM_HOME/tasks-axi-done-calls.txt"
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

run_once() {  # <home> <dispatch-bin>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_OCPOOL_DISPATCH_BIN="$2" bash "$OCPOOL" once 2>&1
}

# wait_for_exit_marker <home> <key> [tries]: poll for the background stub's
# completion marker so a follow-up `once` tick actually has something to
# triage. Bounded so a broken stub fails the test instead of hanging it.
wait_for_exit_marker() {
  local home=$1 key=$2 tries=${3:-60} i
  for ((i = 0; i < tries; i++)); do
    [ -f "$home/state/.ocpool-exit-$key" ] && return 0
    sleep 0.05
  done
  return 1
}

log_of()   { cat "$1/data/ocpool/log.md" 2>/dev/null || true; }
needs_of() { cat "$1/data/ocpool/needs-captain.md" 2>/dev/null || true; }

# --- disarmed once: standby, zero mutation ----------------------------------
test_disarmed_once_is_inert() {
  local home dispatch out
  home=$(new_home disarmed)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"

  out=$(run_once "$home" "$dispatch")
  assert_contains "$out" "standby: DISARMED" "disarmed once did not report DISARMED standby"
  assert_present "$home/state/.ocpool-heartbeat" "heartbeat was not touched on a disarmed tick"
  assert_absent "$home/state/.lock" "disarmed once acquired the fleet lock (must not mutate)"
  assert_absent "$home/state/.ocpool-attempt-pool-a" "disarmed once dispatched a task (must not mutate)"
  [ ! -s "$home/data/ocpool/log.md" ] || fail "disarmed once wrote a mutating receipt: $(log_of "$home")"

  pass "a disarmed once tick stands by: heartbeat only, no lock, no dispatch, no receipt"
}

# --- armed once: pool-marker filter + priority + claim-in-place -------------
test_armed_once_dispatches_pool_items_only() {
  local home dispatch log la lb
  home=$(new_home armed)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-b - second (repo: demo) (kind: ship) (priority: 2) (pool: opencode)' \
    '- [ ] pool-a - first (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' \
    '- [ ] normal-c - not a pool item (repo: demo) (kind: ship) (priority: 0)' \
    > "$home/data/backlog.md"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null
  run_once "$home" "$dispatch" >/dev/null

  assert_present "$home/state/.ocpool-attempt-pool-a" "armed once did not dispatch pool-a"
  assert_present "$home/state/.ocpool-attempt-pool-b" "armed once did not dispatch pool-b"
  assert_absent "$home/state/.ocpool-attempt-normal-c" "armed once dispatched a non-pool-marked item"
  assert_grep '- [~] pool-a' "$home/data/backlog.md" "pool-a was not claimed (checkbox flipped to [~])"
  assert_grep '- [~] pool-b' "$home/data/backlog.md" "pool-b was not claimed (checkbox flipped to [~])"
  assert_grep '- [ ] normal-c' "$home/data/backlog.md" "a non-pool item was mutated"

  log=$(log_of "$home")
  assert_contains "$log" "dispatch	pool-a" "no dispatch receipt for pool-a"
  assert_contains "$log" "dispatch	pool-b" "no dispatch receipt for pool-b"

  la=$(printf '%s\n' "$log" | grep -n 'dispatch	pool-a' | head -1 | cut -d: -f1)
  lb=$(printf '%s\n' "$log" | grep -n 'dispatch	pool-b' | head -1 | cut -d: -f1)
  [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ] || fail "priority ordering wrong: pool-a(line $la) not before pool-b(line $lb)"

  wait_for_exit_marker "$home" pool-a || true
  wait_for_exit_marker "$home" pool-b || true

  pass "an armed once tick dispatches only (pool: opencode) items, by priority, claiming them in place"
}

# --- kill switch --------------------------------------------------------
test_kill_switch_suspends() {
  local home dispatch out
  home=$(new_home kill)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null
  : > "$home/state/.ocpool-kill"

  out=$(run_once "$home" "$dispatch")
  assert_contains "$out" "KILL SWITCH present" "kill switch did not force standby"
  assert_absent "$home/state/.ocpool-attempt-pool-a" "kill switch did not prevent dispatch"
  assert_absent "$home/state/.lock" "kill switch tick acquired the fleet lock"

  pass "an armed tick with the kill switch present suspends all mutating actions"
}

# --- lock held by another session -------------------------------------------
test_lock_held_standby() {
  local home dispatch out holder
  home=$(new_home lockheld)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  sleep 30 & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(run_once "$home" "$dispatch")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_contains "$out" "held by another live session" "lock-held tick did not stand by"
  assert_absent "$home/state/.ocpool-attempt-pool-a" "lock-held tick dispatched work"
  assert_present "$home/state/.ocpool-heartbeat" "lock-held tick did not touch the heartbeat"
  assert_grep "$holder" "$home/state/.lock" "ocpool overwrote another session's fleet lock"

  pass "when another live session holds the fleet lock, ocpool stands by and never overwrites it"
}

# --- capacity math holds -----------------------------------------------
test_capacity_cap_blocks_dispatch() {
  local home dispatch out
  home=$(new_home capacity)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-new - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  # One already-active pool task, tracked the same way a real dispatch would:
  # an attempt marker pointing at a lifecycle ledger row with state=active.
  printf 'busy-a1\n' > "$home/state/.ocpool-attempt-busy"
  printf 'state=active\n' > "$home/state/busy-a1.lifecycle"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OCPOOL_DISPATCH_BIN="$dispatch" FM_OCPOOL_MAX_CONCURRENT=1 bash "$OCPOOL" once 2>&1)

  assert_contains "$out" "dispatch skipped" "capacity cap did not block dispatch"
  assert_absent "$home/state/.ocpool-attempt-pool-new" "dispatch happened despite being at the concurrency cap"

  pass "dispatch is blocked when active pool tasks (read from fm-lifecycle state) are at the concurrency cap"
}

# --- verified -> done (hand-edit fallback) ----------------------------------
test_verified_moves_to_done() {
  local home dispatch out
  home=$(new_home verified)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-v - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  printf '0\n' > "$home/stub-plan/pool-v.rc"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  wait_for_exit_marker "$home" pool-v || fail "stub dispatch for pool-v never finished"

  out=$(run_once "$home" "$dispatch")
  assert_grep '- [x] pool-v' "$home/data/backlog.md" "pool-v was not moved to Done"
  assert_grep '## Done' "$home/data/backlog.md" "no Done section was created"
  assert_contains "$(log_of "$home")" "done	pool-v" "no done receipt for pool-v"
  assert_absent "$home/state/.ocpool-attempt-pool-v" "attempt marker was not cleared after closeout"

  local lc; lc=$(grep '^state=' "$home/state/pool-v-a1.lifecycle" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ "$lc" = completed ] || fail "lifecycle state for pool-v-a1 was not completed: ${lc:-<missing>}"

  pass "a verified (exit 0) attempt closes out the lifecycle and moves the backlog item to Done"
}

# --- verified -> done via a compatible tasks-axi --------------------------
test_verified_uses_tasks_axi_when_available() {
  local home dispatch fakebin out
  home=$(new_home taskaxi)
  rm -f "$home/config/backlog-backend"  # absent = default tasks-axi backend
  dispatch=$(stub_dispatch "$home" stub)
  fakebin=$(fake_tasks_axi "$home")
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-t - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  printf '0\n' > "$home/stub-plan/pool-t.rc"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  PATH="$fakebin:$PATH" run_once "$home" "$dispatch" >/dev/null
  wait_for_exit_marker "$home" pool-t || fail "stub dispatch for pool-t never finished"

  out=$(PATH="$fakebin:$PATH" run_once "$home" "$dispatch")
  assert_present "$home/tasks-axi-done-calls.txt" "ocpool did not call the compatible tasks-axi for the done transition"
  assert_grep "pool-t" "$home/tasks-axi-done-calls.txt" "tasks-axi done was not called with pool-t"

  pass "a verified attempt calls tasks-axi done when the backend is available and compatible"
}

# --- blocked -> stays queued, no attempt burn -------------------------------
test_blocked_returns_to_queued_without_attempt_burn() {
  local home dispatch
  home=$(new_home blocked)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-blk - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  printf '2\n' > "$home/stub-plan/pool-blk.rc"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  wait_for_exit_marker "$home" pool-blk || fail "stub dispatch for pool-blk never finished"

  run_once "$home" "$dispatch" >/dev/null
  assert_grep '- [ ] pool-blk' "$home/data/backlog.md" "pool-blk was not returned to queued"
  assert_no_grep '- [x] pool-blk' "$home/data/backlog.md" "pool-blk was incorrectly marked done"
  assert_absent "$home/state/.ocpool-retry-pool-blk" "a blocked attempt incorrectly consumed a retry"
  assert_contains "$(log_of "$home")" "blocked	pool-blk" "no blocked receipt for pool-blk"

  pass "a blocked (exit 2) attempt returns the item to queued without consuming an attempt"
}

# --- failed -> requeue once -> needs-captain --------------------------------
test_failed_requeues_once_then_needs_captain() {
  local home dispatch
  home=$(new_home failed)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-f - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  printf '3\n' > "$home/stub-plan/pool-f.rc"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  # Attempt 1: dispatch, fail.
  run_once "$home" "$dispatch" >/dev/null
  wait_for_exit_marker "$home" pool-f || fail "attempt 1 never finished"

  # Triage attempt 1 (requeue). The same tick's dispatch phase immediately
  # re-picks the now-unclaimed item as attempt 2, since capacity freed up.
  run_once "$home" "$dispatch" >/dev/null
  assert_contains "$(log_of "$home")" "requeue	pool-f" "no requeue receipt after attempt 1 failure"
  assert_grep '## Handoff note' "$home/data/pool-f/brief.md" "no handoff note appended after attempt 1 failure"
  assert_grep '1' "$home/state/.ocpool-retry-pool-f" "retry counter did not record 1 failed attempt"

  wait_for_exit_marker "$home" pool-f || fail "attempt 2 never finished"

  # Triage attempt 2 (exhausted) -> needs-captain.
  run_once "$home" "$dispatch" >/dev/null
  assert_contains "$(needs_of "$home")" "pool-f | failed-exhausted" "attempt exhaustion was not escalated to needs-captain"
  assert_grep '2' "$home/state/.ocpool-retry-pool-f" "retry counter did not reach 2 after the second failure"

  pass "a failed (exit 3) attempt requeues once with a handoff note, then escalates to needs-captain after the second failure"
}

# --- once_marker prevents double dispatch -----------------------------------
test_once_marker_prevents_double_dispatch() {
  local home dispatch
  home=$(new_home marker)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-m - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  # Pre-set the once_marker for this key's first attempt, as if it had already
  # fired this tick; the item itself is still unclaimed in the backlog.
  : > "$home/state/.ocpool-dispatch-pool-m-a1"

  run_once "$home" "$dispatch" >/dev/null
  assert_absent "$home/state/.ocpool-attempt-pool-m" "once_marker did not prevent a duplicate dispatch of the same attempt"
  assert_grep '- [ ] pool-m' "$home/data/backlog.md" "once_marker guard incorrectly left the item claimed"

  pass "once_marker prevents a duplicate dispatch of the same attempt"
}

# --- status output shape -----------------------------------------------
test_status_output_shape() {
  local home out
  home=$(new_home status)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - x (repo: demo) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" status 2>&1)
  assert_contains "$out" "armed:      no (DISARMED)" "status did not report disarmed"
  assert_contains "$out" "kill:       absent" "status did not report kill absent"
  assert_contains "$out" "active pool tasks: 0" "status did not report active pool task count"
  assert_contains "$out" "queued pool tasks: 1" "status did not report queued pool task count"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" status 2>&1)
  assert_contains "$out" "armed:      YES" "status did not report armed after arm"

  pass "status prints ARMED/KILL/lock/queue-depth/active-count one-liners"
}

# --- arm / disarm -----------------------------------------------------------
test_arm_disarm() {
  local home
  home=$(new_home arm-disarm)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "captain note here" >/dev/null
  assert_present "$home/state/.ocpool-armed" "arm did not write the armed flag"
  assert_grep "captain note here" "$home/state/.ocpool-armed" "arm did not record the captain note"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" disarm >/dev/null
  assert_absent "$home/state/.ocpool-armed" "disarm did not remove the armed flag"

  pass "arm writes the armed flag with the captain note; disarm removes it"
}

test_disarmed_once_is_inert
test_armed_once_dispatches_pool_items_only
test_kill_switch_suspends
test_lock_held_standby
test_capacity_cap_blocks_dispatch
test_verified_moves_to_done
test_verified_uses_tasks_axi_when_available
test_blocked_returns_to_queued_without_attempt_burn
test_failed_requeues_once_then_needs_captain
test_once_marker_prevents_double_dispatch
test_status_output_shape
test_arm_disarm
