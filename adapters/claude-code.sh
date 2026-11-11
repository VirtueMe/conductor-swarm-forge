#!/usr/bin/env bash
# Adapter: claude-code
# Briefing file: AGENTS.md
# Launch command: claude

# Write the task briefing into the worktree as AGENTS.md.
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

  cat > "$worktree/AGENTS.md" << EOF
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
- Conductor dir: $full_conductor
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

# The permission mode an interactive window is launched in, and its --settings, as flags.
#   permission_mode  a member param: auto (the default), acceptEdits, dontAsk or manual. An unattended
#                    window must not stop to ask, so the default is auto, and a claude that has no auto
#                    mode (an older version, or a build without it) gets acceptEdits with a note.
#                    bypassPermissions is not offered; anything else is refused before launch.
# The --settings flag, if there is one, comes from adapter_settings_flag below. Kept apart from
# adapter_params_to_flags on purpose: that one also feeds the headless dispatch, which has its own
# fixed permissions.
# Prints the flags on one line; exits non-zero with a message on a mode that is not allowed.
adapter_permission_flags() { # <params json> <root dir> <state dir>
  local mode flags settings
  mode="$(python3 - "${1:-}" << 'PYEOF'
import json, sys
ALLOWED = ("auto", "acceptEdits", "dontAsk", "manual")
raw = sys.argv[1] if len(sys.argv) > 1 else ""
p = json.loads(raw) if raw.strip() else {}
m = str(p.get("permission_mode") or "auto")
if m not in ALLOWED:
    sys.stderr.write(f"claude-code: unsupported permission_mode '{m}' (allowed: {', '.join(ALLOWED)})\n")
    sys.exit(2)
print(m)
PYEOF
)" || return 2
  if [[ "$mode" == auto ]] && ! claude --help 2>&1 | grep -q '"auto"'; then
    echo "claude-code: this claude has no auto permission mode; using acceptEdits" >&2
    mode=acceptEdits
  fi
  flags="--permission-mode $mode"
  settings="$(adapter_settings_flag "${2:-}" "${3:-}")"
  [[ -z "$settings" ]] || flags="$flags $settings"
  printf '%s\n' "$flags"
}

# The --settings flag of an interactive window: the project's allow list, and Claude's own commit and PR
# attribution switched off (#130). Prints the flag, or nothing when there is nothing to pass.
#
# The project's .claude/settings.json (swarm-start.sh writes it: the scripts, git, the test command) is
# passed with --settings, so a window in a worktree gets the allow list without depending on whether
# claude finds the project root's file from there.
#
# Claude's own attribution is off because the conductor stamps the task's commits itself
# (docs/commit-attribution.md), and Claude's own Co-Authored-By would sit beside ours. It is on unless
# config.md has `attribution: none`, and absent means trailer; any other value is said so on stderr and
# taken as trailer. Whether a repeated --settings merges is not
# documented, so there is one: with the setting on, the project's file is merged with the attribution keys
# over it and written to $state_dir/claude-settings.json, readable only by its owner, and that path is
# passed. It is a file and not inline JSON because the project's settings can hold env entries and helpers,
# which do not belong on a command line `ps` shows. With `none` the project's file is passed by path as
# before and Claude's attribution is left alone. If the project's file is not a JSON object, or the merged
# file cannot be written, the project's file is passed as it is with a warning, and attribution is then not
# turned off. The headless dispatch is not covered: it runs the conductor's handlers, which do not write
# the task's commits.
adapter_settings_flag() { # <root dir> <state dir>
  local project_settings="${1:-}/.claude/settings.json" attribution=""
  if [[ -f "${2:-}/config.md" ]]; then
    attribution="$(sed -n 's/^attribution:[[:space:]]*//p' "$2/config.md" | sed -n '1s/[[:space:]]*$//p')"
  fi
  case "${attribution:-trailer}" in
    none|trailer) ;;
    # attribution-trailer.sh refuses this value; a launch cannot, so it says so and goes on as the default.
    # swarm-start.sh blocks the value, so only a config.md edited by hand gets here.
    *) echo "claude-code: attribution: '$attribution' in config.md is neither trailer nor none; launching as trailer" >&2 ;;
  esac
  if [[ "$attribution" == none ]]; then
    [[ -f "$project_settings" ]] && printf '%s\n' "--settings '$project_settings'"
    return 0
  fi
  python3 - "$project_settings" "${2:-}" << 'PYEOF'
