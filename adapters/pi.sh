#!/usr/bin/env bash
# Adapter: pi  (pi.dev — minimal BYO-model agent harness)
# Briefing file: AGENTS.md
# Launch command: pi
#
# Pi auto-discovers AGENTS.md (and CLAUDE.md) as project context unless
# --no-context-files is passed, so the briefing lands the same way codex's does.
# Unlike codex, an interactive `pi` waits for input rather than auto-acting on the
# context file, so adapter_launch also passes the briefing as the initial message
# to kick the worker off (the session stays interactive afterwards).

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
#   $9  test command (optional)
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
  # Handle both absolute and relative CONDUCTOR_DIR.
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

# Translate a member's params (JSON) into pi CLI flags. Only the keys this adapter
# understands are emitted; everything else is ignored, so a workforce can carry
# tuning other adapters use without breaking this one.
#   model  → --model <model>      (open set — left for the CLI to validate)
#                                  Qualify models as "provider/id" (e.g.
#                                  anthropic/claude-sonnet-4-6): an ambiguous id
#                                  makes pi ask for --provider, which nobody can
#                                  answer in an unattended tmux window.
#   effort → --thinking <level>   (closed set — validated here, fail fast)
# Use the `effort` key for thinking level, not the model pattern's ":<thinking>"
# suffix, so it stays consistent with the other adapters' params bag.
# Prints a single shell-quoted flag string on stdout; exits non-zero with a
# message on an unsupported effort, aborting the spawn before launch. Requires python3.
adapter_params_to_flags() {
  local params_json="${1:-}"
  python3 - "$params_json" << 'EOF'
import json, sys, shlex
THINKING = ("off", "minimal", "low", "medium", "high", "xhigh", "max")
raw = sys.argv[1] if len(sys.argv) > 1 else ""
p = json.loads(raw) if raw.strip() else {}
out = []
if p.get("model"):
    out += ["--model", str(p["model"])]
if p.get("effort"):
    eff = str(p["effort"])
    if eff not in THINKING:
        sys.stderr.write(
            f"pi: unsupported effort '{eff}' (allowed: {', '.join(THINKING)})\n")
        sys.exit(2)
    out += ["--thinking", eff]
print(" ".join(shlex.quote(x) for x in out))
EOF
}

# Launch a pi session — creates the tmux session if it doesn't exist yet,
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
  # AGENTS.md is auto-discovered as project context; passing it as the initial
  # message guarantees the worker starts on the task instead of idling at the prompt.
  local cmd="cd '$root_dir/$worktree' && pi ${param_flags} -- \"\$(cat '$briefing')\""

  if tmux has-session -t "$session" 2>/dev/null; then
    tmux new-window -t "$session" -n "$window_name" "$cmd"
  else
    tmux new-session -d -s "$session" -n "$window_name" "$cmd"
  fi
}

# --- Headless dispatch (conductor-loop.sh) ------------------------------------

