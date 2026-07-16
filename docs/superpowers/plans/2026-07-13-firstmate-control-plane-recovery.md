# Firstmate Control Plane Recovery Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Firstmate session startup complete within a bounded interval, recover only a bounded number of confidently dead secondmates, and emit an honest partial-state receipt instead of hanging.

**Architecture:** Keep the existing session-start ownership and liveness classifier. Add a per-bootstrap wall-clock/budget guard around secondmate recovery, preserve `unknown` as non-mutating, and report skipped recovery explicitly. Do not add a second supervisor or alter the existing backend ownership model.

**Tech Stack:** Bash, tmux backend adapters, existing shell test harness, `tasks-axi`, `no-mistakes`.

---

## Chunk 1: Bound secondmate recovery

### Task 1: Add failing tests for bounded liveness recovery

**Files:**
- Modify: `tests/fm-secondmate-liveness.test.sh`
- Test target: `bin/fm-bootstrap.sh` and `secondmate_liveness_sweep`

- [ ] **Step 1: Add a fixture with more dead secondmates than the recovery budget.**
  Create isolated metadata for several dead tmux secondmates and a fake `fm-spawn.sh` that records each respawn without creating a live agent.

- [ ] **Step 2: Add a test that invokes the sweep with a small budget.**
  Set `FM_SECOND_MATE_RESPAWN_BUDGET=2` and assert no more than two respawn attempts occur.

- [ ] **Step 3: Assert the receipt is explicit.**
  Require a `SECONDMATE_LIVENESS` line stating that recovery was budget-limited and naming the number skipped.

- [ ] **Step 4: Run the focused test and confirm it fails.**
  Run: `bash tests/fm-secondmate-liveness.test.sh`
  Expected: FAIL because the current sweep has no recovery budget.

### Task 2: Implement bounded, convergent recovery

**Files:**
- Modify: `bin/fm-bootstrap.sh:246-315`
- Test: `tests/fm-secondmate-liveness.test.sh`

- [ ] **Step 1: Add a validated integer budget helper.**
  Default to a small finite budget, accept only positive integer overrides, and treat invalid values as the default.

- [ ] **Step 2: Track attempts and elapsed time within the sweep.**
  Stop before starting another respawn when either the count budget or a short wall-clock budget is exhausted.

- [ ] **Step 3: Preserve safety semantics.**
  Continue to act only on `dead`; never respawn `alive` or `unknown`; never kill an endpoint after the budget is exhausted.

- [ ] **Step 4: Emit a structured partial receipt.**
  Report attempted, succeeded, failed, and skipped counts so the session digest can distinguish recovery from complete fleet health.

- [ ] **Step 5: Run the focused test and confirm it passes.**
  Run: `bash tests/fm-secondmate-liveness.test.sh`
  Expected: PASS.

## Chunk 2: Session-start integration and full proof

### Task 3: Add session-start timeout coverage

**Files:**
- Modify: `tests/fm-session-start.test.sh`
- Modify: `tests/fm-bootstrap.test.sh`

- [ ] **Step 1: Add a fake bootstrap case where respawn never converges.**
  Ensure the fake backend remains dead after each spawn attempt.

- [ ] **Step 2: Assert session start returns a non-zero or explicit partial result within the test timeout.**
  The command must never wait indefinitely for secondmate recovery.

- [ ] **Step 3: Assert the digest includes the partial-recovery receipt.**
  Do not accept a silent timeout or a false “all healthy” result.

### Task 4: Run the Firstmate validation stack

**Files:**
- No source changes expected.

- [ ] **Step 1: Run focused shell tests.**
  Run: `bash tests/fm-secondmate-liveness.test.sh && bash tests/fm-session-start.test.sh && bash tests/fm-bootstrap.test.sh`

- [ ] **Step 2: Run the repository doctor/lint suite.**
  Run the repository-declared test/doctor command from `AGENTS.md` and `no-mistakes doctor`.

- [ ] **Step 3: Run a real bounded session-start probe.**
  Run: `timeout 30s bin/fm-session-start.sh`; capture the digest and exact residual fleet state.

- [ ] **Step 4: Commit the isolated control-plane change.**
  Commit message: `fix: bound firstmate secondmate recovery during bootstrap`.

- [ ] **Step 5: Promote only after proof.**
  Run the repo's no-mistakes gate, then merge to `main` only if the gate and review are green. Otherwise preserve the branch with the exact blocker and close the task as blocked, not done.
