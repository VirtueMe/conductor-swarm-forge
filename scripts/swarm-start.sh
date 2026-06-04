#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
ADAPTERS_DIR="$ROOT_DIR/adapters"
PROMPTS_DIR="$ROOT_DIR/prompts"
SESSION="swarm"
KANBAN_SERVER=false
BRIEF_FILE=""
TARGET_DIR=""
LANG="typescript"
TEST_CMD=""
TOPOLOGY="software-dev"

usage() {
  echo "Usage: swarm-start.sh [target-dir] [--brief|-b <file>] [--lang|-l <language>] [--test-cmd|-tc <cmd>] [--topology|-tp <name>] [--kanban-server|-cbs]" >&2
  exit 1
}

# Parse positional target dir + flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kanban-server|-cbs) KANBAN_SERVER=true; shift ;;
    --brief|-b)           BRIEF_FILE="$2"; shift 2 ;;
    --lang|-l)            LANG="$2"; shift 2 ;;
    --test-cmd|-tc)       TEST_CMD="$2"; shift 2 ;;
    --topology|-tp)       TOPOLOGY="$2"; shift 2 ;;
    --help|-h)            usage ;;
    -*)                   echo "Unknown flag: $1" >&2; usage ;;
    *)
      [[ -z "$TARGET_DIR" ]] || { echo "Unexpected argument: $1" >&2; usage; }
      TARGET_DIR="$1"; shift ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
"$SCRIPTS_DIR/preflight-check.sh" \
  ${LANG:+--lang "$LANG"} \
  ${TEST_CMD:+--test-cmd "$TEST_CMD"} \
  ${KANBAN_SERVER:+--kanban-server} || exit 1

# Resolve and validate the topology before doing any work — fail fast.
TOPOLOGY_FILE="$("$SCRIPTS_DIR/topology-load.sh" resolve "$TOPOLOGY")" || {
  echo "Unknown topology: $TOPOLOGY (looked in $ROOT_DIR/topologies)" >&2; exit 1; }
"$SCRIPTS_DIR/topology-load.sh" validate "$TOPOLOGY_FILE" || exit 1

# The topology's integration model must have a matching adapter — fail fast.
# shellcheck source=scripts/integration-resolve.sh
source "$SCRIPTS_DIR/integration-resolve.sh"
integration_file "$TOPOLOGY_FILE" >/dev/null || exit 1

# Resolve target dir — create it if it doesn't exist
if [[ -n "$TARGET_DIR" ]]; then
  mkdir -p "$TARGET_DIR"
  TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
else
  TARGET_DIR="$(pwd)"
fi

# Resolve brief to absolute path before cd
if [[ -n "$BRIEF_FILE" ]]; then
  [[ -f "$BRIEF_FILE" ]] || { echo "Brief file not found: $BRIEF_FILE" >&2; exit 1; }
  BRIEF_FILE="$(cd "$(dirname "$BRIEF_FILE")" && pwd)/$(basename "$BRIEF_FILE")"
fi

# All subsequent operations run inside the target directory
cd "$TARGET_DIR"

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
WORKFORCE="${ROOT_DIR}/workforces/default.json"

echo "Target : $TARGET_DIR"
echo "Tool   : $ROOT_DIR"

# ── Git init ──────────────────────────────────────────────────────────────────

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  git init -q
  cat > .gitignore << 'EOF'
.conductor/
.worktrees/
CLAUDE.md
AGENTS.md
*.pid
*.log
EOF
  git add .gitignore
  git add -A 2>/dev/null || true
  git commit -q -m "chore: initial commit"
  echo "Git repository initialized"
elif [[ ! -f .gitignore ]]; then
  cat > .gitignore << 'EOF'
.conductor/
.worktrees/
CLAUDE.md
AGENTS.md
*.pid
*.log
EOF
  git add .gitignore
  git commit -q -m "chore: add swarm-forge .gitignore"
fi

# ── Conductor dirs ────────────────────────────────────────────────────────────

