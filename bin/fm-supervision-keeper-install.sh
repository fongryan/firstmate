#!/usr/bin/env bash
# Install or remove the macOS launchd boundary for the Firstmate keeper.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
LABEL="com.armalo.firstmate.supervision-keeper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

usage() { echo "usage: $(basename "$0") [install|uninstall|status]"; }

install_keeper() {
  mkdir -p "$HOME/Library/LaunchAgents" "$FM_HOME/state"
  local tmp="$PLIST.tmp.$$"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT_DIR/fm-supervision-keeper.sh</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$FM_HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/Users/$USER/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$FM_HOME/state/.supervision-keeper.launchd.out</string>
  <key>StandardErrorPath</key><string>$FM_HOME/state/.supervision-keeper.launchd.err</string>
</dict></plist>
EOF
  /usr/bin/plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; echo "keeper: invalid launchd plist" >&2; return 1; }
  mv -f "$tmp" "$PLIST"
  launchctl bootout "gui/$UID_VALUE/$PLIST" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$UID_VALUE" "$PLIST" || {
    echo "keeper: launchd bootstrap failed; plist left at $PLIST" >&2
    return 1
  }
  launchctl enable "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
  launchctl kickstart -k "gui/$UID_VALUE/$LABEL" || {
    echo "keeper: launchd kickstart failed; job was bootstrapped but may not be running" >&2
    return 1
  }
  echo "keeper: installed and kicked $LABEL"
}

case "${1:-}" in
  install) install_keeper ;;
  uninstall)
    launchctl bootout "gui/$UID_VALUE/$PLIST" 2>/dev/null || launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "keeper: uninstalled $LABEL"
    ;;
  status) launchctl print "gui/$UID_VALUE/$LABEL" 2>&1 || true; "$SCRIPT_DIR/fm-supervision-keeper.sh" --status ;;
  *) usage >&2; exit 2 ;;
esac
