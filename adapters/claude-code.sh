#!/usr/bin/env bash
# Adapter: claude-code
# Briefing file: CLAUDE.md
# Launch command: claude

# Write the task briefing into the worktree as CLAUDE.md.
# Arguments:
#   $1  worktree path
#   $2  task id
#   $3  skill content (assembled by worker-spawn.sh)
#   $4  task body (description + acceptance criteria)
#   $5  scripts dir
#   $6  root dir
#   $7  branch
#   $8  target language (optional)
adapter_write_briefing() {
  local worktree="$1"
  local task_id="$2"
  local skill_content="$3"
  local task_body="$4"
  local scripts_dir="$5"
  local root_dir="$6"
  local branch="$7"
  local lang="${8:-}"
  local test_cmd="${9:-}"

  # Expand placeholders in skill content.
  # $SCRIPTS_DIR is expanded with CONDUCTOR_DIR= prepended so every script call
  # carries the correct conductor path regardless of the agent's working directory.
  # Handle both absolute and relative CONDUCTOR_DIR
  local full_conductor
  if [[ "$CONDUCTOR_DIR" == /* ]]; then
    full_conductor="$CONDUCTOR_DIR"
  else
    full_conductor="$root_dir/$CONDUCTOR_DIR"
  fi
  local expanded
  expanded=$(printf '%s' "$skill_content" \
    | sed "s|\$TASK_ID|$task_id|g" \
    | sed "s|\$SCRIPTS_DIR|CONDUCTOR_DIR=$full_conductor $scripts_dir|g" \
    | sed "s|\$BRANCH|$branch|g" \
    | sed "s|\$CONDUCTOR_DIR|$full_conductor|g")

  local lang_line=""
  local test_cmd_line=""
  [[ -n "$lang" ]]     && lang_line="- Language: **${lang}** — implement everything in ${lang}"
  [[ -n "$test_cmd" ]] && test_cmd_line="- Test command: \`${test_cmd}\` — run this to verify your work"

  cat > "$worktree/CLAUDE.md" << EOF
# Worker Briefing — task $task_id

$expanded

---

## Task

$task_body

---

## Environment

- Task ID: $task_id
- Branch: $branch
- Scripts: $scripts_dir
- Conductor dir: $root_dir/$CONDUCTOR_DIR
${lang_line}
${test_cmd_line}
EOF
}

# Launch a claude session — creates the tmux session if it doesn't exist yet,
# otherwise adds a new window to the existing session.
# Arguments:
#   $1  tmux session name
#   $2  window name
#   $3  worktree path (relative to root dir)
#   $4  root dir
adapter_launch() {
  local session="$1"
  local window_name="$2"
  local worktree="$3"
  local root_dir="$4"
  local briefing="$root_dir/$worktree/CLAUDE.md"
  local cmd="cd '$root_dir/$worktree' && claude \
    --permission-mode acceptEdits \
    --append-system-prompt-file '$briefing' \
    -n '$window_name' \
    \"\$(cat '$briefing')\""

  if tmux has-session -t "$session" 2>/dev/null; then
    tmux new-window -t "$session" -n "$window_name" "$cmd"
  else
    tmux new-session -d -s "$session" -n "$window_name" "$cmd"
  fi
}
