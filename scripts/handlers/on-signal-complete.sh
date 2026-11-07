#!/usr/bin/env bash
# on-signal-complete as a script: the mechanical steps of skills/conductor/on-signal-complete.md,
# with no model. The loop runs it for a signal artifact with outcome: complete, with
# CONDUCTOR_DIR and TASK_ID set and the scripts on PATH.
#
#   1. close the finishing worker's tmux window
#   2. gather the routing guards: the card's type, the project's test-cmd, and the locks guard
#   3. ask the topology where signal-complete type=<type> config.test-cmd=<...> locks=<...> sends
#      the task, and move it (design to done, a configured test-cmd to validation, chore and
#      spike to the merge stage, everything else to review)
#   4. start the destination stage (a spawn, a human notice, or nothing for a holding column)
#   5. if the task went to done (a design task does, with no validation, review or merge), unblock the
#      tasks that were waiting on it. on-merge-success does this for a task that is merged, and a task
#      that never merges would otherwise leave its dependents in backlog until the next startup reconcile.
#      The project is not checked for completion here: a design task is usually the first of several, and
#      the architect may not have finished creating the rest.
#
# The locks guard is computed for every task, as in on-validation-passed, for the same reason:
# knowing which routes land on a merge would copy the topology's branching into this script.
# test-cmd is the one guard that may be absent. An empty value, a missing key and a missing
# config.md all mean "not configured", which is a real answer the topology routes on, so unlike
# the type and the locks it does not stop the handler.
# The skill's last step, task-list.sh, only prints the board for a model to confirm.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-signal-complete: TASK_ID is not set}"

close_worker_window "$TASK_ID"
type="$(card_field "$TASK_ID" type)"
test_cmd="$(config_field test-cmd)"
guard="$(locks_guard "$TASK_ID")"
route_task "$TASK_ID" signal-complete "type=$type" "config.test-cmd=$test_cmd" "locks=$guard"
if [[ "$ROUTED_DEST" == "done" ]]; then unblock_dependents "$TASK_ID"; fi
