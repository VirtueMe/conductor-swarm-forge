#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

ID="${1:?Usage: task-move.sh <task-id> <column>}"
COLUMN="${2:?Usage: task-move.sh <task-id> <column>}"

KANBAN_DIR="$CONDUCTOR_DIR/kanban"
WORK_DIR="$CONDUCTOR_DIR/work/$ID"

# Valid columns are the active topology's stages, not a hardcoded list.
# shellcheck source=scripts/stages-resolve.sh
source "$SCRIPTS_DIR/stages-resolve.sh"
VALID_COLUMNS="$(topology_stages "$CONDUCTOR_DIR" | tr '\n' ' ')"
[[ " $VALID_COLUMNS " == *" $COLUMN "* ]] || { echo "Invalid column: $COLUMN. Valid: $VALID_COLUMNS" >&2; exit 1; }

mkdir -p "$KANBAN_DIR/$COLUMN" "$WORK_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Write moved artifact
{
  printf -- '---\n'
  printf 'type: moved\n'
  printf 'task-id: %s\n' "$ID"
  printf 'timestamp: %s\n' "$TIMESTAMP"
  printf 'to: %s\n' "$COLUMN"
  printf -- '---\n'
} > "$WORK_DIR/moved-${TIMESTAMP}.md"

# Move card from current column to new column, or create it
for col in $VALID_COLUMNS; do
  if [[ "$col" != "$COLUMN" && -f "$KANBAN_DIR/$col/${ID}.md" ]]; then
    mv "$KANBAN_DIR/$col/${ID}.md" "$KANBAN_DIR/$COLUMN/${ID}.md"
    break
  fi
done

# Regenerate card content in new location
"$SCRIPTS_DIR/task-replay.sh" "$ID"
