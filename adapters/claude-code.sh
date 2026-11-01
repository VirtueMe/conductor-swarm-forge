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
  if [[ -n "${DISPATCH_USAGE_FILE:-}" ]]; then
    jq -c '(.modelUsage // {}) as $m | {
        harness: "claude-code",
        model: (if ($m | length) > 0 then ($m | keys | join("+")) else null end),
        input_tokens: ([$m[].inputTokens // 0] | add // 0),
        output_tokens: ([$m[].outputTokens // 0] | add // 0),
        cache_read_tokens: ([$m[].cacheReadInputTokens // 0] | add // 0),
        cache_write_tokens: ([$m[].cacheCreationInputTokens // 0] | add // 0),
        cost_usd: .total_cost_usd,
        turns: .num_turns }' "$out" > "$DISPATCH_USAGE_FILE"
  fi

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
  if ! dispatch_final_exit "$answer"; then
    echo "claude-code: handler reported failure: $(printf '%s\n' "$answer" | awk 'NF{l=$0} END{print l}')" >&2
    return 1
  fi
  return 0
}
