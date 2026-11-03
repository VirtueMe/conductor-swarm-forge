#!/usr/bin/env bash
# on-review-rejected as a script: the mechanical steps of
# skills/conductor/on-review-rejected.md, with no model. The loop runs it for a review
# artifact with outcome: rejected, with CONDUCTOR_DIR, TASK_ID and ARTIFACT set and the scripts
# on PATH.
#
#   1. close the finishing worker's tmux window
#   2. write a progress note for the next worker
#   3. ask the topology where review-rejected sends the task (no guards: the rework
#      loopback), and move it
#   4. start the destination stage
#
# The same shape as on-validation-failed, and for the same reasons: the note points at the
# artifact instead of summarising it, since a script cannot, and the next worker's briefing
# carries the review artifact in full. The skill writes the note between the move and the stage
# start; route_task does both in one step, so here the note comes before it, and is in the
# history when stage-start.sh builds the worker's briefing.
# A retry after a failed move writes the note again; retries are bounded, and avoiding the
# repeat would take a marker, which is state this handler does not otherwise hold.
# The skill's last step, task-list.sh, only prints the board for a model to confirm.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-review-rejected: TASK_ID is not set}"
: "${ARTIFACT:?on-review-rejected: ARTIFACT is not set}"

close_worker_window "$TASK_ID"
progress_note "$TASK_ID" "review rejected" "${ARTIFACT#"$CONDUCTOR_DIR"/}"
route_task "$TASK_ID" review-rejected
