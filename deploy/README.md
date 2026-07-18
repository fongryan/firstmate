# fm-autopilot on ECS

This deployment runs the canonical Firstmate autopilot as a long-lived Fargate
service. The cloud home is separate from the laptop home; origin is the
convergence point, while `state/.autopilot-kill`, heartbeat receipts, and the
Firstmate backlog remain durable in the cloud home.

## Safe bring-up

1. Set `FM_PROJECTS_SPEC` to the approved public-safe repos. Include `brain`
   when task-scoped execution-profile routing should be active.
2. Run `deploy/deploy-ecs-autopilot.sh --dry-run` and inspect the rendered
   service/task configuration.
3. Populate the required Secrets Manager values (GitHub access plus the
   OAuth-backed harness credentials) and run the deployment script.
4. Verify ECS desired/running counts, task-definition image identity, fresh
   `.autopilot-heartbeat`, CloudWatch ticks, and a real dispatch receipt.

The task is fail-closed: missing credentials, missing project homes, unavailable
treehouse/no-mistakes tooling, stale heartbeats, or a kill flag stop mutation or
surface `needs-captain` rather than pretending the factory is live.

## Laptop-off proof

The minimum useful proof is one complete bounded cycle: queued priority item →
profile route receipt → isolated Firstmate dispatch → repo proof → green merge
or explicit captain escalation. `/healthz` alone is not evidence of execution.

Keep browser-dependent, private/family, money, trading, credential, and
destructive work out of the unattended allowlist. Use the cockpit kill action
or touch `state/.autopilot-kill` before investigating a bad run.
