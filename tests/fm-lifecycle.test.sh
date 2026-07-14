#!/usr/bin/env bash
# Unit tests for the closed-loop lifecycle contract.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$ROOT/bin/fm-lifecycle-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

expect_true() { "$@" || fail "expected success: $*"; }
expect_false() { if "$@"; then fail "expected failure: $*"; fi; }
expect_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

test_state_vocabulary() {
  local state
  for state in queued active blocked needs-decision ready-for-review interrupted completed superseded abandoned; do
    expect_true fm_lifecycle_is_state "$state"
  done
  expect_false fm_lifecycle_is_state unknown
  pass "state vocabulary is explicit and closed"
}

test_transition_matrix() {
  expect_true fm_lifecycle_transition_allowed queued active
  expect_true fm_lifecycle_transition_allowed active blocked
  expect_true fm_lifecycle_transition_allowed blocked active
  expect_true fm_lifecycle_transition_allowed active interrupted
  expect_true fm_lifecycle_transition_allowed ready-for-review completed
  expect_true fm_lifecycle_transition_allowed active superseded
  expect_false fm_lifecycle_transition_allowed completed active
  expect_false fm_lifecycle_transition_allowed queued completed
  pass "transition matrix rejects resurrection and skips"
}

test_terminal_and_id_validation() {
  expect_true fm_lifecycle_is_terminal completed
  expect_true fm_lifecycle_is_terminal interrupted
  expect_false fm_lifecycle_is_terminal active
  expect_true fm_lifecycle_valid_id closed-loop-1
  expect_false fm_lifecycle_valid_id '../escape'
  expect_false fm_lifecycle_valid_id 'has space'
  pass "terminal states and task ids are fail-closed"
}

test_reason_and_time_are_safe() {
  local reason now
  reason=$(fm_lifecycle_clean_field $'bad\tvalue\nnext')
  expect_eq 'bad value next' "$reason" "control characters must be removed"
  now=$(FM_LIFECYCLE_NOW=1700000000 fm_lifecycle_now)
  expect_eq 1700000000 "$now" "injected clock must be deterministic"
  pass "receipt fields and time source are deterministic"
}

test_state_vocabulary
test_transition_matrix
test_terminal_and_id_validation
test_reason_and_time_are_safe
