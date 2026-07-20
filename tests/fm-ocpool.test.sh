#!/usr/bin/env bash
# tests/fm-ocpool.test.sh - behavior tests for bin/fm-ocpool.sh, the headless
# opencode worker-pool loop. Every test runs against a throwaway FM_HOME
# fixture (state/, data/, config/, projects/) and stubs the dispatch bridge via
# FM_OCPOOL_DISPATCH_BIN and tasks-axi via a fakebin on PATH, so no real
# opencode is ever launched, no live fleet state is ever touched, and no real
# tasks-axi install is required. No launchctl is invoked (start/stop/the
# installer are not exercised here).
#
# Coverage:
#   - disarmed `once`: standby, zero mutation
#   - armed `once`: dispatches only (pool: opencode)-marked items, by
#     priority, claiming them via a real `tasks-axi start` call (item leaves
#     "## Queued"), and writes a state/<key>.meta with kind=ocpool-worker
#   - kill switch: armed but state/.ocpool-kill present -> standby
#   - preempt flag: state/.ocpool-preempt present -> standby, own lock released
#   - this loop runs even while the SHARED fleet lock (state/.lock) is held by
#     another live session - it does not stand down for an interactive captain
#   - this loop's own private lock (state/.ocpool.lock) blocks a second
#     concurrent ocpool process
#   - excluded-project hard skip and destructive-text escalation (ported
#     safety guards from fm-autopilot.sh)
#   - capacity math: dispatch is blocked when active pool tasks (read from
#     state/*.meta filtered kind=ocpool-worker, cross-checked against
#     fm-lifecycle state) are at FM_OCPOOL_MAX_CONCURRENT
#   - verified (exit 0) -> lifecycle closeout(completed) + `tasks-axi done`
#   - blocked (exit 2) -> `tasks-axi reopen`, no attempt consumed
#   - failed (exit 3) -> reopens once with a handoff note, then escalates to
#     needs-captain on the second failure
#   - tasks-axi unavailable (config/backlog-backend=manual) -> refuses to
#     dispatch rather than hand-edit the backlog, escalates instead
#   - once_marker prevents a duplicate dispatch of the same attempt
#   - a still-running attempt gets a bin/fm-lifecycle.sh heartbeat
#   - `status` output shape
#   - `arm` / `disarm`
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OCPOOL="$ROOT/bin/fm-ocpool.sh"
TMP_ROOT=$(fm_test_tmproot fm-ocpool-tests)
fm_git_identity fmtest fmtest@example.invalid

# --- shared fake tasks-axi ---------------------------------------------------
# Every test now needs a compatible tasks-axi on PATH: fm-ocpool.sh mutates
# the backlog exclusively through tasks-axi ops, with no hand-edit fallback.
# This fake answers the compat probe (--version/update --help/mv --help) and
# performs a real (simplified) start/reopen/done against $FM_HOME/data/backlog.md,
# moving the item between "## In flight"/"## Queued"/"## Done" sections the
# same way parse_pool_queued (and fm-autopilot.sh's own parser) expect, plus a
# call-log sidecar ($FM_HOME/tasks-axi-calls.txt) for exact-invocation asserts.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
BACKLOG="$FM_HOME/data/backlog.md"
CALLS="$FM_HOME/tasks-axi-calls.txt"

move_item() {  # <id> <to-header> <checkbox>
  local id=$1 to_header=$2 checkbox=$3 tmp item rest
  tmp=$(mktemp) || return 1
  item=$(mktemp) || return 1
  rest=$(mktemp) || return 1
  awk -v id="$id" -v itemfile="$item" -v restfile="$rest" -v checkbox="$checkbox" '
    {
      if (initem) {
        if ($0 ~ /^[[:space:]]/) { print >> itemfile; next }
        initem = 0
      }
      if (!found && $0 ~ ("^- \\[[ ~x]\\] " id "([[:space:]]|$)")) {
        line = $0
        sub(/^- \[[ ~x]\]/, "- [" checkbox "]", line)
        print line >> itemfile
        initem = 1
        found = 1
        next
      }
      print >> restfile
    }
  ' "$BACKLOG"
  if [ ! -s "$item" ]; then rm -f "$tmp" "$item" "$rest"; return 1; fi
  if grep -qF "$to_header" "$rest"; then
    awk -v itemfile="$item" -v hdr="$to_header" '
      { print }
      $0 == hdr && !inserted { while ((getline line < itemfile) > 0) print line; inserted = 1 }
    ' "$rest" > "$tmp"
  else
    cat "$rest" > "$tmp"
    { printf '\n%s\n' "$to_header"; cat "$item"; } >> "$tmp"
  fi
  mv "$tmp" "$BACKLOG"
  rm -f "$item" "$rest"
  return 0
}

