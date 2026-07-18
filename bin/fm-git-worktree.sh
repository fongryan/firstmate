#!/usr/bin/env bash
# Firstmate's direct Git worktree provider.
#
# This file is sourced by spawn, secondmate provisioning, and teardown. It has
# no pool, lease daemon, or external worktree-manager dependency.

fm_git_worktree_root() {
  local project=$1
  printf '%s\n' "${FM_WORKTREE_ROOT:-$HOME/.firstmate/worktrees/$(basename "$project")}" 
}

fm_git_worktree_abs() {
  local project=$1 id=$2 root
  root=$(fm_git_worktree_root "$project")
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: invalid worktree id '$id'" >&2
      return 1
      ;;
  esac
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  printf '%s/%s\n' "$root" "$id"
}

fm_git_worktree_registered() {
  local project=$1 target=$2 target_real line path
  target_real=$(cd "$target" 2>/dev/null && pwd -P) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        path=${line#worktree }
        path=$(cd "$path" 2>/dev/null && pwd -P) || continue
        [ "$path" = "$target_real" ] && return 0
        ;;
    esac
  done < <(git -C "$project" worktree list --porcelain 2>/dev/null)
  return 1
}

fm_git_worktree_quarantine_stale() {
  local target=$1 gitfile gitdir quarantine_root quarantine
  [ -f "$target/.git" ] || return 1
  gitfile=$(sed -n 's/^gitdir: //p' "$target/.git" | head -1)
  [ -n "$gitfile" ] || return 1
  case "$gitfile" in
    /*) gitdir=$gitfile ;;
    *) gitdir=$(cd "$target" 2>/dev/null && cd "$(dirname "$gitfile")" 2>/dev/null && pwd -P)/$(basename "$gitfile") || return 1 ;;
  esac
  [ ! -e "$gitdir" ] || return 1
  quarantine_root=${FM_STALE_WORKTREE_QUARANTINE:-${TMPDIR:-/tmp}/firstmate-stale-worktrees}
  mkdir -p "$quarantine_root" || return 1
  quarantine="$quarantine_root/$(basename "$target").$(date +%s).$$"
  mv "$target" "$quarantine" || return 1
  echo "warning: quarantined stale Git worktree target $target -> $quarantine" >&2
  return 0
}

fm_git_worktree_create() {
  local project=$1 id=$2 target alternate suffix
  project=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo "error: project '$1' is not a directory" >&2
    return 1
  }
  git -C "$project" rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "error: project '$project' is not a Git worktree" >&2
    return 1
  }
  target=$(fm_git_worktree_abs "$project" "$id") || return 1
  if [ -e "$target" ]; then
    fm_git_worktree_registered "$project" "$target" || {
      if fm_git_worktree_quarantine_stale "$target"; then
        :
      else
        # A persistent home can contain the same task id from a different
        # checkout (or a prior clone whose Git admin dir still exists). Never
        # touch that path; derive a deterministic project-specific target so
        # retrying the task cannot deadlock the dispatcher.
        suffix=$(printf '%s' "$project" | cksum | cut -d' ' -f1)
        alternate=$(fm_git_worktree_abs "$project" "$id-$suffix") || return 1
        if [ -e "$alternate" ]; then
          echo "error: worktree targets exist but neither is registered for project: $target $alternate" >&2
          return 1
        fi
        echo "warning: worktree id collision; using project-specific target $alternate" >&2
        target=$alternate
      fi
    }
    if [ -e "$target" ]; then
      printf '%s\n' "$target"
      return 0
    fi
  fi
  git -C "$project" worktree add --detach "$target" HEAD >/dev/null || {
    echo "error: git worktree add failed for $target" >&2
    return 1
  }
  printf '%s\n' "$target"
}

fm_git_worktree_remove() {
  local project=$1 target=$2 force=${3:-0}
  project=$(cd "$project" 2>/dev/null && pwd -P) || return 1
  fm_git_worktree_registered "$project" "$target" || {
    echo "error: refusing to remove unregistered Git worktree: $target" >&2
    return 1
  }
  if [ "$force" = 1 ]; then
    git -C "$project" worktree remove --force "$target"
  else
    git -C "$project" worktree remove "$target"
  fi
}
