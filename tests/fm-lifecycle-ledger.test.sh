#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-ledger.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
LIFECYCLE="$ROOT/bin/fm-lifecycle.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_grep() { grep -F -- "$1" "$2" >/dev/null || fail "$3"; }

test_register_and_transition() {
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000000 \
    "$LIFECYCLE" register task-a --repo app --owner crew-a --branch codex/task-a \
    --worktree "$TMP_ROOT/worktree" --objective "ship a" >/dev/null \
    || fail "register failed"
  [ -f "$STATE/task-a.lifecycle" ] || fail "current lifecycle record missing"
  assert_grep 'state=queued' "$STATE/task-a.lifecycle" "register should start queued"
  assert_grep 'heartbeat_at=1700000000' "$STATE/task-a.lifecycle" "register should seed heartbeat"

  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000010 \
    "$LIFECYCLE" transition task-a active --reason admitted --evidence intake >/dev/null \
    || fail "transition failed"
  assert_grep 'state=active' "$STATE/task-a.lifecycle" "transition should update state"
  [ "$(wc -l < "$STATE/task-a.events" | tr -d ' ')" = 2 ] || fail "expected register and transition receipts"
  pass "register and transition persist current state plus receipts"
}

test_heartbeat_is_monotonic_and_closeout_requires_evidence() {
  local status
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000020 \
    "$LIFECYCLE" heartbeat task-a --owner crew-a >/dev/null || fail "heartbeat failed"
  assert_grep 'heartbeat_at=1700000020' "$STATE/task-a.lifecycle" "heartbeat did not update"

  set +e
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000030 \
    "$LIFECYCLE" closeout task-a completed --reason done >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "closeout without evidence must fail"

  printf 'proof\n' > "$TMP_ROOT/proof.txt"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000030 \
    "$LIFECYCLE" closeout task-a completed --reason done --evidence "$TMP_ROOT/proof.txt" >/dev/null \
    || fail "closeout with evidence failed"
  assert_grep 'state=completed' "$STATE/task-a.lifecycle" "closeout did not become terminal"
  pass "heartbeat and evidence-gated closeout work"
}

test_concurrent_heartbeats_do_not_corrupt_state() {
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000040 FM_LIFECYCLE_RESTORE=1 \
    "$LIFECYCLE" register concurrent --state active --repo app --owner crew-c \
    --branch concurrent --worktree "$TMP_ROOT/concurrent" --objective concurrent >/dev/null \
    || fail "concurrent task registration failed"
  local i
  for i in $(seq 1 8); do
    FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1700000050 \
      "$LIFECYCLE" heartbeat concurrent --owner crew-c >/dev/null &
  done
  wait
  grep -Eq '^heartbeat_at=1700000050$' "$STATE/concurrent.lifecycle" || fail "concurrent heartbeat lost"
  grep -Eq '^heartbeat_seq=[1-8]$' "$STATE/concurrent.lifecycle" || fail "concurrent heartbeat sequence corrupted"
  grep -Eq '^[^=]+=.*$' "$STATE/concurrent.lifecycle" || fail "lifecycle record is malformed"
  pass "per-task lock keeps concurrent heartbeat writes valid"
}

test_register_and_transition
test_heartbeat_is_monotonic_and_closeout_requires_evidence
test_concurrent_heartbeats_do_not_corrupt_state