case "${1:-}" in
  --version) echo "tasks-axi 0.2.2"; exit 0 ;;
  update) [ "${2:-}" = "--help" ] && { echo "flags: --archive-body"; exit 0; }; exit 1 ;;
  mv) [ "${2:-}" = "--help" ] && { echo "usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>"; exit 0; }; exit 1 ;;
  start)
    id=${2:-}
    printf 'start %s\n' "$id" >> "$CALLS"
    move_item "$id" "## In flight" " "
    exit $?
    ;;
  reopen)
    id=${2:-}
    printf 'reopen %s\n' "$id" >> "$CALLS"
    move_item "$id" "## Queued" " "
    exit $?
    ;;
  done)
    shift
    id=${1:-}; shift || true
    printf 'done %s %s\n' "$id" "$*" >> "$CALLS"
    move_item "$id" "## Done" "x"
    exit $?
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tasks-axi"
export PATH="$FAKEBIN:$PATH"

# --- world builder ----------------------------------------------------------
# new_home <name>: a throwaway FM_HOME with state/, data/, config/, projects/,
# a demo clone. config/backlog-backend is left absent (default tasks-axi
# backend), so the fake tasks-axi above is used for every mutation. Echoes the
# home dir.
new_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/demo" "$home/stub-plan"
  printf '%s\n' "$home"
}

# stub_dispatch <home> <name> [sleep-secs]: a fake bridge that reads its
# planned exit code for --task-id <key> from <home>/stub-plan/<key>.rc
# (default 0), optionally sleeps first (for the heartbeat test), prints a
# one-line JSON-shaped receipt, and exits with that code. Echoes the path.
stub_dispatch() {
  local home=$1 name=$2 sleep_secs=${3:-0}
  local cmd="$home/$name.sh"
  cat > "$cmd" <<SH
#!/usr/bin/env bash
key=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --task-id) key=\$2; shift 2 ;;
    *) shift ;;
  esac
done
sleep $sleep_secs
plan="\$FM_HOME/stub-plan/\$key.rc"
code=0
[ -f "\$plan" ] && code=\$(cat "\$plan")
printf '{"status":"stub","taskId":"%s","exit":%s}\n' "\$key" "\${code:-0}"
exit "\${code:-0}"
SH
  chmod +x "$cmd"
  printf '%s\n' "$cmd"
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
calls_of() { cat "$1/tasks-axi-calls.txt" 2>/dev/null || true; }

# queued_section <home>: just the "## Queued" section body, so a test can
# assert an item left Queued without being fooled by the same unchecked
# "- [ ] " form legitimately appearing again under "## In flight".
queued_section() {
  awk '/^## / { insection = ($0 ~ /^## Queued/); next } insection { print }' "$1/data/backlog.md" 2>/dev/null
}

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
  assert_absent "$home/state/.ocpool.lock" "disarmed once acquired the own lock (must not mutate)"
  assert_absent "$home/state/pool-a.meta" "disarmed once dispatched a task (must not mutate)"
  [ ! -s "$home/data/ocpool/log.md" ] || fail "disarmed once wrote a mutating receipt: $(log_of "$home")"

  pass "a disarmed once tick stands by: heartbeat only, no lock, no dispatch, no receipt"
}

