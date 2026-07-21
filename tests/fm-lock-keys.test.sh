#!/usr/bin/env bash
# Focused coverage for the scoped-key lock in fm-lock.sh.
#
# Verifies:
#   1. Default (no flags) acquisition keeps legacy .lock semantics identical:
#      writes the legacy file, populates one key file per default key, refuses
#      to overwrite a live harness pid, self-recovers from a stale pid.
#   2. --keys=acquire on a subset succeeds even when another live harness
#      holds the disjoint subset (true concurrency).
#   3. --includes=K consults the requested set, not the default set, so
#      scoped callers can ask "is K part of what I would acquire?".
#   4. Bad CSV exits 2 with a clear error and never writes a lock file.
#   5. status --keys shows per-key holders.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-keys)

# Live-session pid registry. Tests spawn real long-lived children so kill -0
# works against them; the fake ps simply attributes the registered pids to
# session-shaped codex comms.
declare -a LIVE_PIDS=()

cleanup_pids() {
  local p
  for p in "${LIVE_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
}
trap 'cleanup_pids' EXIT

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
# FM_TEST_SESSION_PID -> session-shaped codex (the in-flight acquire path).
# FM_TEST_BLOCKER_PID  -> a competing live harness holding a key.
# FM_TEST_CALLER_PID   -> the calling bash, never report it as harness-shaped
#                         so the harness walker walks up to a session-shaped
#                         ancestor where the registry has the right pid.
caller=${FM_TEST_CALLER_PID:-}
session=${FM_TEST_SESSION_PID:-}
blocker=${FM_TEST_BLOCKER_PID:-}
case "$*" in
  *"lstart="*)
    if [ "$requested" = "$session" ] || [ "$requested" = "$blocker" ]; then
      printf '%s\n' 'Thu Jul 10 08:00:00 2026'
    else
      printf '%s\n' 'Thu Jul 10 08:01:00 2026'
    fi
    ;;
  *"comm="*)
    case "$requested" in
      "$session"|"$blocker") printf '%s\n' '/usr/local/bin/codex' ;;
      *) printf '%s\n' '/bin/bash' ;;
    esac
    ;;
  *"args="*)
    case "$requested" in
      "$session"|"$blocker") printf '%s\n' 'codex --session-specific' ;;
      *) printf '%s\n' 'bash' ;;
    esac
    ;;
  *"ppid="*)
    if [ "$requested" = "$caller" ]; then
      printf '%s\n' "${session:-1}"
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

# Spawn a long-lived child, register the pid, echo it. The caller takes a
# reference and adds it to LIVE_PIDS so cleanup kills it; the spawn itself
# must return immediately.
spawn_live_session_pid() {
  local marker=$1
  sleep 120 &
  echo "$!" > "$marker"
}

run_with_fake_ps() {
  # <home> <fakebin> <session_pid> <program> [args...]
  # Sets FM_TEST_SESSION_PID in the env so the fake ps reports the right PID
  # as session-shaped; the inner bash then exports FM_TEST_CALLER_PID for the
  # walker. A quirk: the walker walks `$$` -> ppid -> ... , and the fake
  # reports the caller's ppid as the session pid, so even though $BASHPID is
  # the bash running this script, the walker adopts the real session pid.
  local home=$1 fakebin=$2 session_pid=$3; shift 3
  FM_HOME="$home" PATH="$fakebin:$PATH" \
    FM_TEST_SESSION_PID="$session_pid" \
    bash -c 'FM_TEST_CALLER_PID=$BASHPID exec "$@"' _ "$@"
}

# Run fm-lock.sh (or any binary) under the fake ps + fake env, without the
# caller/session wiring above. Used for status calls that should consult the
# same fake ps but need a specific PID reported as session-shaped (e.g. the
# recorded lock owner from a previous acquire).
run_under_fake_env_with_session() {
  local home=$1 fakebin=$2 session_pid=$3; shift 3
  FM_HOME="$home" PATH="$fakebin:$PATH" \
    FM_TEST_SESSION_PID="$session_pid" \
    bash -c 'FM_TEST_CALLER_PID=$BASHPID exec "$@"' _ "$@"
}

