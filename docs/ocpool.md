# fm-ocpool: the headless opencode worker-pool loop

`bin/fm-ocpool.sh` is a second, independent headless driver, a sibling to `bin/fm-autopilot.sh`.
Where `fm-autopilot.sh` drives interactive-harness crewmates up to a small concurrency cap, this loop dispatches short, disposable opencode runs through the flowstate bridge (`bin/fm-ocpool-dispatch.mjs`), with no pane and no resident interactive session per task.
The goal, in the captain's own words, is to "spin off a ton of parallel disconnected workstreams that stay alive and do the work and not kill my laptop."
Liveness here means a durable queue entry plus receipts, not a resident process: a task can be claimed, run in the background, and triaged on a later tick without anything staying attached to it.

It reuses existing systems rather than reimplementing them:

- the existing queue, `data/backlog.md` via tasks-axi;
- flowstate's `scripts/lib/local-agent-runner.mjs` through the bridge, for the actual opencode run, admission, and proof gate;
- `bin/fm-lifecycle.sh`, the closed-loop lifecycle ledger, for all pool task-state truth;
- `bin/fm-wake-lib.sh`'s lock primitives, for this loop's own singleton lock.

## Enqueuing a pool task

A backlog item opts into this pool by carrying a `(pool: opencode)` parenthetical field, the same bracket-field convention `fm-autopilot.sh` already uses for `(repo: ...)`, `(kind: ...)`, and `(priority: ...)`.

```markdown
## Queued
- [ ] fix-flaky-import - repair the CSV importer's date parser (repo: demo) (kind: ship) (priority: 1) (pool: opencode)
```

`fm-autopilot.sh`'s own field parser only recognizes `repo`/`kind`/`priority`, so a `(pool: opencode)` marker is invisible to it - it is not a field autopilot understands, only one it happens to ignore.
No `fm-autopilot.sh` change was needed or made to add this marker.

### The coexistence race, and how it is bounded

`fm-autopilot.sh`'s own tick still scans every row under `## Queued` regardless of the pool marker, and nothing in this system changes that (`fm-autopilot.sh` is out of scope for this loop's own edits).
The moment this loop claims a pool item it flips the line's checkbox from `- [ ] ` to `- [~] ` in place, still inside `## Queued`.
That is the exact "already in flight, skip it" signal `fm-autopilot.sh`'s own `parse_queued`/tick loop already honors (`[ "$status" = " " ] || continue`), so once claimed, a pool item is invisible to `fm-autopilot.sh`'s own dispatch pass too, with no `fm-autopilot.sh` change required.
A residual race remains only for the brief window between a pool item first appearing in `## Queued` and this loop's next tick claiming it: if `fm-autopilot.sh` is armed and ticks in that window, it could dispatch the same item through its own crewmate path first.
Keep pool-eligible projects out of `fm-autopilot.sh`'s own dispatch path (its `FM_AUTOPILOT_EXCLUDE_PROJECTS` knob, or simply do not arm both loops over the same backlog for a project that uses this marker) when that window matters.

## Gates (fail-closed)

Three orthogonal gates, mirroring `fm-autopilot.sh`'s own contract (`docs/autopilot.md`, `docs/autopilot-arming.md`) exactly:

| Gate | Open when | Controlled by |
| --- | --- | --- |
| **ARMED** | `state/.ocpool-armed` exists | `fm-ocpool.sh arm` / `disarm` |
| **KILL** | `state/.ocpool-kill` is absent | operator `touch` / `rm` |
| **LOCK** | this loop holds the shared fleet lock (`state/.lock`) and no other live session does | automatic |

This loop **ships DISARMED**.
Nothing mutating happens until `fm-ocpool.sh arm` runs.

