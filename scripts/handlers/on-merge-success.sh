#!/usr/bin/env bash
# on-merge-success as a script: the mechanical steps of skills/conductor/on-merge-success.md,
# with no model. The loop runs it for a merge artifact with outcome: success, with CONDUCTOR_DIR
# and TASK_ID set and the scripts on PATH.
#
#   1. close the finishing worker's tmux window, and write the task's record to the usage log
#      (task-record.sh: cost, size, rework; a convenience, so a failure there stops nothing)
#   2. ask the topology where merge-success sends the task (no guards: done), and move it
#   3. the three effects of that transition, which the topology names but does not do:
#      unblock the dependents that were waiting on it, release the merges that were waiting on
#      its files, and, if every task is now done, shut the swarm down
#
# Shutting down comes last. Under the loop conductor-shutdown.sh only writes a flag the loop
# checks after this event, so nothing here is cut short, but it also closes the architect window
# and stops the kanban server at once, and nothing should still be starting when that happens.
#
# A retry after a failure partway through runs the whole handler again. The task is moved to done
# a second time (another moved artifact, no other change), and a task already moved out of
# backlog or merge-pending is no longer there to be found. One that was moved but whose stage was
# never started stays where it is until the startup reconcile starts it, as with on-new-task.
# The skill's task-list.sh step only prints the board for a model to confirm.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-merge-success: TASK_ID is not set}"

close_worker_window "$TASK_ID"
task-record.sh "$TASK_ID" || echo "on-merge-success: could not record the task $TASK_ID in the usage log" >&2
route_task "$TASK_ID" merge-success
unblock_dependents "$TASK_ID"
release_merge_pending
if project_done; then conductor-shutdown.sh; fi
