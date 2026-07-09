#!/usr/bin/env bash
# entrypoint.sh — boot the Firstmate cloud autopilot home, then run the headless
# captain loop in the foreground so ECS treats the container's lifetime as the
# autopilot's lifetime.
#
# Boot sequence:
#   1. Materialize harness credentials from Secrets Manager-injected env
#      (CLAUDE_CREDENTIALS_JSON -> ~/.claude/.credentials.json, or
#       CLAUDE_CODE_OAUTH_TOKEN passthrough; CODEX_AUTH_JSON -> ~/.codex/auth.json;
#       GH_TOKEN -> gh auth + git credential helper).
#   2. Clone/refresh the project repos named in FM_PROJECTS_SPEC from origin.
#   3. Seed the runtime FM_HOME (projects.md registry, captain autonomy ruling,
#      backlog skeleton, config knobs, autopilot data dir).
#   4. Arm autopilot (unless FM_AUTOPILOT_ARMED=0) and exec the loop in the
#      foreground with graceful SIGTERM handling (kill switch + lock release).
#
# The cloud FM_HOME (default /var/fm/home) is deliberately SEPARATE from any
# laptop home. Convergence between laptop and cloud happens only through origin:
# both clone the same repos and push/merge to the same remotes. The per-home
# fleet lock is per-FM_HOME, so laptop and cloud never fight over one lock.
#
# Fail-soft: a missing optional credential logs a warning and continues; only a
# genuinely unusable environment (no firstmate code, no writable FM_HOME) aborts.

set -uo pipefail

