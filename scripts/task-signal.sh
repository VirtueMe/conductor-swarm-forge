#!/usr/bin/env bash
set -euo pipefail

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

TASK_ID=""
TYPE=""
OUTCOME=""
WORKER_TYPE=""
BRANCH=""
WORKTREE=""
FILES=""
NOTES=""

usage() {
  echo "Usage: task-signal.sh --task <id> --type <type> [--outcome <outcome>] [--worker-type <type>] [--branch <branch>] [--worktree <path>] [--files <file,...>] [--notes <text>]" >&2
  echo "Types: assigned progress drift signal review merge done" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)        TASK_ID="$2";     shift 2 ;;
    --type)        TYPE="$2";        shift 2 ;;
    --outcome)     OUTCOME="$2";     shift 2 ;;
    --worker-type) WORKER_TYPE="$2"; shift 2 ;;
    --branch)      BRANCH="$2";      shift 2 ;;
    --worktree)    WORKTREE="$2";    shift 2 ;;
    --files)       FILES="$2";       shift 2 ;;
    --notes)       NOTES="$2";       shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$TASK_ID" || -z "$TYPE" ]] && usage

WORK_DIR="$CONDUCTOR_DIR/work/$TASK_ID"
mkdir -p "$WORK_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARTIFACT="$WORK_DIR/${TYPE}-${TIMESTAMP}.md"

# Build artifact frontmatter
FM="---"$'\n'
FM+="type: $TYPE"$'\n'
FM+="task-id: $TASK_ID"$'\n'
FM+="timestamp: $TIMESTAMP"$'\n'
[[ -n "$OUTCOME" ]]     && FM+="outcome: $OUTCOME"$'\n'
[[ -n "$WORKER_TYPE" ]] && FM+="worker-type: $WORKER_TYPE"$'\n'
[[ -n "$BRANCH" ]]      && FM+="branch: $BRANCH"$'\n'
[[ -n "$WORKTREE" ]]    && FM+="worktree: $WORKTREE"$'\n'
if [[ -n "$FILES" ]]; then
  FM+="files-changed:"$'\n'
  IFS=',' read -ra FILE_LIST <<< "$FILES"
  for f in "${FILE_LIST[@]}"; do
    FM+="  - $(echo "$f" | xargs)"$'\n'
  done
fi
FM+="---"$'\n'
[[ -n "$NOTES" ]] && FM+="$NOTES"$'\n'

printf '%s' "$FM" > "$ARTIFACT"

# Regenerate kanban card
"$(dirname "$0")/task-replay.sh" "$TASK_ID"

echo "$ARTIFACT"
