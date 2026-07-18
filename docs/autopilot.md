# fm-autopilot: the headless captain loop

`bin/fm-autopilot.sh` is Firstmate's never-stopping "software factory" driver. It
is the missing piece that keeps the fleet making forward progress when no
interactive captain session is actively prompting.

## What it is (and what it is not)

Firstmate is normally event-driven and captain-in-the-loop: an interactive
harness session holds the fleet lock (`state/.lock`), the watcher
(`bin/fm-watch.sh`) classifies crewmate wakes, and the away-mode daemon
(`bin/fm-supervise-daemon.sh`) injects escalations into the lock-holder's pane.

That design stalls the moment the interactive session goes idle: drained wake
records queue undrained forever, finished crewmate work sits at "needs captain
review/merge" (no project is `+yolo` by default), and nothing dispatches the
next backlog item. `fm-autopilot` closes that gap. When it is **explicitly
armed** and **no interactive session holds the lock**, each tick it:

1. drains the durable wake queue (and asserts watcher liveness);
2. triages finished/blocked crews - merging green, yolo-authorized work through
   the sanctioned merge path, escalating everything else to the captain;
3. dispatches the next queued backlog items up to a concurrency cap;
4. refills the backlog with a single scout when the queue runs low;
5. leaves a receipt for every mutating action.

It does **not** replace the captain. The interactive human session always
outranks autopilot (see "Lock preemption"). It never merges un-green work, never
touches an excluded/live-trading project, never force-pushes, and never deletes
or resets another agent's worktree.

## Lifecycle: three fail-closed gates

A mutating tick runs only when **all three** gates allow it. Any one closes the
door and the tick stands by (touching only the heartbeat).

| Gate | Open when | Controlled by |
| --- | --- | --- |
| **ARMED** | `state/.autopilot-armed` exists | `fm-autopilot.sh arm` / `disarm` |
| **KILL** | `state/.autopilot-kill` is absent | operator `touch` / `rm` |
| **LOCK** | autopilot holds the fleet lock and no other live session does | automatic + `state/.autopilot-preempt` |

Autopilot **ships DISARMED**. Nothing mutating happens until you run `arm`.

### Kill switch

`touch state/.autopilot-kill` immediately suspends all mutating actions on the
next tick (checked every tick). `rm state/.autopilot-kill` resumes. Use it as the
big red button: it is faster and blunter than `disarm`, and survives restarts.

### Lock preemption (the human always wins)

Autopilot records its own lock ownership in `state/.autopilot-owns-lock`. Because
autopilot's process is not a harness, a starting interactive
`bin/fm-session-start.sh` treats autopilot's lock as **stale** and preempts it
automatically - the human session simply steals the lock, and autopilot stands
by on its next tick when it sees another live holder.

For an explicit, immediate handoff, drop a preempt request:

```sh
touch state/.autopilot-preempt   # autopilot releases the fleet lock within one tick
rm    state/.autopilot-preempt   # allow autopilot to reacquire when free
```

While the preempt file is present, autopilot releases the lock and stays in
standby every tick.

## Standby vs. active

Every tick touches `state/.autopilot-heartbeat` (so a cockpit can project
liveness) and then either:

- **stands by** - logs one reason line (`DISARMED`, `KILL SWITCH present`,
  `preempt requested`, or `fleet lock held by another live session`) and does
  nothing else; or
- **runs the active body** - drains wakes, triages crews, dispatches, refills,
  and promotes proposals.

## The tick body, in order

1. **Drain wakes** - `bin/fm-wake-drain.sh` empties the durable queue and asserts
   watcher liveness. Decisions below read each crew's current status directly, so
   a drained record is never lost work: the status log it points at persists.
2. **Triage finished/blocked crews** - for each crewmate meta (secondmates are
   excluded from the cap and from merge):
   - **done + yolo=on**: drive the sanctioned merge path -
     `bin/fm-merge-local.sh` for `local-only`, `bin/fm-pr-merge.sh <id> <pr>` for
     `no-mistakes`/`direct-PR`. A `no-mistakes` merge additionally requires a
     **green proof marker** in the crew's status; without it, the work is
     escalated, not merged. A `.autopilot-merged-<id>` marker prevents a double
     merge on the next tick.
   - **done + yolo=off**: append a needs-captain receipt. Never merged.
   - **blocked/failed**: append a needs-captain receipt with the blocker line,
     bounded by `FM_AUTOPILOT_MAX_RETRIES` so it never loops. Each distinct
     status escalates once, not every tick.
3. **Capacity-gated dispatch** - count active crews (non-terminal metas). While
   under `FM_AUTOPILOT_MAX_CONCURRENT`, dispatch the top queued backlog items in
   priority order via `bin/fm-spawn.sh`. Items in an excluded project are
   hard-skipped; items whose text trips the destructive/security guard are
   escalated, never dispatched; items already in flight are skipped.
4. **Backlog refill** - when queued backlog `< FM_AUTOPILOT_MIN_QUEUE`, dispatch
   exactly one scout (round-robin over non-excluded projects) briefed to propose
   the next highest-leverage items into `data/autopilot/proposals.md`. Only one
   refill scout is ever in flight.
