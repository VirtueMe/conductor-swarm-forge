#!/usr/bin/env bash
# on-validation-failed as a script: the mechanical steps of
# skills/conductor/on-validation-failed.md, with no model. The loop runs it for a validation
# artifact with outcome: failed, with CONDUCTOR_DIR, TASK_ID and ARTIFACT set and the scripts
# on PATH.
#
#   1. close the finishing worker's tmux window
#   2. write a progress note for the next worker
#   3. ask the topology where validation-failed sends the task: the rework loopback, unless the
#      task has failed validation too many times in a row (the topology's count guard, #185), in
#      which case it is parked in validation and the architect and the person are told
#   4. start the destination stage
#
# The skill has the model summarise the failure in the note. A script cannot, so the note points
# at the artifact instead; the next worker's briefing carries the full work history, validation
# artifact included, so nothing is lost. As in the skill, the note is written before the move,
# so a retry after a failed move writes it again; retries are bounded, and avoiding the repeat
# would take a marker, which is state this handler does not otherwise hold.
# The skill's last step, task-list.sh, only prints the board for a model to confirm.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-validation-failed: TASK_ID is not set}"
: "${ARTIFACT:?on-validation-failed: ARTIFACT is not set}"

close_worker_window "$TASK_ID"
# The topology may send a task that keeps failing to @escalate (#185): count the failures in a row.
failures="$(failed_validations "$TASK_ID")"
dest="$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" validation-failed "count.validation-failed=$failures")"
if [[ "$dest" == @escalate ]]; then
  escalate_validation_loop "$TASK_ID" "$failures" "$ARTIFACT"
  exit 0
fi
progress_note "$TASK_ID" "validation failed" "${ARTIFACT#"$CONDUCTOR_DIR"/}"
route_task "$TASK_ID" validation-failed "count.validation-failed=$failures"
