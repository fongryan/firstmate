#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-worktree.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "not ok - $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

repo="$TMP_ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'seed\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm seed

FM_WORKTREE_ROOT="$TMP_ROOT/worktrees"
. "$ROOT/bin/fm-git-worktree.sh"

path=$(fm_git_worktree_create "$repo" task-1) || fail "git worktree create should succeed"
[ -d "$path" ] || fail "created path should exist"
[ "$(git -C "$path" rev-parse --show-toplevel)" = "$path" ] || fail "created path should be a git worktree root"
[ "$path" != "$repo" ] || fail "created path must differ from primary repo"
pass "creates an isolated linked worktree without Treehouse"

fm_git_worktree_registered "$repo" "$path" || fail "created path should be registered"
pass "recognizes registered linked worktree"

fm_git_worktree_remove "$repo" "$path" || fail "registered clean worktree should remove"
[ ! -e "$path" ] || fail "removed worktree path should be absent"
pass "removes a linked worktree through Git"

# A persistent home may retain a target id from another checkout. Creation must
# preserve that path and use a deterministic project-specific alternate.
collision_repo="$TMP_ROOT/collision-repo"
mkdir -p "$collision_repo"
git -C "$collision_repo" init -q
git -C "$collision_repo" config user.email test@example.com
git -C "$collision_repo" config user.name test
printf 'collision\n' > "$collision_repo/README.md"
git -C "$collision_repo" add README.md
git -C "$collision_repo" commit -qm seed
collision_path="$FM_WORKTREE_ROOT/$(basename "$repo")/collision"
mkdir -p "$(dirname "$collision_path")"
git -C "$collision_repo" worktree add --detach "$collision_path" HEAD >/dev/null
alternate=$(fm_git_worktree_create "$repo" collision) || fail "collision should select an alternate target"
[ "$alternate" != "$collision_path" ] || fail "collision reused another checkout's target"
[ -d "$alternate" ] || fail "alternate collision target should exist"
pass "preserves foreign worktree targets and selects a deterministic alternate"

echo "# all fm-git-worktree tests passed"
