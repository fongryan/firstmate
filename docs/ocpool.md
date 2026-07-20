# fm-ocpool: the headless opencode worker-pool loop

`bin/fm-ocpool.sh` is a second, independent headless driver, a sibling to `bin/fm-autopilot.sh`.
Where `fm-autopilot.sh` drives interactive-harness crewmates up to a small concurrency cap, this loop dispatches short, disposable opencode runs through the flowstate bridge (`bin/fm-ocpool-dispatch.mjs`), with no pane and no resident interactive session per task.
The goal, in the captain's own words, is to "spin off a ton of parallel disconnected workstreams that stay alive and do the work and not kill my laptop."
Liveness here means a durable queue entry plus receipts, not a resident process: a task can be claimed, run in the background, and triaged on a later tick without anything staying attached to it.

It reuses existing systems rather than reimplementing them:

- the existing queue, `data/backlog.md`, mutated exclusively through `tasks-axi` (`bin/fm-tasks-axi-lib.sh` gates every call);
- flowstate's `scripts/lib/local-agent-runner.mjs` through the bridge, for the actual opencode run, admission, and proof gate;
- `bin/fm-lifecycle.sh`, the closed-loop lifecycle ledger, for all pool task-state truth;
- `state/<id>.meta`, the same per-task inventory format every other Firstmate direct report uses (`AGENTS.md` section 2), for capacity counting and fleet visibility.

## Enqueuing a pool task

A backlog item opts into this pool by carrying a `(pool: opencode)` parenthetical field, the same bracket-field convention `fm-autopilot.sh` already uses for `(repo: ...)`, `(kind: ...)`, and `(priority: ...)`.

```markdown
## Queued
- [ ] fix-flaky-import - repair the CSV importer's date parser (repo: demo) (kind: ship) (priority: 1) (pool: opencode)
```

**Why `(pool: opencode)` and not `(kind: ocpool)`.**
`kind` looks like the more natural fit - it already exists, no new field - but it is the wrong choice, verified directly against `fm-autopilot.sh`'s source: `dispatch_item()` only branches on `kind` to decide whether to pass `--scout` (`[ "$kind" = scout ] && args+=(--scout)`); every other `kind` value, including `ocpool`, is dispatched as an ordinary ship task through `fm-spawn.sh` on the crew harness.
A `(kind: ocpool)` marker would therefore NOT be ignored by `fm-autopilot.sh` - it would get dispatched through the interactive crew path too, defeating the entire purpose of a separate pool.
`pool` is a field name `fm-autopilot.sh`'s `field()` extractor never queries at all, so it is provably ignored.
No `fm-autopilot.sh` change was needed or made.

### The coexistence race, and how it is bounded

`fm-autopilot.sh`'s own tick still scans every row under `## Queued` regardless of the pool marker, and nothing in this system changes that (`fm-autopilot.sh` is out of scope for this loop's own edits).
This loop claims a pool item with a real `tasks-axi start <key>` call, which physically moves the item out of `## Queued` into `## In flight`.
`fm-autopilot.sh`'s own `parse_queued()` only scans the `## Queued` section (`inq = ($0 ~ /^## Queued/)`), so a claimed item is invisible to it entirely, not merely deprioritized - stronger than an in-place checkbox flip would be.
A residual race remains only for the brief window between a pool item first appearing in `## Queued` and this loop's next tick claiming it: if `fm-autopilot.sh` is armed and ticks in that window, it could dispatch the same item through its own crewmate path first.
Keep pool-eligible projects out of `fm-autopilot.sh`'s own dispatch path (its `FM_AUTOPILOT_EXCLUDE_PROJECTS` knob, or simply do not arm both loops over the same backlog for a project that uses this marker) when that window matters.

## Gates (fail-closed)

Checked in this order every tick - preempt, armed, kill, own lock:

| Gate | Open when | Controlled by |
| --- | --- | --- |
| **PREEMPT** | `state/.ocpool-preempt` is absent | operator `touch` / `rm` |
| **ARMED** | `state/.ocpool-armed` exists | `fm-ocpool.sh arm` / `disarm` |
| **KILL** | `state/.ocpool-kill` is absent | operator `touch` / `rm` |
| **OWN LOCK** | this loop holds `state/.ocpool.lock` | automatic, acquired fresh each tick |

This loop **ships DISARMED**.
Nothing mutating happens until `fm-ocpool.sh arm` runs.

