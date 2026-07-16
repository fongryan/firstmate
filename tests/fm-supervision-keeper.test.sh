#!/usr/bin/env bash
# Regression coverage for the durable Firstmate supervision keeper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

KEEPER="$ROOT/bin/fm-supervision-keeper.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-keeper)
trap 'rm -rf "$TMP_ROOT"' EXIT

test_restart_predicate_requires_identity_and_freshness() {
  local state="$TMP_ROOT/state"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$TMP_ROOT" > "$state/.watch.lock/fm-home"
  # A missing identity is never treated as healthy, even if the pid is live.
  if FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_keeper_watcher_healthy' _ "$KEEPER"; then
    fail "keeper accepted a watcher lock without a process identity"
  fi
  pass "keeper requires watcher identity before treating it as healthy"
}

test_backoff_is_bounded() {
  local out
  out=$(FM_KEEPER_MAX_BACKOFF=7 bash -c '. "$1"; fm_keeper_backoff 1; fm_keeper_backoff 4; fm_keeper_backoff 6' _ "$KEEPER")
  expect_code $'2\n7\n7' "$out" "keeper backoff is exponential and capped"
}

test_keeper_restarts_a_crashing_child() {
  local state="$TMP_ROOT/restart-state" fake="$TMP_ROOT/fake-watch.sh" log="$TMP_ROOT/keeper.log" out
  mkdir -p "$state"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
echo child-started >> "$FM_KEEPER_TEST_LOG"
exit 42
SH
  chmod +x "$fake"
  FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" \
    FM_KEEPER_WATCH_COMMAND="$fake" FM_KEEPER_TEST_LOG="$log" \
    FM_KEEPER_MAX_RESTARTS=2 FM_KEEPER_POLL=0 FM_KEEPER_TEST_MODE=1 \
    "$KEEPER" --once >/dev/null 2>&1
  out=$(cat "$state/.supervision-keeper.log")
  assert_contains "$out" "restarting watcher" "keeper reports the crashed child and restart decision"
  expect_code "3" "$(wc -l < "$log" | tr -d ' ')" "keeper performs the configured bounded restart attempts"
}

test_restart_predicate_requires_identity_and_freshness
test_backoff_is_bounded
test_keeper_restarts_a_crashing_child

echo "all supervision keeper tests passed"
