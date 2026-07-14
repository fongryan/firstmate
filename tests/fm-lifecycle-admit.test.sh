#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-admit.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
LIFECYCLE="$ROOT/bin/fm-lifecycle.sh"
ADMIT="$ROOT/bin/fm-lifecycle-admit.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

register() {
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1000 FM_LIFECYCLE_RESTORE=1 \
    "$LIFECYCLE" register "$1" --state active --repo app --owner owner \
    --branch "branch-$1" --worktree "$TMP_ROOT/$1" --objective "$2" >/dev/null \
    || fail "register failed"
}

test_admission() {
  register existing "ship auth"
  local out status
  out=$(FM_STATE_OVERRIDE="$STATE" "$ADMIT" --repo app --objective "ship auth" --wip 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate active objective should be rejected"
  case "$out" in *duplicate*) : ;; *) fail "duplicate rejection lacks reason" ;; esac

  out=$(FM_STATE_OVERRIDE="$STATE" "$ADMIT" --repo app --objective "ship billing" --wip 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "wip exhaustion should be rejected"
  case "$out" in *wip*) : ;; *) fail "wip rejection lacks reason" ;; esac

  out=$(FM_STATE_OVERRIDE="$STATE" "$ADMIT" --repo app --objective "ship billing" --wip 2 2>&1) \
    || fail "available WIP slot should admit"
  case "$out" in *admitted*) : ;; *) fail "admission output missing" ;; esac
  pass "admission rejects duplicates and WIP overflow"
}

test_admission
