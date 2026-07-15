#!/usr/bin/env bash
# Default project delivery must not require the optional no-mistakes adapter.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/data"

out=$(FM_HOME="$tmp" "$ROOT/bin/fm-project-mode.sh" missing 2>/dev/null)
[ "$out" = "direct-PR off" ] || { echo "expected direct-PR default, got: $out" >&2; exit 1; }

printf '%s\n' '- legacy [no-mistakes] - explicit compatibility mode' > "$tmp/data/projects.md"
out=$(FM_HOME="$tmp" "$ROOT/bin/fm-project-mode.sh" legacy)
[ "$out" = "no-mistakes off" ] || { echo "expected explicit legacy mode, got: $out" >&2; exit 1; }

if grep -Fq 'COMMON_TOOLS="node git gh no-mistakes' "$ROOT/bin/fm-bootstrap.sh"; then
  echo "no-mistakes is still a bootstrap-required tool" >&2
  exit 1
fi

echo "ok - fm-project-mode defaults to direct-PR and keeps no-mistakes explicit-only"
