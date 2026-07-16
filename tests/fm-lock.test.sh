#!/usr/bin/env bash
# Focused unit and integration coverage for Firstmate session-lock attribution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock)

make_fake_ps() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
requested=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then requested=$argument; break; fi
  previous=$argument
done
caller=${FM_TEST_CALLER_PID:-}
app=${FM_TEST_APP_SERVER_PID:-}
competitor=${FM_TEST_COMPETITOR_PID:-}
session=${FM_TEST_SESSION_PID:-}
autopilot=${FM_TEST_AUTOPILOT_PID:-}
case "$*" in
  *"lstart="*)
    if [ "$requested" = "$autopilot" ]; then
      printf '%s\n' "${FM_TEST_AUTOPILOT_ACTUAL_IDENTITY:-Thu Jul 10 08:00:00 2026}"
    else
      printf '%s\n' 'Thu Jul 10 08:01:00 2026'
    fi
    ;;
  *"comm="*)
    case "$requested" in
      "$caller") printf '%s\n' '/bin/zsh' ;;
      "$app") printf '%s\n' '/Applications/Ch' ;;
      "$session"|"$competitor") printf '%s\n' '/usr/local/bin/codex' ;;
      *) printf '%s\n' '/bin/bash' ;;
    esac
    ;;
  *"args="*)
    case "$requested" in
      "$caller") printf '%s\n' '/bin/zsh -lc test' ;;
      "$app") printf '%s\n' '/Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled' ;;
      "$session"|"$competitor") printf '%s\n' 'codex --session-specific' ;;
      "$autopilot") printf '%s\n' 'bash bin/fm-autopilot.sh _loop' ;;
      *) printf '%s\n' 'bash' ;;
    esac
    ;;
  *"ppid="*)
    if [ "$requested" = "$caller" ]; then
      printf '%s\n' "$app"
    elif [ "$requested" = "$app" ]; then
      printf '%s\n' "$session"
    else
      printf '%s\n' '1'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

run_from_codex_app() {
  local home=$1 fakebin=$2 app=$3 session=$4
  shift 4
  FM_HOME="$home" PATH="$fakebin:$PATH" FM_TEST_APP_SERVER_PID="$app" FM_TEST_SESSION_PID="$session" \
    bash -c 'export FM_TEST_CALLER_PID=$BASHPID; exec "$@"' _ "$@"
}

test_session_specific_codex_owns_session() {
  local home fakebin app session out owner
  home="$TMP_ROOT/codex-app"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  sleep 30 & app=$!; sleep 30 & session=$!
  out=$(run_from_codex_app "$home" "$fakebin" "$app" "$session" "$LOCK")
  owner=$(cat "$home/state/.lock")
  kill "$app" "$session" 2>/dev/null || true; wait "$app" 2>/dev/null || true; wait "$session" 2>/dev/null || true
  [ "$owner" = "$session" ] || fail "session-specific Codex process was not selected (owner=$owner session=$session)"
  assert_contains "$out" "lock acquired: harness pid $session" "session acquisition was not reported"
  pass "a session-specific Codex process owns the session"
}

test_competing_live_codex_sessions_fail_closed() {
  local home fakebin app session competitor out status owner
  home="$TMP_ROOT/competition"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  sleep 30 & app=$!; sleep 30 & session=$!; sleep 30 & competitor=$!
  printf '%s\n' "$competitor" > "$home/state/.lock"
  status=0
  out=$(FM_TEST_COMPETITOR_PID="$competitor" run_from_codex_app "$home" "$fakebin" "$app" "$session" "$LOCK" 2>&1) || status=$?
  owner=$(cat "$home/state/.lock")
  kill "$app" "$session" "$competitor" 2>/dev/null || true; wait "$app" 2>/dev/null || true; wait "$session" 2>/dev/null || true; wait "$competitor" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "competing live Codex Desktop session acquired the lock"
  [ "$owner" = "$competitor" ] || fail "competing session rewrote the live owner's lock"
  assert_contains "$out" "another live firstmate session holds the lock" "competition refusal was not explicit"
  pass "a second live Codex Desktop session stays read-only"
}

