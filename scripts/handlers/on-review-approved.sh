#!/usr/bin/env bash
# on-review-approved as a script: the mechanical steps of
# skills/conductor/on-review-approved.md, with no model. The loop runs it for a review
# artifact with outcome: approved, with CONDUCTOR_DIR, TASK_ID and the scripts on PATH.
#
#   1. close the finishing worker's tmux window
#   2. compute the locks guard (fails closed: if it cannot tell, the handler stops)
#   3. ask the topology where review-approved locks=<free|held> sends the task, and move it
#   4. start the destination stage (a spawn, a human notice, or nothing for a holding column)
#
# The skill's last step, task-list.sh, only prints the board for a model to confirm; a script
# has no one to confirm to.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-review-approved: TASK_ID is not set}"

close_worker_window "$TASK_ID"
guard="$(locks_guard "$TASK_ID")"
route_task "$TASK_ID" review-approved "locks=$guard"
