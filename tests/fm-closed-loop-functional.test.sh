#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-closed-loop.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE="$TMP_ROOT/state"; mkdir -p "$STATE"
LIFECYCLE="$ROOT/bin/fm-lifecycle.sh"; REAPER="$ROOT/bin/fm-lifecycle-reap.sh"; RECONCILE="$ROOT/bin/fm-lifecycle-reconcile.sh"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

test_closed_loop_reaches_terminal_states() {
  local wt="$TMP_ROOT/task-wt" proof="$TMP_ROOT/proof" out
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
  printf proof > "$proof"

  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1000 FM_LIFECYCLE_RESTORE=1 FM_LIFECYCLE_HEARTBEAT_TTL=10 FM_LIFECYCLE_HEARTBEAT_GRACE=5 \
    "$LIFECYCLE" register orphan --state active --repo app --owner orphan \
    --branch orphan --worktree "$TMP_ROOT/missing" --objective orphan >/dev/null || fail "register orphan failed"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=2000 "$REAPER" --apply >/dev/null || fail "reaper failed"
  grep -Fx 'state=interrupted' "$STATE/orphan.lifecycle" >/dev/null || fail "orphan did not reach interrupted"

  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1000 FM_LIFECYCLE_RESTORE=1 \
    "$LIFECYCLE" register shipped --state active --repo app --owner ship \
    --branch shipped --worktree "$wt" --objective shipped >/dev/null || fail "register shipped failed"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1001 \
    "$LIFECYCLE" closeout shipped completed --reason proof-passed --evidence "$proof" >/dev/null || fail "closeout failed"
  out=$(FM_STATE_OVERRIDE="$STATE" "$RECONCILE") || fail "reconcile failed"
  printf '%s\n' "$out" | grep -F 'shipped state=completed action=eligible-return' >/dev/null || fail "terminal task not eligible for cleanup"
  pass "functional lifecycle loop reaps orphans and closes proven work"
}

test_reaper_scales_across_many_records() {
  local i start elapsed
  for i in $(seq 1 250); do
    cat > "$STATE/scale-$i.lifecycle" <<EOF
schema=fm-lifecycle.v1
id=scale-$i
state=active
created_at=1000
updated_at=1000
heartbeat_at=1000
heartbeat_seq=0
transition_seq=1
owner=scale
repo=app
branch=scale-$i
worktree=$TMP_ROOT/missing-$i
objective=scale-$i
heartbeat_ttl=10
heartbeat_grace=5
last_reason=registered
last_evidence=
EOF
  done
  start=$(date +%s)
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=2000 "$REAPER" --dry-run >/dev/null || fail "scale dry-run failed"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 10 ] || fail "250-record dry-run exceeded 10s (elapsed=$elapsed)"
  pass "reaper scans 250 records within bounded time"
}

test_closed_loop_reaches_terminal_states
test_reaper_scales_across_many_records
