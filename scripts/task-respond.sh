#!/usr/bin/env bash
set -euo pipefail
# Submit a human decision for a task awaiting input at a mode: manual stage.
# This is the human-facing script — run it from the project root.
#
# Usage: task-respond.sh --task <id> --decision <decision> [--notes <text>]
# Env:   CONDUCTOR_DIR (default: .conductor)

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
TOPOLOGY_JSON="$CONDUCTOR_DIR/topology.json"

TASK_ID=""
DECISION=""
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)     TASK_ID="$2";   shift 2 ;;
    --decision) DECISION="$2";  shift 2 ;;
    --notes)    NOTES="$2";     shift 2 ;;
    *) echo "Usage: task-respond.sh --task <id> --decision <decision> [--notes <text>]" >&2; exit 1 ;;
  esac
done

[[ -z "$TASK_ID" ]]   && { echo "task-respond.sh: --task required" >&2; exit 1; }
[[ -z "$DECISION" ]]  && { echo "task-respond.sh: --decision required" >&2; exit 1; }

# Locate the task's current kanban stage
CURRENT_STAGE=$(find "$CONDUCTOR_DIR/kanban" -name "${TASK_ID}.md" 2>/dev/null \
  | head -1 | sed 's|.*/kanban/||; s|/.*||')

if [[ -n "$CURRENT_STAGE" ]]; then
  # Validate decision against the stage's await list
  VALID=$(python3 - "$TOPOLOGY_JSON" "$CURRENT_STAGE" "$DECISION" << 'PY'
import json, sys
path, stage, decision = sys.argv[1], sys.argv[2], sys.argv[3]
t = json.load(open(path))
spec = t["working_stages"].get(stage, {})
await_list = spec.get("await", [])
if not await_list:
    print(f"warning: stage '{stage}' has no await list; proceeding anyway")
elif decision in await_list:
    print("ok")
else:
    print(f"error: '{decision}' is not in accepted decisions for stage '{stage}': {await_list}")
PY
)
  if [[ "$VALID" == error:* ]]; then
    echo "$VALID" >&2
    exit 1
  fi
  [[ "$VALID" == warning:* ]] && echo "$VALID" >&2
fi

# Write the human artifact — conductor's watch loop picks this up as on-human-decision
"$SCRIPTS_DIR/task-signal.sh" \
  --task "$TASK_ID" \
  --type human \
  --outcome "$DECISION" \
  ${NOTES:+--notes "$NOTES"}

# Clean up human-inbox entry for this task
rm -f "$CONDUCTOR_DIR/human-inbox/${TASK_ID}"-*.md 2>/dev/null || true

echo "Decision '$DECISION' recorded for task $TASK_ID — conductor will route the task."