import json, os, sys, tempfile
path, state_dir = sys.argv[1], sys.argv[2]
def as_is(why):
    sys.stderr.write(f"claude-code: {why}; passing the project's settings as they are, attribution is not turned off\n")
    if os.path.isfile(path):
        print(f"--settings '{path}'")
    sys.exit(0)
settings = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            settings = json.load(f)
        if not isinstance(settings, dict):
            raise ValueError("not a JSON object")
    except (ValueError, OSError) as e:
        as_is(f"{path} is not usable settings JSON ({e})")
settings["attribution"] = {"commit": "", "pr": ""}
target = os.path.join(state_dir, "claude-settings.json")
try:
    os.makedirs(state_dir, exist_ok=True)
    # Written beside the target and moved into place, so two windows starting together never read half a file.
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=".claude-settings.")
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, separators=(",", ":"))
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)
except OSError as e:
    as_is(f"cannot write {target} ({e})")
print(f"--settings '{target}'")
PYEOF
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
  local briefing="$root_dir/$worktree/AGENTS.md"
  local param_flags permission_flags
  param_flags=$(adapter_params_to_flags "$params_json") || return 2
  # Every script a worker calls resolves the project's state through CONDUCTOR_DIR, and the window starts
  # in its own worktree, where the default (a relative .conductor) is a different, empty place: the
  # architect's cards once landed there and the loop saw nothing (#181). So the window gets the absolute one.
  local state_dir="${CONDUCTOR_DIR:-.conductor}"
  [[ "$state_dir" == /* ]] || state_dir="$root_dir/$state_dir"
  permission_flags=$(adapter_permission_flags "$params_json" "$root_dir" "$state_dir") || return 2
  local cmd
  cmd="cd '$root_dir/$worktree' && export CONDUCTOR_DIR=$(printf '%q' "$state_dir") && claude \
    ${permission_flags} \
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

# --- Headless dispatch (conductor-loop.sh) ------------------------------------

# Replaces Claude Code's default system prompt for a dispatched event. The dispatch
# prompt already carries the briefing and the rules, so the default prompt is mostly
# fixed context: measured on one handler it cut cache-write tokens from 17.9k to 7.4k
# (with the tool and MCP trimming below) and the cost to about a third. One run each;
# see "Claude Code dispatch" in docs/event-driven-conductor.md.
CLAUDE_DISPATCH_SYSTEM_PROMPT="You are an automation agent. Run shell commands exactly as instructed and report the outcome in one line."

# Run one conductor event with `claude -p` and report how it went.
#   $1  skill content     $2  artifact path
# Environment (set by conductor-loop.sh): CONDUCTOR_DIR, SCRIPTS_DIR, TASK_ID,
#   DISPATCH_USAGE_FILE. CONDUCTOR_MAX_BUDGET_USD caps one run (default 1).
# The deadline is the loop's: claude -p has no turn limit or timer of its own, so the
# loop's outer timeout bounds it.
# Needs jq to read the result. Exit: 0 finished; 2 cannot succeed on a retry (claude or
# jq missing, a rejected request such as a bad model or credentials, budget reached);
# 1 anything else.
adapter_dispatch() {
  local skill_content="${1:?Usage: adapter_dispatch <skill_content> <artifact>}"
  local artifact="${2:?Usage: adapter_dispatch <skill_content> <artifact>}"

  command -v claude > /dev/null 2>&1 || { echo "claude-code: claude is not installed" >&2; return 2; }
  command -v jq > /dev/null 2>&1 || { echo "claude-code: dispatch needs jq (apt install jq / brew install jq)" >&2; return 2; }

  # shellcheck source=scripts/dispatch-prompt.sh
  source "${SCRIPTS_DIR:?SCRIPTS_DIR is not set}/dispatch-prompt.sh"
  # shellcheck source=scripts/dispatch-result.sh
  source "$SCRIPTS_DIR/dispatch-result.sh"
  # shellcheck source=scripts/wf-read.sh
  source "$SCRIPTS_DIR/wf-read.sh"

  local prompt params flags
  prompt="$(dispatch_prompt "$skill_content" "$artifact")" || return 2
  params="$(wf_field "${CONDUCTOR_DIR:?CONDUCTOR_DIR is not set}/workforce.json" conductor params)"
  flags="$(adapter_params_to_flags "$params")" || return 2
  # adapter_params_to_flags prints shell-quoted words, so eval rebuilds them exactly.
  local -a model_flags=()
  eval "model_flags=($flags)"

  # One dispatch runs at a time (the loop holds a lock), so these names can repeat. A
  # dispatch that is killed leaves them behind, but they are overwritten by the next
  # one, so nothing accumulates, and the last run stays around for debugging.
  local out="$CONDUCTOR_DIR/dispatch-result.json" err="$CONDUCTOR_DIR/dispatch-result.err" rc=0
  rm -f "$out" "$err"

  # Only what a handler needs: Bash for the scripts, Read for files. No MCP servers and
  # no user-level settings, which are most of the fixed context. -p cannot prompt, so
  # anything not allowed is denied (and reported in permission_denials).
  claude -p "$prompt" \
    --output-format json --no-session-persistence \
    --max-budget-usd "${CONDUCTOR_MAX_BUDGET_USD:-1}" \
    --allowedTools Bash Read --tools Bash,Read \
    --strict-mcp-config --setting-sources project \
    --system-prompt "$CLAUDE_DISPATCH_SYSTEM_PROMPT" \
    ${model_flags[@]+"${model_flags[@]}"} < /dev/null > "$out" 2> "$err" || rc=$?

  if ! jq -e . "$out" > /dev/null 2>&1; then
    [[ -s "$err" ]] && head -c 400 "$err" >&2
    echo "claude-code: claude produced no JSON (exit $rc)" >&2
    return 1
  fi

  # The usage record, written whatever the outcome because the spend happened. `usage`
  # is all zeros on an error result, so the figures come from the per-model breakdown.
  local u_model u_in u_out u_cr u_cw u_cw1h u_cost u_turns
  IFS=$'\t' read -r u_model u_in u_out u_cr u_cw u_cw1h u_cost u_turns < <(jq -r '(.modelUsage // {}) as $m | [
      (if ($m | length) > 0 then ($m | keys | join("+")) else "-" end),
      ([$m[].inputTokens // 0] | add // 0),
      ([$m[].outputTokens // 0] | add // 0),
      ([$m[].cacheReadInputTokens // 0] | add // 0),
      ([$m[].cacheCreationInputTokens // 0] | add // 0),
      ([$m[].cacheCreationEphemeral1hInputTokens // 0] | add // 0),
      (.total_cost_usd // "-"), (.num_turns // "-")
    ] | @tsv' "$out")
  dispatch_write_usage claude-code "$u_model" "$u_in" "$u_out" "$u_cr" "$u_cw" "$u_cost" "$u_turns" "$u_cw1h"

  # "-" stands for an empty field: read would otherwise merge adjacent tabs.
  local subtype terminal status is_error denied
  IFS=$'\t' read -r subtype terminal status is_error denied < <(jq -r '[
      (.subtype // "-"), (.terminal_reason // "-"), (.api_error_status // "-" | tostring),
      (.is_error // false | tostring),
      ((.permission_denials // []) | map(.tool_name // "?") | join(",") | if . == "" then "-" else . end)
    ] | @tsv' "$out")
  local answer
  answer="$(jq -r '.result // ""' "$out")"

  # subtype alone is not enough: a rejected model reports subtype "success".
  if [[ "$subtype" == "error_max_budget_usd" ]]; then
    echo "claude-code: budget reached; raise CONDUCTOR_MAX_BUDGET_USD" >&2; return 2
  fi
  case "$status" in
    400|401|403|404)
      echo "claude-code: the request was rejected (HTTP $status): $(printf '%s' "$answer" | head -c 200 | tr '\n' ' ')" >&2
      return 2 ;;
  esac
  if [[ "$is_error" == "true" || "$terminal" != "completed" ]]; then
    echo "claude-code: run did not complete (terminal_reason=$terminal, subtype=$subtype, HTTP $status)" >&2
    return 1
  fi
  if [[ "$denied" != "-" ]]; then
    echo "claude-code: a tool was denied: $denied" >&2
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "claude-code: claude exited $rc" >&2
    return 1
  fi
  dispatch_finish claude-code "$answer" || return 1
  return 0
}

# How this adapter names itself in a commit's Co-Authored-By trailer (#130,
# docs/commit-attribution.md): the tool's name and its URL, tab-separated, on one line.
adapter_attribution() {
  printf '%s\t%s\n' 'Claude Code' 'https://claude.com/claude-code'
}