# --- armed once: pool-marker filter + priority + claim via tasks-axi start --
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

  assert_present "$home/state/pool-a.meta" "armed once did not dispatch pool-a"
  assert_present "$home/state/pool-b.meta" "armed once did not dispatch pool-b"
  assert_grep "kind=ocpool-worker" "$home/state/pool-a.meta" "pool-a meta missing kind=ocpool-worker"
  assert_grep "lifecycle_id=pool-a-a1" "$home/state/pool-a.meta" "pool-a meta missing lifecycle_id pointer"
  assert_absent "$home/state/normal-c.meta" "armed once dispatched a non-pool-marked item"
  local queued; queued=$(queued_section "$home")
  assert_not_contains "$queued" 'pool-a' "pool-a is still listed under ## Queued (not claimed)"
  assert_not_contains "$queued" 'pool-b' "pool-b is still listed under ## Queued (not claimed)"
  assert_grep '- [ ] normal-c' "$home/data/backlog.md" "a non-pool item was mutated"

  local calls; calls=$(calls_of "$home")
  assert_contains "$calls" "start pool-a" "tasks-axi start was not called for pool-a"
  assert_contains "$calls" "start pool-b" "tasks-axi start was not called for pool-b"

  log=$(log_of "$home")
  assert_contains "$log" "dispatch	pool-a" "no dispatch receipt for pool-a"
  assert_contains "$log" "dispatch	pool-b" "no dispatch receipt for pool-b"

  la=$(printf '%s\n' "$log" | grep -n 'dispatch	pool-a' | head -1 | cut -d: -f1)
  lb=$(printf '%s\n' "$log" | grep -n 'dispatch	pool-b' | head -1 | cut -d: -f1)
  [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ] || fail "priority ordering wrong: pool-a(line $la) not before pool-b(line $lb)"

  wait_for_exit_marker "$home" pool-a || true
  wait_for_exit_marker "$home" pool-b || true

  pass "an armed once tick dispatches only (pool: opencode) items, by priority, claiming them via tasks-axi start"
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
  assert_absent "$home/state/pool-a.meta" "kill switch did not prevent dispatch"
  assert_absent "$home/state/.ocpool.lock" "kill switch tick acquired the own lock"

  pass "an armed tick with the kill switch present suspends all mutating actions"
}

# --- preempt flag --------------------------------------------------------
test_preempt_flag_suspends() {
  local home dispatch out
  home=$(new_home preempt)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null
  : > "$home/state/.ocpool-preempt"

  out=$(run_once "$home" "$dispatch")
  assert_contains "$out" "standby: preempt requested" "preempt flag did not force standby"
  assert_absent "$home/state/pool-a.meta" "preempt flag did not prevent dispatch"
  assert_absent "$home/state/.ocpool.lock" "preempt flag left the own lock held"

  pass "an armed tick with state/.ocpool-preempt present suspends all mutating actions and releases the own lock"
}

# --- runs even while the shared fleet lock is held --------------------------
test_runs_while_interactive_lock_held() {
  local home dispatch out holder
  home=$(new_home interactive-lock)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  # A live process (not ocpool) holds the SHARED fleet lock, as an interactive
  # captain session would. fm-ocpool.sh must dispatch anyway - it is
  # subordinate gruntwork, not captain-acting, and does not stand down for it.
  sleep 30 & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(run_once "$home" "$dispatch")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_present "$home/state/pool-a.meta" "ocpool stood down for the shared fleet lock; it must not"
  assert_not_contains "$out" "standby" "ocpool reported standby while only the shared fleet lock (not its own) was held"
  assert_grep "$holder" "$home/state/.lock" "ocpool touched the shared fleet lock, which it must never use"

  pass "ocpool dispatches even while the shared fleet lock (state/.lock) is held by another live session"
}

# --- own lock blocks a second concurrent ocpool process ---------------------
test_own_lock_blocks_second_ocpool_process() {
  local home dispatch out holder
  home=$(new_home own-lock)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  sleep 30 & holder=$!
  printf '%s\n' "$holder" > "$home/state/.ocpool.lock"

  out=$(run_once "$home" "$dispatch")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_contains "$out" "own lock held by another ocpool process" "a live own-lock holder did not force standby"
  assert_absent "$home/state/pool-a.meta" "dispatch happened despite another ocpool process holding the own lock"
  assert_grep "$holder" "$home/state/.ocpool.lock" "ocpool overwrote another live ocpool process's own lock"

  pass "ocpool's own lock blocks a second concurrent ocpool process, and never overwrites a live holder"
}

# --- safety guards: excluded project, destructive text ----------------------
test_excluded_project_skip_dispatch() {
  local home dispatch
  home=$(new_home excluded)
  dispatch=$(stub_dispatch "$home" stub)
  mkdir -p "$home/projects/armalo-fi"
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-money - trade (repo: armalo-fi) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  assert_absent "$home/state/pool-money.meta" "an excluded-project pool item was dispatched"
  assert_contains "$(log_of "$home")" "skip-dispatch	pool-money" "no skip-dispatch receipt for the excluded project"
  assert_not_contains "$(needs_of "$home")" "pool-money" "an excluded-project skip incorrectly escalated to needs-captain"

  pass "a pool item in an FM_AUTOPILOT_EXCLUDE_PROJECTS project is hard-skipped, never escalated"
}

