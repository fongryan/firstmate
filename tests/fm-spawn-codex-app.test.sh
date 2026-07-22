#!/usr/bin/env bash
# Spawn integration: Codex App starts a durable thread in the isolated
# worktree and records the lease credentials needed by later fm-send/teardown.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-app)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
ID=codex-app-spawn
WORKTREES="$TMP_ROOT/worktrees"
FAKE="$TMP_ROOT/fake-bridge.mjs"
LOG="$TMP_ROOT/bridge.log"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$WORKTREES"
printf '%s\n' codex > "$HOME_DIR/config/crew-harness"
printf 'Complete the isolated Codex App smoke task.\n' > "$HOME_DIR/data/$ID/brief.md"
touch "$HOME_DIR/state/.last-watcher-beat"
fm_git_init_commit "$PROJECT"
cat > "$FAKE" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';
fs.appendFileSync(process.env.FM_TEST_BRIDGE_LOG, process.argv.slice(2).join('\t') + '\n');
const action = process.argv[process.argv.indexOf('--action') + 1];
if (action !== 'create') process.exit(2);
console.log(JSON.stringify({ threadId: 'thread-spawn-smoke', token: 'lease-spawn-smoke' }));
NODE
chmod +x "$FAKE"

out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
  FM_WORKTREE_ROOT="$WORKTREES" FM_CODEX_APP_BRIDGE_BIN="$FAKE" FM_TEST_BRIDGE_LOG="$LOG" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --harness codex --backend codex-app 2>&1) \
  || fail "codex-app spawn failed: $out"

META="$HOME_DIR/state/$ID.meta"
assert_present "$META" 'codex-app spawn did not write task metadata'
assert_grep 'backend=codex-app' "$META" 'metadata did not record Codex App backend'
assert_grep 'window=thread-spawn-smoke' "$META" 'metadata target must be the durable thread id'
assert_grep 'codex_app_thread_id=thread-spawn-smoke' "$META" 'metadata missing durable Codex thread id'
assert_grep 'codex_app_lease_token=lease-spawn-smoke' "$META" 'metadata missing bridge lease token'
assert_grep $'--status\t'"$HOME_DIR"'/state/'"$ID"'.status' "$LOG" 'spawn did not give the bridge the canonical status return path'
assert_contains "$out" "spawned $ID" 'spawn did not report success'
pass 'fm-spawn creates a Codex App task with durable thread and lease metadata'
