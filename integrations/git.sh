#!/usr/bin/env bash
# Integration adapter: git
#
# Defines how work is isolated and consolidated under a git integration model:
# each task gets its own worktree + feature branch, and concurrent merges lock
# the files they touch. Selected by a topology's `integration: git` field.
#
# Sourced (not executed) by worker-spawn.sh and task-locks.sh, mirroring the
# agent-adapter pattern in adapters/*.sh. Both contract functions return through
# stdout (one output convention for the whole contract):
#
#   integration_prepare_workspace <task_id> <worker_type> <title> [<base_branch>]
#       Ensure the task's workspace exists. Prints a single tab-separated line:
#         <workspace>\t<branch>
#       where <workspace> is the path the worker runs in and <branch> is the
#       branch name (empty for integrations without branches). VCS chatter goes to
#       /dev/null so stdout carries only the result line; a workspace that cannot be
#       made returns 1 with git's reason on stderr. There is one workspace per task:
#       where the task's branch is already checked out (the coder's worktree) that is
#       the workspace for any later role, since git allows a branch in one worktree
#       only and the validator, reviewer and merger work on the coder's output. A new branch
#       forks from <base_branch> when it resolves to a
#       commit, else from the current HEAD.
#
#   integration_locks
#       Print the resource ids currently locked by in-flight consolidations,
#       one per line. Empty output means nothing is locked (@merge stays `free`).

# The worktree, other than the main working tree, where <branch> is checked out, relative to the current
# directory when it is under it (git reports physical paths, so the comparison is against pwd -P, which
# is also what a symlinked project directory needs). Nothing if there is none.
_integration_branch_worktree() { # <branch>
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$1" -v top="$top" -v pwd="$(pwd -P)" '
    /^worktree / { p = substr($0, 10) }
    $1 == "branch" && $2 == b && p != top {
      if (index(p, pwd "/") == 1) p = substr(p, length(pwd) + 2)
      print p; exit
    }'
}

integration_prepare_workspace() {
  local task_id="$1" worker_type="$2" title="$3" base="${4:-}"
  local slug branch worktree existing
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
  branch="feature/${task_id}-${slug}"
  worktree=".worktrees/${worker_type}-${task_id}"

  if [[ -n "$base" ]] && ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    base=""
  fi

  # One workspace per task: git allows a branch in one worktree only, and a later role (validator,
  # reviewer, merger) has to see the coder's work. So where the task's branch is already checked out,
  # that is the workspace, whatever role asked and whatever it is called.
  existing="$(_integration_branch_worktree "$branch")"
  if [[ -n "$existing" ]]; then
    worktree="$existing"
  elif [[ ! -d "$worktree" ]]; then
    # The first attempt fails when the branch exists, which is expected and not worth a message; the
    # second says why when the workspace cannot be made. Only stdout is kept clean: it carries the result.
    git worktree add "$worktree" -b "$branch" ${base:+"$base"} >/dev/null 2>&1 || \
      git worktree add "$worktree" "$branch" >/dev/null || return 1
  fi

  printf '%s\t%s\n' "$worktree" "$branch"
}

integration_locks() {
  local conductor_dir="${CONDUCTOR_DIR:-.conductor}"
  local merging_dir="$conductor_dir/kanban/merging"
  [[ -d "$merging_dir" ]] || return 0

  # Print all files currently locked by active merges, one per line, deduplicated
  while IFS= read -r card; do
    [[ -f "$card" ]] || continue
    awk 'BEGIN{f=0; found=0} /^---$/{f++; next} f==1 && /^files-changed:/{found=1; next} found && /^  - /{sub(/^  - /,""); print; next} found && !/^  /{exit}' "$card"
  done < <(ls "$merging_dir"/*.md 2>/dev/null || true) | sort -u
}
