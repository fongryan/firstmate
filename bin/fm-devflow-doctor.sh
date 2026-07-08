#!/usr/bin/env bash
# fm-devflow-doctor.sh - read-only health check for the local firstmate devflow.
#
# This is an integrator, not another supervisor: it composes existing firstmate
# owners (bootstrap, project-mode, crew-state, guard data files) and reports
# whether this home has enough local truth to run repeatable agent work.
# Usage:
#   fm-devflow-doctor.sh [--json] [--repo-only]
#     --json       emit a compact JSON report instead of text
#     --repo-only  skip host-local tool and live crew probes; useful in CI/tests
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

JSON=0
REPO_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --repo-only) REPO_ONLY=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "usage: fm-devflow-doctor.sh [--json] [--repo-only]" >&2
      exit 2
      ;;
  esac
done

CHECKS=""
FAILS=0
WARNS=0

json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

add_check() { # <status> <area> <subject> <detail>
  local status=$1 area=$2 subject=$3 detail=$4 line
  case "$status" in
    fail) FAILS=$((FAILS + 1)) ;;
    warn) WARNS=$((WARNS + 1)) ;;
  esac
  line="$status|$area|$subject|$detail"
  CHECKS="${CHECKS}${CHECKS:+
}$line"
}

file_has() { # <path> <pattern>
  [ -f "$1" ] && grep -F -- "$2" "$1" >/dev/null 2>&1
}

check_tool() {
  local tool=$1
  if command -v "$tool" >/dev/null 2>&1; then
    add_check ok tools "$tool" "$(command -v "$tool")"
  else
    add_check fail tools "$tool" "missing from PATH"
  fi
}

check_required_file() { # <path> <area> <subject> <needle1> [needle2...]
  local path=$1 area=$2 subject=$3 needle ok=1
  shift 3
  if [ ! -s "$path" ]; then
    add_check fail "$area" "$subject" "missing or empty: $path"
    return
  fi
  for needle in "$@"; do
    if ! file_has "$path" "$needle"; then
      ok=0
      add_check fail "$area" "$subject" "missing required phrase '$needle' in $path"
    fi
  done
  [ "$ok" -eq 1 ] && add_check ok "$area" "$subject" "$path"
}

check_project_registry() {
  local reg="$DATA/projects.md" name mode yolo dir nm_remote
  if [ ! -s "$reg" ]; then
    add_check fail projects registry "missing or empty: $reg"
    return
  fi
  add_check ok projects registry "$reg"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir="$PROJECTS/$name"
    if [ -d "$dir/.git" ] || git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
      add_check ok projects "$name" "clone present"
    else
      add_check fail projects "$name" "registered project missing clone at $dir"
      continue
    fi

    read -r mode yolo < <("$SCRIPT_DIR/fm-project-mode.sh" "$name" 2>/dev/null)
    add_check ok modes "$name" "$mode yolo=$yolo"
    case "$mode" in
      no-mistakes)
        nm_remote=$(git -C "$dir" remote get-url no-mistakes 2>/dev/null || true)
        if [ -n "$nm_remote" ]; then
          add_check ok gates "$name" "no-mistakes remote present"
        else
          add_check fail gates "$name" "no-mistakes mode but remote is missing"
        fi
        ;;
      direct-PR)
        if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
          add_check ok gates "$name" "origin remote present"
        else
          add_check fail gates "$name" "direct-PR mode but origin remote is missing"
        fi
        ;;
      local-only)
        add_check ok gates "$name" "local-only: PR/no-mistakes automation intentionally skipped"
        ;;
      *)
        add_check fail modes "$name" "unknown mode: $mode"
        ;;
    esac
  done < <(awk '$1=="-" { print $2 }' "$reg")
}

