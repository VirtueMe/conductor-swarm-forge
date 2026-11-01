#!/usr/bin/env bash
# Tests adapter_dispatch in adapters/claude-code.sh with no AI and no network: a stub
# `claude` on the PATH records the arguments it was given and prints a canned result
# object. The shapes of the canned results (success, rejected model, budget stop) were
# captured from real `claude -p --output-format json` runs.
#
# Usage: scripts/test-claude-dispatch.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
ADAPTER="$ROOT_DIR/adapters/claude-code.sh"

TMP="$(mktemp -d)"
# A private tmux server: if a test ever reaches the real worker-spawn.sh, it cannot touch the
# user's own tmux session.
export TMUX_TMPDIR="$TMP/tmux"; mkdir -p "$TMUX_TMPDIR"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
# check <message> <command...>: pass if the command succeeds
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else fail "$msg ($(args_line))"; fi; }
# has_arg <flag-or-value>: the stub saw this as one of its arguments
has_arg() { grep -qxF -- "$1" "$TMP/args"; }
args_line() { tr '\n' ' ' < "$TMP/args" | cut -c1-400; }

# --- stub claude and canned results -------------------------------------------
mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/claude" << 'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGS"
cat "$STUB_JSON"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$TMP/bin/claude"
export STUB_ARGS="$TMP/args" STUB_JSON="$TMP/fx/ok.json"

ZERO='"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
MU='"modelUsage":{"claude-opus-4-8":{"inputTokens":8,"outputTokens":701,"cacheReadInputTokens":20055,"cacheCreationInputTokens":7429,"costUSD":0.1019}}'
printf '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":4,"total_cost_usd":0.1019,"result":"Moved 0001 to merging.","permission_denials":[],"usage":{"input_tokens":8,"output_tokens":701,"cache_read_input_tokens":20055,"cache_creation_input_tokens":7429},%s}' "$MU" > "$TMP/fx/ok.json"
# A rejected model reports subtype "success" with is_error true
printf '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":404,"num_turns":1,"total_cost_usd":0,"result":"There is an issue with the selected model (no-such-model).","permission_denials":[],%s,"modelUsage":{}}' "$ZERO" > "$TMP/fx/badmodel.json"
# A budget stop has no result, a zeroed usage block, and real figures in modelUsage
# shellcheck disable=SC2016  # the dollar sign is part of the captured message
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"terminal_reason":"budget_exhausted","num_turns":1,"total_cost_usd":0.175,"errors":["Reached maximum budget ($0.001)"],"permission_denials":[],%s,%s}' "$ZERO" "$MU" > "$TMP/fx/budget.json"
printf '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529,"num_turns":1,"total_cost_usd":0,"result":"Overloaded","permission_denials":[],%s,"modelUsage":{}}' "$ZERO" > "$TMP/fx/overloaded.json"
printf '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":3,"total_cost_usd":0.05,"result":"Done.","permission_denials":[{"tool_name":"Edit"}],%s}' "$MU" > "$TMP/fx/denied.json"
printf '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":3,"total_cost_usd":0.05,"result":"task-locks.sh failed.\\nHANDLER-FAILED: task-locks.sh exited 1","permission_denials":[],%s}' "$MU" > "$TMP/fx/handlerfailed.json"
printf '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"max_turns","num_turns":50,"total_cost_usd":0.9,"result":"","permission_denials":[],%s}' "$MU" > "$TMP/fx/maxturns.json"
echo 'this is not json' > "$TMP/fx/garbage.json"

# --- a conductor dir to dispatch in -------------------------------------------
export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR/prompts"
cp "$ROOT_DIR/prompts/conductor.prompt" "$CONDUCTOR_DIR/prompts/"
cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"
export SCRIPTS_DIR TASK_ID=0001
export DISPATCH_USAGE_FILE="$TMP/usage.json"

# dispatch <fixture> [claude exit code]: runs adapter_dispatch; sets RC and ERR
dispatch() {
  STUB_JSON="$TMP/fx/$1.json" STUB_RC="${2:-0}" RC=0
  export STUB_JSON STUB_RC
  rm -f "${DISPATCH_USAGE_FILE:-/nonexistent}"
  ERR="$(PATH="$TMP/bin:$PATH" bash -c 'source "$1"; adapter_dispatch "# Skill: Example
1. do the thing" "/x/work/0001/review-1.md"' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
}
usage_field() { jq -r ".$1" "$DISPATCH_USAGE_FILE"; }