mkdir -p \
  "$CONDUCTOR_DIR/tasks" \
  "$CONDUCTOR_DIR/work" \
  "$CONDUCTOR_DIR/architect-inbox"

# Kanban columns come from the topology's stage list (one stage per line)
while IFS= read -r stage; do
  [[ -n "$stage" ]] && mkdir -p "$CONDUCTOR_DIR/kanban/$stage"
done < <("$SCRIPTS_DIR/topology-load.sh" stages "$TOPOLOGY_FILE")

# Copy skills, prompts, and the active topology into the project so agents
# never read outside it
cp -r "$ROOT_DIR/skills"  "$CONDUCTOR_DIR/skills"
cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
cp "$TOPOLOGY_FILE" "$CONDUCTOR_DIR/topology.json"

# Write project-level permissions: read/write the project, read/execute the scripts
mkdir -p ".claude"
cat > ".claude/settings.json" << EOF
{
  "permissions": {
    "allow": [
      "Bash($SCRIPTS_DIR/*)",
      "Bash(bash $SCRIPTS_DIR/*)",
      "Bash(git *)",
      "Bash(lein *)",
      "Bash(npm *)",
      "Bash(cargo *)",
      "Bash(go *)",
      "Bash(mix *)",
      "Bash(bundle *)",
      "Bash(pytest *)"
    ],
    "deny": [
      "Bash(brew *)",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(npm install *)",
      "Bash(pip install *)"
    ]
  }
}
EOF


# ── Project config ────────────────────────────────────────────────────────────

# Auto-detect test command if not explicitly provided
if [[ -z "$TEST_CMD" ]]; then
  TEST_CMD=$("$SCRIPTS_DIR/detect-test-cmd.sh" "." ${LANG:+--lang "$LANG"} 2>/dev/null || true)
fi

{
  printf -- '---\n'
  printf 'lang: %s\n'     "${LANG:-}"
  printf 'test-cmd: %s\n' "${TEST_CMD:-}"
  printf 'topology: %s\n' "$TOPOLOGY"
  printf -- '---\n'
} > "$CONDUCTOR_DIR/config.md"
echo "Topology : $TOPOLOGY"
[[ -n "$LANG" ]]     && echo "Language : $LANG"
if [[ -n "$TEST_CMD" ]]; then
  echo "Test cmd : $TEST_CMD"
else
  echo "Test cmd : (none detected — validation will be skipped)"
fi

# ── Conductor briefing ────────────────────────────────────────────────────────

ADAPTER_NAME=$(python3 - "$WORKFORCE" "conductor" << 'EOF'
import json, sys
wf = json.load(open(sys.argv[1]))
for m in wf["members"]:
    if m["role"] == sys.argv[2]:
        print(m["adapter"]); sys.exit(0)
sys.stderr.write("No conductor adapter in workforce\n"); sys.exit(1)
EOF
)