test_default_acquire_writes_legacy_and_keys() {
  local home fakebin session_pid owner out status
  home="$TMP_ROOT/default-acquire"; mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  spawn_live_session_pid "$TMP_ROOT/.session-A"
  session_pid=$(cat "$TMP_ROOT/.session-A")
  LIVE_PIDS+=("$session_pid")
  out=$(run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" 2>&1)
  [ -f "$home/state/.lock" ] || fail "legacy .lock missing"
  for key in fleet queue lifecycle secondmate-sync x-mode; do
    [ -f "$home/state/.locks/$key.lock" ] || fail "key file $key.lock missing"
  done
  owner=$(cat "$home/state/.lock")
  [ "$owner" = "$session_pid" ] || fail "legacy owner mismatch (got $owner expected $session_pid)"
  kill -0 "$owner" 2>/dev/null || fail "legacy owner $owner is not a live process"
  assert_contains "$out" "lock acquired" "default-acquire did not announce success"
  assert_contains "$out" "keys=" "default-acquire did not print the requested keys"
  # status should agree that the legacy lock is held live.
  status=$(run_under_fake_env_with_session "$home" "$fakebin" "$session_pid" "$LOCK" status 2>&1)
  assert_contains "$status" "lock: held by live harness pid $owner" "legacy status disagrees with acquired owner"
  pass "default-acquire writes legacy file + one key file per default key"
}

test_disjoint_keys_acquire_in_parallel() {
  local home fakebin session_pid_a session_pid_b session_pid_blocker out rc owner1
  home="$TMP_ROOT/disjoint"
  mkdir -p "$home/state/.locks"
  fakebin=$(make_fake_ps "$home/fake")
  spawn_live_session_pid "$TMP_ROOT/.session-disjoint-A"
  session_pid_a=$(cat "$TMP_ROOT/.session-disjoint-A")
  LIVE_PIDS+=("$session_pid_a")
  spawn_live_session_pid "$TMP_ROOT/.session-disjoint-B"
  session_pid_b=$(cat "$TMP_ROOT/.session-disjoint-B")
  LIVE_PIDS+=("$session_pid_b")
  spawn_live_session_pid "$TMP_ROOT/.session-disjoint-blocker"
  session_pid_blocker=$(cat "$TMP_ROOT/.session-disjoint-blocker")
  LIVE_PIDS+=("$session_pid_blocker")
  printf '%s\n' "$session_pid_blocker" > "$home/state/.locks/fleet.lock"
  # Re-make the fake ps so FM_TEST_BLOCKER_PID is honored.
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
requested=""
previous=""
for argument in "\$@"; do
  if [ "\$previous" = "-p" ]; then requested=\$argument; break; fi
  previous=\$argument
done
caller=\${FM_TEST_CALLER_PID:-}
session=\${FM_TEST_SESSION_PID:-}
blocker=$session_pid_blocker
case "\$*" in
  *lstart=*)
    if [ "\$requested" = "\$session" ] || [ "\$requested" = "\$blocker" ]; then printf '%s\n' 'Thu Jul 10 08:00:00 2026'
    else printf '%s\n' 'Thu Jul 10 08:01:00 2026'; fi ;;
  *comm=*)
    case "\$requested" in "\$session"|"\$blocker") printf '%s\n' '/usr/local/bin/codex' ;; *) printf '%s\n' '/bin/bash' ;; esac ;;
  *args=*)
    case "\$requested" in "\$session"|"\$blocker") printf '%s\n' 'codex --session-specific' ;; *) printf '%s\n' 'bash' ;; esac ;;
  *ppid=*)
    if [ "\$requested" = "\$caller" ]; then printf '%s\n' "\${session:-1}"
    else printf '%s\n' '1'; fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(run_with_fake_ps "$home" "$fakebin" "$session_pid_b" "$LOCK" --keys "lifecycle,queue" 2>&1) || fail "disjoint acquire exited non-zero: $out"
  rc=0
  run_with_fake_ps "$home" "$fakebin" "$session_pid_b" "$LOCK" --keys "fleet" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "fleet acquire succeeded against a live blocker pid"
  owner1=$(cat "$home/state/.locks/fleet.lock")
  [ "$owner1" = "$session_pid_blocker" ] || fail "disjoint path clobbered the live fleet blocker (got $owner1)"
  pass "disjoint keys acquire in parallel; fleet acquire correctly blocks"
}

