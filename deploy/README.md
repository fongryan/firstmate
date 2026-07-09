# fm-autopilot on ECS — 24/7 Firstmate factory runbook

Run Firstmate's headless captain loop (`bin/fm-autopilot.sh`) as a Fargate
service on the existing **armalo-admin-swarm** ECS cluster (us-west-2), so the
factory keeps dispatching crewmates and merging proven-green `+yolo` work with
the laptop off.

**These files live only under `firstmate/deploy/`. They do not modify any
existing firstmate file.**

| File | Purpose |
|------|---------|
| `Dockerfile.autopilot` | arm64 image: bash, git, tmux, node, jq, ripgrep, aws/gh CLIs, `@anthropic-ai/claude-code`, `@openai/codex`, `opencode-ai`, `tasks-axi`; carries firstmate code (tracked material only, no local state). `treehouse` + `no-mistakes` are private-repo binaries installed at **boot** by the entrypoint via `gh` (the build has no token). |
| `entrypoint.sh` | Boots the cloud FM_HOME: materializes creds, clones projects from origin, seeds `data/`+`config/`, arms autopilot, runs the loop in the foreground with graceful SIGTERM. |
| `task-def-autopilot.json` | Fargate task-def template (1 vCPU / 4 GB, log group `/ecs/fm-autopilot`, secrets from Secrets Manager). Tokens like `__IMAGE_URI__` are filled by the deploy script. |
| `deploy-ecs-autopilot.sh` | ECR + build/push + log group + secret placeholders + task-def register + service create/update + wait-stable. `--dry-run` prints the plan. |

## The convergence model (why cloud and laptop don't fight)

- The fleet lock (`state/.lock`) is **per-FM_HOME**. The cloud home is
  `/var/fm/home` inside the container; your laptop home is
  `/Users/ryanfong/workspace/firstmate`. Different homes → different locks → they
  never contend.
- Both homes clone the **same repos from origin** and push/merge to the **same
  remotes**. Origin is the single convergence point. The cloud autopilot's
  crewmates open PRs / merge to `main` exactly like laptop crewmates; the laptop
  pulls to see their work.
- An interactive laptop `fm-session-start.sh` still preempts the *laptop* home's
  autopilot instantly. The cloud autopilot is preempted by writing its own
  preempt/kill flags (see kill switch below), not by a laptop session.

## One-time setup

### 1. Populate the three secrets (REQUIRED — deploy creates them EMPTY)

The deploy script creates `fm/gh-token`, `fm/claude-credentials`, and
`fm/codex-auth` as **empty placeholders** if absent. Autopilot cannot act until
you put real values in. Copy your local OAuth creds up (OAuth, not API keys):

```sh
# Claude Code OAuth (whole credentials file — the container writes it to
# ~/.claude/.credentials.json)
aws secretsmanager put-secret-value --region us-west-2 \
  --secret-id fm/claude-credentials \
  --secret-string file://$HOME/.claude/.credentials.json

# Codex OAuth (~/.codex/auth.json)
aws secretsmanager put-secret-value --region us-west-2 \
  --secret-id fm/codex-auth \
  --secret-string file://$HOME/.codex/auth.json

# GitHub token with repo scope (clones + pushes + gh). Use a fine-grained or
# classic PAT string, not a file:
aws secretsmanager put-secret-value --region us-west-2 \
  --secret-id fm/gh-token \
  --secret-string "ghp_xxxxxxxxxxxxxxxxxxxx"
```

If you only run `claude` crewmates (the default `FM_CREW_HARNESS=claude`),
`fm/codex-auth` can stay a placeholder — codex just won't be available.

**The `fm/gh-token` must also have read access to the private tool repos
`kunchenguid/treehouse` and `kunchenguid/no-mistakes`.** The entrypoint installs
those two binaries at boot via `gh release download` (the image build has no
token, so they are not baked in). Without a token that can read them, crewmate
worktree leases and the promotion gate are degraded and the boot log prints a
loud WARN.

### 2. Choose the cloud fleet

Set `FM_PROJECTS_SPEC` = comma-separated `name=git_url` pairs. **Do not include
live-trading / money-path repos** (`armalo-fi`, `poly-sdk`) — keep them out of
the cloud fleet entirely. Even if one slipped in, it is in
`FM_AUTOPILOT_EXCLUDE_PROJECTS` (hard dispatch+merge exclusion) and
`FM_AUTOPILOT_YOLO_EXCLUDE` (never gets `+yolo`).

```sh
export FM_PROJECTS_SPEC="app=https://github.com/<org>/app.git,flowstate=https://github.com/<org>/flowstate.git,brain=https://github.com/<org>/brain.git"
```

## Deploy

```sh
cd /Users/ryanfong/workspace/firstmate

# a) See the whole plan without touching AWS:
FM_PROJECTS_SPEC="$FM_PROJECTS_SPEC" deploy/deploy-ecs-autopilot.sh --dry-run

# b) Real deploy (builds arm64 image, pushes to ECR, registers task def,
#    creates/updates the fm-autopilot service, waits for stable):
FM_PROJECTS_SPEC="$FM_PROJECTS_SPEC" deploy/deploy-ecs-autopilot.sh
```

## Verify one full autonomous cycle (laptop off)

```sh
# 1. Tail the container logs:
aws logs tail /ecs/fm-autopilot --region us-west-2 --follow

# Expect: entrypoint boot lines → "autopilot ARMED" → "armed tick: holding fleet
# lock" every ~120s. The heartbeat drives the ECS healthCheck (a heartbeat older
# than 10 min fails health and ECS recycles the task).

# 2. Give it a real backlog item to prove dispatch→gate→merge. Two ways:
#    (a) Bake a seed at boot: set FM_BACKLOG_SEED_FILE to a mounted backlog.md, or
#    (b) exec into the running task and append to data/backlog.md, or push it via
#        the cockpit projector once wired.

# 3. Confirm the receipts trail (inside the task, /var/fm/home/data/autopilot/):
#    log.md          — one line per mutating action (dispatch, merge, escalate)
#    needs-captain.md — anything that needs you (yolo=off finished work, blockers)
#    proposals.md    — backlog-refill proposals
```

