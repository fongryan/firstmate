# Closed-loop lifecycle

Firstmate's task lifecycle is closed when every task has a durable owner,
positive liveness evidence, a bounded expiry, and a terminal receipt.

## State owner

`state/<task>.lifecycle` owns current state. `state/<task>.events` is the
append-only audit trail. Runtime `.meta` files, sparse `.status` wake logs, and
`data/backlog.md` are projections or adapters; none can silently revive or
delete lifecycle state.

Valid states are:

```text
queued active blocked needs-decision ready-for-review
interrupted completed superseded abandoned
```

Terminal states are `interrupted`, `completed`, `superseded`, and `abandoned`.
Terminal records remain after volatile runtime cleanup so history and restart
evidence survive worktree reuse.

## Automatic loop

1. `fm-spawn.sh` admits the objective and registers the task before launching
   the harness.
2. The watcher refreshes heartbeats only when the crew has positive working
   evidence.
3. The periodic watcher and every session restart run
   `fm-lifecycle-reap.sh --apply`.
4. An expired active heartbeat becomes `interrupted` with a receipt. The same
   operation is safe to repeat.
5. `fm-lifecycle-reconcile.sh` classifies worktrees. Dirty, leased, missing,
   unknown, and active worktrees are protected; only clean terminal work is
   eligible for an explicit return.
6. `fm-teardown.sh` writes a terminal closeout receipt before deleting volatile
   metadata. Normal teardown is `completed`; explicit force teardown is
   `abandoned`.

## Safety and scale

The loop is autonomous for classification and recovery, but destructive actions
remain fail-closed. Every task mutation uses a per-task lock, atomic current
state replacement, and an append-only event receipt. Reaper and snapshot scans
are bounded filesystem scans with no network calls or unbounded pane capture;
the functional fixture covers hundreds of records and is designed to extend to
thousands of concurrent tasks.

Useful commands:

```sh
bin/fm-lifecycle-reap.sh --dry-run
bin/fm-lifecycle-reap.sh --apply
bin/fm-lifecycle-reconcile.sh
bin/fm-fleet-snapshot.sh --json
```
