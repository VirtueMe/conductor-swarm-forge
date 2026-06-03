#!/usr/bin/env bash
set -euo pipefail

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
CONDUCTOR_ID_PADDING="${CONDUCTOR_ID_PADDING:-4}"

TITLE=""
TYPE="feature"
DEPENDS_ON=""
DESCRIPTION=""

usage() {
  echo "Usage: task-create.sh --title <title> [--type <type>] [--depends-on <id,...>] [--description <text>]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)       TITLE="$2";       shift 2 ;;
    --type)        TYPE="$2";        shift 2 ;;
    --depends-on)  DEPENDS_ON="$2";  shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$TITLE" ]] && usage

TASKS_DIR="$CONDUCTOR_DIR/tasks"
WORK_DIR="$CONDUCTOR_DIR/work"

mkdir -p "$TASKS_DIR" "$WORK_DIR"

# Auto-increment ID with zero padding
LAST_ID=$(ls "$TASKS_DIR" 2>/dev/null | grep -E "^[0-9]+\.md$" | sed 's/\.md$//' | sort -n | tail -1 || true)
NEXT_NUM=$(( 10#${LAST_ID:-0} + 1 ))
ID=$(printf "%0${CONDUCTOR_ID_PADDING}d" "$NEXT_NUM")

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Build depends-on YAML block
if [[ -z "$DEPENDS_ON" ]]; then
  DEPENDS_YAML="depends-on: []"
else
  DEPENDS_YAML="depends-on:"
  IFS=',' read -ra DEPS <<< "$DEPENDS_ON"
  for dep in "${DEPS[@]}"; do
    dep=$(echo "$dep" | xargs)
    DEPENDS_YAML+=$'\n'"  - $dep"
  done
fi

# Write immutable task file
{
  printf -- '---\n'
  printf 'id: %s\n' "$ID"
  printf 'title: %s\n' "$TITLE"
  printf 'type: %s\n' "$TYPE"
  printf '%s\n' "$DEPENDS_YAML"
  printf -- '---\n'
  printf '\n## Description\n%s\n' "$DESCRIPTION"
  printf '\n## Acceptance Criteria\n- [ ] \n'
} > "$TASKS_DIR/${ID}.md"

# Write initial card artifact
mkdir -p "$WORK_DIR/$ID"
{
  printf -- '---\n'
  printf 'type: card\n'
  printf 'task-id: %s\n' "$ID"
  printf 'timestamp: %s\n' "$TIMESTAMP"
  printf 'priority: normal\n'
  printf 'notes: Created\n'
  printf -- '---\n'
} > "$WORK_DIR/$ID/card-${TIMESTAMP}.md"

# Place in backlog
"$(dirname "$0")/task-move.sh" "$ID" backlog

echo "$ID"
