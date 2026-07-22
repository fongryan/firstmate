#!/usr/bin/env bash
# Codex App runtime backend.  A task target is a durable Codex thread id, not
# a PID: Codex Desktop's app-server is shared by unrelated Desktop threads.

fm_backend_codex_app_bridge_bin() {
  printf '%s' "${FM_CODEX_APP_BRIDGE_BIN:-$FM_ROOT/bin/fm-codex-app-bridge.mjs}"
}

fm_backend_codex_app_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=codex-app requires node" >&2; return 1; }
  command -v codex >/dev/null 2>&1 || { echo "error: backend=codex-app requires the Codex CLI bundled with Codex Desktop" >&2; return 1; }
  [ -f "$(fm_backend_codex_app_bridge_bin)" ] || { echo "error: Codex App bridge is missing" >&2; return 1; }
}

fm_backend_codex_app_call() {  # bridge flags, including --action
  local bridge
  bridge=$(fm_backend_codex_app_bridge_bin)
  node "$bridge" call --home "$FM_HOME" "$@"
}

fm_backend_codex_app_create() {  # <task-id> <cwd> <prompt> <status-path> -> thread<TAB>lease-token
  local task=$1 cwd=$2 prompt=$3 status_path=$4 out thread token
  fm_backend_codex_app_tool_check || return 1
  out=$(fm_backend_codex_app_call --action create --task "$task" --cwd "$cwd" --prompt "$prompt" --status "$status_path") || return 1
  thread=$(printf '%s' "$out" | fm_backend_codex_app_json_field threadId) || return 1
  token=$(printf '%s' "$out" | fm_backend_codex_app_json_field token) || return 1
  printf '%s\t%s' "$thread" "$token"
}

fm_backend_codex_app_json_field() {  # <field>
  node -e 'const fs=require("fs");const v=JSON.parse(fs.readFileSync(0,"utf8"));const x=process.argv[1].split(".").reduce((a,k)=>a&&a[k],v);if(x===undefined||x===null)process.exit(1);process.stdout.write(String(x));' "$1"
}

fm_backend_codex_app_task_for_thread() {  # <thread-id> -> task id + token, tab separated
  local thread=$1 meta recorded task token
  for meta in "$FM_HOME/state"/*.meta; do
    [ -e "$meta" ] || continue
    recorded=$(grep '^codex_app_thread_id=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$recorded" = "$thread" ] || continue
    task=${meta##*/}; task=${task%.meta}
    token=$(grep '^codex_app_lease_token=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$token" ] || { echo "error: missing codex_app_lease_token in $meta" >&2; return 1; }
    printf '%s\t%s' "$task" "$token"
    return 0
  done
  echo "error: no codex-app metadata owns thread $thread" >&2
  return 1
}

fm_backend_codex_app_capture() {  # <thread> <lines>
  local thread=$1 lines=$2 out
  out=$(fm_backend_codex_app_call --action capture --thread "$thread" --lines "$lines") || return 1
  printf '%s' "$out" | fm_backend_codex_app_json_field text
}

fm_backend_codex_app_send_text_submit() {  # <thread> <text> <retries> <sleep> <settle>
  local thread=$1 text=$2 task_token task token
  task_token=$(fm_backend_codex_app_task_for_thread "$thread") || return 1
  task=${task_token%%$'\t'*}; token=${task_token#*$'\t'}
  fm_backend_codex_app_call --action send --task "$task" --token "$token" --text "$text" >/dev/null || return 1
  printf 'empty'
}

fm_backend_codex_app_send_key() {
  echo 'error: Codex App threads do not expose terminal key injection; send text through fm-send instead' >&2
  return 1
}

fm_backend_codex_app_kill() {  # <thread>
  local thread=$1 task_token task token
  task_token=$(fm_backend_codex_app_task_for_thread "$thread") || return 1
  task=${task_token%%$'\t'*}; token=${task_token#*$'\t'}
  fm_backend_codex_app_call --action archive --task "$task" --token "$token" >/dev/null
}

fm_backend_codex_app_target_exists() {  # <thread>
  local out exists
  out=$(fm_backend_codex_app_call --action exists --thread "$1") || return 1
  exists=$(printf '%s' "$out" | fm_backend_codex_app_json_field exists 2>/dev/null || true)
  [ "$exists" = true ]
}
