#!/usr/bin/env bash
# on-new-task as a script: the mechanical steps of skills/conductor/on-new-task.md, with no
# model. The loop runs it for a task's card artifact, with CONDUCTOR_DIR, TASK_ID and TASK_FILE
# set and the scripts on PATH.
#
#   0. skip a replayed event: a card already in any column but the first stage means the task
#      was placed, and routing it again would pull it back. A skip is a success (exit 0, no
#      move), so the loop records the event as done
#   1. gather the type and the deps guard (all-done, or pending)
#   2. ask the topology where new-task type=<...> deps=<...> sends the task, and move it
#   3. start the destination stage (a spawn, a notice, or nothing for a holding column)
#   4. if the task went to done (a design task does, the architect having written it), unblock the
#      tasks that were waiting on it
#
# The skill's replay guard is kept as it is, including what it cannot see: a card that reached
# the second stage but whose worker never started (a crash between the move and the start) is
# also "placed", and this skips it. The startup reconcile starts the entry stage of any card in
# ready, so a restart repairs it; a retry within the same run does not.
# The skill's last step, task-list.sh, only prints the board for a model to confirm.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

: "${TASK_ID:?on-new-task: TASK_ID is not set}"

if card="$(card_path "$TASK_ID")"; then
  first="$(topology-load.sh stages "$CONDUCTOR_DIR/topology.json" | sed -n 1p)"
  if [[ -z "$first" ]]; then
    echo "on-new-task: the topology lists no stages, so the first one is unknown" >&2
    exit 1
  fi
  stage="$(basename "$(dirname "$card")")"
  if [[ "$stage" != "$first" ]]; then
    echo "on-new-task: $TASK_ID already placed ($stage), skipped" >&2
    exit 0
  fi
fi

# The task file, not the card: the card may not exist yet, and the type is written once, at creation.
: "${TASK_FILE:?on-new-task: TASK_FILE is not set}"
type="$(fm_field "$TASK_FILE" type)"
if [[ -z "$type" ]]; then echo "on-new-task: task $TASK_ID has no type, so its route is unknown" >&2; exit 1; fi
deps="$(deps_done "$TASK_ID")"
route_task "$TASK_ID" new-task "type=$type" "deps=$deps"
if [[ "$ROUTED_DEST" == "done" ]]; then unblock_dependents "$TASK_ID"; fi
