# Durable supervision keeper

`bin/fm-watch.sh` is intentionally a one-cycle watcher: it exits after a wake
so the harness can resume the captain session. A long-lived owner must therefore
re-arm it after every wake and after every unexpected exit.

On macOS, install the durable owner with:

```sh
bin/fm-supervision-keeper-install.sh install
```

The installer creates a user-scoped LaunchAgent with `RunAtLoad`, `KeepAlive`,
and a five-second launchd throttle. The keeper itself uses the home-scoped
watcher lock and process identity, starts `fm-watch-arm.sh` as a child, records
bounded crash/restart evidence, and re-arms the child with exponential backoff.
It only starts the away-mode injection daemon while `state/.afk` exists; normal
captain sessions therefore get a durable watcher without an unsolicited
injection path.

Useful checks:

```sh
bin/fm-supervision-keeper.sh --status
bin/fm-supervision-keeper-install.sh status
tail -f state/.supervision-keeper.log
```

The keeper is deliberately home-scoped and never uses broad process matching.
`launchd` is the outer restart boundary; the keeper is the inner restart
boundary for the one-cycle watcher. If launchd cannot bootstrap the job, the
installer exits non-zero and leaves the plist in place for diagnosis.
