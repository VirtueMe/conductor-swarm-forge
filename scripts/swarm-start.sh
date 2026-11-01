#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
ADAPTERS_DIR="$ROOT_DIR/adapters"
PROMPTS_DIR="$ROOT_DIR/prompts"
SESSION="swarm"
KANBAN_SERVER=false
HEADLESS=false
BRIEF_FILE=""
TARGET_DIR=""
LANG="typescript"
TEST_CMD=""
TOPOLOGY="software-dev"
WORKFORCE_NAME="default"
BASE_BRANCH=""

usage() {
  echo "Usage: swarm-start.sh [target-dir] [--brief|-b <file>] [--lang|-l <language>] [--test-cmd|-tc <cmd>] [--topology|-tp <name>] [--workforce|-wf <name>] [--base-branch|-bb <name>] [--kanban-server|-cbs] [--headless-conductor|-hc]" >&2
  exit 1
}

# Parse positional target dir + flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kanban-server|-cbs) KANBAN_SERVER=true; shift ;;
    --headless-conductor|-hc) HEADLESS=true; shift ;;
    --brief|-b)           BRIEF_FILE="$2"; shift 2 ;;
    --lang|-l)            LANG="$2"; shift 2 ;;
    --test-cmd|-tc)       TEST_CMD="$2"; shift 2 ;;
    --topology|-tp)       TOPOLOGY="$2"; shift 2 ;;
    --workforce|-wf)      WORKFORCE_NAME="$2"; shift 2 ;;
    --base-branch|-bb)    BASE_BRANCH="$2"; shift 2 ;;
    --help|-h)            usage ;;
    -*)                   echo "Unknown flag: $1" >&2; usage ;;
    *)
      [[ -z "$TARGET_DIR" ]] || { echo "Unexpected argument: $1" >&2; usage; }
      TARGET_DIR="$1"; shift ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
PREFLIGHT_ARGS=()
[[ "$HEADLESS" == true ]] && PREFLIGHT_ARGS+=(--conductor-loop)   # GNU timeout and jq, for the loop
"$SCRIPTS_DIR/preflight-check.sh" \
  ${LANG:+--lang "$LANG"} \
  ${TEST_CMD:+--test-cmd "$TEST_CMD"} \
  ${KANBAN_SERVER:+--kanban-server} \
  ${PREFLIGHT_ARGS[@]+"${PREFLIGHT_ARGS[@]}"} || exit 1

# Resolve and check the topology before doing any work — fail fast.
# `check` runs structural validate then behavioral completeness (e.g. manual stages need a human handler).
TOPOLOGY_FILE="$("$SCRIPTS_DIR/topology-load.sh" resolve "$TOPOLOGY")" || {
  echo "Unknown topology: $TOPOLOGY (looked in $ROOT_DIR/topologies)" >&2; exit 1; }
"$SCRIPTS_DIR/topology-load.sh" check "$TOPOLOGY_FILE" || exit 1

# The topology's integration model must have a matching adapter — fail fast.
# shellcheck source=scripts/integration-resolve.sh
source "$SCRIPTS_DIR/integration-resolve.sh"
integration_file "$TOPOLOGY_FILE" >/dev/null || exit 1

# Resolve the workforce (role → agent adapter) — fail fast if missing. A topology
# declares the roles; the workforce says who runs them, so a non-default pack
# (e.g. marketing) selects its own with --workforce.
WORKFORCE="${ROOT_DIR}/workforces/${WORKFORCE_NAME}.json"
[[ -f "$WORKFORCE" ]] || { echo "Unknown workforce: $WORKFORCE_NAME (looked in $ROOT_DIR/workforces)" >&2; exit 1; }

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
# CONDUCTOR_POLL_INTERVAL — seconds the conductor sleeps between polls when the
# artifact queue is empty (default 3). Written to config.md so the conductor can read it.
# CONDUCTOR_NOTIFY_CHANNEL — "push" adds a desktop notification (macOS) when the headless
#                            conductor loop halts. Anything else: no notification beyond the
#                            conductor window and the inbox files. Default: none.
# WORKFORCE was resolved and existence-checked above (from --workforce).

echo "Target : $TARGET_DIR"
echo "Tool   : $ROOT_DIR"

# ── Git init ──────────────────────────────────────────────────────────────────

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  git init -q
  cat > .gitignore << 'EOF'
.conductor/
.worktrees/
.export/
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
.export/
AGENTS.md
*.pid
*.log
EOF
  git add .gitignore
  git commit -q -m "chore: add swarm-forge .gitignore"
fi

# ── Base branch ───────────────────────────────────────────────────────────────

# Task branches fork from the base branch and merges land on it. Without
# --base-branch the repo's default branch is used as-is (nothing created or
# switched). A named base is reused if it exists, else created from the default.
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH=$("$SCRIPTS_DIR/base-branch-resolve.sh" --default 2>/dev/null) \
    || BASE_BRANCH=$(git symbolic-ref --short HEAD)
  echo "Base     : $BASE_BRANCH (default)"