The LOCK gate is the *same* `state/.lock` fleet lock `fm-autopilot.sh` uses, and the same preemption contract applies: a starting interactive `fm-session-start.sh` treats this loop's own process as non-harness and preempts it automatically, so an interactive captain session always outranks both automated loops.
This loop records its own ownership in `state/.ocpool-owns-lock` (distinct from `fm-autopilot.sh`'s `state/.autopilot-owns-lock`), so the two loops alternate brief per-tick holds of the same lock rather than permanently locking each other out.

A separate **singleton lock** (`state/.ocpool-singleton.lock`, acquired and released through `bin/fm-wake-lib.sh`'s `fm_lock_try_acquire`/`fm_lock_release` - never a hand-rolled `mkdir` loop) only prevents two `fm-ocpool.sh` processes (a stray `once` and a running `start` loop, for example) from running a mutating tick body at the same instant.
It says nothing about captain precedence; the fleet lock above does that.

## Capacity

Free dispatch slots = `FM_OCPOOL_MAX_CONCURRENT` minus active pool tasks, counted by reading each in-flight task's `state=` field directly out of its `bin/fm-lifecycle.sh` ledger file - never from `ps`, and never from a second, private ledger.
A small marker file per claimed key (`state/.ocpool-attempt-<key>`) records which lifecycle id to read for that key; that marker is the one "gate/marker touch-file" this loop keeps outside `bin/fm-lifecycle.sh` itself, not a second source of truth.

`FM_OCPOOL_MAX_ACTIVE_AGENTS` is a **separate, larger** cap, forwarded to the bridge as `FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS`.
Flowstate's resource-guardian, run in `FLOWSTATE_RESOURCE_GUARD_MODE=enforce`, is the single authority for that cap; this loop never second-guesses a guardian admission refusal, it only relays the refusal as a `blocked` outcome (see below).

## The bridge exit-code contract

`bin/fm-ocpool-dispatch.mjs` runs once per attempt, in the background, with stdout and stderr captured to `data/ocpool/<key>.log`:

| Exit | Meaning | This loop's response |
| --- | --- | --- |
| `0` | verified | `bin/fm-lifecycle.sh closeout completed`; backlog item moved to `## Done` (tasks-axi when the backend is available and compatible, otherwise a hand-edit fallback); receipt line. |
| `2` | blocked - machine admission refused, not this task's fault | Backlog item unclaimed back to `- [ ] `, re-picked on a later tick; does **not** consume an attempt; receipt line names the reason. |
| `3` / `4` | failed | Attempts below `FM_OCPOOL_MAX_ATTEMPTS` (default 2): unclaimed for a retry, with a handoff note appended to the task's brief (`## Handoff note`). Attempts exhausted: `bin/fm-lifecycle.sh closeout abandoned`, escalated to `data/ocpool/needs-captain.md`, left claimed so nothing silently retries it forever. |
| `5` | config bug | `closeout abandoned`, escalated to `data/ocpool/needs-captain.md` immediately, no retry. |
| anything else | unrecognized | treated as a failed attempt (conservative). |

Each attempt gets its own lifecycle id, `<key>-a<attempt-number>` (`fix-flaky-import-a1`, `fix-flaky-import-a2`, ...), registered `queued` then transitioned `active` at dispatch time and driven to a terminal `fm-lifecycle` state (`completed`, `interrupted`, or `abandoned`) at triage time.
A blocked outcome does not bump the attempt counter, so a blocked attempt's retry reuses the same attempt number; a failed outcome does bump it.

## Receipts

One line per mutating action, appended to `data/ocpool/log.md`: `<timestamp>\t<action>\t<target>\t<detail>`.
Actions include `dispatch`, `done`, `blocked`, `requeue`, `escalate`, `arm`, `disarm`.
Everything that needs a human lands in `data/ocpool/needs-captain.md`: `<timestamp> | <key> | <reason> | <detail>`.
`state/.ocpool-heartbeat` is touched every tick, armed or not, so a cockpit can project this loop's liveness the same way it already does for `fm-autopilot.sh`.

## Environment knobs

| Var | Default | Meaning |
| --- | --- | --- |
| `FM_OCPOOL_TICK_SECONDS` | `60` | loop cadence seconds |
| `FM_OCPOOL_MAX_CONCURRENT` | `3` | max active pool tasks before dispatch stops |
| `FM_OCPOOL_MAX_ATTEMPTS` | `2` | max attempts per task before escalating to needs-captain |
| `FM_OCPOOL_MAX_ACTIVE_AGENTS` | `5` | forwarded to the bridge as `FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS` |
| `FM_OCPOOL_DONE_KEEP` | `10` | Done-section prune target used by the hand-edit fallback |
| `FM_OCPOOL_DISPATCH_BIN` | `$FM_ROOT/bin/fm-ocpool-dispatch.mjs` | the bridge command this loop execs |
| `FM_OCPOOL_SESSION` | `fm-ocpool` | tmux session name for `start`/`stop` |
| `FLOWSTATE_ROOT` / `FM_FLOWSTATE_ROOT` | (unset) | passed through unchanged to the bridge when set in this loop's own environment; the bridge's own default (a sibling `../flowstate` directory) applies when neither is set |

It also honors the standard Firstmate home overrides (`FM_ROOT_OVERRIDE` / `FM_HOME` / `FM_STATE_OVERRIDE` / `FM_DATA_OVERRIDE` / `FM_CONFIG_OVERRIDE` / `FM_PROJECTS_OVERRIDE`), so a temp fixture home is fully isolated.

## Subcommands

```sh
fm-ocpool.sh start      # launch the loop as a detached tmux session
fm-ocpool.sh stop       # kill the loop session and release the fleet + singleton locks
fm-ocpool.sh status     # print ARMED/KILL/lock/queue-depth/active-count one-liners
fm-ocpool.sh once       # run exactly one tick in the foreground, then exit
fm-ocpool.sh arm [note] # write state/.ocpool-armed with an optional note
fm-ocpool.sh disarm     # remove state/.ocpool-armed
```

`once` is the supervised single-pass form, used by the test suite and by an operator who wants to watch one tick before trusting the loop.
`start` requires tmux.

## Installing the launchd keeper

```sh
bin/fm-ocpool-install.sh install                # bootstrap the launchd job
bin/fm-ocpool-install.sh install --print-plist   # render the plist to stdout; touches nothing
bin/fm-ocpool-install.sh uninstall               # bootout and remove the plist
bin/fm-ocpool-install.sh status                  # launchctl print + fm-ocpool.sh status
```

Cloned from `bin/fm-supervision-keeper-install.sh`'s plist shape, label `com.armalo.firstmate.ocpool`.
The keeper runs `fm-ocpool.sh start`.
Installing the keeper is safe by itself: the loop stays inert until `fm-ocpool.sh arm` writes `state/.ocpool-armed`, exactly like `fm-autopilot.sh`.

## First-arm runbook

1. **Pre-flight (disarmed).** Confirm nothing mutates while disarmed:

   ```sh
   cd /Users/ryanfong/workspace/firstmate
   bin/fm-ocpool.sh once      # expect a "standby: DISARMED" line, zero mutations
   bin/fm-ocpool.sh status
   ```

2. **Enqueue at least one `(pool: opencode)` item** in `data/backlog.md`, and confirm the project it targets has a clone under `projects/`.

3. **Arm with a note**, then run one armed pass in the foreground and read every receipt before trusting the loop:

   ```sh
   bin/fm-ocpool.sh arm "first arm - conservative caps"
   bin/fm-ocpool.sh once
   cat data/ocpool/log.md
   cat data/ocpool/needs-captain.md 2>/dev/null
   ```

4. **Start the loop** once the single pass looks right:

   ```sh
   bin/fm-ocpool.sh start     # detached tmux session 'fm-ocpool'
   bin/fm-ocpool.sh status
   ```

5. **To stop:** `bin/fm-ocpool.sh stop`, and optionally `touch state/.ocpool-kill` to hard-disable until cleared.

## Known limitations

- The hand-edit Done-section mover (used only when the tasks-axi backend is unavailable or `config/backlog-backend=manual`) assumes the canonical `## In flight` / `## Queued` / `## Done` section shape from section 10 of `AGENTS.md`.
  A backlog file with legacy drift (for example `[x]` entries left inside `## Queued` rather than moved to `## Done`) is not repaired by this loop; it only ever touches the one item it is claiming or closing out.
- This loop's marker/receipt files (`state/.ocpool-*`, `data/ocpool/*`) are never pruned automatically, the same policy `fm-autopilot.sh` already uses for its own `state/.autopilot-*` markers.
