#!/usr/bin/env bash
# Tests adapter_dispatch in adapters/codex.sh with no AI and no network: a stub `codex` on
# the PATH records its arguments and plays back a canned event stream. The event shapes
# (thread.started, turn.started, item.completed, turn.completed, turn.failed) were
# captured from real `codex exec --json` runs.
#
# Usage: scripts/test-codex-dispatch.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
ADAPTER="$ROOT_DIR/adapters/codex.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else fail "$msg ($(tr '\n' ' ' < "$TMP/args" | cut -c1-300))"; fi; }
has_arg() { grep -qxF -- "$1" "$TMP/args"; }
arg_after() { grep -xA1 -- "$1" "$TMP/args" | tail -1; }

# --- stub codex and canned event streams ---------------------------------------
mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/codex" << 'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGS"
# Is stdin closed? A read that times out means something is still holding the pipe open.
if read -r -t 1 _; then echo "data" > "$STUB_STDIN"; else
  if [[ $? -gt 128 ]]; then echo "open" > "$STUB_STDIN"; else echo "eof" > "$STUB_STDIN"; fi
fi
cat "$STUB_OUT"
[[ -f "$STUB_ERR" ]] && cat "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$TMP/bin/codex"
export STUB_ARGS="$TMP/args" STUB_STDIN="$TMP/stdin" STUB_ERR="$TMP/stub.err"

START='{"type":"thread.started","thread_id":"t1"}
{"type":"turn.started"}'
DONE='{"type":"turn.completed","usage":{"input_tokens":15253,"cached_input_tokens":12288,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}'
CMD_FAILED='{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"false","aggregated_output":"","exit_code":1,"status":"failed"}}'
msg() { printf '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":%s}}' "$(jq -Rs . <<< "$1")"; }
fx() { cat > "$TMP/fx/$1.jsonl"; }

printf '%s\n%s\n%s\n%s\n' "$START" "$CMD_FAILED" "$(msg 'Moved 0001 to merging.')" "$DONE" | fx ok
WARN='{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for x not found. Defaulting to fallback metadata."}}'
printf '%s\n%s\n%s\n%s\n' "$START" "$WARN" "$(msg 'Done.')" "$DONE" | fx warning-only
printf '%s\n%s\n%s\n%s\n' "$START" "$(msg 'locks failed.
HANDLER-FAILED: task-locks.sh exited 1')" "$DONE" "" | fx handlerfailed
{
  echo "$START"
  echo '{"type":"error","message":"The '"'"'x'"'"' model is not supported when using Codex with a ChatGPT account."}'
  echo '{"type":"turn.failed","error":{"message":"The '"'"'x'"'"' model is not supported when using Codex with a ChatGPT account."}}'
} | fx unsupported
{ echo "$START"; echo '{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}'; } | fx transient
{ echo "$START"; echo '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"sleep 40","status":"in_progress"}}'; } | fx killed
{ echo "$START"; echo "$DONE"; echo 'warning: a stray line that is not JSON'; msg 'Two turns.'; echo; echo "$DONE"; } | fx two-turns
: > "$TMP/fx/empty.jsonl"

# --- a conductor dir to dispatch in -------------------------------------------
export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR/prompts"
cp "$ROOT_DIR/prompts/conductor.prompt" "$CONDUCTOR_DIR/prompts/"
printf '{"members":[{"role":"conductor","adapter":"codex","params":{"model":"gpt-5","effort":"high"}}]}' > "$CONDUCTOR_DIR/workforce.json"
export SCRIPTS_DIR TASK_ID=0001
export DISPATCH_USAGE_FILE="$TMP/usage.json"

# dispatch <fixture> [codex exit code]: runs adapter_dispatch; sets RC and ERR
dispatch() {
  STUB_OUT="$TMP/fx/$1.jsonl" STUB_RC="${2:-0}" RC=0
  export STUB_OUT STUB_RC
  rm -f "$DISPATCH_USAGE_FILE" "$TMP/args" "$TMP/stdin"
  # shellcheck disable=SC2016  # $1 belongs to the child shell
  ERR="$(PATH="$TMP/bin:$PATH" bash -c 'source "$1"; adapter_dispatch "# Skill: Example
1. do the thing" "/x/work/0001/review-1.md"' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
}
usage_field() { jq -c ".$1" "$DISPATCH_USAGE_FILE"; }

