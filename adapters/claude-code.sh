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

# Translate a member's params (JSON) into claude CLI flags. Only the keys this
# adapter understands are emitted; everything else is ignored, so a workforce can
# carry tuning other adapters use without breaking this one.
#   model  → --model <model>   (open set — left for the CLI to validate)
#   effort → --effort <level>  (closed set — validated here, fail fast)
# Prints a single shell-quoted flag string on stdout; exits non-zero with a
# message on an unsupported effort, aborting the spawn before launch. Requires python3.
adapter_params_to_flags() {
  local params_json="${1:-}"
  python3 - "$params_json" << 'EOF'
import json, sys, shlex
EFFORT = ("low", "medium", "high", "xhigh", "max")
raw = sys.argv[1] if len(sys.argv) > 1 else ""
p = json.loads(raw) if raw.strip() else {}
out = []
if p.get("model"):
    out += ["--model", str(p["model"])]
if p.get("effort"):
    eff = str(p["effort"])
    if eff not in EFFORT:
        sys.stderr.write(
            f"claude-code: unsupported effort '{eff}' (allowed: {', '.join(EFFORT)})\n")
        sys.exit(2)
    out += ["--effort", eff]
print(" ".join(shlex.quote(x) for x in out))
EOF
}

# Launch a claude session — creates the tmux session if it doesn't exist yet,
# otherwise adds a new window to the existing session.
# Arguments:
#   $1  tmux session name
#   $2  window name
#   $3  worktree path (relative to root dir)
#   $4  root dir
#   $5  member params as JSON (optional) — translated to CLI flags
adapter_launch() {
  local session="$1"
  local window_name="$2"
  local worktree="$3"
  local root_dir="$4"
  local params_json="${5:-}"
  local briefing="$root_dir/$worktree/CLAUDE.md"
  local param_flags
  param_flags=$(adapter_params_to_flags "$params_json")
  local cmd="cd '$root_dir/$worktree' && claude \
    --permission-mode acceptEdits \
    ${param_flags} \
    --append-system-prompt-file '$briefing' \
    -n '$window_name' \
    \"\$(cat '$briefing')\""

  if tmux has-session -t "$session" 2>/dev/null; then
    tmux new-window -t "$session" -n "$window_name" "$cmd"
  else
    tmux new-session -d -s "$session" -n "$window_name" "$cmd"
  fi
}
