# Remove Treehouse From Firstmate Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Firstmate fully functional without Treehouse while preserving legacy metadata and existing work safely.

**Architecture:** Add one Git worktree provider helper and route spawn, secondmate provisioning, and teardown through it. Preserve existing legacy directories safely, but do not require or invoke Treehouse. Update workspace contracts and tests so ordinary Git worktrees are the supported isolation mechanism.

**Tech Stack:** Bash, Git linked worktrees, Firstmate shell test harness.

---

### Task 1: Add the Git worktree provider

**Files:**
- Create: `bin/fm-git-worktree.sh`
- Test: `tests/fm-git-worktree.test.sh`

- [x] Write failing tests for create, path validation, and safe removal.
- [x] Run the new test and confirm the provider is missing.
- [x] Implement `fm_git_worktree_create`, `fm_git_worktree_remove`, and
      `fm_git_worktree_registered` with ordinary Git commands.
- [x] Run the provider tests until green.
- [ ] Commit the provider and tests.

### Task 2: Route spawn and secondmate provisioning through Git

**Files:**
- Modify: `bin/fm-spawn.sh`
- Modify: `bin/fm-home-seed.sh`
- Test: `tests/fm-spawn-git-worktree.test.sh`

- [x] Add a failing no-Treehouse spawn test.
- [x] Replace the session-provider Treehouse command with Git provider creation.
- [x] Replace `home=-` secondmate acquisition with Git provider creation.
- [x] Run spawn and lifecycle tests without a Treehouse executable.
- [ ] Commit the spawn/provisioning slice.

### Task 3: Route teardown and bootstrap away from Treehouse

**Files:**
- Modify: `bin/fm-teardown.sh`
- Modify: `bin/fm-bootstrap.sh`
- Modify: `bin/fm-backend.sh`
- Test: `tests/fm-bootstrap.test.sh`
- Test: `tests/fm-teardown-git-worktree.test.sh`

- [x] Add failing tests proving no Treehouse dependency is reported.
- [x] Remove Treehouse from session-provider tool requirements and lease checks.
- [x] Remove Treehouse return from newly-created Git worktrees.
- [x] Preserve legacy directories without deleting them.
- [x] Run the complete Firstmate focused suite.
- [ ] Commit the runtime migration.

### Task 4: Update the workspace contract and closeout

**Files:**
- Modify: `/Users/ryanfong/workspace/DEV_WORKFLOW.md`
- Modify: `/Users/ryanfong/workspace/AGENTS.md`
- Modify: `/Users/ryanfong/workspace/LOOPS.md`
- Modify: `AGENTS.md`
- Modify: `CLAUDE.md`

- [x] Replace mandatory Treehouse instructions with ordinary Git worktree
      guidance.
- [x] State that existing Treehouse worktrees are preserved but no longer
      required.
- [ ] Run `check-captain-stack.sh`, shell syntax checks, and all Firstmate tests.
- [ ] Record the exact merge/push and fleet disposition.
