#!/usr/bin/env bash
# fm-ocpool-install.sh - install or remove the macOS launchd boundary for the
# Firstmate opencode worker-pool loop (bin/fm-ocpool.sh), cloned from
# bin/fm-supervision-keeper-install.sh's plist shape. The keeper runs
# `fm-ocpool.sh _loop` directly, NOT `start`: launchd (KeepAlive +
# ThrottleInterval) is already the process supervisor here, so the tmux
# wrapper `start` would use is redundant - `_loop` is the same loop minus that
# wrapper, and is the correct direct entrypoint for any external supervisor
# (launchd here, an ECS task definition in a container). The loop is inert
# until `fm-ocpool.sh arm` writes state/.ocpool-armed, so installing the
# keeper never enables mutating dispatch by itself - see docs/ocpool.md for
# the arming ceremony.
#
# usage:
#   fm-ocpool-install.sh install                # bootstrap the launchd job
#   fm-ocpool-install.sh install --print-plist   # render the plist to stdout
#                                                 # and exit; touches nothing
#   fm-ocpool-install.sh uninstall               # bootout and remove the plist
#   fm-ocpool-install.sh status                  # launchctl print + fm-ocpool.sh status
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
LABEL="com.armalo.firstmate.ocpool"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

usage() { echo "usage: $(basename "$0") [install [--print-plist]|uninstall|status]"; }

render_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT_DIR/fm-ocpool.sh</string><string>_loop</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$FM_HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/Users/$USER/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$FM_HOME/state/.ocpool-keeper.launchd.out</string>
  <key>StandardErrorPath</key><string>$FM_HOME/state/.ocpool-keeper.launchd.err</string>
</dict></plist>
EOF
}

install_keeper() {
  if [ "${1:-}" = "--print-plist" ]; then
    render_plist
    return 0
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$FM_HOME/state"
  local tmp="$PLIST.tmp.$$"
  render_plist > "$tmp"
  /usr/bin/plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; echo "ocpool keeper: invalid launchd plist" >&2; return 1; }
  mv -f "$tmp" "$PLIST"
  launchctl bootout "gui/$UID_VALUE/$PLIST" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$UID_VALUE" "$PLIST" || {
    echo "ocpool keeper: launchd bootstrap failed; plist left at $PLIST" >&2
    return 1
  }
  launchctl enable "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
  launchctl kickstart -k "gui/$UID_VALUE/$LABEL" || {
    echo "ocpool keeper: launchd kickstart failed; job was bootstrapped but may not be running" >&2
    return 1
  }
  echo "ocpool keeper: installed and kicked $LABEL (loop is inert until 'fm-ocpool.sh arm')"
}

case "${1:-}" in
  install) install_keeper "${2:-}" ;;
  uninstall)
    launchctl bootout "gui/$UID_VALUE/$PLIST" 2>/dev/null || launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "ocpool keeper: uninstalled $LABEL"
    ;;
  status) launchctl print "gui/$UID_VALUE/$LABEL" 2>&1 || true; "$SCRIPT_DIR/fm-ocpool.sh" status ;;
  *) usage >&2; exit 2 ;;
esac
