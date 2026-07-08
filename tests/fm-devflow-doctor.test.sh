#!/usr/bin/env bash
# Behavior tests for bin/fm-devflow-doctor.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$ROOT/bin/fm-devflow-doctor.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-devflow-doctor-tests)

new_home() {
  local name=$1 root home projects state data
  root="$TMP_ROOT/$name/root"
  home="$TMP_ROOT/$name/home"
  projects="$home/projects"
  state="$home/state"
  data="$home/data"
  mkdir -p "$root" "$home" "$projects" "$state" "$data"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s|%s|%s\n' "$root" "$home" "$projects" "$state" "$data"
}

seed_required_artifacts() {
  local data=$1
  cat > "$data/proof-packet-template.md" <<'EOF'
# Proof Packet
Intent
Touched files
Proof commands
Residual risks
EOF
  cat > "$data/recovery-playbook.md" <<'EOF'
# Recovery
running
idle
waiting-for-prompt
report-written-no-done
stale
failed
EOF
  cat > "$data/security-hygiene.md" <<'EOF'
# Security
No secrets
Dangerous commands
External live proof
EOF
  cat > "$data/repo-adoption-matrix.md" <<'EOF'
# Matrix
Mode
Canonical proof
Allowed automation
Secondmate
EOF
}

seed_project() {
  local projects=$1 name=$2 mode=$3 data=$4 repo bare
  repo="$projects/$name"
  bare=$(mktemp -d "$TMP_ROOT/$name.remote.XXXXXX")
  rm -rf "$bare"
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$bare"
  if [ "$mode" = no-mistakes ]; then
    git -C "$repo" remote add no-mistakes "file://$TMP_ROOT/$name-no-mistakes.git"
  fi
  printf -- '- %s [%s] - test project (added 2026-07-07)\n' "$name" "$mode" >> "$data/projects.md"
}

test_repo_only_passes_with_required_artifacts() {
  local rec root home projects state data out status
  rec=$(new_home pass)
  IFS='|' read -r root home projects state data <<EOF
$rec
EOF
  seed_required_artifacts "$data"
  seed_project "$projects" enterprise-code no-mistakes "$data"
  : > "$data/secondmates.md"

  status=0
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" FM_PROJECTS_OVERRIDE="$projects" PATH="$BASE_PATH" "$DOCTOR" --repo-only) || status=$?
  expect_code 0 "$status" "doctor repo-only happy path"
  assert_contains "$out" "firstmate devflow doctor: ok" "doctor did not report ok"
  assert_contains "$out" $'ok\tgates\tenterprise-code\tno-mistakes remote present' "doctor did not verify no-mistakes remote"
  assert_contains "$out" $'ok\tartifacts\trepo-adoption-matrix' "doctor did not verify adoption matrix"
  pass "fm-devflow-doctor repo-only validates required local surfaces"
}

test_missing_artifacts_fail_and_json_is_valid_shape() {
  local rec root home projects state data out status
  rec=$(new_home missing)
  IFS='|' read -r root home projects state data <<EOF
$rec
EOF
  seed_project "$projects" enterprise-code no-mistakes "$data"

  status=0
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" FM_PROJECTS_OVERRIDE="$projects" PATH="$BASE_PATH" "$DOCTOR" --repo-only --json) || status=$?
  [ "$status" -ne 0 ] || fail "doctor should fail when required artifacts are missing"
  assert_contains "$out" '"status":"fail"' "json did not expose fail status"
  assert_contains "$out" '"subject":"proof-packet"' "json did not name missing proof packet"
  assert_contains "$out" '"subject":"repo-adoption-matrix"' "json did not name missing matrix"
  pass "fm-devflow-doctor fails loudly for missing required local surfaces"
}

test_repo_mode_gate_checks() {
  local rec root home projects state data out status repo
  rec=$(new_home gates)
  IFS='|' read -r root home projects state data <<EOF
$rec
EOF
  seed_required_artifacts "$data"
  repo="$projects/brain"
  fm_git_init_commit "$repo"
  printf -- '- brain [no-mistakes] - missing gate project (added 2026-07-07)\n' > "$data/projects.md"

  status=0
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" FM_PROJECTS_OVERRIDE="$projects" PATH="$BASE_PATH" "$DOCTOR" --repo-only) || status=$?
  [ "$status" -ne 0 ] || fail "doctor should fail when no-mistakes remote is missing"
  assert_contains "$out" $'fail\tgates\tbrain\tno-mistakes mode but remote is missing' "doctor did not flag missing no-mistakes remote"
  pass "fm-devflow-doctor enforces project mode gate invariants"
}

test_secondmate_registry_without_final_newline_is_checked() {
  local rec root home projects state data out status
  rec=$(new_home secondmate-eof)
  IFS='|' read -r root home projects state data <<EOF
$rec
EOF
  seed_required_artifacts "$data"
  seed_project "$projects" enterprise-code no-mistakes "$data"
  printf -- '- missing-sm - no final newline' > "$data/secondmates.md"

  status=0
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" FM_PROJECTS_OVERRIDE="$projects" PATH="$BASE_PATH" "$DOCTOR" --repo-only) || status=$?
  [ "$status" -ne 0 ] || fail "doctor should fail when final secondmate line has no matching meta"
  assert_contains "$out" $'fail\tsecondmates\tmissing-sm\tregistry entry has no state meta' "doctor missed the no-newline secondmate registry entry"
  pass "fm-devflow-doctor checks final secondmate registry line without trailing newline"
}

test_repo_only_passes_with_required_artifacts
test_missing_artifacts_fail_and_json_is_valid_shape
test_repo_mode_gate_checks
test_secondmate_registry_without_final_newline_is_checked
