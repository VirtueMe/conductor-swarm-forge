#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
# shellcheck source=scripts/artifact-name.sh
source "$SCRIPTS_DIR/artifact-name.sh"

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

# Build everything except the timestamp line first. The name is claimed (an empty
# file appears) only once the content is ready, so the conductor never finds an
# artifact that is empty for longer than one write.
FM_HEAD="---"$'\n'
FM_HEAD+="type: $TYPE"$'\n'
FM_HEAD+="task-id: $TASK_ID"$'\n'
FM_TAIL=""
[[ -n "$OUTCOME" ]]     && FM_TAIL+="outcome: $OUTCOME"$'\n'
[[ -n "$WORKER_TYPE" ]] && FM_TAIL+="worker-type: $WORKER_TYPE"$'\n'
[[ -n "$BRANCH" ]]      && FM_TAIL+="branch: $BRANCH"$'\n'
[[ -n "$WORKTREE" ]]    && FM_TAIL+="worktree: $WORKTREE"$'\n'
if [[ -n "$FILES" ]]; then
  FM_TAIL+="files-changed:"$'\n'
  IFS=',' read -ra FILE_LIST <<< "$FILES"
  for f in "${FILE_LIST[@]}"; do
    FM_TAIL+="  - $(echo "$f" | xargs)"$'\n'
  done
fi
FM_TAIL+="---"$'\n'
[[ -n "$NOTES" ]] && FM_TAIL+="$NOTES"$'\n'

# Sets ARTIFACT and TIMESTAMP; never reuses the name of an earlier artifact.
artifact_claim "$WORK_DIR" "$TYPE"
printf '%s' "${FM_HEAD}timestamp: $TIMESTAMP"$'\n'"${FM_TAIL}" > "$ARTIFACT"

# Regenerate kanban card
"$SCRIPTS_DIR/task-replay.sh" "$TASK_ID"

echo "$ARTIFACT"
