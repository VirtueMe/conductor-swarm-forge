#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

ID="${1:?Usage: task-replay.sh <task-id>}"

TASKS_DIR="$CONDUCTOR_DIR/tasks"
WORK_DIR="$CONDUCTOR_DIR/work"
KANBAN_DIR="$CONDUCTOR_DIR/kanban"

TASK_FILE="$TASKS_DIR/${ID}.md"
[[ -f "$TASK_FILE" ]] || { echo "Task $ID not found" >&2; exit 1; }

# Kanban stages for the active topology — used to locate the card's current
# column and to default a brand-new card to the topology's first stage.
# shellcheck source=scripts/stages-resolve.sh
source "$SCRIPTS_DIR/stages-resolve.sh"
STAGES="$(topology_stages "$CONDUCTOR_DIR")"
FIRST_STAGE="$(printf '%s\n' "$STAGES" | head -1)"

# Extract a scalar field from YAML frontmatter
yaml_field() {
  local file="$1" field="$2"
  awk 'BEGIN{f=0} /^---$/{f++; next} f==1 && /^'"$field"': /{sub(/^'"$field"': /,""); print; exit}' "$file"
}

# Extract a list field from YAML frontmatter (one item per line)
yaml_list() {
  local file="$1" field="$2"
  awk 'BEGIN{f=0; found=0} /^---$/{f++; next} f==1 && /^'"$field"':/{found=1; next} found && /^  - /{sub(/^  - /,""); print; next} found && !/^  /{exit}' "$file"
}

# Extract body content after frontmatter
yaml_body() {
  awk '/^---$/{f++; next} f>=2{print}' "$1"
}

# Read base task info
TITLE=$(yaml_field "$TASK_FILE" "title")
TYPE=$(yaml_field "$TASK_FILE" "type")
TASK_BODY=$(yaml_body "$TASK_FILE")

# State to build up via replay
PRIORITY="normal"
WORKER_TYPE=""
BRANCH=""
WORKTREE=""
FILES_CHANGED=()
LAST_UPDATED=""
HISTORY=""

# Replay all artifacts in timestamp order
WORK_PATH="$WORK_DIR/$ID"
if [[ -d "$WORK_PATH" ]]; then
  # Timestamped filenames sort lexically into chronological order.
  for artifact in "$WORK_PATH"/*.md; do
    [[ -f "$artifact" ]] || continue

    ART_TYPE=$(yaml_field "$artifact" "type")
    ART_TIMESTAMP=$(yaml_field "$artifact" "timestamp")
    LAST_UPDATED="$ART_TIMESTAMP"

    case "$ART_TYPE" in
      card)
        PRIORITY=$(yaml_field "$artifact" "priority")
        HISTORY+="- $ART_TIMESTAMP  card created — priority: $PRIORITY"$'\n'
        ;;
      assigned)
        WORKER_TYPE=$(yaml_field "$artifact" "worker-type")
        BRANCH=$(yaml_field "$artifact" "branch")
        WORKTREE=$(yaml_field "$artifact" "worktree")
        HISTORY+="- $ART_TIMESTAMP  assigned to $WORKER_TYPE — branch: $BRANCH"$'\n'
        ;;
      progress)
        FIRST_LINE=$(yaml_body "$artifact" | head -1)
        HISTORY+="- $ART_TIMESTAMP  progress: $FIRST_LINE"$'\n'
        ;;
      drift)
        FIRST_LINE=$(yaml_body "$artifact" | head -1)
        HISTORY+="- $ART_TIMESTAMP  drift: $FIRST_LINE"$'\n'
        ;;
      signal)
        OUTCOME=$(yaml_field "$artifact" "outcome")
        FILES_CHANGED=()
        while IFS= read -r line; do
          [[ -n "$line" ]] && FILES_CHANGED+=("$line")
        done < <(yaml_list "$artifact" "files-changed")
        FIRST_LINE=$(yaml_body "$artifact" | head -1)
        HISTORY+="- $ART_TIMESTAMP  signal: $OUTCOME — $FIRST_LINE"$'\n'
        ;;
      review)
        OUTCOME=$(yaml_field "$artifact" "outcome")
        FIRST_LINE=$(yaml_body "$artifact" | head -1)
        HISTORY+="- $ART_TIMESTAMP  review: $OUTCOME — $FIRST_LINE"$'\n'
        ;;
      merge)
        OUTCOME=$(yaml_field "$artifact" "outcome")
        MERGE_FILES=()
        while IFS= read -r line; do
          [[ -n "$line" ]] && MERGE_FILES+=("$line")
        done < <(yaml_list "$artifact" "files-changed")
        [[ ${#MERGE_FILES[@]} -gt 0 ]] && FILES_CHANGED=("${MERGE_FILES[@]}")
        FIRST_LINE=$(yaml_body "$artifact" | head -1)
        HISTORY+="- $ART_TIMESTAMP  merge: $OUTCOME — $FIRST_LINE"$'\n'
        ;;
      moved)
        TO=$(yaml_field "$artifact" "to")
        HISTORY+="- $ART_TIMESTAMP  moved to $TO"$'\n'
        ;;
      done)
        HISTORY+="- $ART_TIMESTAMP  closed"$'\n'
        ;;
    esac
  done
fi

# Find current kanban location
CURRENT_COLUMN=""
CURRENT_CARD=""
for col in $STAGES; do
  if [[ -f "$KANBAN_DIR/$col/${ID}.md" ]]; then
    CURRENT_COLUMN="$col"
    CURRENT_CARD="$KANBAN_DIR/$col/${ID}.md"
    break
  fi
done

if [[ -z "$CURRENT_COLUMN" ]]; then
  CURRENT_COLUMN="$FIRST_STAGE"
  mkdir -p "$KANBAN_DIR/$FIRST_STAGE"
  CURRENT_CARD="$KANBAN_DIR/$FIRST_STAGE/${ID}.md"
fi

# Build files-changed YAML block
FILES_YAML=""
if [[ ${#FILES_CHANGED[@]} -gt 0 ]]; then
  FILES_YAML="files-changed:"$'\n'
  for f in "${FILES_CHANGED[@]}"; do
    FILES_YAML+="  - $f"$'\n'
  done
fi

# Clear worker info when task is done — no active worker.
# NOTE: the terminal stage is still the literal "done" by convention (every
# pack ends there); deferred until the topology declares a `terminal` field.
if [[ "$CURRENT_COLUMN" == "done" ]]; then
  WORKER_TYPE=""
  BRANCH=""
  WORKTREE=""
fi

# Write materialized kanban card
{
  printf -- '---\n'
  printf 'id: %s\n' "$ID"
  printf 'title: %s\n' "$TITLE"
  printf 'type: %s\n' "$TYPE"
  printf 'status: %s\n' "$CURRENT_COLUMN"
  printf 'priority: %s\n' "$PRIORITY"
  [[ -n "$WORKER_TYPE" ]] && printf 'worker-type: %s\n' "$WORKER_TYPE"
  [[ -n "$BRANCH" ]]      && printf 'branch: %s\n' "$BRANCH"
  [[ -n "$WORKTREE" ]]    && printf 'worktree: %s\n' "$WORKTREE"
  [[ -n "$FILES_YAML" ]]  && printf '%s' "$FILES_YAML"
  [[ -n "$LAST_UPDATED" ]] && printf 'last-updated: %s\n' "$LAST_UPDATED"
  printf -- '---\n'
  printf '\n%s\n' "$TASK_BODY"
  printf '\n## History\n%s' "${HISTORY:-}"
} > "$CURRENT_CARD"
