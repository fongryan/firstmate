#!/usr/bin/env bash
# Contract tests for the real Codex App backend adapter.  Its target is the
# durable thread id; mutable operations authenticate with the task lease token.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-codex-app)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
LOG="$TMP_ROOT/bridge.log"
FAKE="$TMP_ROOT/fake-bridge.mjs"
cat > "$FAKE" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FM_TEST_BRIDGE_LOG, args.join('\t') + '\n');
const action = args[args.indexOf('--action') + 1];
if (action === 'capture') console.log(JSON.stringify({ text: 'captured transcript' }));
else if (action === 'exists') console.log(JSON.stringify({ exists: true }));
else console.log(JSON.stringify({ accepted: true, archived: true }));
NODE
chmod +x "$FAKE"

fm_write_meta "$HOME_DIR/state/alpha.meta" \
  'window=thread-alpha' \
  'backend=codex-app' \
  'codex_app_thread_id=thread-alpha' \
  'codex_app_lease_token=lease-token-alpha' \
  'harness=codex'

FM_HOME="$HOME_DIR" FM_CODEX_APP_BRIDGE_BIN="$FAKE" FM_TEST_BRIDGE_LOG="$LOG" \
  bash -c '. "$0/bin/fm-backend.sh"; fm_backend_capture codex-app thread-alpha 40' "$ROOT" \
  > "$TMP_ROOT/capture.txt" || fail 'codex-app capture failed'
[ "$(cat "$TMP_ROOT/capture.txt")" = 'captured transcript' ] || fail 'codex-app capture did not return bridge transcript'
assert_grep $'--action\tcapture' "$LOG" 'capture did not call bridge capture action'

FM_HOME="$HOME_DIR" FM_CODEX_APP_BRIDGE_BIN="$FAKE" FM_TEST_BRIDGE_LOG="$LOG" \
  bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit codex-app thread-alpha "operator message" 1 0 0' "$ROOT" \
  > "$TMP_ROOT/send.txt" || fail 'codex-app send failed'
[ "$(cat "$TMP_ROOT/send.txt")" = empty ] || fail 'codex-app send must return the generic accepted verdict'
assert_grep $'--action\tsend' "$LOG" 'send did not call bridge send action'
assert_grep $'--token\tlease-token-alpha' "$LOG" 'send did not authenticate with the durable task lease'

FM_HOME="$HOME_DIR" FM_CODEX_APP_BRIDGE_BIN="$FAKE" FM_TEST_BRIDGE_LOG="$LOG" \
  bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists codex-app thread-alpha' "$ROOT" \
  || fail 'codex-app target existence should use bridge read authority'

FM_HOME="$HOME_DIR" FM_CODEX_APP_BRIDGE_BIN="$FAKE" FM_TEST_BRIDGE_LOG="$LOG" \
  bash -c '. "$0/bin/fm-backend.sh"; fm_backend_kill codex-app thread-alpha' "$ROOT" \
  || fail 'codex-app archive failed'
assert_grep $'--action\tarchive' "$LOG" 'kill must archive the Codex thread rather than kill a shared app-server PID'

pass 'codex-app backend routes capture/send/existence/archive through the durable thread bridge'
