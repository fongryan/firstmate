#!/usr/bin/env bash
# Focused behavior tests for autopilot owner propagation through fm-spawn.sh.
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
  display-message) printf '%s\n' 'firstmate'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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
  printf '%s\n' 'codex' > "$home/config/crew-harness"
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

test_autopilot_owner_is_exported_to_harness() {
  local log
  log=$(run_spawn_case with-owner 424242)
  assert_grep "export FM_AUTOPILOT_LOCK_OWNER_PID='424242'" "$log" "fm-spawn did not export the autopilot owner into the harness pane"
  pass "fm-spawn propagates the autopilot loop owner into the dispatched harness"
}

test_ordinary_spawn_does_not_export_autopilot_owner() {
  local log
  log=$(run_spawn_case without-owner)
  assert_not_contains "$(cat "$log")" 'FM_AUTOPILOT_LOCK_OWNER_PID' "ordinary fm-spawn leaked an autopilot owner marker"
  pass "ordinary fm-spawn leaves the autopilot owner marker absent"
}

test_autopilot_owner_is_exported_to_harness
test_ordinary_spawn_does_not_export_autopilot_owner