else
  read -r BASE_CASE _ < <("$SCRIPTS_DIR/base-branch-resolve.sh" "$BASE_BRANCH") || exit 1
  echo "Base     : $BASE_BRANCH ($BASE_CASE)"
fi

# ── Conductor dirs ────────────────────────────────────────────────────────────

mkdir -p \
  "$CONDUCTOR_DIR/tasks" \
  "$CONDUCTOR_DIR/work" \
  "$CONDUCTOR_DIR/architect-inbox"

# Cursor file for the conductor's batch-drain loop — initialised to now so the
# startup scan owns pre-existing artifacts and the poll loop owns what comes after.
touch "$CONDUCTOR_DIR/last-poll"

# Kanban columns come from the topology's stage list (one stage per line)
while IFS= read -r stage; do
  [[ -n "$stage" ]] && mkdir -p "$CONDUCTOR_DIR/kanban/$stage"
done < <("$SCRIPTS_DIR/topology-load.sh" stages "$TOPOLOGY_FILE")

# Copy skills, prompts, and the active topology + workforce into the project so
# agents never read outside it. worker-spawn reads the workforce from here (the
# conductor invokes it without inheriting this shell's env).
cp -r "$ROOT_DIR/skills"  "$CONDUCTOR_DIR/skills"
cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
cp "$TOPOLOGY_FILE" "$CONDUCTOR_DIR/topology.json"
cp "$WORKFORCE"     "$CONDUCTOR_DIR/workforce.json"

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
  printf 'lang: %s\n'          "${LANG:-}"
  printf 'test-cmd: %s\n'      "${TEST_CMD:-}"
  printf 'topology: %s\n'      "$TOPOLOGY"
  printf 'base-branch: %s\n'   "$BASE_BRANCH"
  printf 'poll-interval: %s\n' "${CONDUCTOR_POLL_INTERVAL:-3}"
  printf 'notify-channel: %s\n' "${CONDUCTOR_NOTIFY_CHANNEL:-none}"
  printf -- '---\n'
} > "$CONDUCTOR_DIR/config.md"
echo "Topology : $TOPOLOGY"
echo "Workforce: $WORKFORCE_NAME"
[[ -n "$LANG" ]]     && echo "Language : $LANG"
if [[ -n "$TEST_CMD" ]]; then
  echo "Test cmd : $TEST_CMD"
else
  echo "Test cmd : (none detected — validation will be skipped)"
fi

# ── Conductor briefing ────────────────────────────────────────────────────────

# shellcheck source=scripts/wf-read.sh
source "$SCRIPTS_DIR/wf-read.sh"

ADAPTER_NAME=$(wf_field "$WORKFORCE" "conductor" adapter)