check_secondmates() {
  local reg="$DATA/secondmates.md" line id meta home projects_line
  if [ ! -s "$reg" ]; then
    add_check warn secondmates registry "no persistent secondmates registered"
    return
  fi
  add_check ok secondmates registry "$reg"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        meta="$STATE/$id.meta"
        if [ ! -f "$meta" ]; then
          add_check fail secondmates "$id" "registry entry has no state meta"
          continue
        fi
        if grep -q '^kind=secondmate' "$meta" 2>/dev/null; then
          add_check ok secondmates "$id" "state meta marks kind=secondmate"
        else
          add_check fail secondmates "$id" "state meta is not kind=secondmate"
        fi
        home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
        [ -n "$home" ] && [ -d "$home" ] \
          && add_check ok secondmates "$id" "home present: $home" \
          || add_check fail secondmates "$id" "home missing: ${home:-unset}"
        projects_line=$(grep '^projects=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
        [ -n "$projects_line" ] \
          && add_check ok secondmates "$id" "projects=$projects_line" \
          || add_check warn secondmates "$id" "no projects= scope in meta"
        ;;
    esac
  done < "$reg"
}

check_live_crews() {
  local meta id state_line
  [ -d "$STATE" ] || { add_check fail state directory "missing: $STATE"; return; }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    state_line=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true)
    case "$state_line" in
      state:\ failed*|state:\ blocked*)
        add_check fail crew "$id" "$state_line"
        ;;
      state:\ parked*)
        add_check warn crew "$id" "$state_line"
        ;;
      state:\ idle*)
        add_check ok crew "$id" "$state_line"
        ;;
      state:\ unknown*)
        add_check warn crew "$id" "$state_line"
        ;;
      *)
        add_check ok crew "$id" "${state_line:-no state line}"
        ;;
    esac
  done
}

check_status_logs_for_secrets() {
  local file hit
  [ -d "$STATE" ] || return
  for file in "$STATE"/*.status "$DATA"/*/report.md "$DATA"/*/brief.md; do
    [ -f "$file" ] || continue
    hit=$(grep -Ein '(api[_-]?key|secret[_-]?(id|key)?|secretmanager|get-secret-value|password|authorization:|bearer[[:space:]])' "$file" 2>/dev/null | head -1 || true)
    if [ -n "$hit" ]; then
      add_check warn security "$(basename "$file")" "possible secret-like text: $hit"
    fi
  done
}

if [ "$REPO_ONLY" -eq 0 ]; then
  for tool in tmux node gh treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi; do
    check_tool "$tool"
  done
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1 || true)
  if [ -n "$BOOT_OUT" ]; then
    if printf '%s\n' "$BOOT_OUT" | grep -Eq '^(MISSING:|NEEDS_|TANGLE:|FLEET_SYNC: .*STUCK:|SECONDMATE_SYNC: .*skipped:|FMX: .*failed)'; then
      add_check warn bootstrap detect-only "$BOOT_OUT"
    else
      add_check ok bootstrap detect-only "$BOOT_OUT"
    fi
  else
    add_check ok bootstrap detect-only "silent"
  fi
else
  add_check ok tools repo-only "host-local tool checks skipped"
fi

[ -d "$FM_HOME" ] && add_check ok home root "$FM_HOME" || add_check fail home root "missing: $FM_HOME"
[ -d "$DATA" ] && add_check ok home data "$DATA" || add_check fail home data "missing: $DATA"
[ -d "$STATE" ] && add_check ok home state "$STATE" || add_check fail home state "missing: $STATE"
[ -d "$PROJECTS" ] && add_check ok home projects "$PROJECTS" || add_check fail home projects "missing: $PROJECTS"

check_project_registry
check_secondmates
check_required_file "$DATA/proof-packet-template.md" artifacts proof-packet \
  "Intent" "Touched files" "Proof commands" "Residual risks"
check_required_file "$DATA/recovery-playbook.md" artifacts recovery-playbook \
  "running" "idle" "waiting-for-prompt" "report-written-no-done" "stale" "failed"
check_required_file "$DATA/security-hygiene.md" artifacts security-hygiene \
  "No secrets" "Dangerous commands" "External live proof"
check_required_file "$DATA/repo-adoption-matrix.md" artifacts repo-adoption-matrix \
  "Mode" "Canonical proof" "Allowed automation" "Secondmate"
check_status_logs_for_secrets
[ "$REPO_ONLY" -eq 1 ] || check_live_crews

if [ "$JSON" -eq 1 ]; then
  printf '{'
  printf '"status":"%s","fails":%s,"warnings":%s,"checks":[' "$([ "$FAILS" -eq 0 ] && echo ok || echo fail)" "$FAILS" "$WARNS"
  first=1
  while IFS='|' read -r status area subject detail; do
    [ -n "$status" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"status":"%s","area":"%s","subject":"%s","detail":"%s"}' \
      "$(json_escape "$status")" "$(json_escape "$area")" "$(json_escape "$subject")" "$(json_escape "$detail")"
  done <<EOF
$CHECKS
EOF
  printf ']}\n'
else
  printf 'firstmate devflow doctor: %s (%s fail, %s warning)\n' "$([ "$FAILS" -eq 0 ] && echo ok || echo fail)" "$FAILS" "$WARNS"
  while IFS='|' read -r status area subject detail; do
    [ -n "$status" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$status" "$area" "$subject" "$detail"
  done <<EOF
$CHECKS
EOF
fi

[ "$FAILS" -eq 0 ]
