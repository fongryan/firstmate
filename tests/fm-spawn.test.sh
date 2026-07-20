#!/usr/bin/env bash
# Integration coverage for autopilot owner propagation through fm-spawn.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn)

make_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'codex-cli 0.144.2'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/codex"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

run_spawn_case() {
  local name=$1 owner=${2:-} case_dir home project worktree fakebin log id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  log="$case_dir/launch.log"
  id="spawn-$name"
  worktree="$case_dir/worktrees/$id"
  fakebin=$(make_fakebin "$case_dir/fake")
  if [ "${FM_TEST_LEGACY_CODEX:-0}" = 1 ]; then
    cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.3'; exit 0 ;;
esac
exit 0
SH
    chmod +x "$fakebin/codex"
  fi
  mkdir -p "$home/config" "$home/data/$id" "$home/projects" "$home/state"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_init_commit "$project"
  mkdir -p "$case_dir/worktrees"
  touch "$home/state/.last-watcher-beat"
  : > "$log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_WORKTREE_ROOT="$case_dir/worktrees" \
    FM_CODEX_CLI="${FM_TEST_CODEX_CLI:-}" \
    FM_CODEX_CLI_FALLBACKS="${FM_TEST_CODEX_FALLBACKS:-}" \
    FM_FAKE_PANE_PATH="$worktree" FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' \
    FM_AUTOPILOT_LOCK_OWNER_PID="$owner" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --harness codex >/dev/null 2>&1 \
    || fail "fm-spawn failed for $name"
  printf '%s\n' "$log"
}

test_legacy_codex_shadow_uses_verified_fallback_cli() {
  local case_dir official official_abs log
  case_dir="$TMP_ROOT/verified-codex"
  mkdir -p "$case_dir"
  official="$case_dir/codex-official"
  cat > "$official" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'codex-cli 0.144.2'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$official"
  official_abs="$(cd "$(dirname "$official")" && pwd -P)/$(basename "$official")"
  log=$(FM_TEST_LEGACY_CODEX=1 FM_TEST_CODEX_FALLBACKS="$official" run_spawn_case verified-codex-cli)
  assert_grep "'$official_abs' --dangerously-bypass-approvals-and-sandbox" "$log" \
    "spawn did not reject a shadowing legacy codex package and use the compatible fallback"
  assert_no_grep 'send-keys.* codex --dangerously-bypass' "$log" \
    "spawn still emitted the ambiguous bare codex command"
  pass "fm-spawn rejects a legacy PATH codex and uses a verified compatible fallback"
}

test_relative_explicit_codex_cli_is_canonicalized() {
  local case_dir case_dir_abs resolved
  case_dir="$TMP_ROOT/relative-explicit-codex"
  mkdir -p "$case_dir/bin" "$case_dir/different-target-cwd"
  cat > "$case_dir/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'codex-cli 1.2.3'
SH
  chmod +x "$case_dir/bin/codex"
  case_dir_abs=$(cd "$case_dir" && pwd -P)
  resolved=$(cd "$case_dir" && FM_CODEX_CLI=./bin/codex "$ROOT/bin/fm-harness.sh" codex-cli)
  [ "$resolved" = "$case_dir_abs/bin/codex" ] \
    || fail "relative Codex override was not canonicalized: $resolved"
  (cd "$case_dir/different-target-cwd" && "$resolved" --version >/dev/null) \
    || fail "canonical Codex path did not survive a different target cwd"
  pass "fm-harness canonicalizes a relative Codex override for worktree launches"
}

test_invalid_explicit_codex_cli_fails_closed() {
  local case_dir legacy rc out
  case_dir="$TMP_ROOT/invalid-explicit-codex"
  mkdir -p "$case_dir"
  legacy="$case_dir/codex-legacy"
  cat > "$legacy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '0.2.3'
SH
  chmod +x "$legacy"
  set +e
  out=$(FM_CODEX_CLI="$legacy" "$ROOT/bin/fm-harness.sh" codex-cli 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "invalid explicit Codex CLI must fail closed"
  assert_contains "$out" "is not an executable Codex-compatible CLI" \
    "invalid explicit Codex CLI did not explain the verification failure"
  pass "fm-harness rejects an explicit legacy/non-compatible Codex executable"
}

test_all_codex_candidates_invalid_fails_closed() {
  local case_dir fakebin rc out
  case_dir="$TMP_ROOT/all-codex-invalid"
  fakebin=$(make_fakebin "$case_dir/fake")
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '0.2.3'
SH
  chmod +x "$fakebin/codex"
  set +e
  out=$(PATH="$fakebin:/usr/bin:/bin" FM_CODEX_CLI='' FM_CODEX_CLI_FALLBACKS="$case_dir/missing" \
    "$ROOT/bin/fm-harness.sh" codex-cli 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "all invalid Codex candidates must fail closed"
  assert_contains "$out" "no verified Codex-compatible CLI found" \
    "all-invalid candidate failure did not explain the resolution blocker"
  pass "fm-harness fails closed when PATH and every configured Codex fallback are invalid"
}

test_live_autopilot_generation_reaches_every_child() {
  local first_log second_log owner identity
  sleep 30 & owner=$!
  identity=$(LC_ALL=C ps -o lstart= -p "$owner" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  first_log=$(run_spawn_case with-owner-first "$owner")
  second_log=$(run_spawn_case with-owner-second "$owner")
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  assert_grep "export FM_AUTOPILOT_LOCK_OWNER_PID='$owner'" "$first_log" "first child missed owner PID"
  assert_grep "export FM_AUTOPILOT_LOCK_OWNER_IDENTITY='$identity'" "$first_log" "first child missed birth identity"
  assert_grep "export FM_AUTOPILOT_LOCK_OWNER_PID='$owner'" "$second_log" "second child missed owner PID"
  assert_grep "export FM_AUTOPILOT_LOCK_OWNER_IDENTITY='$identity'" "$second_log" "second child missed stable birth identity"
  pass "all dispatched children inherit one live autopilot owner generation"
}

test_dead_or_absent_owner_never_leaks() {
  local absent_log dead_log
  absent_log=$(run_spawn_case absent-owner)
  dead_log=$(run_spawn_case dead-owner 999999)
  assert_no_grep 'FM_AUTOPILOT_LOCK_OWNER_' "$absent_log" "ordinary spawn leaked owner markers"
  assert_no_grep 'FM_AUTOPILOT_LOCK_OWNER_' "$dead_log" "dead owner markers reached a child"
  pass "ordinary and dead-owner spawns omit autopilot markers"
}

test_live_autopilot_generation_reaches_every_child
test_dead_or_absent_owner_never_leaks
test_legacy_codex_shadow_uses_verified_fallback_cli
test_relative_explicit_codex_cli_is_canonicalized
test_invalid_explicit_codex_cli_fails_closed
test_all_codex_candidates_invalid_fails_closed