section "1 · A finished run"
dispatch ok
assert_eq "exit 0" "$RC" "0"
check "claude -p" has_arg -p
check "no session persistence" has_arg --no-session-persistence
assert_eq "output format" "$(grep -xA1 -- '--output-format' "$TMP/args" | tail -1)" "json"
assert_eq "budget cap default" "$(grep -xA1 -- '--max-budget-usd' "$TMP/args" | tail -1)" "1"
assert_eq "tools limited to what handlers use" "$(grep -xA1 -- '--tools' "$TMP/args" | tail -1)" "Bash,Read"
check "no MCP servers" has_arg --strict-mcp-config
assert_eq "user-level settings skipped" "$(grep -xA1 -- '--setting-sources' "$TMP/args" | tail -1)" "project"
assert_eq "short system prompt" "$(grep -xA1 -- '--system-prompt' "$TMP/args" | tail -1 | cut -c1-23)" "You are an automation a"
assert_eq "the conductor's model from the workforce" "$(grep -xA1 -- '--model' "$TMP/args" | tail -1)" "claude-opus-4-8"
check "the prompt carries the skill" grep -q '^1. do the thing' "$TMP/args"
check "and the artifact" grep -q 'Artifact: /x/work/0001/review-1.md' "$TMP/args"

section "2 · The usage record"
assert_eq "harness" "$(usage_field harness)" "claude-code"
assert_eq "model" "$(usage_field model)" "claude-opus-4-8"
assert_eq "input tokens" "$(usage_field input_tokens)" "8"
assert_eq "output tokens" "$(usage_field output_tokens)" "701"
assert_eq "cache read tokens" "$(usage_field cache_read_tokens)" "20055"
assert_eq "cache write tokens" "$(usage_field cache_write_tokens)" "7429"
assert_eq "cost" "$(usage_field cost_usd)" "0.1019"
assert_eq "turns" "$(usage_field turns)" "4"
assert_eq "one line" "$(wc -l < "$DISPATCH_USAGE_FILE" | tr -d ' ')" "1"

section "3 · Settings that change the call"
CONDUCTOR_MAX_BUDGET_USD=0.4 dispatch ok
assert_eq "budget cap from the environment" "$(grep -xA1 -- '--max-budget-usd' "$TMP/args" | tail -1)" "0.4"
printf '{"members":[{"role":"conductor","adapter":"claude-code","params":{"model":"claude-sonnet-4-6","effort":"high"}}]}' > "$CONDUCTOR_DIR/workforce.json"
dispatch ok
assert_eq "model follows the workforce" "$(grep -xA1 -- '--model' "$TMP/args" | tail -1)" "claude-sonnet-4-6"
assert_eq "effort follows the workforce" "$(grep -xA1 -- '--effort' "$TMP/args" | tail -1)" "high"
printf '{"members":[{"role":"conductor","adapter":"claude-code"}]}' > "$CONDUCTOR_DIR/workforce.json"
dispatch ok
assert_eq "exit 0 with no params" "$RC" "0"
if has_arg --model; then fail "passed a model nobody asked for"; else ok "no model flag when the workforce sets none"; fi
cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"

section "4 · A rejected request is not retried"
dispatch badmodel 1
assert_eq "exit 2" "$RC" "2"
case "$ERR" in *"rejected (HTTP 404)"*) ok "says why" ;; *) fail "message: $ERR" ;; esac

section "5 · A budget stop is not retried, and its spend is recorded"
dispatch budget 1
assert_eq "exit 2" "$RC" "2"
case "$ERR" in *"CONDUCTOR_MAX_BUDGET_USD"*) ok "names the setting" ;; *) fail "message: $ERR" ;; esac
assert_eq "cost still recorded" "$(usage_field cost_usd)" "0.175"
assert_eq "tokens read from modelUsage, not the zeroed usage block" "$(usage_field cache_write_tokens)" "7429"

section "6 · Failures that are worth a retry"
dispatch overloaded 1
assert_eq "an overloaded API: exit 1" "$RC" "1"
dispatch denied
assert_eq "a denied tool: exit 1" "$RC" "1"
case "$ERR" in *"denied: Edit"*) ok "names the tool" ;; *) fail "message: $ERR" ;; esac
dispatch maxturns
assert_eq "a run that did not complete: exit 1" "$RC" "1"
dispatch ok 1
assert_eq "claude exiting non-zero: exit 1" "$RC" "1"
dispatch garbage 1
assert_eq "no JSON at all: exit 1" "$RC" "1"
case "$ERR" in *"no JSON"*) ok "says so" ;; *) fail "message: $ERR" ;; esac