section "1 · A finished run"
dispatch ok
assert_eq "exit 0 (a failing command inside the run is not a failure)" "$RC" "0"
assert_eq "exec subcommand" "$(head -1 "$TMP/args")" "exec"
check "json events" has_arg --json
check "ephemeral" has_arg --ephemeral
check "no git repo needed" has_arg --skip-git-repo-check
assert_eq "sandbox default" "$(arg_after -s)" "danger-full-access"
assert_eq "model from the workforce" "$(arg_after --model)" "gpt-5"
assert_eq "effort from the workforce" "$(arg_after -c)" "model_reasoning_effort=high"
check "the prompt carries the skill" grep -q '^1. do the thing' "$TMP/args"
check "and the artifact" grep -q 'Artifact: /x/work/0001/review-1.md' "$TMP/args"

section "2 · The usage record"
assert_eq "harness" "$(usage_field harness)" '"codex"'
assert_eq "model asked for" "$(usage_field model)" '"gpt-5"'
assert_eq "input excludes the cached part" "$(usage_field input_tokens)" "2965"
assert_eq "output tokens" "$(usage_field output_tokens)" "5"
assert_eq "cache read is the cached input" "$(usage_field cache_read_tokens)" "12288"
assert_eq "cache write" "$(usage_field cache_write_tokens)" "0"
assert_eq "no cost is reported, so null" "$(usage_field cost_usd)" "null"
assert_eq "turns: model and tool steps" "$(usage_field turns)" "2"

section "3 · stdin is closed"
# The dispatch is started with a pipe on stdin that stays open; the stub must still see EOF.
STUB_OUT="$TMP/fx/ok.jsonl" STUB_RC=0
export STUB_OUT STUB_RC
# shellcheck disable=SC2016  # $1 belongs to the child shell
PATH="$TMP/bin:$PATH" bash -c 'source "$1"; adapter_dispatch s /a' _ "$ADAPTER" < <(sleep 4) > /dev/null 2>&1 || true
assert_eq "codex saw end-of-file" "$(cat "$TMP/stdin")" "eof"

section "4 · A warning is not a failure"
dispatch warning-only
assert_eq "exit 0" "$RC" "0"

section "5 · Settings that change the call"
CONDUCTOR_CODEX_SANDBOX=workspace-write dispatch ok
assert_eq "sandbox from the environment" "$(arg_after -s)" "workspace-write"
CONDUCTOR_CODEX_SANDBOX=nonsense dispatch ok
assert_eq "an unknown sandbox: exit 2" "$RC" "2"
case "$ERR" in *"must be read-only, workspace-write or danger-full-access"*) ok "says what is allowed" ;; *) fail "message: $ERR" ;; esac
assert_eq "codex was not run" "$([[ -e "$TMP/args" ]] && echo ran || echo not-run)" "not-run"
printf '{"members":[{"role":"conductor","adapter":"codex"}]}' > "$CONDUCTOR_DIR/workforce.json"
dispatch ok
assert_eq "exit 0 with no params" "$RC" "0"
if has_arg --model; then fail "passed a model nobody asked for"; else ok "no model flag"; fi
assert_eq "model is null in the record" "$(usage_field model)" "null"
printf '{"members":[{"role":"conductor","adapter":"codex","params":{"model":"gpt-5","effort":"high"}}]}' > "$CONDUCTOR_DIR/workforce.json"

section "6 · Several turns add up"
dispatch two-turns
assert_eq "exit 0 despite the stray line" "$RC" "0"
assert_eq "input summed" "$(usage_field input_tokens)" "5930"
assert_eq "cache read summed" "$(usage_field cache_read_tokens)" "24576"

section "7 · A rejected model is not retried"
dispatch unsupported 1
assert_eq "exit 2" "$RC" "2"
case "$ERR" in *"rejected"*"not supported"*) ok "quotes the message" ;; *) fail "message: $ERR" ;; esac
assert_eq "no usage without turn.completed" "$([[ -e "$DISPATCH_USAGE_FILE" ]] && echo written || echo none)" "none"

section "8 · A failure worth a retry"
dispatch transient 1
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"the run failed"*"stream disconnected"*) ok "quotes the message" ;; *) fail "message: $ERR" ;; esac

