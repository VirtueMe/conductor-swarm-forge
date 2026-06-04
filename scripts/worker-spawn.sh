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

TOPOLOGY_JSON="$CONDUCTOR_DIR/topology.json"

# Valid worker types are the working-stage roles declared in the active topology.
VALID_TYPES="$("$SCRIPTS_DIR/topology-load.sh" roles "$TOPOLOGY_JSON" | tr '\n' ' ')"
[[ " $VALID_TYPES " == *" $WORKER_TYPE "* ]] || {
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

# Map a worker-type (role) to its working stage from the topology. worker-spawn
# is invoked with a ROLE, but the topology's skill accessor is keyed by STAGE, so
# we find the working stage whose role equals the worker-type. Kept local (rather
# than added to topology-load.sh) — it's the caller's role→stage concern.
stage_for_role() {
  local role="$1"
  python3 - "$TOPOLOGY_JSON" "$role" << 'EOF'
import json, sys
t = json.load(open(sys.argv[1]))
for stage, spec in t["working_stages"].items():
    if spec.get("role") == sys.argv[2]:
        print(stage); sys.exit(0)
sys.stderr.write(f"No working stage for role: {sys.argv[2]}\n"); sys.exit(1)
EOF
}

# Select the appropriate skill file based on work history.
# Reading history (which artifact is most recent + its outcome) is the caller's
# job; we distil it into a `last_artifact` token (merge checked before review)
# and hand it to the topology's skill accessor, which maps token → skill.
select_skill() {
  local task_id="$1"
  local role="$2"
  local work_dir="$CONDUCTOR_DIR/work/$task_id"

  local stage
  stage=$(stage_for_role "$role")

  local last_artifact=""

  # Most recent merge artifact — conflict? (checked before review)
  local latest_merge
  latest_merge=$(ls "$work_dir"/merge-*.md 2>/dev/null | sort | tail -1 || true)
  if [[ -n "$latest_merge" ]]; then
    [[ "$(yaml_field "outcome" "$latest_merge")" == "conflict" ]] && last_artifact="merge:conflict"
  fi

  # Most recent review artifact — rejected?
  if [[ -z "$last_artifact" ]]; then
    local latest_review
    latest_review=$(ls "$work_dir"/review-*.md 2>/dev/null | sort | tail -1 || true)
    if [[ -n "$latest_review" ]]; then
      [[ "$(yaml_field "outcome" "$latest_review")" == "rejected" ]] && last_artifact="review:rejected"
    fi
  fi

  if [[ -n "$last_artifact" ]]; then
    "$SCRIPTS_DIR/topology-load.sh" skill "$TOPOLOGY_JSON" "$stage" "$last_artifact"
  else
    "$SCRIPTS_DIR/topology-load.sh" skill "$TOPOLOGY_JSON" "$stage"
  fi
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

# Load the integration adapter (how work is isolated/consolidated) from the
# topology's `integration` field — git, shared-doc, none.
# shellcheck source=scripts/integration-resolve.sh
source "$SCRIPTS_DIR/integration-resolve.sh"
source_integration "$TOPOLOGY_JSON" || exit 1

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

# Prepare the workspace via the integration adapter. It prints "<workspace>\t<branch>"
# (branch empty for branchless integration models).
TITLE=$(yaml_field "title" "$TASK_FILE")
IFS=$'\t' read -r WORKTREE_PATH BRANCH < <(integration_prepare_workspace "$TASK_ID" "$WORKER_TYPE" "$TITLE")

# Write assigned artifact, then move the card to the role's working stage.
# stage_for_role maps the role back to the stage that spawns it: for the coder
# this is the ready→in-progress transition; for reviewer/merger it matches the
# column the conductor already routed the card to (so the move is idempotent).
"$SCRIPTS_DIR/task-signal.sh" \
  --task "$TASK_ID" \
  --type assigned \
  --worker-type "$WORKER_TYPE" \
  --branch "$BRANCH" \
  --worktree "$WORKTREE_PATH"

WORK_STAGE=$(stage_for_role "$WORKER_TYPE")
"$SCRIPTS_DIR/task-move.sh" "$TASK_ID" "$WORK_STAGE"

# Write briefing and launch via adapter
adapter_write_briefing \
  "$WORKTREE_PATH" "$TASK_ID" "$SKILL_CONTENT" "$TASK_BODY" \
  "$SCRIPTS_DIR" "$PROJECT_DIR" "$BRANCH" "${LANG:-}" "${TEST_CMD:-}"

adapter_launch "$SESSION" "${WORKER_TYPE}-${TASK_ID}" "$WORKTREE_PATH" "$PROJECT_DIR"

echo "Spawned $WORKER_TYPE ($ADAPTER_NAME) for task $TASK_ID — skill: $SKILL_PATH"