A "full cycle" = autopilot dispatches a queued item to a crewmate in a treehouse
worktree, the crewmate ships through no-mistakes to a green PR, and autopilot
merges it (because the project is `+yolo`) — all recorded in `log.md`, with your
laptop closed.

## Kill switch (from your phone)

The loop checks `state/.autopilot-kill` every tick. Any of these stops all
mutating actions within one tick:

- **Cockpit action** (once wired): the cockpit's `autopilot-kill` action touches
  the flag.
- **SIGTERM / scale to 0**: `aws ecs update-service --cluster armalo-admin-swarm
  --service fm-autopilot --desired-count 0 --region us-west-2`. The entrypoint
  traps SIGTERM, sets the kill flag, and releases the fleet lock cleanly before
  exit.
- **Exec + touch**: `aws ecs execute-command ... --command "touch
  /var/fm/home/state/.autopilot-kill"` (requires ECS Exec enabled on the
  service). Remove the file to resume.

To fully re-arm after a kill, remove the flag; a fresh container boot also clears
any stale kill flag from a prior shutdown.

## Account cycling (multiple OAuth accounts)

Autopilot supports colon-separated profile dirs for quota spreading:

- `FM_AUTOPILOT_CLAUDE_PROFILES` — colon-separated `CLAUDE_CONFIG_DIR` list.
- `FM_AUTOPILOT_CODEX_PROFILES` — colon-separated `CODEX_HOME` list.

To use more than one account, store each account's creds in its own secret
version or its own secret (`fm/claude-credentials-2`, …), materialize each into a
distinct config dir in a custom entrypoint wrapper, and point the `*_PROFILES`
env at those dirs. The loop rotates across them for its bounded brain calls and
crewmate launches. A single account works fine without this.

## Knobs (task-def env; all optional)

| Env | Default | Meaning |
|-----|---------|---------|
| `FM_PROJECTS_SPEC` | *(none)* | `name=url,...` repos to clone + autopilot |
| `FM_CREW_HARNESS` | `claude` | crew harness (OAuth-backed) |
| `FM_AUTOPILOT_ARMED` | `1` | `0` = boot in standby (disarmed) |
| `FM_AUTOPILOT_TICK_SECS` | `120` | loop cadence |
| `FM_AUTOPILOT_MAX_CONCURRENT` | `3` | crewmate concurrency cap |
| `FM_AUTOPILOT_MIN_QUEUE` | `5` | refill-scout threshold |
| `FM_AUTOPILOT_EXCLUDE_PROJECTS` | `armalo-fi,poly-sdk` | never dispatch/merge |
| `FM_AUTOPILOT_YOLO_EXCLUDE` | `armalo-fi,poly-sdk,dad-plan` | never `+yolo` in generated projects.md |
| `FM_BACKLOG_SEED_FILE` | *(none)* | path to a backlog.md to seed the queue |

## Known limitations

- **OAuth refresh lifetimes.** OAuth tokens expire. `claude-code` and `codex`
  refresh in place using the credentials file, but if a refresh token is revoked
  or ages out, re-run the `put-secret-value` commands above and recycle the task
  (`--force-new-deployment`). Watch the logs for auth failures on crewmate
  launches.
- **no-mistakes gate reachability.** Crewmates ship `no-mistakes`-mode projects
  through the gate. The gate's local init (`no-mistakes init`) needs an `origin`
  remote and its backing store; if the gate isn't fully operational in-container,
  ship tasks **escalate to `needs-captain.md` instead of merging** — they are
  never merged un-green. Validate the gate for your projects before relying on
  auto-merge.
- **tmux-in-container.** Crewmate sessions run under a tmux server inside the
  task. On SIGTERM the entrypoint releases the fleet lock but does not tear down
  in-flight crewmate sessions; their work converges via origin (unlanded work is
  simply picked up again next boot). There is no attachable terminal — observe
  via CloudWatch logs and the receipts files.
- **No browser.** The container has no Chrome/`chrome-devtools-axi` surface, so
  browser-dependent scouts/QA can't run here. Keep browser work on the laptop.
- **Backlog is local.** `data/backlog.md` is gitignored and does not travel via
  origin. The cloud home starts with an empty queue unless you seed it
  (`FM_BACKLOG_SEED_FILE`) or push items via the cockpit. Only project *code*
  converges through origin; the *queue* is per-home.

## Next commands (copy/paste)

```sh
# (a) populate secrets
aws secretsmanager put-secret-value --region us-west-2 --secret-id fm/claude-credentials --secret-string file://$HOME/.claude/.credentials.json
aws secretsmanager put-secret-value --region us-west-2 --secret-id fm/codex-auth        --secret-string file://$HOME/.codex/auth.json
aws secretsmanager put-secret-value --region us-west-2 --secret-id fm/gh-token          --secret-string "<github-token>"

# (b) deploy
cd /Users/ryanfong/workspace/firstmate
export FM_PROJECTS_SPEC="app=<url>,flowstate=<url>,brain=<url>"
deploy/deploy-ecs-autopilot.sh --dry-run   # inspect
deploy/deploy-ecs-autopilot.sh             # ship

# (c) verify one autonomous cycle
aws logs tail /ecs/fm-autopilot --region us-west-2 --follow
```
