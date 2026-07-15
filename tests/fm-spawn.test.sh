#!/usr/bin/env bash
# Integration coverage for autopilot owner propagation through fm-spawn.sh.
set -u

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
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

run_spawn_case() {
  local name=$1 owner=${2:-} case_dir home project worktree fakebin log id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  log="$case_dir/launch.log"
  id="spawn-$name"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/config" "$home/data/$id" "$home/projects" "$home/state"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$worktree" FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' \
    FM_AUTOPILOT_LOCK_OWNER_PID="$owner" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --harness codex >/dev/null 2>&1 \
    || fail "fm-spawn failed for $name"
  printf '%s\n' "$log"
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