test_stale_owner_is_recovered() {
  local home fakebin app session owner
  home="$TMP_ROOT/stale"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  printf '%s\n' 999999 > "$home/state/.lock"
  sleep 30 & app=$!; sleep 30 & session=$!
  run_from_codex_app "$home" "$fakebin" "$app" "$session" "$LOCK" >/dev/null
  owner=$(cat "$home/state/.lock")
  kill "$app" "$session" 2>/dev/null || true; wait "$app" 2>/dev/null || true; wait "$session" 2>/dev/null || true
  [ "$owner" = "$session" ] || fail "stale owner was not replaced by the current session harness"
  pass "a dead lock owner is recovered"
}

test_live_autopilot_owner_is_retained_by_dispatched_app() {
  local home fakebin app autopilot identity out status owner
  home="$TMP_ROOT/autopilot"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  sleep 30 & app=$!; sleep 30 & autopilot=$!
  identity='Thu Jul 10 08:00:00 2026'
  printf '%s\n' "$autopilot" > "$home/state/.lock"
  printf '%s\n' "$autopilot" > "$home/state/.autopilot-owns-lock"
  status=0
  out=$(FM_TEST_AUTOPILOT_PID="$autopilot" \
    FM_AUTOPILOT_LOCK_OWNER_PID="$autopilot" \
    FM_AUTOPILOT_LOCK_OWNER_IDENTITY="$identity" \
    run_from_codex_app "$home" "$fakebin" "$app" "" "$LOCK" 2>&1) || status=$?
  owner=$(cat "$home/state/.lock")
  kill "$app" "$autopilot" 2>/dev/null || true; wait "$app" 2>/dev/null || true; wait "$autopilot" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "autopilot-dispatched app-server was treated as lock owner"
  [ "$owner" = "$autopilot" ] || fail "dispatched app-server replaced the Bash autopilot owner"
  assert_contains "$out" "autopilot pid $autopilot retains the fleet lock" "autopilot retention was not explicit"
  assert_contains "$out" "operate read-only" "dispatched app-server did not fail closed"
  pass "Bash autopilot ownership survives dispatched Codex app startup"
}

test_reused_autopilot_pid_is_recovered() {
  local home fakebin app session autopilot owner
  home="$TMP_ROOT/pid-reuse"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  sleep 30 & app=$!; sleep 30 & session=$!; sleep 30 & autopilot=$!
  printf '%s\n' "$autopilot" > "$home/state/.lock"
  printf '%s\n' "$autopilot" > "$home/state/.autopilot-owns-lock"
  FM_TEST_AUTOPILOT_PID="$autopilot" \
    FM_TEST_AUTOPILOT_ACTUAL_IDENTITY='Thu Jul 10 08:02:00 2026' \
    FM_AUTOPILOT_LOCK_OWNER_PID="$autopilot" \
    FM_AUTOPILOT_LOCK_OWNER_IDENTITY='Thu Jul 10 08:00:00 2026' \
    run_from_codex_app "$home" "$fakebin" "$app" "$session" "$LOCK" >/dev/null
  owner=$(cat "$home/state/.lock")
  kill "$app" "$session" "$autopilot" 2>/dev/null || true; wait "$app" 2>/dev/null || true; wait "$session" 2>/dev/null || true; wait "$autopilot" 2>/dev/null || true
  [ "$owner" = "$session" ] || fail "reused autopilot PID generation remained owner"
  pass "PID-generation mismatch recovers ownership safely"
}

test_session_specific_codex_owns_session
test_competing_live_codex_sessions_fail_closed
test_stale_owner_is_recovered
test_live_autopilot_owner_is_retained_by_dispatched_app
test_reused_autopilot_pid_is_recovered
