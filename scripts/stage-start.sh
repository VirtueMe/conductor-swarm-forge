#!/usr/bin/env bash
set -euo pipefail
# Start whatever a task's new stage needs: spawn the stage's worker, notify a
# human for a manual stage, or do nothing for a holding column.
#
# Every conductor handler used to repeat this as inline "derive the role and mode
# from the topology, then spawn or notify" bash. This is its single source of
# truth, so the destination logic is edited in one place and can be tested.
#
# Usage: stage-start.sh <task-id> <stage>
# Env:   CONDUCTOR_DIR (default: .conductor)
#
#   - a stage with a role        -> worker-spawn.sh <task-id> <role>
#   - a stage with mode: manual  -> task-notify.sh --task <task-id> --stage <stage>
#   - the holding column right before the entry stage (`ready` in the shipped
#     topologies) -> start the entry stage: its worker, or a notification if the
#     entry stage is manual
#   - any other holding column (backlog, merge-pending, done) -> nothing
#
# The entry-holding column is found from the stage order, not by name, so a
# topology may call it anything. Run it after task-move.sh; calling it twice for
# the same task is safe because worker-spawn.sh skips a task that already has a
# live worker.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
TOPOLOGY_JSON="$CONDUCTOR_DIR/topology.json"

TASK_ID="${1:?Usage: stage-start.sh <task-id> <stage>}"
STAGE="${2:?Usage: stage-start.sh <task-id> <stage>}"

topo() { "$SCRIPTS_DIR/topology-load.sh" "$@"; }

# Fail loudly on a stage the topology does not know. Treating a typo as a holding
# column would silently strand the task.
STAGES="$(topo stages "$TOPOLOGY_JSON")"
if ! grep -qxF -- "$STAGE" <<< "$STAGES"; then
  echo "stage-start.sh: unknown stage '$STAGE' (not in $TOPOLOGY_JSON)" >&2
  exit 2
fi

ROLE="$(topo role "$TOPOLOGY_JSON" "$STAGE")"
MODE="$(topo mode "$TOPOLOGY_JSON" "$STAGE")"

if [[ -n "$ROLE" ]]; then
  exec "$SCRIPTS_DIR/worker-spawn.sh" "$TASK_ID" "$ROLE"
elif [[ "$MODE" == "manual" ]]; then
  exec "$SCRIPTS_DIR/task-notify.sh" --task "$TASK_ID" --stage "$STAGE"
fi

# A holding column. Only the one right before the entry stage starts the pipeline.
ENTRY_STAGE="$(topo entry-stage "$TOPOLOGY_JSON")"
ENTRY_HOLD=""
previous=""
while IFS= read -r candidate; do
  if [[ "$candidate" == "$ENTRY_STAGE" ]]; then ENTRY_HOLD="$previous"; break; fi
  previous="$candidate"
done <<< "$STAGES"

if [[ -n "$ENTRY_HOLD" && "$STAGE" == "$ENTRY_HOLD" ]]; then
  # The entry stage's own role. (`entry-role` would skip a manual entry stage and
  # return the role of the first stage that has one, spawning the wrong worker.)
  ENTRY_ROLE="$(topo role "$TOPOLOGY_JSON" "$ENTRY_STAGE")"
  if [[ -n "$ENTRY_ROLE" ]]; then
    exec "$SCRIPTS_DIR/worker-spawn.sh" "$TASK_ID" "$ENTRY_ROLE"
  else
    exec "$SCRIPTS_DIR/task-notify.sh" --task "$TASK_ID" --stage "$ENTRY_STAGE"
  fi
fi

echo "stage-start.sh: '$STAGE' is a holding column — nothing to start for task $TASK_ID"
