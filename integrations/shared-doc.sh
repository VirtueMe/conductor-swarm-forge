#!/usr/bin/env bash
# Integration adapter: shared-doc
#
# Defines how work is isolated and consolidated under a shared-document model:
# every task's deliverable lives in one shared folder that all of the task's
# stage-workers contribute to (draft → fact-check → review → publish), and the
# final "publish" stage consolidates it in place of a merge. There are no
# branches and no file locks. Selected by a topology's `integration: shared-doc`
# field (e.g. topologies/marketing.json).
#
# Sourced (not executed) by worker-spawn.sh and task-locks.sh via
# integration-resolve.sh, mirroring integrations/git.sh. Both contract functions
# return through stdout:
#
#   integration_prepare_workspace <task_id> <worker_type> <title>
#       Ensure the task's workspace exists. Prints a single tab-separated line:
#         <workspace>\t<branch>
#       The branch field is EMPTY — shared-doc is branchless. The workspace is
#       keyed by task (not by worker), so each stage-worker picks up the same
#       evolving deliverable, the way the git model reuses one worktree per task.
#
#   integration_locks
#       Print the resource ids currently locked by in-flight consolidations.
#       shared-doc has no locking, so this prints NOTHING (an empty lock set keeps
#       any @merge guard `free`; the marketing topology has no @merge at all).

integration_prepare_workspace() {
  # Contract args: <task_id> <worker_type> <title>. shared-doc keys the workspace
  # by task only and has no branches, so worker_type/title are unused here.
  local task_id="$1"
  local workspace="deliverables/${task_id}"

  mkdir -p "$workspace"

  # Empty branch field — shared-doc is branchless.
  printf '%s\t%s\n' "$workspace" ""
}

integration_locks() {
  # No locking under shared-doc: deliverables live in a shared folder and the
  # publish stage consolidates in place, so nothing is ever locked. Print nothing.
  return 0
}