test_dangerous_text_escalates() {
  local home dispatch
  home=$(new_home danger)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-danger - please rm -rf everything (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  assert_absent "$home/state/pool-danger.meta" "a destructive-text pool item was dispatched"
  assert_contains "$(needs_of "$home")" "pool-danger | destructive/security-sensitive" "a destructive-text item was not escalated"

  pass "a pool item matching the destructive/security-sensitive guard is escalated, never dispatched"
}

# --- capacity math holds -----------------------------------------------
test_capacity_cap_blocks_dispatch() {
  local home dispatch out
  home=$(new_home capacity)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-new - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  # One already-active pool task, tracked the same way a real dispatch would:
  # a state/<key>.meta with kind=ocpool-worker pointing at a lifecycle ledger
  # row with state=active.
  printf 'kind=ocpool-worker\nlifecycle_id=busy-a1\n' > "$home/state/busy.meta"
  printf 'state=active\n' > "$home/state/busy-a1.lifecycle"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OCPOOL_DISPATCH_BIN="$dispatch" FM_OCPOOL_MAX_CONCURRENT=1 bash "$OCPOOL" once 2>&1)

  assert_contains "$out" "dispatch skipped" "capacity cap did not block dispatch"
  assert_absent "$home/state/pool-new.meta" "dispatch happened despite being at the concurrency cap"

  pass "dispatch is blocked when active pool tasks (state/*.meta kind=ocpool-worker, fm-lifecycle state) are at the concurrency cap"
}

# --- tasks-axi unavailable: refuse to dispatch, never hand-edit -------------
test_tasks_axi_unavailable_refuses_to_dispatch() {
  local home dispatch
  home=$(new_home noaxi)
  dispatch=$(stub_dispatch "$home" stub)
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-a - do a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  assert_absent "$home/state/pool-a.meta" "dispatch happened despite the tasks-axi backend being unavailable"
  assert_absent "$home/tasks-axi-calls.txt" "tasks-axi was called despite backlog-backend=manual"
  assert_contains "$(needs_of "$home")" "pool-a | tasks-axi-unavailable" "an unavailable backlog backend was not escalated"
  assert_grep '- [ ] pool-a' "$home/data/backlog.md" "the backlog was hand-edited despite tasks-axi being unavailable"

  pass "with the tasks-axi backend unavailable (config/backlog-backend=manual), ocpool refuses to dispatch rather than hand-edit the backlog"
}

# --- verified -> done via tasks-axi -----------------------------------------
test_verified_moves_to_done() {
  local home dispatch
  home=$(new_home verified)
  dispatch=$(stub_dispatch "$home" stub)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-v - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  printf '0\n' > "$home/stub-plan/pool-v.rc"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  wait_for_exit_marker "$home" pool-v || fail "stub dispatch for pool-v never finished"

  run_once "$home" "$dispatch" >/dev/null
  assert_grep '- [x] pool-v' "$home/data/backlog.md" "pool-v was not moved to Done"
  assert_grep '## Done' "$home/data/backlog.md" "no Done section was created"
  assert_contains "$(calls_of "$home")" "done pool-v" "tasks-axi done was not called for pool-v"
  assert_contains "$(log_of "$home")" "done	pool-v" "no done receipt for pool-v"
  assert_absent "$home/state/pool-v.meta" "meta was not cleared after closeout"

  local lc; lc=$(grep '^state=' "$home/state/pool-v-a1.lifecycle" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ "$lc" = completed ] || fail "lifecycle state for pool-v-a1 was not completed: ${lc:-<missing>}"
  local ev; ev=$(grep '^last_evidence=' "$home/state/pool-v-a1.lifecycle" 2>/dev/null | tail -1 | cut -d= -f2-)
  assert_contains "$ev" "pool-v.receipt.json" "closeout evidence did not point at the bridge's receipt.json"

  pass "a verified (exit 0) attempt closes out the lifecycle with the bridge's receipt.json as evidence and calls tasks-axi done"
}

# --- blocked -> reopened, no attempt burn -----------------------------------
test_blocked_reopens_without_attempt_burn() {
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
  assert_grep '- [ ] pool-blk' "$home/data/backlog.md" "pool-blk was not reopened to queued"
  assert_no_grep '- [x] pool-blk' "$home/data/backlog.md" "pool-blk was incorrectly marked done"
  assert_contains "$(calls_of "$home")" "reopen pool-blk" "tasks-axi reopen was not called for pool-blk"
  assert_absent "$home/state/.ocpool-retry-pool-blk" "a blocked attempt incorrectly consumed a retry"
  assert_contains "$(log_of "$home")" "blocked	pool-blk" "no blocked receipt for pool-blk"

  pass "a blocked (exit 2) attempt is reopened to queued via tasks-axi, without consuming an attempt"
}

