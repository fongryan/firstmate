#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-import.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE="$TMP_ROOT/state"; DATA="$TMP_ROOT/data"; mkdir -p "$STATE" "$DATA/legacy"
cat > "$STATE/legacy.meta" <<EOF
window=dead:fm-legacy
worktree=$TMP_ROOT/missing
project=$TMP_ROOT/project
harness=claude
kind=ship
EOF
printf 'Legacy objective\n' > "$DATA/legacy/brief.md"
out=$(FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_LIFECYCLE_IMPORT_NOW=1000 "$ROOT/bin/fm-lifecycle-import.sh") || { echo "not ok - import failed"; exit 1; }
grep -F 'lifecycle-imported=1' <<<"$out" >/dev/null || { echo "not ok - import count wrong"; exit 1; }
grep -F 'state=active' "$STATE/legacy.lifecycle" >/dev/null || { echo "not ok - legacy task not imported"; exit 1; }
out=$(FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_LIFECYCLE_IMPORT_NOW=1000 "$ROOT/bin/fm-lifecycle-import.sh")
grep -F 'lifecycle-imported=0' <<<"$out" >/dev/null || { echo "not ok - import not idempotent"; exit 1; }
printf 'ok - legacy meta records import once into lifecycle state\n'