log() { printf '[entrypoint %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '[entrypoint %s] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf '[entrypoint %s] FATAL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

FM_ROOT="${FM_ROOT:-/opt/firstmate}"
FM_HOME="${FM_HOME:-/var/fm/home}"
export FM_ROOT FM_HOME
export FM_ROOT_OVERRIDE="$FM_ROOT"   # fm scripts self-locate bin/ from FM_ROOT
export HOME="${HOME:-/root}"

AUTOPILOT="$FM_ROOT/bin/fm-autopilot.sh"
[ -x "$AUTOPILOT" ] || die "fm-autopilot.sh not found/executable at $AUTOPILOT"

STATE="$FM_HOME/state"
DATA="$FM_HOME/data"
CONFIG="$FM_HOME/config"
PROJECTS="$FM_HOME/projects"
mkdir -p "$STATE" "$DATA" "$DATA/autopilot" "$CONFIG" "$PROJECTS" \
  || die "cannot create runtime home under $FM_HOME"

# Knobs with conservative defaults.
CREW_HARNESS="${FM_CREW_HARNESS:-claude}"
YOLO_EXCLUDE="${FM_AUTOPILOT_YOLO_EXCLUDE:-armalo-fi,poly-sdk,dad-plan}"
EXCLUDE_PROJECTS="${FM_AUTOPILOT_EXCLUDE_PROJECTS:-armalo-fi,poly-sdk}"
export FM_AUTOPILOT_EXCLUDE_PROJECTS="$EXCLUDE_PROJECTS"
export FM_AUTOPILOT_BRAIN="${FM_AUTOPILOT_BRAIN:-claude}"
export FM_BACKEND="${FM_BACKEND:-tmux}"

# ---------------------------------------------------------------------------
# 1. Harness + GitHub credentials
# ---------------------------------------------------------------------------
materialize_creds() {
  # Claude Code OAuth
  if [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]; then
    umask 077
    printf '%s' "$CLAUDE_CREDENTIALS_JSON" > "$HOME/.claude/.credentials.json"
    log "claude: wrote ~/.claude/.credentials.json ($(wc -c < "$HOME/.claude/.credentials.json") bytes)"
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    log "claude: using CLAUDE_CODE_OAUTH_TOKEN from env"
  else
    warn "claude: no CLAUDE_CREDENTIALS_JSON or CLAUDE_CODE_OAUTH_TOKEN; claude crewmates will fail until a secret is populated"
  fi

  # Codex OAuth
  if [ -n "${CODEX_AUTH_JSON:-}" ]; then
    umask 077
    printf '%s' "$CODEX_AUTH_JSON" > "$HOME/.codex/auth.json"
    log "codex: wrote ~/.codex/auth.json ($(wc -c < "$HOME/.codex/auth.json") bytes)"
  else
    warn "codex: no CODEX_AUTH_JSON; codex crewmates unavailable (fine if crew harness is claude)"
  fi

  # GitHub token: git clone/push + gh
  if [ -n "${GH_TOKEN:-}" ]; then
    export GH_TOKEN
    git config --global credential.helper store
    git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
    git config --global user.name  "${GIT_AUTHOR_NAME:-fm-autopilot}"
    git config --global user.email "${GIT_AUTHOR_EMAIL:-fm-autopilot@armalo.ai}"
    printf 'https://x-access-token:%s@github.com\n' "$GH_TOKEN" > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
    gh auth status >/dev/null 2>&1 || log "gh: token present (gh auth via GH_TOKEN env)"
    log "github: credential helper + insteadOf configured"
  else
    warn "github: no GH_TOKEN; private clones and pushes will fail"
  fi
}

# ---------------------------------------------------------------------------
# 2. Clone / refresh project repos from origin
#    FM_PROJECTS_SPEC="name=git_url,name=git_url,..."
# ---------------------------------------------------------------------------
clone_projects() {
  local spec="${FM_PROJECTS_SPEC:-}"
  if [ -z "$spec" ]; then
    warn "FM_PROJECTS_SPEC empty; no project repos will be cloned (autopilot will idle with an empty fleet)"
    return 0
  fi
  local IFS=,
  local entry name url
  for entry in $spec; do
    name="${entry%%=*}"
    url="${entry#*=}"
    [ -n "$name" ] && [ -n "$url" ] && [ "$name" != "$url" ] || { warn "skipping malformed FM_PROJECTS_SPEC entry: '$entry'"; continue; }
    local dest="$PROJECTS/$name"
    if [ -d "$dest/.git" ]; then
      log "project $name: refreshing (git fetch + fast-forward)"
      git -C "$dest" fetch --quiet origin || warn "project $name: fetch failed"
      local def
      def="$(git -C "$dest" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
      def="${def:-main}"
      git -C "$dest" checkout --quiet "$def" 2>/dev/null || true
      git -C "$dest" merge --ff-only --quiet "origin/$def" 2>/dev/null || warn "project $name: not fast-forwardable, left as-is"
    else
      log "project $name: cloning $url"
      git clone --quiet "$url" "$dest" || { warn "project $name: clone FAILED"; continue; }
    fi
    # no-mistakes projects need the local gate initialized (best-effort; the gate
    # may require its daemon/db to be reachable — see README limitations).
    if in_csv "$name" "$YOLO_EXCLUDE"; then :; fi
  done
}

# ---------------------------------------------------------------------------
# 2b. Install captain-stack binaries from private repos (needs GH_TOKEN)
# ---------------------------------------------------------------------------
install_captain_binaries() {
  if ! command -v gh >/dev/null 2>&1; then warn "gh missing; cannot install treehouse/no-mistakes"; return 0; fi
  if [ -z "${GH_TOKEN:-}" ]; then warn "no GH_TOKEN; skipping treehouse/no-mistakes install (crewmate dispatch/gate will be degraded)"; return 0; fi
  local arch; case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) arch=arm64 ;; esac
  local repo bin pattern td
  for pair in "kunchenguid/treehouse:treehouse" "kunchenguid/no-mistakes:no-mistakes"; do
    repo="${pair%%:*}"; bin="${pair##*:}"
    if command -v "$bin" >/dev/null 2>&1; then log "$bin: already installed ($(command -v "$bin"))"; continue; fi
    pattern="*linux-${arch}.tar.gz"
    td="$(mktemp -d)"
    if gh release download --repo "$repo" --pattern "$pattern" --dir "$td" 2>/dev/null; then
      tar -xzf "$td"/*.tar.gz -C "$td" 2>/dev/null || true
      # Move the extracted binary (named like the tool) onto PATH.
      local found; found="$(find "$td" -type f -name "$bin" -perm -u+x 2>/dev/null | head -1)"
      [ -n "$found" ] || found="$(find "$td" -type f -name "$bin" 2>/dev/null | head -1)"
      if [ -n "$found" ]; then
        install -m 0755 "$found" "/usr/local/bin/$bin"
        log "$bin: installed to /usr/local/bin/$bin ($(/usr/local/bin/$bin --version 2>/dev/null | head -1 || echo ok))"
      else
        warn "$bin: downloaded tarball but no '$bin' binary inside"
      fi
    else
      warn "$bin: gh release download failed (repo private/unauth or no ${arch} asset); crewmate dispatch/gate degraded"
    fi
    rm -rf "$td"
  done
}

in_csv() { # in_csv <needle> <csv>
  local needle="$1" csv="$2" IFS=,
  local x
  for x in $csv; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# 3. Seed runtime FM_HOME (data/ + config/)
# ---------------------------------------------------------------------------
seed_home() {
  # config: crew harness + backend. No crew-dispatch.json by default so fm-spawn
  # resolves the single crew harness (avoids the explicit-harness backstop and
  # keeps every crewmate on the OAuth-backed default).
  printf '%s\n' "$CREW_HARNESS" > "$CONFIG/crew-harness"
  printf 'tmux\n' > "$CONFIG/backend"
  # Operator may mount a richer dispatch policy at $CONFIG/crew-dispatch.json.
  if [ -n "${FM_CREW_DISPATCH_JSON:-}" ]; then
    printf '%s' "$FM_CREW_DISPATCH_JSON" > "$CONFIG/crew-dispatch.json"
    log "config: crew-dispatch.json written from FM_CREW_DISPATCH_JSON"
  fi

  # projects.md registry: generate from FM_PROJECTS_SPEC, applying +yolo except
  # for the yolo-exclude set (live-trading / family-private stay captain-in-loop).
  if [ ! -f "$DATA/projects.md" ]; then
    {
      printf '# Projects\n\n'
      local spec="${FM_PROJECTS_SPEC:-}" IFS=, entry name mode
      for entry in $spec; do
        name="${entry%%=*}"
        [ -n "$name" ] || continue
        if in_csv "$name" "$YOLO_EXCLUDE"; then mode="no-mistakes"; else mode="no-mistakes +yolo"; fi
        printf -- '- %s [%s] - cloud autopilot project (added %s)\n' "$name" "$mode" "$(date -u +%Y-%m-%d)"
      done
    } > "$DATA/projects.md"
    log "data: generated projects.md ($(grep -c '^- ' "$DATA/projects.md" 2>/dev/null || echo 0) projects)"
  fi

  # captain.md: record the standing 24/7 autonomy ruling for the cloud home.
  if [ ! -f "$DATA/captain.md" ]; then
    cat > "$DATA/captain.md" <<'CAP'
# Captain Preferences (cloud autopilot home)

- Autonomy ruling (2026-07-09): the fleet runs 24/7 autopilot by default.
  Proven-green work auto-merges on +yolo projects so nothing is orphaned; the
  captain reviews receipts, not queues. Interactive sessions always preempt the
  autopilot lock. armalo-fi, poly-sdk, and dad-plan keep captain-in-the-loop
  regardless.
- OAuth over API keys for LLM calls (OAuth = free).
CAP
    log "data: seeded captain.md autonomy ruling"
  fi

  # backlog skeleton: real items converge via origin/cockpit; a seed file/env can
  # prepopulate the queue for first-cycle verification.
  if [ ! -f "$DATA/backlog.md" ]; then
    if [ -n "${FM_BACKLOG_SEED_FILE:-}" ] && [ -f "$FM_BACKLOG_SEED_FILE" ]; then
      cp "$FM_BACKLOG_SEED_FILE" "$DATA/backlog.md"
      log "data: backlog.md seeded from $FM_BACKLOG_SEED_FILE"
    else
      cat > "$DATA/backlog.md" <<'BL'
# Backlog

## In flight
(none)

## Queued

## Done
BL
      log "data: wrote empty backlog skeleton (push real items via cockpit or FM_BACKLOG_SEED_FILE)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 4. tmux server for crewmate sessions
# ---------------------------------------------------------------------------
start_tmux() {
  # Crewmates use the tmux backend; ensure a server is up so fm-spawn's
  # `tmux new-session` attaches to it rather than racing to create one.
  tmux start-server 2>/dev/null || true
  log "tmux: server started (crewmate session backend)"
}

# ---------------------------------------------------------------------------
# 5. Arm + run the loop in the foreground with graceful shutdown
# ---------------------------------------------------------------------------
LOOP_PID=""
shutdown() {
  log "SIGTERM received: engaging kill switch + releasing fleet lock"
  # Kill switch first: any in-flight tick stops taking mutating actions.
  touch "$STATE/.autopilot-kill" 2>/dev/null || true
  if [ -n "$LOOP_PID" ] && kill -0 "$LOOP_PID" 2>/dev/null; then
    kill -TERM "$LOOP_PID" 2>/dev/null || true
    # The loop's own TERM trap releases the fleet lock; wait for it.
    wait "$LOOP_PID" 2>/dev/null || true
  fi
  # Belt-and-suspenders: stop also releases the lock and clears the pid marker.
  "$AUTOPILOT" stop >/dev/null 2>&1 || true
  log "shutdown complete"
  exit 0
}
trap shutdown TERM INT

main() {
  log "boot: FM_HOME=$FM_HOME FM_ROOT=$FM_ROOT crew-harness=$CREW_HARNESS"
  materialize_creds
  install_captain_binaries
  clone_projects
  seed_home
  start_tmux

  # Clear any stale kill switch from a previous container's shutdown so this
  # fresh boot can actually mutate.
  rm -f "$STATE/.autopilot-kill" 2>/dev/null || true

  if [ "${FM_AUTOPILOT_ARMED:-1}" = "1" ]; then
    "$AUTOPILOT" arm "${FM_AUTOPILOT_ARM_NOTE:-cloud autopilot (ECS) armed at boot}" || warn "arm failed"
  else
    log "autopilot left DISARMED (FM_AUTOPILOT_ARMED=0); will run in standby"
  fi

  "$AUTOPILOT" status || true
  log "starting foreground autopilot loop (tick ${FM_AUTOPILOT_TICK_SECS:-120}s)"

  # Run the loop as a child so the trap above can forward SIGTERM to it. The
  # loop's internal trap releases the fleet lock and removes its pid marker.
  "$AUTOPILOT" _loop &
  LOOP_PID=$!
  wait "$LOOP_PID"
}

main "$@"