# Run one conductor event through `pi --mode rpc` and report how it went.
#   $1  skill content     $2  artifact path
# Environment (set by conductor-loop.sh): CONDUCTOR_DIR, SCRIPTS_DIR, TASK_ID,
#   DISPATCH_DEADLINE, DISPATCH_USAGE_FILE. PI_ABORT_GRACE (default 5) is how long to wait
#   for a run to settle after an abort.
# One pi process per event, so the stats are per event with no new_session. Unlike
# claude -p, Pi has no timer of its own and the loop's outer timeout is only a backstop:
# scripts/pi-rpc-run.py sends `abort` when DISPATCH_DEADLINE passes. Pi has no per-run
# budget flag, so the deadline is the only bound on a run.
# Needs python3 (the RPC client) and jq. Exit: 0 finished; 2 cannot succeed on a retry
# (pi, python3 or jq missing, or a rejected request such as a bad model or credentials);
# 1 anything else, including a deadline that passed.
adapter_dispatch() {
  local skill_content="${1:?Usage: adapter_dispatch <skill_content> <artifact>}"
  local artifact="${2:?Usage: adapter_dispatch <skill_content> <artifact>}"

  local tool
  for tool in pi python3 jq; do
    command -v "$tool" > /dev/null 2>&1 || { echo "pi: dispatch needs $tool" >&2; return 2; }
  done

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

  # Fixed names under the conductor dir: one dispatch runs at a time, a killed dispatch
  # leaves files that the next one overwrites, and the last run stays for debugging.
  local prompt_file="$CONDUCTOR_DIR/dispatch-prompt.txt" out="$CONDUCTOR_DIR/dispatch-result.json"
  printf '%s\n' "$prompt" > "$prompt_file"
  rm -f "$out"

  local rc=0
  # Pi runs tools unattended with no permission prompts, so limit them to what a handler
  # needs: bash for the scripts, read for files. No edit or write.
  python3 "$SCRIPTS_DIR/pi-rpc-run.py" \
    --prompt-file "$prompt_file" --out "$out" \
    --deadline "${DISPATCH_DEADLINE:-600}" --grace "${PI_ABORT_GRACE:-5}" \
    -- --tools bash,read ${model_flags[@]+"${model_flags[@]}"} || rc=$?

  if [[ ! -s "$out" ]] || ! jq -e . "$out" > /dev/null 2>&1; then
    echo "pi: the RPC client produced no result (exit $rc)" >&2
    return 1
  fi

  # The usage record, written whatever the outcome because the spend happened.
  if [[ -n "${DISPATCH_USAGE_FILE:-}" ]]; then
    jq -c '{
        harness: "pi",
        model: .model,
        input_tokens: (.stats.tokens.input // 0),
        output_tokens: (.stats.tokens.output // 0),
        cache_read_tokens: (.stats.tokens.cacheRead // 0),
        cache_write_tokens: (.stats.tokens.cacheWrite // 0),
        cost_usd: (.stats.cost // null),
        turns: (.stats.assistantMessages // null) }' "$out" > "$DISPATCH_USAGE_FILE"
  fi

  # "-" stands for an empty field: read would otherwise merge adjacent tabs.
  local deadline_hit settled aborted rejected stop_reason retry_failed pi_exit
  IFS=$'\t' read -r deadline_hit settled aborted rejected stop_reason retry_failed pi_exit < <(jq -r '[
      (.deadline_hit | tostring), (.settled | tostring), (.aborted | tostring),
      (.prompt_rejected // "-" | gsub("[\t\n]"; " ")), (.stop_reason // "-"),
      (.auto_retry_failed // "-" | gsub("[\t\n]"; " ")), (.pi_exit // "-" | tostring)
    ] | @tsv' "$out")
  local error_message answer
  error_message="$(jq -r '.error_message // ""' "$out")"
  answer="$(jq -r '.final_text // ""' "$out")"

  if [[ "$deadline_hit" == "true" ]]; then
    echo "pi: the deadline (${DISPATCH_DEADLINE:-600}s) passed; the run was aborted" >&2; return 1
  fi
  if [[ "$rejected" != "-" ]]; then
    echo "pi: the prompt was rejected: $rejected" >&2; return 1
  fi
  if [[ "$settled" != "true" ]]; then
    echo "pi: exited before the run settled (exit $pi_exit): $(jq -r '.stderr // ""' "$out" | head -c 300 | tr '\n' ' ')" >&2
    return 1
  fi
  if [[ "$aborted" == "true" ]]; then
    echo "pi: the run was aborted" >&2; return 1
  fi
  # Pi reports a failed model call inside the run: the prompt is accepted and the run
  # settles, with stopReason "error" and the HTTP status leading errorMessage.
  if [[ "$stop_reason" == "error" ]]; then
    case "$error_message" in
      400*|401*|403*|404*)
        echo "pi: the request was rejected: $(printf '%s' "$error_message" | head -c 200 | tr '\n' ' ')" >&2
        return 2 ;;
    esac
    echo "pi: the model call failed: $(printf '%s' "$error_message" | head -c 200 | tr '\n' ' ')" >&2
    return 1
  fi
  if [[ "$retry_failed" != "-" ]]; then
    echo "pi: retries gave up: $retry_failed" >&2; return 1
  fi
  if ! dispatch_final_exit "$answer"; then
    echo "pi: handler reported failure: $(printf '%s\n' "$answer" | awk 'NF{l=$0} END{print l}')" >&2
    return 1
  fi
  return 0
}
