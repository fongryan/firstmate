#!/usr/bin/env bash
# Functional smoke for the real Codex Desktop app-server ancestry on macOS.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-codex-desktop.XXXXXX")
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/state"

pid=$$
app_server=''
for _ in 1 2 3 4 5 6 7 8; do
  args=$(ps -o args= -p "$pid" 2>/dev/null || true)
  case "$args" in
    *'/codex '*' app-server'*) app_server=$pid; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
done

if [ -z "$app_server" ]; then
  printf '%s\n' 'ok - skipped: this process is not running under Codex Desktop app-server'
  exit 0
fi

out=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh")
owner=$(cat "$home/state/.lock")
[ "$owner" = "$app_server" ] || fail "real Codex Desktop owner mismatch (owner=$owner app-server=$app_server)"
assert_contains "$out" "lock acquired: harness pid $app_server" "real app-server acquisition was not reported"
status=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
assert_contains "$status" "lock: held by live harness pid $app_server" "real app-server liveness was not recognized"
pass "real Codex Desktop app-server owns and retains an isolated Firstmate lock"