section "9 · A run that was killed leaves no completion"
dispatch killed 124
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"ended without completing"*) ok "says so" ;; *) fail "message: $ERR" ;; esac
assert_eq "no usage record" "$([[ -e "$DISPATCH_USAGE_FILE" ]] && echo written || echo none)" "none"

section "10 · No events at all"
printf 'Reading additional input from stdin...\n' > "$STUB_ERR"
dispatch empty 1
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"no events"*) ok "says so" ;; *) fail "message: $ERR" ;; esac
case "$ERR" in *"Reading additional input"*) ok "passes on codex's own message" ;; *) fail "stderr not shown: $ERR" ;; esac
rm -f "$STUB_ERR"

section "11 · codex exits non-zero after completing"
dispatch ok 1
assert_eq "exit 1" "$RC" "1"

section "12 · The model reports a failed guard"
dispatch handlerfailed
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"HANDLER-FAILED: task-locks.sh exited 1"*) ok "quotes the reason" ;; *) fail "message: $ERR" ;; esac

section "13 · Missing tools"
RC=0
# shellcheck disable=SC2016  # $1 belongs to the child shell
ERR="$(PATH="$TMP/nowhere" "$BASH" -c 'source "$1"; adapter_dispatch s a' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
assert_eq "no codex: exit 2" "$RC" "2"
mkdir -p "$TMP/bin-nojq"; cp "$TMP/bin/codex" "$TMP/bin-nojq/codex"
RC=0
# shellcheck disable=SC2016  # $1 belongs to the child shell
ERR="$(PATH="$TMP/bin-nojq" "$BASH" -c 'source "$1"; adapter_dispatch s a' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
assert_eq "no jq: exit 2" "$RC" "2"
case "$ERR" in *"needs jq"*) ok "says what to install" ;; *) fail "message: $ERR" ;; esac

section "14 · Through the loop"
SW="$TMP/swarm"; mkdir -p "$SW/.conductor"/{tasks,work}
export CONDUCTOR_DIR="$SW/.conductor"
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp "$topo" "$CONDUCTOR_DIR/topology.json"
cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"
cp -r "$ROOT_DIR/skills" "$CONDUCTOR_DIR/skills"; cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
printf 'lang: bash\npoll-interval: 1\n' > "$CONDUCTOR_DIR/config.md"
"$SCRIPTS_DIR/task-create.sh" --title T --type chore --description x > /dev/null
PATH="$TMP/bin:$PATH" STUB_OUT="$TMP/fx/ok.jsonl" bash "$SCRIPTS_DIR/conductor-loop.sh" --once > /dev/null 2>&1   # seeds the ledger
sleep 1
"$SCRIPTS_DIR/task-signal.sh" --task 0001 --type signal --outcome complete > /dev/null
RC=0
STUB_OUT="$TMP/fx/ok.jsonl" STUB_RC=0 PATH="$TMP/bin:$PATH" CONDUCTOR_ADAPTER_FILE="$ADAPTER" \
  bash "$SCRIPTS_DIR/conductor-loop.sh" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
assert_eq "the loop exits 0" "$RC" "0"
assert_eq "the event is recorded" "$("$SCRIPTS_DIR/artifact-ledger.sh" unprocessed)" ""
check "codex was given the signal-complete skill" grep -q '^# Skill: On Signal Complete' "$TMP/args"
assert_eq "the loop's usage file holds the record" "$(jq -r .harness "$CONDUCTOR_DIR/dispatch-usage.json")" "codex"
sleep 1; "$SCRIPTS_DIR/task-signal.sh" --task 0001 --type review --outcome approved > /dev/null
RC=0
STUB_OUT="$TMP/fx/unsupported.jsonl" STUB_RC=1 PATH="$TMP/bin:$PATH" CONDUCTOR_ADAPTER_FILE="$ADAPTER" CONDUCTOR_MAX_ATTEMPTS=3 CONDUCTOR_RETRY_DELAY=0 \
  bash "$SCRIPTS_DIR/conductor-loop.sh" --once > /dev/null 2> "$TMP/loop.err" || RC=$?
assert_eq "a rejected model halts the loop" "$RC" "1"
assert_eq "after one attempt, not three" "$(grep -c 'attempt' "$TMP/loop.err" || true)" "1"
check "as an unusable event" grep -q '^kind: unusable' "$CONDUCTOR_DIR/conductor-loop.halted"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
