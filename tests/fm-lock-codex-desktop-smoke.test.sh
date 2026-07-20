#!/usr/bin/env bash
# Functional smoke for the real Codex Desktop app-server ancestry on macOS.
set -u

# shellcheck source=tests/lib.sh
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

rc=0
out=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "shared Codex Desktop app-server must not acquire a Firstmate lock"
assert_contains "$out" "cannot locate harness process in ancestry" "Desktop app-server refusal was not explicit"
assert_absent "$home/state/.lock" "shared Desktop app-server wrote a fleet lock"
pass "real Codex Desktop app-server fails closed without a session-specific owner"
