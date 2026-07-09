#!/usr/bin/env bash
# Focused behavior tests for fleet-lock acquisition and autopilot attribution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock)

make_fake_ps() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
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
    if [ "$requested" = "${FM_TEST_HARNESS_PID:-}" ] || [ "$requested" = "${FM_TEST_LIVE_HARNESS_PID:-}" ]; then
      printf '%s\n' '/usr/local/bin/codex'
    else
      printf '%s\n' 'bash'
    fi
    ;;
  *"args="*)
    if [ "$requested" = "${FM_TEST_HARNESS_PID:-}" ] || [ "$requested" = "${FM_TEST_LIVE_HARNESS_PID:-}" ]; then
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
  printf '%s\n' "$fakebin"
}

run_as_harness() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" PATH="$fakebin:$PATH" "$@" bash -c '
    export FM_TEST_HARNESS_PID=$BASHPID
    exec bash "$1"
  ' _ "$LOCK" 2>&1
}

test_ordinary_session_acquires_valid_lock() {
  local home fakebin out owner
  home="$TMP_ROOT/ordinary"
  fakebin=$(make_fake_ps "$home/fake")
  mkdir -p "$home/state"

  out=$(run_as_harness "$home" "$fakebin" env)
  owner=$(cat "$home/state/.lock")
  assert_contains "$out" "lock acquired: harness pid $owner" "ordinary session did not acquire a harness-owned lock"
  case "$owner" in ''|*[!0-9]*) fail "ordinary lock owner was not numeric: $owner" ;; esac
  pass "ordinary non-autopilot sessions acquire a valid harness-owned fleet lock"
}

test_interactive_session_preempts_autopilot() {
  local home fakebin out autopilot new_owner
  home="$TMP_ROOT/interactive-preempt"
  fakebin=$(make_fake_ps "$home/fake")
  mkdir -p "$home/state"
  sleep 30 & autopilot=$!
  printf '%s\n' "$autopilot" > "$home/state/.lock"
  printf '%s\n' "$autopilot" > "$home/state/.autopilot-owns-lock"

  out=$(run_as_harness "$home" "$fakebin" env)
  new_owner=$(cat "$home/state/.lock")
  kill "$autopilot" 2>/dev/null || true
  wait "$autopilot" 2>/dev/null || true

  [ "$new_owner" != "$autopilot" ] || fail "interactive session left the autopilot PID in the fleet lock"
  assert_contains "$out" "lock acquired: harness pid $new_owner" "interactive preemption did not acquire the lock"
  pass "an unmarked interactive session still preempts a live autopilot owner"
}

test_dead_autopilot_owner_is_reclaimable() {
  local home fakebin out owner
  home="$TMP_ROOT/dead-owner"
  fakebin=$(make_fake_ps "$home/fake")
  mkdir -p "$home/state"
  printf '%s\n' '999999' > "$home/state/.lock"
  printf '%s\n' '999999' > "$home/state/.autopilot-owns-lock"

  out=$(run_as_harness "$home" "$fakebin" env FM_AUTOPILOT_LOCK_OWNER_PID=999999)
  owner=$(cat "$home/state/.lock")
  [ "$owner" != 999999 ] || fail "dead autopilot owner was not reclaimed"
  assert_contains "$out" "lock acquired: harness pid $owner" "dead owner reclaim did not acquire the lock"
  pass "a stale autopilot owner remains reclaimable even with an inherited marker"
}

test_dispatched_harness_retains_live_autopilot_owner() {
  local home fakebin out autopilot
  home="$TMP_ROOT/dispatched-retain"
  fakebin=$(make_fake_ps "$home/fake")
  mkdir -p "$home/state"
  sleep 30 & autopilot=$!
  printf '%s\n' "$autopilot" > "$home/state/.lock"
  printf '%s\n' "$autopilot" > "$home/state/.autopilot-owns-lock"

  out=$(run_as_harness "$home" "$fakebin" env FM_AUTOPILOT_LOCK_OWNER_PID="$autopilot")
  assert_grep "$autopilot" "$home/state/.lock" "dispatched harness replaced the live autopilot lock owner"
  assert_contains "$out" "lock retained: autopilot pid $autopilot" "dispatched harness did not report retained ownership"
  kill "$autopilot" 2>/dev/null || true
  wait "$autopilot" 2>/dev/null || true
  pass "an autopilot-dispatched harness retains the matching live loop PID"
}

test_ordinary_session_acquires_valid_lock
test_interactive_session_preempts_autopilot
test_dead_autopilot_owner_is_reclaimable
test_dispatched_harness_retains_live_autopilot_owner
