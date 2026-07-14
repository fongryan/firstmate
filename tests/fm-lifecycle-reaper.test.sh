#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-reaper.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
LIFECYCLE="$ROOT/bin/fm-lifecycle.sh"
REAPER="$ROOT/bin/fm-lifecycle-reap.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_grep() { grep -F -- "$1" "$2" >/dev/null || fail "$3"; }

register() {
  local id=$1 state=$2 now=$3
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW="$now" FM_LIFECYCLE_RESTORE=1 \
    FM_LIFECYCLE_HEARTBEAT_TTL=10 FM_LIFECYCLE_HEARTBEAT_GRACE=5 \
    "$LIFECYCLE" register "$id" --state "$state" --repo app --owner "owner-$id" \
    --branch "branch-$id" --worktree "$TMP_ROOT/$id" --objective "$id objective" >/dev/null \
    || fail "register $id failed"
}

test_dry_run_is_non_mutating_and_apply_is_idempotent() {
  register stale active 1000
  register fresh active 1009
  register queued queued 1000

  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1020 "$REAPER" --dry-run) \
    || fail "dry-run failed"
  assert_grep 'stale' <(printf '%s\n' "$out") "dry-run did not identify stale task"
  assert_grep 'active' "$STATE/stale.lifecycle" "dry-run mutated stale task"
  assert_grep 'active' "$STATE/fresh.lifecycle" "fresh task changed during dry-run"

  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1020 "$REAPER" --apply >/dev/null \
    || fail "apply failed"
  assert_grep 'state=interrupted' "$STATE/stale.lifecycle" "stale task not interrupted"
  [ "$(wc -l < "$STATE/stale.events" | tr -d ' ')" = 2 ] || fail "expected one reaper transition"

  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1020 "$REAPER" --apply >/dev/null \
    || fail "second apply failed"
  [ "$(wc -l < "$STATE/stale.events" | tr -d ' ')" = 2 ] || fail "second apply duplicated transition"
  assert_grep 'state=active' "$STATE/fresh.lifecycle" "fresh task was reaped"
  assert_grep 'state=queued' "$STATE/queued.lifecycle" "queued task was reaped"
  pass "reaper is dry-run safe and apply-idempotent"
}

test_interrupted_task_can_be_explicitly_restarted() {
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=3000 FM_LIFECYCLE_RESTORE=1 FM_LIFECYCLE_HEARTBEAT_TTL=10 FM_LIFECYCLE_HEARTBEAT_GRACE=5 \
    "$LIFECYCLE" register restartable --state active --repo app --owner restart \
    --branch restart --worktree "$TMP_ROOT/restart" --objective restart >/dev/null || fail "restart task register failed"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=4000 "$REAPER" --apply >/dev/null || fail "restart task reap failed"
  assert_grep 'state=interrupted' "$STATE/restartable.lifecycle" "restart task not interrupted"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=4010 FM_LIFECYCLE_RESTORE=1 \
    "$LIFECYCLE" register restartable --state active --repo app --owner restart \
    --branch restart --worktree "$TMP_ROOT/restart" --objective restart >/dev/null || fail "explicit restart failed"
  assert_grep 'state=active' "$STATE/restartable.lifecycle" "explicit restart did not reactivate"
  pass "only explicit restore can restart interrupted work"
}

test_live_endpoint_protection_skips_stale_record() {
  register live-endpoint active 5000
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=5020 \
    FM_LIFECYCLE_PROTECTED_IDS=live-endpoint "$REAPER" --apply) \
    || fail "protected apply failed"
  assert_grep 'action=protected' <(printf '%s\n' "$out") \
    "reaper did not report the live endpoint protection"
  assert_grep 'state=active' "$STATE/live-endpoint.lifecycle" \
    "live endpoint protection reaped an active record"
  [ "$(wc -l < "$STATE/live-endpoint.events" | tr -d ' ')" = 1 ] \
    || fail "protected record unexpectedly received a transition"
  pass "reaper protects records whose endpoint was observed alive during session start"
}

test_dry_run_is_non_mutating_and_apply_is_idempotent
test_interrupted_task_can_be_explicitly_restarted
test_live_endpoint_protection_skips_stale_record
