#!/usr/bin/env bash
set -euo pipefail

# Spawns a worker: selects the right skill, writes a briefing via the workforce
# adapter, creates the worktree, and opens a tmux window.
# The conductor calls this — never workers directly.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
PROJECT_DIR="$(pwd)"
# Normalise CONDUCTOR_DIR — keep absolute paths, default relative to .conductor
if [[ -z "${CONDUCTOR_DIR:-}" ]]; then
  CONDUCTOR_DIR=".conductor"
elif [[ "$CONDUCTOR_DIR" != /* ]]; then
  CONDUCTOR_DIR="$(cd "$CONDUCTOR_DIR" 2>/dev/null && pwd || echo "$CONDUCTOR_DIR")"
fi
WORKFORCE="${WORKFORCE:-$ROOT_DIR/workforces/default.json}"
ADAPTERS_DIR="$ROOT_DIR/adapters"
# Skills are copied into the project at swarm-start time so agents read locally
SKILLS_DIR="$CONDUCTOR_DIR/skills"
SESSION="swarm"

TASK_ID="${1:?Usage: worker-spawn.sh <task-id> <worker-type>}"
WORKER_TYPE="${2:?Usage: worker-spawn.sh <task-id> <worker-type>}"

VALID_TYPES="coder validator reviewer merger"
[[ " $VALID_TYPES " =~ " $WORKER_TYPE " ]] || {
  echo "Invalid worker type: $WORKER_TYPE. Valid: $VALID_TYPES" >&2; exit 1
}

# --- Helpers -----------------------------------------------------------------

yaml_field() {
  awk 'BEGIN{f=0} /^---$/{f++; next} f==1 && /^'"$1"': /{sub(/^'"$1"': /,""); print; exit}' "$2"
}

yaml_body() {
  awk '/^---$/{f++; next} f>=2{print}' "$1"
}

# Read the adapter name for a role from the workforce JSON (requires python3)
get_adapter() {
  local role="$1"
  python3 - "$WORKFORCE" "$role" << 'EOF'
import json, sys
wf = json.load(open(sys.argv[1]))
for m in wf["members"]:
    if m["role"] == sys.argv[2]:
        print(m["adapter"]); sys.exit(0)
sys.stderr.write(f"No adapter found for role: {sys.argv[2]}\n"); sys.exit(1)
EOF
}

# Select the appropriate skill file based on work history
select_skill() {
  local task_id="$1"
  local role="$2"
  local work_dir="$CONDUCTOR_DIR/work/$task_id"

  [[ "$role" == "validator" ]] && echo "validator/validate" && return
  [[ "$role" == "reviewer"  ]] && echo "reviewer/review"   && return
  [[ "$role" == "merger"    ]] && echo "merger/merge"      && return
  [[ "$role" != "coder" ]]    && echo "$role/$role"        && return

  # Most recent merge artifact — conflict?
  local latest_merge
  latest_merge=$(ls "$work_dir"/merge-*.md 2>/dev/null | sort | tail -1 || true)
  if [[ -n "$latest_merge" ]]; then
    local outcome
    outcome=$(yaml_field "outcome" "$latest_merge")
    [[ "$outcome" == "conflict" ]] && echo "coder/on-conflict" && return
  fi

  # Most recent review artifact — rejected?
  local latest_review
  latest_review=$(ls "$work_dir"/review-*.md 2>/dev/null | sort | tail -1 || true)
  if [[ -n "$latest_review" ]]; then
    local outcome
    outcome=$(yaml_field "outcome" "$latest_review")
    [[ "$outcome" == "rejected" ]] && echo "coder/on-rejection" && return
  fi

  echo "coder/fresh-start"
}

# --- Main --------------------------------------------------------------------

TASK_FILE="$CONDUCTOR_DIR/tasks/${TASK_ID}.md"
[[ -f "$TASK_FILE" ]] || { echo "Task $TASK_ID not found" >&2; exit 1; }

# Read project config
CONFIG_FILE="$CONDUCTOR_DIR/config.md"
LANG=""
TEST_CMD=""
if [[ -f "$CONFIG_FILE" ]]; then
  LANG=$(yaml_field "lang" "$CONFIG_FILE")
  TEST_CMD=$(yaml_field "test-cmd" "$CONFIG_FILE")
fi

# Derive branch name and worktree path
TITLE=$(yaml_field "title" "$TASK_FILE")
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
BRANCH="feature/${TASK_ID}-${SLUG}"
WORKTREE_PATH=".worktrees/${WORKER_TYPE}-${TASK_ID}"

# Load adapter
ADAPTER_NAME=$(get_adapter "$WORKER_TYPE")
ADAPTER_FILE="$ADAPTERS_DIR/${ADAPTER_NAME}.sh"
[[ -f "$ADAPTER_FILE" ]] || { echo "Adapter not found: $ADAPTER_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ADAPTER_FILE"

# Select and read skill
SKILL_PATH=$(select_skill "$TASK_ID" "$WORKER_TYPE")
SKILL_FILE="$SKILLS_DIR/${SKILL_PATH}.md"
[[ -f "$SKILL_FILE" ]] || { echo "Skill not found: $SKILL_FILE" >&2; exit 1; }
SKILL_CONTENT=$(cat "$SKILL_FILE")

# Read task body
TASK_BODY=$(yaml_body "$TASK_FILE")

# Create git worktree
if [[ ! -d "$WORKTREE_PATH" ]]; then
  git worktree add "$WORKTREE_PATH" -b "$BRANCH" 2>/dev/null || \
  git worktree add "$WORKTREE_PATH" "$BRANCH"
fi

# Write assigned artifact and move to in-progress
"$SCRIPTS_DIR/task-signal.sh" \
  --task "$TASK_ID" \
  --type assigned \
  --worker-type "$WORKER_TYPE" \
  --branch "$BRANCH" \
  --worktree "$WORKTREE_PATH"

"$SCRIPTS_DIR/task-move.sh" "$TASK_ID" in-progress

# Write briefing and launch via adapter
adapter_write_briefing \
  "$WORKTREE_PATH" "$TASK_ID" "$SKILL_CONTENT" "$TASK_BODY" \
  "$SCRIPTS_DIR" "$PROJECT_DIR" "$BRANCH" "${LANG:-}" "${TEST_CMD:-}"

adapter_launch "$SESSION" "${WORKER_TYPE}-${TASK_ID}" "$WORKTREE_PATH" "$PROJECT_DIR"

echo "Spawned $WORKER_TYPE ($ADAPTER_NAME) for task $TASK_ID — skill: $SKILL_PATH"
