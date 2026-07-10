#!/usr/bin/env bash
# cockpit-daily-refresh.sh — Refreshes the flowstate cockpit daily
#
# Phase 7 of next-agent-work (2026-07-10).
#
# Runs:
#   1. flowstate-firstmate meta-orchestrator (5 per-repo FMs aggregated)
#   2. flowstate projector (writes fleet.json with profile lane)
#   3. brain profile compact (refresh PROFILE.compact.md)
#
# Schedule: 03:15 PT daily via launchd (com.armalo.cockpit-daily).
# Pre-conditions: captain-profile-pipeline runs at 03:17, so this must
# finish before that.

set -uo pipefail

FM_ROOT="/Users/ryanfong/workspace/firstmate"
FS_ROOT="/Users/ryanfong/workspace/firstmate/projects/flowstate"
BRAIN_ROOT="/Users/ryanfong/workspace/firstmate/projects/brain"
LOG="/Users/ryanfong/.hermes/logs/cockpit-daily.log"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

mkdir -p "$(dirname "$LOG")"

log "=== Cockpit daily refresh start ==="

# Step 1: meta-orchestrator (aggregates 5 per-repo FMs)
log "step 1/3: meta-orchestrator"
python3 "$HOME/.flowstate-firstmate/bin/fm-aggregate.py" 2>&1 | tail -5 | tee -a "$LOG"

# Step 2: flowstate projector (writes fleet.json with profile lane)
log "step 2/3: flowstate projector"
cd "$FS_ROOT"
node projector/flowstate-projector.mjs --once 2>&1 | tail -3 | tee -a "$LOG"

# Step 3: brain profile compact (refresh PROFILE.compact.md)
log "step 3/3: brain profile compact"
cd "$BRAIN_ROOT"
node tools/brain-cli.mjs profile compact 2>&1 | head -3 | tee -a "$LOG"

log "=== Cockpit daily refresh complete ==="