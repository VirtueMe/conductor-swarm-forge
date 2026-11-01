#!/usr/bin/env bash
# Adapter: codex
# Briefing file: AGENTS.md
# Launch command: codex

# Write the task briefing into the worktree as AGENTS.md.
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

  # Resolve the conductor dir once: CONDUCTOR_DIR may be absolute or relative to
  # the project root, and prefixing root_dir onto an absolute path doubles it.
  local full_conductor
  if [[ "$CONDUCTOR_DIR" == /* ]]; then
    full_conductor="$CONDUCTOR_DIR"
  else
    full_conductor="$root_dir/$CONDUCTOR_DIR"
  fi

  local expanded
  expanded=$(printf '%s' "$skill_content" \
    | sed "s|\$TASK_ID|$task_id|g" \
    | sed "s|\$SCRIPTS_DIR|$scripts_dir|g" \
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

# Translate a member's params (JSON) into codex CLI flags. Only the keys this
# adapter understands are emitted; everything else is ignored.
#   model  → --model <model>                       (open set — left for the CLI to validate)
#   effort → -c model_reasoning_effort=<effort>    (closed set — validated here, fail fast)
# Prints a single shell-quoted flag string on stdout; exits non-zero with a
# message on an unsupported effort, aborting the spawn before launch. Requires python3.
adapter_params_to_flags() {
  local params_json="${1:-}"
  python3 - "$params_json" << 'EOF'
import json, sys, shlex
EFFORT = ("minimal", "low", "medium", "high")
raw = sys.argv[1] if len(sys.argv) > 1 else ""
p = json.loads(raw) if raw.strip() else {}
out = []
if p.get("model"):
    out += ["--model", str(p["model"])]
if p.get("effort"):
    eff = str(p["effort"])
    if eff not in EFFORT:
        sys.stderr.write(
            f"codex: unsupported effort '{eff}' (allowed: {', '.join(EFFORT)})\n")
        sys.exit(2)
    out += ["-c", f"model_reasoning_effort={eff}"]
print(" ".join(shlex.quote(x) for x in out))
EOF
}

# Launch a codex session — creates the tmux session if it doesn't exist yet,
# otherwise adds a new window to the existing session.
#   $5  member params as JSON (optional) — translated to CLI flags
adapter_launch() {
  local session="$1"
  local window_name="$2"
  local worktree="$3"
  local root_dir="$4"
  local params_json="${5:-}"
  local param_flags
  param_flags=$(adapter_params_to_flags "$params_json")
  local cmd="cd '$root_dir/$worktree' && codex ${param_flags}"

  if tmux has-session -t "$session" 2>/dev/null; then
    tmux new-window -t "$session" -n "$window_name" "$cmd"
  else
    tmux new-session -d -s "$session" -n "$window_name" "$cmd"
  fi
}

# --- Headless dispatch (conductor-loop.sh) ------------------------------------

# Run one conductor event with `codex exec --json` and report how it went.
#   $1  skill content     $2  artifact path
# Environment (set by conductor-loop.sh): CONDUCTOR_DIR, SCRIPTS_DIR, TASK_ID,
#   DISPATCH_USAGE_FILE. CONDUCTOR_CODEX_SANDBOX picks the sandbox (default
#   danger-full-access, see below).
# The deadline is the loop's: codex exec has no timer of its own, and a killed run reports
# no usage at all (no turn.completed), so a timed-out event leaves no usage record.
# Needs jq. Exit: 0 finished; 2 cannot succeed on a retry (codex or jq missing, a bad
# sandbox setting, a rejected model or credentials); 1 anything else.
#
# Sandbox. The handlers close and open worker windows through tmux, and the tmux socket
# is outside any workspace. Measured: under workspace-write, connecting to it fails with
# "Operation not permitted", and --add-dir does not help. That also blinds the spawn guard
# (its `tmux list-windows` fails quietly). So the default is danger-full-access, which
# matches the other two adapters: claude-code allows Bash without limit and Pi runs its
# tools with no permission prompts. Set CONDUCTOR_CODEX_SANDBOX=workspace-write only for
# a conductor whose handlers never touch tmux.
adapter_dispatch() {
  local skill_content="${1:?Usage: adapter_dispatch <skill_content> <artifact>}"
  local artifact="${2:?Usage: adapter_dispatch <skill_content> <artifact>}"

  command -v codex > /dev/null 2>&1 || { echo "codex: codex is not installed" >&2; return 2; }
  command -v jq > /dev/null 2>&1 || { echo "codex: dispatch needs jq (apt install jq / brew install jq)" >&2; return 2; }

  local sandbox="${CONDUCTOR_CODEX_SANDBOX:-danger-full-access}"
  case "$sandbox" in
    read-only|workspace-write|danger-full-access) ;;
    *) echo "codex: CONDUCTOR_CODEX_SANDBOX must be read-only, workspace-write or danger-full-access (got '$sandbox')" >&2
       return 2 ;;
  esac

  # shellcheck source=scripts/dispatch-prompt.sh
  source "${SCRIPTS_DIR:?SCRIPTS_DIR is not set}/dispatch-prompt.sh"
  # shellcheck source=scripts/dispatch-result.sh
  source "$SCRIPTS_DIR/dispatch-result.sh"
  # shellcheck source=scripts/wf-read.sh
  source "$SCRIPTS_DIR/wf-read.sh"

  local prompt params flags model
  prompt="$(dispatch_prompt "$skill_content" "$artifact")" || return 2
  params="$(wf_field "${CONDUCTOR_DIR:?CONDUCTOR_DIR is not set}/workforce.json" conductor params)"
  flags="$(adapter_params_to_flags "$params")" || return 2
  # adapter_params_to_flags prints shell-quoted words, so eval rebuilds them exactly.
  local -a model_flags=()
  eval "model_flags=($flags)"
  # The events do not name the model, so report the one that was asked for, if any.
  model="$(printf '%s' "$params" | jq -r '.model // "-"')"

  # One dispatch runs at a time (the loop holds a lock), so these names can repeat. A
  # dispatch that is killed leaves them behind, but the next one overwrites them.
  local out="$CONDUCTOR_DIR/dispatch-result.jsonl" err="$CONDUCTOR_DIR/dispatch-result.err" rc=0
  rm -f "$out" "$err"

  # stdin must be closed: with a pipe on stdin, codex exec waits for it to end even when
  # the prompt is an argument, and the run hangs until the loop's timeout.
  codex exec --json -s "$sandbox" --ephemeral --skip-git-repo-check \
    ${model_flags[@]+"${model_flags[@]}"} "$prompt" < /dev/null > "$out" 2> "$err" || rc=$?

  # The events are JSON lines; a line that does not parse (a stray warning) is skipped.
  local events
  events="$(jq -cR 'fromjson? // empty' "$out" 2> /dev/null | jq -cs . 2> /dev/null || true)"
  if [[ -z "$events" || "$events" == "[]" ]]; then
    [[ -s "$err" ]] && head -c 400 "$err" >&2
    echo "codex: codex produced no events (exit $rc)" >&2
    return 1
  fi

  # Usage, summed over turn.completed. Codex's input_tokens includes the cached part, and
  # the shared record keeps cached input apart, so subtract it. A run that was killed or
  # failed has no turn.completed and so no usage; the record is then not written.
  local completed u_in u_out u_cr u_cw u_turns
  completed="$(jq '[.[] | select(.type == "turn.completed")] | length' <<< "$events")"
  if [[ "$completed" -gt 0 ]]; then
    IFS=$'\t' read -r u_in u_out u_cr u_cw u_turns < <(jq -r '
        [.[] | select(.type == "turn.completed") | .usage] as $u
        | [ ([$u[] | ((.input_tokens // 0) - (.cached_input_tokens // 0))] | add | if . < 0 then 0 else . end),
            ([$u[] | .output_tokens // 0] | add),
            ([$u[] | .cached_input_tokens // 0] | add),
            ([$u[] | .cache_write_input_tokens // 0] | add),
            ([.[] | select(.type == "item.completed" and (.item.type == "agent_message" or .item.type == "command_execution"))] | length)
          ] | @tsv' <<< "$events")
    dispatch_write_usage codex "$model" "$u_in" "$u_out" "$u_cr" "$u_cw" "-" "$u_turns"
  fi

  # A failed run: turn.failed (or an error event) and a non-zero exit. An item of type
  # "error" is only a warning, and a command that exits non-zero is just a command.
  local failure
  failure="$(jq -r '[.[] | select(.type == "turn.failed") | .error.message // "turn failed"] | first // ([.[] | select(.type == "error") | .message] | first // "")' <<< "$events")"
  if [[ -n "$failure" ]]; then
    # Codex gives no status code, only text, so match the messages that a retry cannot fix.
    case "$(printf '%s' "$failure" | tr '[:upper:]' '[:lower:]')" in
      *"not supported"*|*"not found"*|*"unauthorized"*|*"not logged in"*|*"invalid api key"*|*"authentication"*|*"forbidden"*)
        echo "codex: the request was rejected: $(printf '%s' "$failure" | head -c 200 | tr '\n' ' ')" >&2
        return 2 ;;
    esac
    echo "codex: the run failed: $(printf '%s' "$failure" | head -c 200 | tr '\n' ' ')" >&2
    return 1
  fi
  if [[ "$completed" -eq 0 ]]; then
    echo "codex: the run ended without completing (exit $rc)" >&2
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "codex: codex exited $rc" >&2
    return 1
  fi

  local answer
  answer="$(jq -r '[.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last // ""' <<< "$events")"
  dispatch_finish codex "$answer" || return 1
  return 0
}