### Lock model: this loop does NOT stand down for an interactive captain

Unlike `fm-autopilot.sh`, this loop does not touch the shared fleet lock (`state/.lock`) at all, and is never preempted by a starting interactive `fm-session-start.sh`.
The rationale: this loop is subordinate gruntwork dispatch, not captain-acting on the fleet, so it keeps running even while an interactive session is live - `fm-autopilot.sh`'s stand-down-for-the-captain rule deliberately does not apply here.
The one way a captain pauses it explicitly is `state/.ocpool-preempt` (`touch` to pause, `rm` to resume), mirroring `fm-autopilot.sh`'s own preempt-flag shape but on its own path.

Its own private lock, `state/.ocpool.lock`, both prevents two `fm-ocpool.sh` processes from running a mutating tick at the same instant and is the loop's singleton guard - no separate lock is needed for that.
This lock is a single pid file, compared against the current process's own `$$`.
An earlier draft copied `fm-autopilot.sh`'s two-file `lock`/`owns-lock` trio literally, including its `pid == owner` "we hold it" check - that check only works when a lock has two *distinct* classes of writer (`fm-autopilot.sh` vs. an interactive captain session touching the shared `state/.lock`, where only `fm-autopilot.sh` ever writes the owner file).
This loop's private lock has exactly one writer class (`fm-ocpool.sh` itself), so a literal copy made `pid == owner` true for *any* live holder, not just the checking process itself; a second concurrent `fm-ocpool.sh` process would wrongly conclude "we hold it" and steal the lock out from under a live first process.
`tests/fm-ocpool.test.sh` caught this before it shipped.
The fixed, single-file, `$$`-comparison form is the same pattern `bin/fm-lifecycle.sh`'s own `acquire_lock()` uses.

## Safety guards (ported from `fm-autopilot.sh`, non-negotiable)

A pool item must pass the same guards `fm-autopilot.sh`'s `dispatch_item()` applies (`fm-autopilot.sh:441-487`), or a pool without them would reopen a closed safety hole:

- **Excluded project** - `FM_AUTOPILOT_EXCLUDE_PROJECTS` (default `armalo-fi,poly-sdk`), the *same* env var `fm-autopilot.sh` reads, so one captain configuration covers both loops.
  A match is a hard skip: a `skip-dispatch` receipt, never an escalation.
- **Destructive/security-sensitive text** - the same `DANGER_RE` pattern (`--no-verify`, `--force`, `rm -rf`, `DROP TABLE`, `private key`, `credential`, `LIVE_TRADING`, ...).
  A match escalates to `data/ocpool/needs-captain.md`, never dispatched.
- **No `(repo: ...)`** - escalated, cannot dispatch without a target project.
- **Missing project clone** - escalated.

## Capacity

Free dispatch slots = `FM_OCPOOL_MAX_CONCURRENT` minus active pool tasks.
This mirrors `fm-autopilot.sh`'s own `count_active_crew()` (`fm-autopilot.sh:370-388`): at dispatch, this loop writes `state/<key>.meta` with `kind=ocpool-worker` (the same `state/<id>.meta` convention every other direct report uses) and `lifecycle_id=<attempt-id>`.
Counting scans `state/*.meta` filtering `kind=ocpool-worker`, and for each one whose recorded `lifecycle_id` has `state=active` in its `bin/fm-lifecycle.sh` ledger file, counts it - never via `ps`, never via a second private ledger.

`FM_OCPOOL_MAX_ACTIVE_AGENTS` is a **separate, larger** cap, forwarded to the bridge as `FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS`.
Flowstate's resource-guardian, run in `FLOWSTATE_RESOURCE_GUARD_MODE=enforce`, is the single authority for that cap; this loop never second-guesses a guardian admission refusal, it only relays the refusal as a `blocked` outcome (see below).

## The bridge exit-code contract

