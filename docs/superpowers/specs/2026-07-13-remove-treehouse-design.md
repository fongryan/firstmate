# Remove Treehouse From Firstmate

## Goal

Remove Treehouse as a required runtime dependency and replace its task-isolation
responsibility with ordinary Git linked worktrees managed directly by Firstmate.

## Decisions

- Firstmate owns task worktree creation and cleanup through Git.
- Session backends (tmux, herdr, zellij, and cmux) provide terminals only;
  they no longer require Treehouse in bootstrap dependency checks.
- Orca remains a separate backend because it owns both its terminal and its
  worktree through its own API.
- Existing metadata that identifies a Treehouse-backed path remains readable;
  teardown uses Git worktree removal when the path is registered, and preserves
  unknown/unregistered paths instead of guessing.
- Existing Treehouse directories and leases are not deleted by this migration.

## Runtime shape

`fm-spawn.sh` calls a shared Git worktree helper before creating the terminal.
The helper creates a path under the configured Firstmate worktree root, checks
that it is a linked worktree distinct from the primary checkout, and records
the branch/path in existing task metadata. `fm-teardown.sh` validates landing
and dirtiness, then removes the linked worktree with `git worktree remove`.

Secondmate homes use the same helper when the requested home is `-`; explicit
home paths retain clone compatibility for existing callers.

## Safety

- Never use `reset --hard`, `clean`, or blanket conflict strategies.
- Refuse removal when a worktree is dirty, unlanded, unregistered, or owned by
  an active task unless `--force` is explicitly supplied.
- Keep legacy Treehouse cleanup only as a compatibility path for metadata that
  cannot be proven to be a Git linked worktree.

## Proof

- Unit tests prove bootstrap passes with no Treehouse binary.
- Spawn integration tests prove a linked Git worktree is created without a
  Treehouse command.
- Teardown integration tests prove the linked worktree is removed safely.
- Existing backend/session/lifecycle suites remain green.
