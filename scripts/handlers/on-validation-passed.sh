#!/usr/bin/env bash
# on-validation-passed as a script: the mechanical steps of
# skills/conductor/on-validation-passed.md, with no model. The loop runs it for a validation
# artifact with outcome: passed, with CONDUCTOR_DIR, TASK_ID and the scripts on PATH.
#
#   1. close the finishing worker's tmux window
#   2. gather the routing guards: the card's type, and the locks guard
#   3. ask the topology where validation-passed type=<type> locks=<free|held> sends the task,
#      and move it (chore and spike go to the merge stage, everything else to review)
#   4. start the destination stage (a spawn, a human notice, or nothing for a holding column)
#
# The locks guard is computed for every task, though only a route that lands on a merge reads
# it. Knowing which types do would copy the topology's type branching into this script, and a
# route that did not get "locks" would park a chore on merge-pending without saying so. The cost
# is that a task going to review also stops if task-locks.sh fails. The skill's last step,
# task-list.sh, only prints the board for a model to confirm; a script has no one to confirm to.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-validation-passed: TASK_ID is not set}"

close_worker_window "$TASK_ID"
type="$(card_field "$TASK_ID" type)"
guard="$(locks_guard "$TASK_ID")"
route_task "$TASK_ID" validation-passed "type=$type" "locks=$guard"