`bin/fm-ocpool-dispatch.mjs` runs once per attempt, in the background: stdout (the bridge's own printed receipt JSON) captured to `data/ocpool/<key>.receipt.json`, stderr to `data/ocpool/<key>.log`.

| Exit | Meaning | This loop's response |
| --- | --- | --- |
| `0` | verified | `bin/fm-lifecycle.sh closeout completed --evidence <receipt.json>`; backlog item moved to `## Done` via `tasks-axi done`; receipt line. |
| `2` | blocked - machine admission refused, not this task's fault | Backlog item reopened to `## Queued` via `tasks-axi reopen`; does **not** consume an attempt; receipt line names the reason. |
| `3` / `4` | failed | Attempts below `FM_OCPOOL_MAX_ATTEMPTS` (default 2): `tasks-axi reopen`, with a handoff note appended to the task's brief (`## Handoff note`). Attempts exhausted: `bin/fm-lifecycle.sh closeout abandoned`, escalated to `data/ocpool/needs-captain.md`, left claimed so nothing silently retries it forever. |
| `5` | config bug | `closeout abandoned`, escalated to `data/ocpool/needs-captain.md` immediately, no retry. |
| anything else | unrecognized | treated as a failed attempt (conservative). |

Each attempt gets its own lifecycle id, `<key>-a<attempt-number>` (`fix-flaky-import-a1`, `fix-flaky-import-a2`, ...), registered `queued` then transitioned `active` at dispatch time and driven to a terminal `fm-lifecycle` state (`completed`, `interrupted`, or `abandoned`) at triage time.
A blocked outcome does not bump the attempt counter, so a blocked attempt's retry reuses the same attempt number; a failed outcome does bump it.

**Heartbeat.**
Every tick, after triage, this loop calls `bin/fm-lifecycle.sh heartbeat <attempt-id> --owner ocpool` for every attempt still running (its exit marker not yet present), so the ledger's heartbeat never goes stale while the bridge process is genuinely alive.
A task about to be triaged this same tick (exit marker already present) is skipped; a task already at a terminal lifecycle state is never reached here at all, because triage removes its `state/<key>.meta` the moment it goes terminal, and `bin/fm-lifecycle.sh` itself refuses to heartbeat a terminal task regardless.

## Backlog mutation: tasks-axi only, never a hand-edit

This loop mutates `data/backlog.md` exclusively through `tasks-axi start` / `tasks-axi reopen` / `tasks-axi done`, gated on `bin/fm-tasks-axi-lib.sh`'s `fm_tasks_axi_backend_available`.
There is no hand-edit fallback.
When the backend is unavailable - `tasks-axi` missing or incompatible, or `config/backlog-backend=manual` - this loop refuses to dispatch and escalates `tasks-axi-unavailable` to `data/ocpool/needs-captain.md`, rather than editing the file itself.

**Captain-concurrency caveat.**
This loop's own private lock only serializes its own ticks against itself and against other `fm-ocpool.sh` processes.
It does **not** serialize against an interactive captain session, a live `fm-autopilot.sh`, or a human running `tasks-axi` by hand, all of which may be mutating `data/backlog.md` at the same time (by design - see "Lock model" above).
`tasks-axi`'s own file writes are expected to be safe against interleaving at the file level, but a captain actively working the same backlog concurrently can still observe a claim, reopen, or done land in between their own edits.
If a captain wants to hand-edit a pool item while this loop might be ticking, `touch state/.ocpool-preempt` first.

## Receipts

One line per mutating action, appended to `data/ocpool/log.md`: `<timestamp>\t<action>\t<target>\t<detail>`.
Actions include `dispatch`, `done`, `blocked`, `requeue`, `escalate`, `skip-dispatch`, `arm`, `disarm`.
Everything that needs a human lands in `data/ocpool/needs-captain.md`: `<timestamp> | <key> | <reason> | <detail>`.
`state/.ocpool-heartbeat` is touched every tick, armed or not, so a cockpit can project this loop's liveness the same way it already does for `fm-autopilot.sh`.

## Environment knobs

| Var | Default | Meaning |
| --- | --- | --- |
| `FM_OCPOOL_TICK_SECS` | `60` | loop cadence seconds |
| `FM_OCPOOL_MAX_CONCURRENT` | `3` | max active pool tasks before dispatch stops |
| `FM_OCPOOL_MAX_ATTEMPTS` | `2` | max attempts per task before escalating to needs-captain |
| `FM_OCPOOL_MAX_ACTIVE_AGENTS` | `5` | forwarded to the bridge as `FLOWSTATE_RESOURCE_GUARD_MAX_ACTIVE_AGENTS` |
| `FM_AUTOPILOT_EXCLUDE_PROJECTS` | `armalo-fi,poly-sdk` | shared with `fm-autopilot.sh`; never-touch projects |
| `FM_OCPOOL_DISPATCH_BIN` | `$FM_ROOT/bin/fm-ocpool-dispatch.mjs` | the bridge command this loop execs |
| `FM_OCPOOL_SESSION` | `fm-ocpool` | tmux session name for `start`/`stop` |
| `FLOWSTATE_ROOT` / `FM_FLOWSTATE_ROOT` | (unset) | passed through unchanged to the bridge when set in this loop's own environment; the bridge's own default (a sibling `../flowstate` directory) applies when neither is set |

It also honors the standard Firstmate home overrides (`FM_ROOT_OVERRIDE` / `FM_HOME` / `FM_STATE_OVERRIDE` / `FM_DATA_OVERRIDE` / `FM_CONFIG_OVERRIDE` / `FM_PROJECTS_OVERRIDE`), so a temp fixture home is fully isolated.

## Subcommands

```sh
fm-ocpool.sh start      # launch the loop as a detached tmux session
fm-ocpool.sh stop       # kill the loop session and release the own lock
fm-ocpool.sh status     # print ARMED/KILL/preempt/own-lock/queue-depth/active-count one-liners
fm-ocpool.sh once       # run exactly one tick in the foreground, then exit
fm-ocpool.sh arm [note] # write state/.ocpool-armed with an optional note
fm-ocpool.sh disarm     # remove state/.ocpool-armed
```

`once` is the supervised single-pass form, used by the test suite and by an operator who wants to watch one tick before trusting the loop.
`start` requires tmux.
`_loop` is an internal subcommand: the raw loop body with no tmux wrapper, launched by `start` and also the correct direct entrypoint for an external process supervisor - see the launchd keeper below.

## Installing the launchd keeper

```sh
bin/fm-ocpool-install.sh install                # bootstrap the launchd job
bin/fm-ocpool-install.sh install --print-plist   # render the plist to stdout; touches nothing
bin/fm-ocpool-install.sh uninstall               # bootout and remove the plist
bin/fm-ocpool-install.sh status                  # launchctl print + fm-ocpool.sh status
```

Cloned from `bin/fm-supervision-keeper-install.sh`'s plist shape, label `com.armalo.firstmate.ocpool`.
The keeper runs `fm-ocpool.sh _loop` directly, **not** `start`: launchd (`KeepAlive` + `ThrottleInterval`) is already the process supervisor here, so the tmux wrapper `start` would use is redundant.
The same `_loop` entrypoint is the correct one for a container-based supervisor (an ECS task definition), not just launchd.
Installing the keeper is safe by itself: the loop stays inert until `fm-ocpool.sh arm` writes `state/.ocpool-armed`, exactly like `fm-autopilot.sh`.

## First-arm runbook

1. **Pre-flight (disarmed).** Confirm nothing mutates while disarmed:

   ```sh
   cd /Users/ryanfong/workspace/firstmate
   bin/fm-ocpool.sh once      # expect a "standby: DISARMED" line, zero mutations
   bin/fm-ocpool.sh status
   ```

2. **Enqueue at least one `(pool: opencode)` item** in `data/backlog.md`, and confirm the project it targets has a clone under `projects/`.
   Confirm `tasks-axi` is installed and compatible (`bin/fm-tasks-axi-lib.sh`'s probe) - without it, every dispatch escalates `tasks-axi-unavailable` instead of running.

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
   To pause without stopping (for example, to hand-edit the backlog safely): `touch state/.ocpool-preempt`; `rm state/.ocpool-preempt` to resume.

## Known limitations

- **`fm-autopilot.sh` capacity coexistence (resolved).** `fm-autopilot.sh`'s `count_active_crew()` excludes `kind=ocpool-worker` metas the same way it excludes `kind=secondmate`, so pool tasks never consume autopilot's own dispatch capacity.
  Each loop's cap governs only its own dispatches; the machine-wide agent ceiling is the resource guardian's enforce-mode admission check (see "Capacity semantics").
- **No `## Done` pruning knob.** Pruning `## Done` to the configured keep count is entirely `tasks-axi done`'s own responsibility (`.tasks.toml`'s `done_keep`), since this loop no longer hand-edits the backlog at all.
- **Fleet-view / session-digest integration is groundwork only.** The `state/<key>.meta` this loop writes uses the standard field shape (`AGENTS.md` section 2), including a synthetic `window=ocpool:<key>` (not a real backend window - there is no pane), but `bin/fm-fleet-view.sh` and the session-start digest have not been extended to specially render an `ocpool-worker` kind; they will show one, but not necessarily meaningfully.
