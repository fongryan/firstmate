#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-reconcile.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE="$TMP_ROOT/state"; mkdir -p "$STATE"
LIFECYCLE="$ROOT/bin/fm-lifecycle.sh"; RECONCILE="$ROOT/bin/fm-lifecycle-reconcile.sh"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_grep() { grep -F -- "$1" "$2" >/dev/null || fail "$3"; }

register_active() {
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1000 FM_LIFECYCLE_RESTORE=1 \
    "$LIFECYCLE" register "$1" --state active --repo app --owner owner \
    --branch "branch-$1" --worktree "$2" --objective "$1 objective" >/dev/null || fail "register $1 failed"
}

test_reconcile_is_safe_and_explicit() {
  local clean="$TMP_ROOT/clean" dirty="$TMP_ROOT/dirty" missing="$TMP_ROOT/missing"
  mkdir -p "$clean" "$dirty"
  git -C "$clean" init -q
  git -C "$clean" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
  git -C "$dirty" init -q
  git -C "$dirty" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
  printf dirty > "$dirty/file"
  register_active terminal "$clean"
  printf proof > "$TMP_ROOT/proof"
  FM_STATE_OVERRIDE="$STATE" FM_LIFECYCLE_NOW=1001 "$LIFECYCLE" closeout terminal completed --reason shipped --evidence "$TMP_ROOT/proof" >/dev/null || fail "closeout failed"
  register_active dirty "$dirty"
  register_active missing "$missing"

  local out
  out=$(FM_STATE_OVERRIDE="$STATE" "$RECONCILE") || fail "reconcile failed"
  assert_grep 'terminal state=completed action=eligible-return' <(printf '%s\n' "$out") "clean terminal worktree not eligible"
  assert_grep 'dirty state=active action=protected-dirty' <(printf '%s\n' "$out") "dirty worktree not protected"
  assert_grep 'missing state=active action=protected-missing' <(printf '%s\n' "$out") "missing worktree not surfaced"
  [ -d "$clean" ] || fail "read-only reconcile removed clean worktree"
  [ -e "$dirty/file" ] || fail "read-only reconcile damaged dirty worktree"
  pass "reconciliation classifies worktrees without destructive mutation"
}

test_reconcile_is_safe_and_explicit