5. **Promote proposals** - when a scout has written backlog-ready lines to
   `data/autopilot/proposals.md`, autopilot (v1, conservative) records a
   needs-captain receipt pointing at them rather than editing `data/backlog.md`
   itself - the backlog remains firstmate's queue to own. A future armed
   promotion path can adopt them via a bounded judgment turn.

## Receipts and proof model

Every mutating action leaves a receipt. Three files under `data/autopilot/`
(all gitignored, like the rest of `data/`):

- **`log.md`** - one tab-separated line per action:
  `<timestamp>\t<action>\t<target>\t<proof-ref>`. Actions include `dispatch`,
  `skip-dispatch`, `merge-pr`, `merge-local`, `escalate`, `rotate-profile`,
  `arm`, `disarm`.
- **`needs-captain.md`** - everything that needs a human:
  `<timestamp> | <id> | <reason> | <detail>`. This is the queue an interactive
  captain drains when they return.
- **`proposals.md`** - backlog-ready lines proposed by refill scouts, awaiting
  captain adoption.

`state/.autopilot-heartbeat` is touched every tick (standby or active) so an
external cockpit can show whether autopilot is alive and how long since its last
pass.

## Bounded LLM judgment

Where a decision genuinely needs model judgment (promoting a proposal,
summarizing a blocked crew's unblock path), autopilot shells out to a **bounded**
headless turn (`claude -p "<prompt>" --max-turns 2` by default). The harness is
swappable via `FM_AUTOPILOT_BRAIN` (or fully overridden by
`FM_AUTOPILOT_BRAIN_CMD`), and calls are rate-limited to
`FM_AUTOPILOT_MAX_BRAIN_CALLS_PER_HOUR`. When the hourly budget is spent,
autopilot degrades gracefully (skips the judgment) rather than spinning.

## Account cycling (v1)

If a spawn or brain call fails with a rate-limit signature and profile lists are
configured, autopilot rotates to the next profile and retries once:

- `FM_AUTOPILOT_CLAUDE_PROFILES` - colon-separated `CLAUDE_CONFIG_DIR` values.
- `FM_AUTOPILOT_CODEX_PROFILES` - colon-separated `CODEX_HOME` values.

The rotation is logged as a `rotate-profile` receipt. When the lists are unset,
rotation is a no-op.

## Safety hard rules (encoded, not just documented)

- **Never push `--no-verify`, never force-merge.** Autopilot never pushes; it
  merges only through `fm-pr-merge.sh` (squash) and `fm-merge-local.sh`
  (fast-forward only), both of which go through the sanctioned gate and never
  force.
- **Never merge un-green work.** A `no-mistakes`/`direct-PR` merge requires a
  recorded `pr=` AND (for `no-mistakes`) a green proof marker; otherwise it is
  escalated.
- **Never touch a live-trading / money project.** `FM_AUTOPILOT_EXCLUDE_PROJECTS`
  (default `armalo-fi,poly-sdk`) is a hard dispatch AND merge exclusion. Any
  backlog item whose text matches the destructive/security guard is escalated and
  skipped.
- **Never delete or reset another agent's worktree.** Autopilot runs no teardown,
  `git reset`, or `git clean`.
- **yolo=off means ask.** Finished work in a yolo=off project is written as a
  needs-captain receipt, never merged.

## Environment knobs

| Var | Default | Meaning |
| --- | --- | --- |
| `FM_AUTOPILOT_TICK_SECS` | `120` | loop cadence seconds |
| `FM_AUTOPILOT_MAX_CONCURRENT` | `3` | max active crews before dispatch stops |
| `FM_AUTOPILOT_MIN_QUEUE` | `5` | refill a scout when queued backlog is below this |
| `FM_AUTOPILOT_MAX_RETRIES` | `1` | max auto-handled retries of a blocked/failed task |
| `FM_AUTOPILOT_MAX_BRAIN_CALLS_PER_HOUR` | `6` | bounded judgment-turn budget |
| `FM_AUTOPILOT_EXCLUDE_PROJECTS` | `armalo-fi,poly-sdk` | never-touch projects (comma list) |
| `FM_AUTOPILOT_BRAIN` | `claude` | harness for bounded judgment turns |
| `FM_AUTOPILOT_BRAIN_CMD` | (unset) | full override of the brain invocation (`FM_AUTOPILOT_PROMPT` is exported) |
| `FM_AUTOPILOT_SPAWN_CMD` | `$FM_ROOT/bin/fm-spawn.sh` | dispatch command (swap for tests/harnesses) |
| `FM_AUTOPILOT_MERGE_PR_CMD` | `$FM_ROOT/bin/fm-pr-merge.sh` | PR merge command |
| `FM_AUTOPILOT_MERGE_LOCAL_CMD` | `$FM_ROOT/bin/fm-merge-local.sh` | local-only merge command |
| `FM_AUTOPILOT_CLAUDE_PROFILES` | (unset) | colon list of `CLAUDE_CONFIG_DIR` for cycling |
| `FM_AUTOPILOT_CODEX_PROFILES` | (unset) | colon list of `CODEX_HOME` for cycling |
| `FM_AUTOPILOT_SESSION` | `fm-autopilot` | tmux session name for `start`/`stop` |

It also honors the standard Firstmate home overrides
(`FM_ROOT_OVERRIDE` / `FM_HOME` / `FM_STATE_OVERRIDE` / `FM_DATA_OVERRIDE` /
`FM_CONFIG_OVERRIDE` / `FM_PROJECTS_OVERRIDE`), so a temp fixture home is fully
isolated.

## Subcommands

```
fm-autopilot.sh start      # launch the loop as a detached tmux session
fm-autopilot.sh stop       # kill the loop session and release the fleet lock
fm-autopilot.sh status     # print arm/kill/preempt/lock/heartbeat/queue picture
fm-autopilot.sh once       # run exactly one tick in the foreground, then exit
fm-autopilot.sh arm [note] # write state/.autopilot-armed with an optional note
fm-autopilot.sh disarm     # remove state/.autopilot-armed
```

`once` is the supervised single-pass form used by the test suite and by an
operator who wants to watch one tick before committing to the loop. `start`
requires tmux.

## Running on ECS (containerized 24/7 factory)

The same script is meant to run in a container where `FM_HOME` is a cloud
Firstmate home and the project repos are cloned from `origin`. It works there
with these caveats - each is a real thing to wire up in the image, not an
afterthought:

- **tmux availability.** `start`/`stop` use tmux to hold the long-lived loop. In
  a container, either install tmux and run `start`, or (simpler and more
  container-native) skip tmux entirely and run the loop as the container's PID 1
  by invoking `once` on an interval from a tiny wrapper, or run
  `fm-autopilot.sh _loop` directly as the entrypoint (it is the same loop `start`
  launches, minus the tmux wrapper). Prefer `_loop` as the entrypoint so the
  container's own supervisor (ECS) is the process manager.
- **Harness CLI auth.** Dispatch and brain turns invoke `claude` / `codex` /
  `opencode` etc. Those CLIs need their credentials. Mount them as secrets
  (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or the harness's token env) and point the
  profile-cycling lists at the mounted dirs. Without valid auth, dispatch/brain
  calls fail and autopilot escalates - it degrades, it does not corrupt.
- **Git credentials.** Merges (`fm-pr-merge.sh` via `gh-axi`, `fm-merge-local.sh`
  via local git) need push/API credentials in the container: a `GH_TOKEN` for
  `gh-axi`, and a git identity + credential helper for any local merge. A
  `local-only` project needs only a working tree and identity; a PR flow needs
  the GitHub token.
- **Treehouse worktrees work fine in a container.** Treehouse only needs a git
  repo and a writable pool dir; nothing about it assumes a desktop. Point its
  pool at a container volume and `treehouse get --lease` behaves exactly as on a
  laptop.
- **Clock and heartbeat.** The heartbeat is an mtime; make sure the container
  clock is sane so a cockpit reading `state/.autopilot-heartbeat` age is
  meaningful.

The autopilot's own state (`state/.autopilot-*`) and receipts
(`data/autopilot/*`) should live on a persistent volume so an ECS task restart is
a non-event: a fresh task re-reads the armed flag, the kill switch, and the
receipts, and resumes.

## First-arm runbook

1. **Pre-flight (disarmed).** From a lock-free session, run one supervised pass
   and read the receipts - nothing mutates while disarmed:

   ```sh
   cd /Users/ryanfong/workspace/firstmate
   bin/fm-autopilot.sh once      # expect a "standby: DISARMED" line, zero mutations
   bin/fm-autopilot.sh status
   ```

2. **Confirm the kill switch is clear** and the excluded-project list is what you
   expect:

   ```sh
   ls state/.autopilot-kill 2>/dev/null && echo "kill switch present - remove to enable"
   echo "excluded: ${FM_AUTOPILOT_EXCLUDE_PROJECTS:-armalo-fi,poly-sdk}"
   ```

3. **Arm with a note**, then run one armed pass in the foreground and read every
   receipt before trusting the loop:

   ```sh
   bin/fm-autopilot.sh arm "first arm - conservative caps, exclude armalo-fi/poly-sdk"
   bin/fm-autopilot.sh once
   cat data/autopilot/log.md
   cat data/autopilot/needs-captain.md 2>/dev/null
   ```

4. **Start the loop** once the single pass looks right:

   ```sh
   bin/fm-autopilot.sh start      # detached tmux session 'fm-autopilot'
   bin/fm-autopilot.sh status
   ```

5. **To hand back to a human**, either start an interactive
   `bin/fm-session-start.sh` (it preempts autopilot's stale lock automatically) or
   `touch state/.autopilot-preempt`. To stop entirely:

   ```sh
   bin/fm-autopilot.sh stop
   touch state/.autopilot-kill    # optional: hard-disable until you clear it
   ```

Keep the caps conservative on the first several arms. Widen
`FM_AUTOPILOT_MAX_CONCURRENT` and turn on `+yolo` for individual projects only
after you have watched the receipts and trust the merge decisions.