test_stale_owner_recovers_per_key() {
  local home fakebin session_pid
  home="$TMP_ROOT/stale"
  mkdir -p "$home/state/.locks"
  fakebin=$(make_fake_ps "$home/fake")
  printf '%s\n' 999999 > "$home/state/.locks/fleet.lock"
  printf '%s\n' 999998 > "$home/state/.locks/queue.lock"
  spawn_live_session_pid "$TMP_ROOT/.session-stale"
  session_pid=$(cat "$TMP_ROOT/.session-stale")
  LIVE_PIDS+=("$session_pid")
  out=$(run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" --keys "fleet,queue" 2>&1) || fail "stale-recovery exit non-zero: $out"
  for key in fleet queue; do
    new=$(cat "$home/state/.locks/$key.lock")
    [ "$new" = "$session_pid" ] || fail "$key lock did not self-recover from stale pid (got $new expected $session_pid)"
  done
  pass "stale per-key pid self-recovers on next acquire"
}

test_includes_honors_requested_set() {
  local home fakebin session_pid
  home="$TMP_ROOT/includes"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  spawn_live_session_pid "$TMP_ROOT/.session-includes"
  session_pid=$(cat "$TMP_ROOT/.session-includes")
  LIVE_PIDS+=("$session_pid")
  rc=0; run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" --keys "lifecycle" --includes "lifecycle" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "--includes K failed when K is in requested set"
  rc=0; run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" --keys "lifecycle" --includes "fleet" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "--includes K returned 0 when K is not in requested set"
  pass "--includes consults the requested key set, not the default set"
}

test_bad_csv_returns_2_and_writes_nothing() {
  local home fakebin session_pid rc
  home="$TMP_ROOT/bad-csv"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  spawn_live_session_pid "$TMP_ROOT/.session-bad"
  session_pid=$(cat "$TMP_ROOT/.session-bad")
  LIVE_PIDS+=("$session_pid")
  rc=0; run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" --keys "" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "empty --keys did not return 2 (got $rc)"
  rc=0; run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" --keys "fleet,Queue" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "uppercase --keys did not return 2 (got $rc)"
  [ -z "$(ls "$home/state/.locks/" 2>/dev/null)" ] || fail "bad csv still wrote a lock file"
  pass "invalid CSV exits 2 and never writes a lock file"
}

test_status_per_key_prints_holders() {
  local home fakebin session_pid out
  home="$TMP_ROOT/status"
  mkdir -p "$home/state/.locks"
  fakebin=$(make_fake_ps "$home/fake")
  # Inject a "dead" pid that the fake ps reports as plain bash (so holder_alive
  # returns 1); the per-key status should print 'stale'.
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
requested=""
previous=""
for argument in "\$@"; do
  if [ "\$previous" = "-p" ]; then requested=\$argument; break; fi
  previous=\$argument
done
caller=\${FM_TEST_CALLER_PID:-}
session=\${FM_TEST_SESSION_PID:-}
case "\$*" in
  *lstart=*)
    if [ "\$requested" = "\$session" ] || [ "\$requested" = "999999" ]; then
      # Same start time for both the live session and the "dead" pid - the
      # test still needs status to recognize the live one as live; only the
      # comm/args check distinguishes them.
      printf '%s\n' 'Thu Jul 10 08:00:00 2026'
    else
      printf '%s\n' 'Thu Jul 10 08:01:00 2026'
    fi ;;
  *comm=*)
    case "\$requested" in
      "\$session") printf '%s\n' '/usr/local/bin/codex' ;;
      *) printf '%s\n' '/bin/bash' ;;
    esac ;;
  *args=*)
    case "\$requested" in "\$session") printf '%s\n' 'codex --session-specific' ;; *) printf '%s\n' 'bash' ;; esac ;;
  *ppid=*)
    if [ "\$requested" = "\$caller" ]; then printf '%s\n' "\${session:-1}"
    else printf '%s\n' '1'; fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' 999999 > "$home/state/.locks/fleet.lock"
  spawn_live_session_pid "$TMP_ROOT/.session-status"
  session_pid=$(cat "$TMP_ROOT/.session-status")
  LIVE_PIDS+=("$session_pid")
  run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" --keys "queue,lifecycle" >/dev/null
  out=$(run_under_fake_env_with_session "$home" "$fakebin" "$session_pid" "$LOCK" status --keys "fleet,queue,lifecycle" 2>&1)
  assert_contains "$out" "key fleet: stale" "stale fleet status missing"
  assert_contains "$out" "key queue: held by live harness" "live queue status missing"
  assert_contains "$out" "key lifecycle: held by live harness" "live lifecycle status missing"
  pass "status --keys reports each requested key with its actual holder"
}

test_legacy_status_unaffected() {
  local home fakebin session_pid out owner
  home="$TMP_ROOT/legacy-status"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$home/fake")
  spawn_live_session_pid "$TMP_ROOT/.session-legacy"
  session_pid=$(cat "$TMP_ROOT/.session-legacy")
  LIVE_PIDS+=("$session_pid")
  rc=0; run_with_fake_ps "$home" "$fakebin" "$session_pid" "$LOCK" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "unflagged default acquire unexpectedly blocked"
  owner=$(cat "$home/state/.lock")
  out=$(run_under_fake_env_with_session "$home" "$fakebin" "$session_pid" "$LOCK" status 2>&1)
  assert_contains "$out" "lock: held by live harness pid $owner" "legacy status line regressed"
  pass "unflagged acquisition still produces the legacy status line"
}

test_default_acquire_writes_legacy_and_keys
test_disjoint_keys_acquire_in_parallel
test_stale_owner_recovers_per_key
test_includes_honors_requested_set
test_bad_csv_returns_2_and_writes_nothing
test_status_per_key_prints_holders
test_legacy_status_unaffected