ADAPTER_FILE="$ADAPTERS_DIR/${ADAPTER_NAME}.sh"
[[ -f "$ADAPTER_FILE" ]] || { echo "Adapter not found: $ADAPTER_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ADAPTER_FILE"

# Conductor launch-time params (tuning bag) — handed to the adapter verbatim.
CONDUCTOR_PARAMS=$(wf_field "$WORKFORCE" "conductor" params)

# Headless conductor (opt-in): an adapter that defines adapter_dispatch can run the loop
# instead of an interactive session. This is decided here, straight after the conductor's
# adapter is sourced and before the architect's is: sourcing a second adapter could add or
# replace functions. Without the flag nothing below changes.
RUN_LOOP=false
if [[ "$HEADLESS" == true ]]; then
  if declare -F adapter_dispatch > /dev/null; then
    RUN_LOOP=true
  else
    echo "Warning: --headless-conductor needs an adapter with adapter_dispatch; '$ADAPTER_NAME' has none." >&2
    echo "         Falling back to the interactive conductor." >&2
  fi
fi

if [[ "$RUN_LOOP" == true ]]; then
  # The loop builds its own prompt from $CONDUCTOR_DIR/prompts, so there is no briefing to
  # write: the file would be unused.
  echo "Conductor: headless loop (adapter: $ADAPTER_NAME)"
else
  SKILL_CONTENT=$(cat "$PROMPTS_DIR/conductor.prompt")
  TASK_BODY="$(printf 'SKILLS_DIR: %s\nCONDUCTOR_DIR: %s/%s\nSCRIPTS_DIR: %s\nLANG: %s' \
    "$TARGET_DIR/$CONDUCTOR_DIR/skills" "$TARGET_DIR" "$CONDUCTOR_DIR" "$SCRIPTS_DIR" "${LANG:-unknown}")"

  adapter_write_briefing \
    "." "conductor" "$SKILL_CONTENT" "$TASK_BODY" \
    "$SCRIPTS_DIR" "$TARGET_DIR" "" "${LANG:-}"

  echo "Conductor initialized (adapter: $ADAPTER_NAME)"
fi

# ── Architect briefing ────────────────────────────────────────────────────────

if [[ -n "$BRIEF_FILE" ]]; then
  ARCH_ADAPTER_NAME=$(wf_field "$WORKFORCE" "architect" adapter)
  ARCH_ADAPTER_FILE="$ADAPTERS_DIR/${ARCH_ADAPTER_NAME}.sh"
  [[ -f "$ARCH_ADAPTER_FILE" ]] || { echo "Architect adapter not found: $ARCH_ADAPTER_FILE" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$ARCH_ADAPTER_FILE"

  ARCH_PARAMS=$(wf_field "$WORKFORCE" "architect" params)

  ARCH_SKILL=$(cat "$PROMPTS_DIR/architect.prompt")
  BRIEF_CONTENT=$(cat "$BRIEF_FILE")
  ARCH_BODY="$(printf 'SKILLS_DIR: %s\nCONDUCTOR_DIR: %s/%s\nSCRIPTS_DIR: %s\nLANG: %s\n\n---\n\n## Project Brief\n\n%s' \
    "$TARGET_DIR/$CONDUCTOR_DIR/skills" "$TARGET_DIR" "$CONDUCTOR_DIR" "$SCRIPTS_DIR" "${LANG:-unknown}" "$BRIEF_CONTENT")"

  cp "$BRIEF_FILE" "$CONDUCTOR_DIR/brief.md"
  mkdir -p ".worktrees/architect"
  adapter_write_briefing \
    ".worktrees/architect" "architect" "$ARCH_SKILL" "$ARCH_BODY" \
    "$SCRIPTS_DIR" "$TARGET_DIR" "" "${LANG:-}"

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

# ── Headless conductor ───────────────────────────────────────────────────────

# Starts conductor-loop.sh as the conductor window's command.
#  - tmux gives a new window the server's environment, not ours, so the loop's tuning
#    variables (CONDUCTOR_*, PI_ABORT_GRACE) are put on the command line.
#  - bash -c keeps the script independent of the user's login shell.
#  - When the loop exits, the window turns into a shell (exec) instead of closing, so a
#    halt's banner stays on screen and a restart is just running the loop again.
#  - The loop prints its log lines (timestamped) in this window and appends them to
#    $CONDUCTOR_DIR/conductor.log; any other window can `tail -F` that file.
launch_conductor_loop() {
  local assignments="" name script
  # compgen -e lists the exported variables by name, so a value is read as it is: spaces,
  # quotes and newlines all go through printf %q intact.
  while IFS= read -r name; do
    [[ "$name" == "CONDUCTOR_DIR" ]] && continue
    assignments+=" $(printf '%q' "$name=${!name}")"
  done < <(compgen -e | grep -E '^(CONDUCTOR_[A-Z_]+|PI_ABORT_GRACE)$' || true)
  # After a halt and a restart the window is new and empty, so it first shows where the last run
  # left off: the end of conductor.log (the loop appends to it, with the same lines it prints).
  local log; log="$(printf '%q' "$CONDUCTOR_DIR/conductor.log")"
  script="cd $(printf '%q' "$TARGET_DIR") && "
  # shellcheck disable=SC2016  # the quotes are for the window's shell
  script+="if [ -s $log ]; then printf '%s\\n' '--- earlier in conductor.log:'; tail -n 20 $log; printf '%s\\n' '--- now:'; fi; "
  script+="env CONDUCTOR_DIR=$(printf '%q' "$CONDUCTOR_DIR")${assignments} $(printf '%q' "$SCRIPTS_DIR/conductor-loop.sh"); "
  # shellcheck disable=SC2016  # these expand in the window's shell, not here
  script+='status=$?; printf "\nconductor-loop exited with status %s.\nThis window is now a shell: restart it with scripts/conductor-loop.sh\n" "$status"; exec "${SHELL:-bash}"'
  tmux new-session -d -s "$SESSION" -n "conductor" "bash -c $(printf '%q' "$script")"
}

# ── tmux ─────────────────────────────────────────────────────────────────────

echo ""

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Attaching to existing tmux session '$SESSION'"
else
  echo "Starting tmux session '$SESSION'"
  if [[ "$RUN_LOOP" == true ]]; then
    launch_conductor_loop
  else
    adapter_launch "$SESSION" "conductor" "." "$TARGET_DIR" "$CONDUCTOR_PARAMS"
  fi
  [[ -n "$BRIEF_FILE" ]] && adapter_launch "$SESSION" "architect" ".worktrees/architect" "$TARGET_DIR" "${ARCH_PARAMS:-}"

  # Kill kanban server automatically when the tmux session closes
  if [[ "$KANBAN_SERVER" == true ]]; then
    tmux set-hook -t "$SESSION" session-closed \
      "run-shell '$SCRIPTS_DIR/swarm-stop.sh $TARGET_DIR'"
  fi
fi

tmux attach-session -t "$SESSION"
