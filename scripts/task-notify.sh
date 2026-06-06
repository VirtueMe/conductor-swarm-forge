#!/usr/bin/env bash
set -euo pipefail
# Notify the human that a task is awaiting their decision at a mode: manual stage.
# Called by the conductor when a task enters a manual working stage — never by workers.
#
# Usage: task-notify.sh --task <id> --stage <stage>
# Env:   CONDUCTOR_DIR (default: .conductor)

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
TOPOLOGY_JSON="$CONDUCTOR_DIR/topology.json"

TASK_ID=""
STAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)  TASK_ID="$2"; shift 2 ;;
    --stage) STAGE="$2";   shift 2 ;;
    *) echo "Usage: task-notify.sh --task <id> --stage <stage>" >&2; exit 1 ;;
  esac
done

[[ -z "$TASK_ID" ]] && { echo "task-notify.sh: --task required" >&2; exit 1; }
[[ -z "$STAGE" ]]   && { echo "task-notify.sh: --stage required" >&2; exit 1; }

TASK_FILE="$CONDUCTOR_DIR/tasks/${TASK_ID}.md"
[[ -f "$TASK_FILE" ]] || { echo "Task $TASK_ID not found" >&2; exit 1; }

TITLE=$(awk 'BEGIN{f=0} /^---$/{f++; next} f==1 && /^title: /{sub(/^title: /,""); print; exit}' "$TASK_FILE")

# Read notify config from topology
CHANNEL=$(python3 - "$TOPOLOGY_JSON" "$STAGE" << 'PY'
import json, sys
t = json.load(open(sys.argv[1]))
spec = t["working_stages"].get(sys.argv[2], {})
print(spec.get("notify", {}).get("channel", "tmux"))
PY
)

AWAIT_CSV=$(python3 - "$TOPOLOGY_JSON" "$STAGE" << 'PY'
import json, sys
t = json.load(open(sys.argv[1]))
spec = t["working_stages"].get(sys.argv[2], {})
print(", ".join(spec.get("await", [])))
PY
)

MSG=$(python3 - "$TOPOLOGY_JSON" "$STAGE" "$TASK_ID" "$TITLE" << 'PY'
import json, sys
path, stage, task_id, title = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
t = json.load(open(path))
spec = t["working_stages"].get(stage, {})
tpl = spec.get("notify", {}).get("message", "Task {id} needs your decision at stage {stage}: {reason}")
print(tpl.replace("{id}", task_id).replace("{stage}", stage).replace("{reason}", title))
PY
)

TIMEOUT_AFTER=$(python3 - "$TOPOLOGY_JSON" "$STAGE" << 'PY'
import json, sys
t = json.load(open(sys.argv[1]))
spec = t["working_stages"].get(sys.argv[2], {})
print(spec.get("timeout", {}).get("after", ""))
PY
)

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Write human-inbox file so the human can find what's waiting
# printf avoids heredoc command-substitution: an unquoted <<EOF would execute
# backtick/$() sequences present in user-controlled values (TITLE, MSG, etc.).
mkdir -p "$CONDUCTOR_DIR/human-inbox"
{
  printf -- '---\ntask-id: %s\nstage: %s\ntimestamp: %s\naccepted-decisions: %s\n---\n' \
    "$TASK_ID" "$STAGE" "$TIMESTAMP" "$AWAIT_CSV"
  printf '%s\n\nTask: %s\nAccepted decisions: %s\n' "$MSG" "$TITLE" "$AWAIT_CSV"
  [[ -n "$TIMEOUT_AFTER" ]] && printf 'Timeout: %s\n' "$TIMEOUT_AFTER"
  printf '\nRespond:\n  scripts/task-respond.sh --task %s --decision <decision> [--notes "your notes"]\n' \
    "$TASK_ID"
} > "$CONDUCTOR_DIR/human-inbox/${TASK_ID}-${TIMESTAMP}.md"

# Always display in the conductor window
printf '\n%s\n' "=== HUMAN INPUT REQUIRED ==="
printf 'Task %s — %s\n' "$TASK_ID" "$TITLE"
printf 'Stage:     %s\n' "$STAGE"
printf 'Decisions: %s\n' "$AWAIT_CSV"
[[ -n "$TIMEOUT_AFTER" ]] && printf 'Timeout:   %s\n' "$TIMEOUT_AFTER"
printf 'Respond:   scripts/task-respond.sh --task %s --decision <decision>\n' "$TASK_ID"
printf '%s\n\n' "============================="

# Push notification — macOS only, graceful fail
# Strip double-quotes from MSG: embedding $MSG directly inside a "-quoted osascript
# string allows a title like Fix "auth" bug to close the AppleScript string literal
# early, causing a parse error or — with a crafted title — arbitrary AppleScript injection.
if [[ "$CHANNEL" == "push" ]] && command -v osascript &>/dev/null; then
  NOTIF_MSG="${MSG//\"/}"
  osascript -e "display notification \"$NOTIF_MSG\" with title \"Swarm: Human Input Required\" sound name \"Glass\"" 2>/dev/null || true
fi

# Record in work history so the kanban card shows the pending request
"$SCRIPTS_DIR/task-signal.sh" \
  --task "$TASK_ID" \
  --type progress \
  --notes "conductor: awaiting human decision at stage '$STAGE' — accepted: $AWAIT_CSV"
