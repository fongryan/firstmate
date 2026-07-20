#!/usr/bin/env bash
# Regression test: the shared Codex desktop app-server is the stable process
# that owns the Firstmate session for Codex Desktop tool calls.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home_root=$(fm_test_tmproot fm-lock-codex-app-server)
home="$home_root/home"
fakebin=$(fm_fakebin "$home_root/fake")
mkdir -p "$home/state"
printf '%s\n' "$$" > "$home/state/.lock"

cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Applications/ChatGPT.app/Contents/Resources/codex'; exit 0 ;;
  *"args="*) printf '%s\n' 'codex -c features.code_mode_host=true app-server --analytics-default-enabled'; exit 0 ;;
esac
exit 1
SH
chmod +x "$fakebin/ps"

out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
assert_contains "$out" "lock: held by live harness pid $$" \
  "fm-lock did not retain the shared Codex app-server as the stable holder"
pass "fm-lock recognizes the shared Codex app-server as the Firstmate holder"