# --- failed -> reopen once -> needs-captain --------------------------------
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

  # Triage attempt 1 (reopen). The same tick's dispatch phase immediately
  # re-picks the now-queued item as attempt 2, since capacity freed up.
  run_once "$home" "$dispatch" >/dev/null
  assert_contains "$(log_of "$home")" "requeue	pool-f" "no requeue receipt after attempt 1 failure"
  assert_grep '## Handoff note' "$home/data/pool-f/brief.md" "no handoff note appended after attempt 1 failure"
  assert_grep '1' "$home/state/.ocpool-retry-pool-f" "retry counter did not record 1 failed attempt"

  wait_for_exit_marker "$home" pool-f || fail "attempt 2 never finished"

  # Triage attempt 2 (exhausted) -> needs-captain.
  run_once "$home" "$dispatch" >/dev/null
  assert_contains "$(needs_of "$home")" "pool-f | failed-exhausted" "attempt exhaustion was not escalated to needs-captain"
  assert_grep '2' "$home/state/.ocpool-retry-pool-f" "retry counter did not reach 2 after the second failure"

  local lc; lc=$(grep '^state=' "$home/state/pool-f-a2.lifecycle" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ "$lc" = abandoned ] || fail "lifecycle state for the exhausted pool-f-a2 attempt was not abandoned: ${lc:-<missing>}"

  pass "a failed (exit 3) attempt reopens once via tasks-axi with a handoff note, then escalates to needs-captain after the second failure"
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
  assert_absent "$home/state/pool-m.meta" "once_marker did not prevent a duplicate dispatch of the same attempt"
  assert_absent "$home/tasks-axi-calls.txt" "once_marker did not prevent the tasks-axi start call"
  assert_grep '- [ ] pool-m' "$home/data/backlog.md" "once_marker guard incorrectly left the item claimed"

  pass "once_marker prevents a duplicate dispatch of the same attempt"
}

# --- heartbeat for a still-running attempt ----------------------------------
test_heartbeat_for_still_running_attempt() {
  local home dispatch
  home=$(new_home heartbeat)
  dispatch=$(stub_dispatch "$home" stub-slow 0.4)
  printf '%s\n' '# Backlog' '## Queued' \
    '- [ ] pool-hb - ship a thing (repo: demo) (kind: ship) (priority: 1) (pool: opencode)' > "$home/data/backlog.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null

  run_once "$home" "$dispatch" >/dev/null
  assert_present "$home/state/pool-hb.meta" "the slow stub was not dispatched"
  assert_absent "$home/state/.ocpool-exit-pool-hb" "the slow stub finished before the heartbeat tick could observe it running"

  # A second tick while the bridge is still asleep should heartbeat the
  # attempt without touching its terminal state.
  run_once "$home" "$dispatch" >/dev/null
  local seq; seq=$(grep '^heartbeat_seq=' "$home/state/pool-hb-a1.lifecycle" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$seq" ] && [ "$seq" -ge 1 ] || fail "heartbeat_seq did not advance for a still-running attempt: ${seq:-<missing>}"
  assert_grep 'state=active' "$home/state/pool-hb-a1.lifecycle" "a heartbeated attempt was incorrectly moved out of active"

  wait_for_exit_marker "$home" pool-hb || fail "the slow stub never finished"

  pass "a still-running attempt (no exit marker yet) gets a bin/fm-lifecycle.sh heartbeat every tick"
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
  assert_contains "$out" "preempt:    absent" "status did not report preempt absent"
  assert_contains "$out" "active pool tasks: 0" "status did not report active pool task count"
  assert_contains "$out" "queued pool tasks: 1" "status did not report queued pool task count"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" arm "test" >/dev/null
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$OCPOOL" status 2>&1)
  assert_contains "$out" "armed:      YES" "status did not report armed after arm"

  pass "status prints ARMED/KILL/preempt/own-lock/queue-depth/active-count one-liners"
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
test_preempt_flag_suspends
test_runs_while_interactive_lock_held
test_own_lock_blocks_second_ocpool_process
test_excluded_project_skip_dispatch
test_dangerous_text_escalates
test_capacity_cap_blocks_dispatch
test_tasks_axi_unavailable_refuses_to_dispatch
test_verified_moves_to_done
test_blocked_reopens_without_attempt_burn
test_failed_requeues_once_then_needs_captain
test_once_marker_prevents_double_dispatch
test_heartbeat_for_still_running_attempt
test_status_output_shape
test_arm_disarm
