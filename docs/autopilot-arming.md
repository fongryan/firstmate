# Autopilot Arming Runbook (pending captain-authorized apply)

> Written 2026-07-09 by the flowstate-freeze debug session. Ryan explicitly
> ruled: always-on autonomous operation with auto-merge of proven-green work,
> 24/7, across all repos, so nothing is lost or orphaned and the captain is
> never the blocker. This file holds the exact state changes that require the
> fleet lock, so the next lock-free session (or the lock holder) can apply
> them in one pass. Companion: `docs/autopilot.md` + `bin/fm-autopilot.sh`.

## 1. Registry patch — flip `+yolo` (edit `data/projects.md`)

Add `+yolo` inside the mode brackets for these projects ONLY:

- `app [no-mistakes +yolo]`
- `flowstate [no-mistakes +yolo]`
- `armalo [no-mistakes +yolo]`
- `brain [no-mistakes +yolo]`
- `engine [no-mistakes +yolo]`
- `armalo-agent [no-mistakes +yolo]`
- `enterprise-code [no-mistakes +yolo]`
- `lab [no-mistakes +yolo]`

Explicitly KEEP yolo off (captain-in-the-loop stays mandatory):

- `armalo-fi` (live-trading risk gates; safety boundary)
- `poly-sdk` (venue/live-trading boundary)
- `dad-plan` (family-private sends; draft-first rules)

Rationale: `+yolo` is the existing, already-implemented switch that lets
firstmate approve PR merges / local merges itself (see `bin/fm-project-mode.sh`
and `bin/fm-pr-merge.sh`). No new merge machinery is needed — only this
registry change plus the autopilot loop to drive it while no human session is
active.

## 2. Captain preference update (edit `data/captain.md`)

Append under Captain Preferences:

    - Autonomy ruling (2026-07-09): the fleet runs 24/7 autopilot by default.
      Proven-green work auto-merges on +yolo projects so nothing is orphaned;
      the captain reviews receipts, not queues. Interactive sessions always
      preempt the autopilot lock. armalo-fi, poly-sdk, and dad-plan keep
      captain-in-the-loop regardless.

## 3. Stale learning to correct (edit `data/learnings.md`)

The 2026-07-08 "Codex-as-crewmate is DOWN (Auth)" entry is stale:
`codex login status` reports "Logged in using ChatGPT" as of 2026-07-09.
Codex dispatch profiles are usable again; remove/annotate the entry.

## 4. Arm sequence (after 1–3 applied)

```sh
bin/fm-wake-drain.sh                       # clear the queued wakes first
bin/fm-autopilot.sh status                 # expect: disarmed, standby
bin/fm-autopilot.sh arm "captain ruling 2026-07-09: 24/7 autopilot"
bin/fm-autopilot.sh start                  # tmux-backed loop; watch first 2 ticks
tail -f data/autopilot/log.md              # receipts
```

Kill switch at any time: `touch state/.autopilot-kill` (or the cockpit kill
action once wired). Interactive preemption: start any normal
`fm-session-start.sh` session — autopilot yields the lock within one tick.

## 5. Cloud follow-up (register as backlog items)

- `fm-autopilot-ecs-s1` — containerize the firstmate home + harness CLIs
  (claude/codex/opencode) on the existing `armalo-admin-swarm` ECS cluster,
  repos cloned from origin, creds via Secrets Manager, projector co-located
  pushing to the hosted cockpit. Proof: autopilot completes one full
  dispatch→green-gate→merge cycle with the laptop off.
- `flowstate-dns-authority-s1` — public `armalo.ai` DNS is GoDaddy-authoritative;
  Route 53 aliases alone cannot move `flowstate.armalo.ai` off Vercel. Decide:
  keep Vercel for the cockpit (works today) or repoint/delegate to Route 53
  for the ECS ALB path. Until decided, the ECS `flowstate-cockpit` service
  (already ACTIVE 1/1, task-def :2) serves no public traffic and receives no
  projector pushes — either point the projector's `FLOWSTATE_PUSH_URL` at it
  too, or scale it to 0 to stop paying for a dark service.
- `cockpit-ui-v2-s1` — apply `flowstate/docs/cockpit-ui-v2-spec.md` on top of
  the WIP snapshot `wip-cockpit-full-20260709`.
- `flowstate-wip-land-s1` — the 7,108-line uncommitted cockpit WIP in the
  flowstate hot checkout (action API, server.mjs, orchestrator, ECS deploy
  script, 8 test files) must be committed/landed through no-mistakes before
  it rots. Snapshot tags exist: `wip-cockpit-20260709` (tracked),
  `wip-cockpit-full-20260709` (includes untracked).