ADAPTER_FILE="$ADAPTERS_DIR/${ADAPTER_NAME}.sh"
[[ -f "$ADAPTER_FILE" ]] || { echo "Adapter not found: $ADAPTER_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ADAPTER_FILE"

SKILL_CONTENT=$(cat "$PROMPTS_DIR/conductor.prompt")
TASK_BODY="$(printf 'SKILLS_DIR: %s\nCONDUCTOR_DIR: %s/%s\nSCRIPTS_DIR: %s\nLANG: %s' \
  "$TARGET_DIR/$CONDUCTOR_DIR/skills" "$TARGET_DIR" "$CONDUCTOR_DIR" "$SCRIPTS_DIR" "${LANG:-unknown}")"

adapter_write_briefing \
  "." "conductor" "$SKILL_CONTENT" "$TASK_BODY" \
  "$SCRIPTS_DIR" "$TARGET_DIR" "main" "${LANG:-}"

echo "Conductor initialized (adapter: $ADAPTER_NAME)"

# ── Architect briefing ────────────────────────────────────────────────────────

if [[ -n "$BRIEF_FILE" ]]; then
  ARCH_ADAPTER_NAME=$(python3 - "$WORKFORCE" "architect" << 'EOF'
import json, sys
wf = json.load(open(sys.argv[1]))
for m in wf["members"]:
    if m["role"] == sys.argv[2]:
        print(m["adapter"]); sys.exit(0)
sys.stderr.write("No architect adapter in workforce\n"); sys.exit(1)
EOF
)
  ARCH_ADAPTER_FILE="$ADAPTERS_DIR/${ARCH_ADAPTER_NAME}.sh"
  [[ -f "$ARCH_ADAPTER_FILE" ]] || { echo "Architect adapter not found: $ARCH_ADAPTER_FILE" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$ARCH_ADAPTER_FILE"

  ARCH_SKILL=$(cat "$PROMPTS_DIR/architect.prompt")
  BRIEF_CONTENT=$(cat "$BRIEF_FILE")
  ARCH_BODY="$(printf 'SKILLS_DIR: %s\nCONDUCTOR_DIR: %s/%s\nSCRIPTS_DIR: %s\nLANG: %s\n\n---\n\n## Project Brief\n\n%s' \
    "$TARGET_DIR/$CONDUCTOR_DIR/skills" "$TARGET_DIR" "$CONDUCTOR_DIR" "$SCRIPTS_DIR" "${LANG:-unknown}" "$BRIEF_CONTENT")"

  cp "$BRIEF_FILE" "$CONDUCTOR_DIR/brief.md"
  mkdir -p ".worktrees/architect"
  adapter_write_briefing \
    ".worktrees/architect" "architect" "$ARCH_SKILL" "$ARCH_BODY" \
    "$SCRIPTS_DIR" "$TARGET_DIR" "main" "${LANG:-}"

  echo "Architect briefed from: $(basename "$BRIEF_FILE") (adapter: $ARCH_ADAPTER_NAME)"
fi

# ── Kanban board ──────────────────────────────────────────────────────────────

if [[ "$KANBAN_SERVER" == true ]]; then
  KANBAN_PID_FILE="$CONDUCTOR_DIR/kanban-server.pid"
  KANBAN_PORT_FILE="$CONDUCTOR_DIR/kanban-server.port"

  # Kill any existing instance for this project
  if [[ -f "$KANBAN_PID_FILE" ]]; then
    kill "$(cat "$KANBAN_PID_FILE")" 2>/dev/null || true
    rm -f "$KANBAN_PID_FILE" "$KANBAN_PORT_FILE"
  fi

  # Find a free port starting from PORT env var or 3000
  KANBAN_PORT="${PORT:-3000}"
  while nc -z localhost "$KANBAN_PORT" 2>/dev/null; do
    KANBAN_PORT=$(( KANBAN_PORT + 1 ))
  done

  CONDUCTOR_DIR="$CONDUCTOR_DIR" PORT="$KANBAN_PORT" \
    node "$ROOT_DIR/kanban-board.js" >> "$CONDUCTOR_DIR/kanban-server.log" 2>&1 &
  echo $! > "$KANBAN_PID_FILE"
  echo "$KANBAN_PORT" > "$KANBAN_PORT_FILE"
  echo "Kanban board → http://localhost:${KANBAN_PORT}"
fi

# ── tmux ─────────────────────────────────────────────────────────────────────

echo ""

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Attaching to existing tmux session '$SESSION'"
else
  echo "Starting tmux session '$SESSION'"
  adapter_launch "$SESSION" "conductor" "." "$TARGET_DIR"
  [[ -n "$BRIEF_FILE" ]] && adapter_launch "$SESSION" "architect" ".worktrees/architect" "$TARGET_DIR"

  # Kill kanban server automatically when the tmux session closes
  if [[ "$KANBAN_SERVER" == true ]]; then
    tmux set-hook -t "$SESSION" session-closed \
      "run-shell '$SCRIPTS_DIR/swarm-stop.sh $TARGET_DIR'"
  fi
fi

tmux attach-session -t "$SESSION"
