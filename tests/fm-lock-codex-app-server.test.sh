#!/usr/bin/env bash
# Regression test: the shared Codex desktop app-server is not a Firstmate session.
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
assert_contains "$out" "lock: stale (pid $$ dead or not a harness)" \
  "fm-lock treated the shared Codex app-server as a live Firstmate harness"
pass "fm-lock rejects the shared Codex app-server as a Firstmate holder"
