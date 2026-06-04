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
#   integration_prepare_workspace <task_id> <worker_type> <title>
#       Ensure the task's workspace exists. Prints a single tab-separated line:
#         <workspace>\t<branch>
#       where <workspace> is the path the worker runs in and <branch> is the
#       branch name (empty for integrations without branches). All VCS chatter
#       goes to /dev/null so stdout carries only the result line.
#
#   integration_locks
#       Print the resource ids currently locked by in-flight consolidations,
#       one per line. Empty output means nothing is locked (@merge stays `free`).

integration_prepare_workspace() {
  local task_id="$1" worker_type="$2" title="$3"
  local slug branch worktree
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
  branch="feature/${task_id}-${slug}"
  worktree=".worktrees/${worker_type}-${task_id}"

  if [[ ! -d "$worktree" ]]; then
    git worktree add "$worktree" -b "$branch" >/dev/null 2>&1 || \
    git worktree add "$worktree" "$branch" >/dev/null 2>&1
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