section "7 · The model reports a failed guard"
dispatch handlerfailed
assert_eq "HANDLER-FAILED on the last line: exit 1" "$RC" "1"
case "$ERR" in *"HANDLER-FAILED: task-locks.sh exited 1"*) ok "quotes the reason" ;; *) fail "message: $ERR" ;; esac

section "8 · No usage file asked for"
unset DISPATCH_USAGE_FILE
dispatch ok
assert_eq "exit 0" "$RC" "0"
export DISPATCH_USAGE_FILE="$TMP/usage.json"

section "9 · claude is not installed"
RC=0
# shellcheck disable=SC2016  # $1 belongs to the child shell
ERR="$(PATH="$TMP/nowhere" "$BASH" -c 'source "$1"; adapter_dispatch s a' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
assert_eq "exit 2" "$RC" "2"
case "$ERR" in *"not installed"*) ok "says so" ;; *) fail "message: $ERR" ;; esac

section "10 · jq is not installed"
mkdir -p "$TMP/bin-nojq"; cp "$TMP/bin/claude" "$TMP/bin-nojq/claude"
RC=0
# shellcheck disable=SC2016  # $1 belongs to the child shell
ERR="$(PATH="$TMP/bin-nojq" "$BASH" -c 'source "$1"; adapter_dispatch s a' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
assert_eq "exit 2" "$RC" "2"
case "$ERR" in *"needs jq"*) ok "says what to install" ;; *) fail "message: $ERR" ;; esac

section "11 · Nothing accumulates between dispatches"
dispatch ok; dispatch ok; dispatch badmodel 1; dispatch ok
assert_eq "two fixed files, however many dispatches" "$(find "$CONDUCTOR_DIR" -maxdepth 1 -name 'dispatch-result*' | wc -l | tr -d ' ')" "2"

section "12 · Through the loop"
SW="$TMP/swarm"; mkdir -p "$SW/.conductor"/{tasks,work}
export CONDUCTOR_DIR="$SW/.conductor"
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp "$topo" "$CONDUCTOR_DIR/topology.json"
cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"
cp -r "$ROOT_DIR/skills" "$CONDUCTOR_DIR/skills"; cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
printf 'lang: bash\npoll-interval: 1\n' > "$CONDUCTOR_DIR/config.md"
"$SCRIPTS_DIR/task-create.sh" --title T --type chore --description x > /dev/null
PATH="$TMP/bin:$PATH" bash "$SCRIPTS_DIR/conductor-loop.sh" --once > /dev/null 2>&1   # seeds the ledger
sleep 1
"$SCRIPTS_DIR/task-signal.sh" --task 0001 --type signal --outcome complete > /dev/null
RC=0
STUB_JSON="$TMP/fx/ok.json" PATH="$TMP/bin:$PATH" CONDUCTOR_ADAPTER_FILE="$ADAPTER" \
  bash "$SCRIPTS_DIR/conductor-loop.sh" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
assert_eq "the loop exits 0" "$RC" "0"
assert_eq "the event is recorded" "$("$SCRIPTS_DIR/artifact-ledger.sh" unprocessed)" ""
check "claude was given the signal-complete skill" grep -q '^# Skill: On Signal Complete' "$TMP/args"
assert_eq "the loop's usage file holds the record" "$(jq -r .harness "$CONDUCTOR_DIR/dispatch-usage.json")" "claude-code"
RC=0
: > "$TMP/args"
sleep 1; "$SCRIPTS_DIR/task-signal.sh" --task 0001 --type review --outcome approved > /dev/null
STUB_JSON="$TMP/fx/badmodel.json" STUB_RC=1 PATH="$TMP/bin:$PATH" CONDUCTOR_ADAPTER_FILE="$ADAPTER" CONDUCTOR_MAX_ATTEMPTS=3 CONDUCTOR_RETRY_DELAY=0 \
  bash "$SCRIPTS_DIR/conductor-loop.sh" --once > /dev/null 2> "$TMP/loop.err" || RC=$?
assert_eq "a rejected request halts the loop" "$RC" "1"
assert_eq "after one attempt, not three" "$(grep -c 'attempt' "$TMP/loop.err" || true)" "1"
check "as an unusable event" grep -q '^kind: unusable' "$CONDUCTOR_DIR/conductor-loop.halted"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
