#!/usr/bin/env bash
# Tests scripts/conductor-loop.sh with no tmux, no AI and no swarm: a stub
# adapter_dispatch logs what it is called with and returns the exit codes the test
# queues for it. The real task-create.sh, task-signal.sh, artifact-ledger.sh,
# topology-load.sh and conductor skills are used.
#
# Usage: scripts/test-conductor-loop.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

LOOP="$SCRIPTS_DIR/conductor-loop.sh"

TMP="$(mktemp -d)"
# A private tmux server: if a test ever reaches the real worker-spawn.sh, it cannot touch the
# user's own tmux session.
export TMUX_TMPDIR="$TMP/tmux"; mkdir -p "$TMUX_TMPDIR"
LOOP_PID=""
# shellcheck disable=SC2329  # invoked via trap, not a direct call
cleanup() {
  [[ -n "$LOOP_PID" ]] && kill "$LOOP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
# Claude Code's sign-in and state are the test's own, never ~/.claude: no test reaches the usage endpoint.
export CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json" CLAUDE_JSON_FILE="$TMP/no-claude.json" CLAUDE_STATUSLINE_FILE="$TMP/no-claude-statusline.json"
# The Claude usage endpoint's state is the test's own (never ~/.claude), and an answer is not reused: each read asks the stub (#173).
export CLAUDE_USAGE_STATE_FILE="$TMP/endpoint-state.json" CLAUDE_USAGE_FRESH_SECONDS=0

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
# expect_grep <pattern> <file> <message>: pass if the pattern is in the file, else show the file
expect_grep() {
  if grep -q -- "$1" "$2"; then ok "$3"; else fail "$3 (in $2: $(tr '\n' '|' < "$2" | cut -c1-300))"; fi
}

# --- stub adapter -------------------------------------------------------------
# Queue exit codes in $STUB_RC, one per line: 0, 1, 2, or "sleep" (hang). An empty
# queue means success. $STUB_HOOK, if it exists, is run inside the dispatch.
STUB="$TMP/stub-adapter.sh"
cat > "$STUB" << 'STUB_EOF'
adapter_dispatch() {
  local skill="$1" art="$2" rc=0
  if [[ "$art" == "startup" ]]; then
    # The startup reconcile: logged apart from events, and the queued exit codes are not for it.
    echo "reconcile $(printf '%s' "$skill" | head -1) task_id=[${TASK_ID:-}] artifact=[${ARTIFACT:-}]" >> "$STUB_LOG"
    [[ -n "${STUB_USAGE:-}" && -n "${DISPATCH_USAGE_FILE:-}" ]] && printf '%s\n' "$STUB_USAGE" > "$DISPATCH_USAGE_FILE"
    [[ -n "${STUB_ERRMSG:-}" && "${STUB_RECONCILE_RC:-0}" != 0 ]] && echo "$STUB_ERRMSG" >&2
    return "${STUB_RECONCILE_RC:-0}"
  fi
  {
    echo "start $TASK_ID $(basename "$art") | $(printf '%s' "$skill" | head -1)"
    echo "env CONDUCTOR_DIR=$CONDUCTOR_DIR LOOP=${CONDUCTOR_LOOP:-} DEADLINE=${DISPATCH_DEADLINE:-} USAGE=${DISPATCH_USAGE_FILE:-}"
    echo "env task_file_exists=$([[ -f "$TASK_FILE" ]] && echo yes || echo no) artifact_exists=$([[ -f "$ARTIFACT" ]] && echo yes || echo no) task-list=$(command -v task-list.sh)"
  } >> "$STUB_LOG"
  if [[ -s "$STUB_RC" ]]; then
    rc="$(head -1 "$STUB_RC")"
    tail -n +2 "$STUB_RC" > "$STUB_RC.next"; mv "$STUB_RC.next" "$STUB_RC"
  fi
  [[ -n "${STUB_USAGE:-}" && -n "${DISPATCH_USAGE_FILE:-}" ]] && printf '%s\n' "$STUB_USAGE" > "$DISPATCH_USAGE_FILE"
  [[ -n "${STUB_ANSWER:-}" && -n "${DISPATCH_ANSWER_FILE:-}" ]] && printf '%s\n' "$STUB_ANSWER" > "$DISPATCH_ANSWER_FILE"
  [[ -n "${STUB_ERRMSG:-}" ]] && echo "$STUB_ERRMSG" >&2
  [[ -f "$STUB_HOOK" ]] && bash "$STUB_HOOK"
  if [[ "$rc" == "sleep" ]]; then sleep "$STUB_SLEEP_ARG"; rc=0; fi
  echo "end $TASK_ID $rc" >> "$STUB_LOG"
  return "$rc"
}
STUB_EOF
export STUB_LOG="$TMP/stub.log" STUB_RC="$TMP/stub.rc" STUB_HOOK="$TMP/stub.hook"
# A sleep length no other process uses, so pgrep can tell this test's children apart.
export STUB_SLEEP_ARG="29.$$"
children_left() { pgrep -f "sleep $STUB_SLEEP_ARG" | wc -l | tr -d ' '; }

# --- helpers ------------------------------------------------------------------
SW="$TMP/swarm"
new_swarm() {
  rm -rf "$SW"; mkdir -p "$SW/.conductor"/{tasks,work}
  export CONDUCTOR_DIR="$SW/.conductor"
  local topo; topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
  while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done \
    < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
  cp "$topo" "$CONDUCTOR_DIR/topology.json"
  cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"
  cp -r "$ROOT_DIR/skills" "$CONDUCTOR_DIR/skills"
  cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
  printf 'lang: bash\npoll-interval: 1\n' > "$CONDUCTOR_DIR/config.md"
  : > "$STUB_LOG"; : > "$STUB_RC"; rm -f "$STUB_HOOK"
  unset CONDUCTOR_MAX_ATTEMPTS CONDUCTOR_DISPATCH_DEADLINE CONDUCTOR_KILL_GRACE CONDUCTOR_TIMEOUT_CMD STUB_RECONCILE_RC STUB_ERRMSG STUB_USAGE STUB_ANSWER CONDUCTOR_HEARTBEAT
  # No script handles an event unless a section says so: these tests are about the loop, and would
  # otherwise change each time a real handler in scripts/handlers is converted.
  mkdir -p "$TMP/no-handlers"; export CONDUCTOR_HANDLERS_DIR="$TMP/no-handlers"
  export CONDUCTOR_RETRY_DELAY=0
  # The stub handlers move nothing, so every card they leave in backlog would be healed after the
  # event (#170), and these tests are about the loop's other work. Section 50 turns the check on.
  export CONDUCTOR_BACKLOG_CHECK=off
}
create_task() { "$SCRIPTS_DIR/task-create.sh" --title "T" --type chore --description "x" > /dev/null; }
signal() { "$SCRIPTS_DIR/task-signal.sh" --task "$1" --type "$2" ${3:+--outcome "$3"} > /dev/null; }
run_loop() { # sets RC
  RC=0
  CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
}
dispatches() { grep -c '^start ' "$STUB_LOG" || true; }
unprocessed() { "$SCRIPTS_DIR/artifact-ledger.sh" unprocessed; }
queue() { : > "$STUB_RC"; local c; for c in "$@"; do echo "$c" >> "$STUB_RC"; done; }
# ulines <event prefix>: the usage log lines for one event, as compact JSON
ulines() { jq -c "select(.record == null and ((.event // \"\") | startswith(\"$1\")))" "$CONDUCTOR_DIR/usage.jsonl" 2> /dev/null; }
# ufield <event prefix> <jq path>: one field of the last such line
ufield() { ulines "$1" | tail -1 | jq -r "$2"; }
notices() { find "$CONDUCTOR_DIR/$1" -name 'loop-halt-*.md' 2> /dev/null | wc -l | tr -d ' '; }
notice() { find "$CONDUCTOR_DIR/$1" -name 'loop-halt-*.md' | head -1; }
halt_kind() { awk -F': ' '/^kind: /{print $2}' "$CONDUCTOR_DIR/conductor-loop.halted" 2>/dev/null || true; }

# 1 -------------------------------------------------------------------------------
section "1 · First start seeds the ledger instead of replaying history"
new_swarm
create_task; signal 0001 signal complete
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "nothing dispatched for existing artifacts" "$(dispatches)" "0"
assert_eq "everything existing is recorded" "$(unprocessed)" ""
assert_eq "ledger has all three artifacts" "$(wc -l < "$CONDUCTOR_DIR/processed.log" | tr -d ' ')" "3"

# 2 -------------------------------------------------------------------------------
section "2 · A new event is dispatched once, then recorded"
sleep 1; signal 0001 signal complete
run_loop
assert_eq "one dispatch" "$(dispatches)" "1"
expect_grep '^start 0001 signal-.* | # Skill: On Signal Complete' "$STUB_LOG" "the signal-complete handler ran for task 0001"
assert_eq "recorded as processed" "$(unprocessed)" ""
run_loop
assert_eq "a second run dispatches nothing" "$(dispatches)" "1"

# 3 -------------------------------------------------------------------------------
section "3 · The dispatch gets the environment the skills need"
expect_grep "^env CONDUCTOR_DIR=$CONDUCTOR_DIR LOOP=1 DEADLINE=600 USAGE=$CONDUCTOR_DIR/dispatch-usage.json" "$STUB_LOG" "CONDUCTOR_DIR, CONDUCTOR_LOOP, DISPATCH_DEADLINE, DISPATCH_USAGE_FILE"
expect_grep "^env task_file_exists=yes artifact_exists=yes task-list=$SCRIPTS_DIR/task-list.sh" "$STUB_LOG" "TASK_FILE, ARTIFACT set; scripts on PATH"

# 4 -------------------------------------------------------------------------------
section "4 · Events with no handler are recorded without a dispatch"
new_swarm
create_task
run_loop                                    # seeds
: > "$STUB_LOG"
signal 0001 progress; sleep 1; "$SCRIPTS_DIR/task-move.sh" 0001 ready
assert_eq "progress and moved are waiting" "$(unprocessed | wc -l | tr -d ' ')" "2"
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "no dispatch" "$(dispatches)" "0"
assert_eq "both recorded" "$(unprocessed)" ""

# 5 -------------------------------------------------------------------------------
section "5 · A new task (a card artifact) runs the new-task handler"
# The loop has no rule of its own for `card`: it gets the handler from topology-load.sh
# conductor-skill, the rule the interactive conductor uses, so this also checks they agree.
sleep 1; create_task
run_loop
expect_grep '^start 0002 card-.* | # Skill: On New Task' "$STUB_LOG" "on-new-task ran for task 0002"
expect_grep '^env task_file_exists=yes' "$STUB_LOG" "TASK_FILE points at the task"
assert_eq "its moved artifact needed no dispatch" "$(unprocessed)" ""

# 6 -------------------------------------------------------------------------------
section "6 · One event at a time"
new_swarm
create_task; create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete; signal 0002 signal complete; signal 0001 validation passed
run_loop
assert_eq "three dispatches" "$(dispatches)" "3"
assert_eq "start and end alternate" "$(grep -E '^(start|end) ' "$STUB_LOG" | awk '{print $1}' | tr '\n' ' ')" "start end start end start end "

# 7 -------------------------------------------------------------------------------
section "7 · A failure is retried, then succeeds"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue 1 0
CONDUCTOR_MAX_ATTEMPTS=3 run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "two attempts" "$(dispatches)" "2"
assert_eq "recorded" "$(unprocessed)" ""

# 8 -------------------------------------------------------------------------------
section "8 · Repeated failure halts and keeps the event"
new_swarm
create_task; create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete; sleep 1; signal 0002 signal complete
queue 1 1
CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "two attempts, no more" "$(dispatches)" "2"
assert_eq "halt kind" "$(halt_kind)" "failed"
assert_eq "the failed event is still unprocessed, with the next behind it" "$(unprocessed | wc -l | tr -d ' ')" "2"
assert_eq "the second task was not touched" "$(grep -c '^start 0002' "$STUB_LOG" || true)" "0"
queue
run_loop
assert_eq "a restart retries the same event" "$(dispatches)" "4"
assert_eq "and clears the halt" "$([[ -f "$CONDUCTOR_DIR/conductor-loop.halted" ]] && echo yes || echo no)" "no"

# 9 -------------------------------------------------------------------------------
section "9 · Exit 2 halts without a retry"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue 2 0
CONDUCTOR_MAX_ATTEMPTS=3 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "one attempt" "$(dispatches)" "1"
assert_eq "halt kind" "$(halt_kind)" "unusable"

# 10 ------------------------------------------------------------------------------
section "10 · A handler that cannot be resolved halts without a dispatch"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal weird
run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "no dispatch" "$(dispatches)" "0"
assert_eq "halt kind" "$(halt_kind)" "unresolvable"
expect_grep 'no skill file' "$CONDUCTOR_DIR/conductor-loop.halted" "names the missing skill"
new_swarm
create_task; run_loop
printf -- '---\ntask-id: 0001\n---\n' > "$CONDUCTOR_DIR/work/0001/broken-20261031-235959.md"
run_loop
assert_eq "an artifact with no type halts too" "$(halt_kind)" "unresolvable"

# 11 ------------------------------------------------------------------------------
section "11 · A hung handler is killed at the deadline"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue sleep
START=$SECONDS
CONDUCTOR_MAX_ATTEMPTS=1 CONDUCTOR_DISPATCH_DEADLINE=1 CONDUCTOR_KILL_GRACE=1 run_loop
ELAPSED=$(( SECONDS - START ))
assert_eq "exit 1" "$RC" "1"
if [[ "$ELAPSED" -le 8 ]]; then ok "stopped after ${ELAPSED}s, not the stub's 30s"; else fail "took ${ELAPSED}s"; fi
assert_eq "halt kind" "$(halt_kind)" "failed"
assert_eq "the handler never finished" "$(grep -c '^end ' "$STUB_LOG" || true)" "0"
assert_eq "event not recorded" "$(unprocessed | wc -l | tr -d ' ')" "1"
sleep 0.5
assert_eq "the handler's child process is gone too" "$(children_left)" "0"

# 12 ------------------------------------------------------------------------------
section "12 · A killed loop leaves the event for the restart"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue sleep
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" &
LOOP_PID=$!
for _ in $(seq 1 50); do grep -q '^start ' "$STUB_LOG" && break; sleep 0.1; done
kill -TERM "$LOOP_PID"
wait "$LOOP_PID" 2>/dev/null || true
LOOP_PID=""
assert_eq "the handler had started" "$(dispatches)" "1"
assert_eq "it did not finish" "$(grep -c '^end ' "$STUB_LOG" || true)" "0"
sleep 0.5
assert_eq "no process from the dispatch is left running" "$(children_left)" "0"
assert_eq "the event is still unprocessed" "$(unprocessed | wc -l | tr -d ' ')" "1"
assert_eq "the lock was released" "$([[ -d "$CONDUCTOR_DIR/conductor-loop.lock" ]] && echo held || echo free)" "free"
run_loop
assert_eq "the restart runs it again" "$(dispatches)" "2"
assert_eq "and records it" "$(unprocessed)" ""

# 13 ------------------------------------------------------------------------------
section "13 · One loop per conductor dir"
new_swarm
create_task; run_loop
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" &
LOOP_PID=$!
for _ in $(seq 1 50); do [[ -f "$CONDUCTOR_DIR/conductor-loop.lock/pid" ]] && break; sleep 0.1; done
run_loop
assert_eq "a second loop refuses" "$RC" "4"
kill -TERM "$LOOP_PID"; wait "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""
mkdir -p "$CONDUCTOR_DIR/conductor-loop.lock"; echo 999999 > "$CONDUCTOR_DIR/conductor-loop.lock/pid"
run_loop
assert_eq "a lock left by a dead process is taken over" "$RC" "0"

# 14 ------------------------------------------------------------------------------
section "14 · The loop polls and picks up an event that arrives later"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" &
LOOP_PID=$!
sleep 1.5
signal 0001 signal complete
# Wait for the event to be recorded, not only for the handler to finish: the loop marks it a
# moment after the dispatch returns, and killing it in between would lose the mark.
for _ in $(seq 1 100); do [[ -z "$(unprocessed)" ]] && grep -q '^end ' "$STUB_LOG" && break; sleep 0.1; done
assert_eq "dispatched while running" "$(dispatches)" "1"
kill -TERM "$LOOP_PID"; wait "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""
assert_eq "recorded" "$(unprocessed)" ""

# 15 ------------------------------------------------------------------------------
section "15 · Shutdown: the handler asks, the loop exits and closes its own window"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$TMP/tmux.log" > "$TMP/bin/tmux"; chmod +x "$TMP/bin/tmux"
: > "$TMP/tmux.log"
echo 'conductor-shutdown.sh' > "$STUB_HOOK"
signal 0001 signal complete
RC=0
PATH="$TMP/bin:$PATH" CONDUCTOR_ADAPTER_FILE="$STUB" timeout 20 bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
assert_eq "the loop exited on its own" "$RC" "0"
assert_eq "the event was recorded first" "$(unprocessed)" ""
assert_eq "a requested shutdown is not a halt: no notice for the human" "$(notices human-inbox)" "0"
assert_eq "nor for the architect" "$(notices architect-inbox)" "0"
expect_grep 'kill-window -t swarm:architect' "$TMP/tmux.log" "architect window closed"
if grep -q 'swarm:conductor' "$TMP/tmux.log"; then fail "the handler closed the loop's own window"; else ok "the loop's window was left to the loop"; fi
: > "$TMP/tmux.log"
(unset CONDUCTOR_LOOP; PATH="$TMP/bin:$PATH" bash "$SCRIPTS_DIR/conductor-shutdown.sh" > /dev/null)
expect_grep 'kill-window -t swarm:conductor' "$TMP/tmux.log" "outside the loop it closes the conductor window as before"

# 16 ------------------------------------------------------------------------------
section "16 · An adapter without adapter_dispatch is refused"
new_swarm
echo '# no dispatch here' > "$TMP/empty-adapter.sh"
RC=0
CONDUCTOR_ADAPTER_FILE="$TMP/empty-adapter.sh" bash "$LOOP" --once > /dev/null 2> "$TMP/loop.err" || RC=$?
assert_eq "exit 3" "$RC" "3"

# 17 ------------------------------------------------------------------------------
section "17 · Attempts at one event are spaced out"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue 1 1
START=$SECONDS
CONDUCTOR_MAX_ATTEMPTS=2 CONDUCTOR_RETRY_DELAY=2 run_loop
ELAPSED=$(( SECONDS - START ))
assert_eq "two attempts" "$(dispatches)" "2"
if [[ "$ELAPSED" -ge 2 && "$ELAPSED" -le 6 ]]; then ok "waited between them (${ELAPSED}s)"; else fail "elapsed ${ELAPSED}s, expected 2 to 6"; fi

# 18 ------------------------------------------------------------------------------
section "18 · A missing timeout command is reported up front"
new_swarm
create_task
RC=0
CONDUCTOR_TIMEOUT_CMD=no-such-timeout CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > /dev/null 2> "$TMP/loop.err" || RC=$?
assert_eq "exit 3" "$RC" "3"
expect_grep "needs GNU timeout" "$TMP/loop.err" "says what to install"
assert_eq "nothing was dispatched" "$(dispatches)" "0"

# 19 ------------------------------------------------------------------------------
section "19 · A halt tells the human and the architect"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue 1 1
STUB_ERRMSG="stub: the model call failed" CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "one notice for the human" "$(notices human-inbox)" "1"
assert_eq "one for the architect" "$(notices architect-inbox)" "1"
expect_grep '^type: halt$' "$(notice architect-inbox)" "the architect's notice is typed halt"
expect_grep '^kind: failed$' "$(notice human-inbox)" "the kind of halt"
expect_grep '^artifact: 0001/signal-' "$(notice human-inbox)" "the artifact"
expect_grep '^handler: conductor/on-signal-complete$' "$(notice human-inbox)" "the handler"
expect_grep 'Last error: stub: the model call failed' "$(notice human-inbox)" "the last error the adapter reported"
expect_grep '^last-error: stub: the model call failed' "$CONDUCTOR_DIR/conductor-loop.halted" "the halt file has it too"
expect_grep 'CONDUCTOR LOOP HALTED' "$TMP/loop.out" "a banner in the conductor window"

# 20 ------------------------------------------------------------------------------
section "20 · Every kind of halt notifies"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal weird
run_loop
assert_eq "unresolvable: halt kind" "$(halt_kind)" "unresolvable"
assert_eq "unresolvable: both notified" "$(( $(notices human-inbox) + $(notices architect-inbox) ))" "2"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue 2
run_loop
assert_eq "unusable: halt kind" "$(halt_kind)" "unusable"
assert_eq "unusable: both notified" "$(( $(notices human-inbox) + $(notices architect-inbox) ))" "2"

# 21 ------------------------------------------------------------------------------
section "21 · Starting again clears the notices"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
signal 0001 signal complete
queue 1 1
CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "halted, with notices" "$(( $(notices human-inbox) + $(notices architect-inbox) ))" "2"
queue
run_loop
assert_eq "the restart succeeds" "$RC" "0"
assert_eq "the human's notice is gone" "$(notices human-inbox)" "0"
assert_eq "so is the architect's" "$(notices architect-inbox)" "0"
assert_eq "and the halt file" "$([[ -f "$CONDUCTOR_DIR/conductor-loop.halted" ]] && echo yes || echo no)" "no"

# 22 ------------------------------------------------------------------------------
section "22 · A clean run leaves no notice"
assert_eq "none for the human" "$(notices human-inbox)" "0"
assert_eq "none for the architect" "$(notices architect-inbox)" "0"

# 23 ------------------------------------------------------------------------------
section "23 · A notice that cannot be written does not change the halt"
new_swarm
create_task; run_loop; : > "$STUB_LOG"
touch "$CONDUCTOR_DIR/human-inbox"             # a file where the directory should be
signal 0001 signal complete
queue 1 1
CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "the halt is still exit 1" "$RC" "1"
assert_eq "the halt file is still written" "$(halt_kind)" "failed"
assert_eq "the architect's notice is still written" "$(notices architect-inbox)" "1"

# 24 ------------------------------------------------------------------------------
section "24 · The loop reconciles first, on every start"
new_swarm
create_task
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the reconcile was dispatched once" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "1"
expect_grep '^reconcile # Skill: Reconcile ' "$STUB_LOG" "it is the reconcile skill"
expect_grep 'task_id=\[\] artifact=\[\]' "$STUB_LOG" "with no task and no artifact"
: > "$STUB_LOG"
sleep 1; signal 0001 signal complete
run_loop
assert_eq "a second start reconciles again" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "1"
assert_eq "before it handles the new event" "$(grep -E '^(reconcile|start) ' "$STUB_LOG" | cut -d' ' -f1 | tr '\n' ' ')" "reconcile start "

# 25 ------------------------------------------------------------------------------
section "25 · A fresh swarm has nothing to reconcile"
new_swarm
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "no model call" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "0"
expect_grep 'nothing to reconcile' "$TMP/loop.err" "and it says so"

# 26 ------------------------------------------------------------------------------
section "26 · A failing reconcile is retried, then halts before any event"
new_swarm
create_task
signal 0001 signal complete
sleep 1
STUB_RECONCILE_RC=1 STUB_ERRMSG="stub: reconcile failed" CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "two attempts" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "2"
assert_eq "no event was handled" "$(dispatches)" "0"
assert_eq "halt kind" "$(halt_kind)" "failed"
expect_grep '^artifact: startup$' "$CONDUCTOR_DIR/conductor-loop.halted" "the halt names the startup"
expect_grep '^handler: conductor/reconcile$' "$CONDUCTOR_DIR/conductor-loop.halted" "and the reconcile"
expect_grep 'Last error: stub: reconcile failed' "$(notice human-inbox)" "the notice has the last error"

# 27 ------------------------------------------------------------------------------
section "27 · A missing reconcile skill halts"
new_swarm
create_task
rm -f "$CONDUCTOR_DIR/skills/conductor/reconcile.md"
run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "halt kind" "$(halt_kind)" "unresolvable"
expect_grep 'no skill file' "$CONDUCTOR_DIR/conductor-loop.halted" "names the missing file"

# 28 ------------------------------------------------------------------------------
section "28 · Every dispatch is logged with its record"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"claude-code","model":"m1","input_tokens":8,"output_tokens":701,"cache_read_tokens":20055,"cache_write_tokens":7429,"cost_usd":0.1019,"turns":4}' run_loop
assert_eq "one line for the event" "$(ulines 0001/signal | wc -l | tr -d ' ')" "1"
assert_eq "the task" "$(ufield 0001/signal .task)" "0001"
assert_eq "the handler" "$(ufield 0001/signal .handler)" "conductor/on-signal-complete"
assert_eq "attempt" "$(ufield 0001/signal .attempt)" "1"
assert_eq "outcome" "$(ufield 0001/signal .outcome)" "finished"
assert_eq "rc" "$(ufield 0001/signal .rc)" "0"
assert_eq "harness from the record" "$(ufield 0001/signal .harness)" "claude-code"
assert_eq "model" "$(ufield 0001/signal .model)" "m1"
assert_eq "input tokens" "$(ufield 0001/signal .input_tokens)" "8"
assert_eq "output tokens" "$(ufield 0001/signal .output_tokens)" "701"
assert_eq "cache read tokens" "$(ufield 0001/signal .cache_read_tokens)" "20055"
assert_eq "cache write tokens" "$(ufield 0001/signal .cache_write_tokens)" "7429"
assert_eq "cost" "$(ufield 0001/signal .cost_usd)" "0.1019"
assert_eq "turns" "$(ufield 0001/signal .turns)" "4"
assert_eq "usage was reported" "$(ufield 0001/signal .usage)" "reported"
assert_eq "the role is the conductor" "$(ufield 0001/signal .role)" "conductor"
assert_eq "a cost the harness reported is cost_source reported" "$(ufield 0001/signal .cost_source)" "reported"
assert_eq "a UTC timestamp" "$(ufield 0001/signal .ts | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' || true)" "1"
assert_eq "a duration in seconds" "$(ufield 0001/signal '.duration_s | type')" "number"

# 29 ------------------------------------------------------------------------------
section "29 · A harness that reports no cost is logged with a null cost, not zero"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"codex","model":null,"input_tokens":2965,"output_tokens":5,"cache_read_tokens":12288,"cache_write_tokens":0,"cost_usd":null,"turns":2}' run_loop
assert_eq "cost is null" "$(ufield 0001/signal .cost_usd)" "null"
assert_eq "the tokens are there" "$(ufield 0001/signal .input_tokens)" "2965"
assert_eq "and the record counts as reported" "$(ufield 0001/signal .usage)" "reported"
assert_eq "but its cost is unknown, not reported" "$(ufield 0001/signal .cost_source)" "unknown"

# 29b -----------------------------------------------------------------------------
section "29b · A known model gets an estimate next to a reported cost"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":701,"cache_read_tokens":20055,"cache_write_tokens":7429,"cost_usd":0.1019,"turns":4}' run_loop
assert_eq "the harness's own cost is kept" "$(ufield 0001/signal .cost_usd)" "0.1019"
assert_eq "the estimate is there too" "$(ufield 0001/signal .estimated_cost_usd)" "0.07402375"
assert_eq "cost_source stays reported" "$(ufield 0001/signal .cost_source)" "reported"

# 29c -----------------------------------------------------------------------------
section "29c · With no reported cost the estimate is the cost, and an unknown model has none"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"codex","model":"gpt-5","input_tokens":2965,"output_tokens":5,"cache_read_tokens":12288,"cache_write_tokens":0,"cost_usd":null,"turns":2}' run_loop
assert_eq "no reported cost" "$(ufield 0001/signal .cost_usd)" "null"
assert_eq "estimated from the table" "$(ufield 0001/signal .estimated_cost_usd)" "0.00529225"
assert_eq "cost_source is estimated" "$(ufield 0001/signal .cost_source)" "estimated"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"codex","model":"not-a-model","input_tokens":2965,"output_tokens":5,"cache_read_tokens":12288,"cache_write_tokens":0,"cost_usd":null,"turns":2}' run_loop
assert_eq "an unknown model: no estimate, not zero" "$(ufield 0001/signal .estimated_cost_usd)" "null"
assert_eq "cost_source is unknown" "$(ufield 0001/signal .cost_source)" "unknown"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
run_loop
assert_eq "an attempt with no record has no estimate" "$(ufield 0001/signal .estimated_cost_usd)" "null"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
CONDUCTOR_PRICES="$TMP/missing.json" STUB_USAGE='{"harness":"codex","model":"gpt-5","input_tokens":1,"output_tokens":1,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":null,"turns":1}' run_loop
assert_eq "a missing price table still writes the line" "$(ulines 0001/signal | wc -l | tr -d ' ')" "1"
assert_eq "with no estimate" "$(ufield 0001/signal .estimated_cost_usd)" "null"

# 29d -----------------------------------------------------------------------------
section "29d · A line says what it was billed to: the pool, and the billing it implies"
# The sign-in files are the test's own, so nothing reads the real ones.
export CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json" CODEX_AUTH_FILE="$TMP/no-codex-login.json"
unset ANTHROPIC_API_KEY
RECORD='{"harness":"claude-code","model":"m1","input_tokens":8,"output_tokens":701,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.1,"turns":4}'
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE="$RECORD" run_loop
assert_eq "no sign-in found and the workforce declares nothing: pool unknown" "$(ufield 0001/signal .pool)" "unknown"
assert_eq "and billing unknown" "$(ufield 0001/signal .billing)" "unknown"
new_swarm
jq '(.members[] | select(.role == "conductor")) += {pool: "api:anthropic"}' "$CONDUCTOR_DIR/workforce.json" > "$TMP/wf.json" \
  && mv "$TMP/wf.json" "$CONDUCTOR_DIR/workforce.json"
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE="$RECORD" run_loop
assert_eq "the conductor member's declared pool stands when nothing is detected" "$(ufield 0001/signal .pool)" "api:anthropic"
assert_eq "and its billing" "$(ufield 0001/signal .billing)" "api"
new_swarm
jq '(.members[] | select(.role == "conductor")) += {pool: "api:anthropic"}' "$CONDUCTOR_DIR/workforce.json" > "$TMP/wf.json" \
  && mv "$TMP/wf.json" "$CONDUCTOR_DIR/workforce.json"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"oauth-test-token"}}' > "$CLAUDE_CREDENTIALS_FILE"
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE="$RECORD" run_loop
assert_eq "a login overrides what the workforce declares" "$(ufield 0001/signal .pool)" "subscription:anthropic"
rm -f "$CLAUDE_CREDENTIALS_FILE"

# 30 ------------------------------------------------------------------------------
section "30 · An attempt with no record is logged as usage none"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
run_loop
assert_eq "usage none" "$(ufield 0001/signal .usage)" "none"
assert_eq "the harness is the adapter that ran" "$(ufield 0001/signal .harness)" "stub-adapter"
assert_eq "tokens are null, not zero" "$(ufield 0001/signal .input_tokens)" "null"
assert_eq "cost_source is unknown" "$(ufield 0001/signal .cost_source)" "unknown"
assert_eq "the role is still the conductor" "$(ufield 0001/signal .role)" "conductor"
assert_eq "cost is null" "$(ufield 0001/signal .cost_usd)" "null"

# 31 ------------------------------------------------------------------------------
section "31 · Every attempt of a retried event is logged"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue 1 0
STUB_USAGE='{"harness":"claude-code","cost_usd":0.05}' CONDUCTOR_MAX_ATTEMPTS=3 run_loop
assert_eq "two lines" "$(ulines 0001/signal | wc -l | tr -d ' ')" "2"
assert_eq "the first failed" "$(ulines 0001/signal | head -1 | jq -r '.outcome + " " + (.attempt|tostring) + " " + (.rc|tostring)')" "failed 1 1"
assert_eq "the second finished" "$(ulines 0001/signal | tail -1 | jq -r '.outcome + " " + (.attempt|tostring) + " " + (.rc|tostring)')" "finished 2 0"
assert_eq "the failed attempt kept its cost" "$(ulines 0001/signal | head -1 | jq -r .cost_usd)" "0.05"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue 1 1
CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "a halt after two attempts leaves two lines" "$(ulines 0001/signal | wc -l | tr -d ' ')" "2"

# 32 ------------------------------------------------------------------------------
section "32 · The outcome says why an attempt ended"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue 2
run_loop
assert_eq "exit 2 is unusable" "$(ufield 0001/signal .outcome)" "unusable"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue sleep
CONDUCTOR_MAX_ATTEMPTS=1 CONDUCTOR_DISPATCH_DEADLINE=1 CONDUCTOR_KILL_GRACE=1 run_loop
assert_eq "a timeout is a timeout" "$(ufield 0001/signal .outcome)" "timeout"
assert_eq "with the exit status of timeout" "$(ufield 0001/signal .rc)" "124"
assert_eq "and no record" "$(ufield 0001/signal .usage)" "none"

# 33 ------------------------------------------------------------------------------
section "33 · The startup reconcile is logged like any event"
new_swarm
create_task
STUB_USAGE='{"harness":"claude-code","cost_usd":0.19}' run_loop
assert_eq "event" "$(ufield startup .event)" "startup"
assert_eq "no task" "$(ufield startup .task)" "null"
assert_eq "handler" "$(ufield startup .handler)" "conductor/reconcile"
assert_eq "cost" "$(ufield startup .cost_usd)" "0.19"

# 34 ------------------------------------------------------------------------------
section "34 · A loop that is killed leaves a line for the attempt in flight"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue sleep
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" &
LOOP_PID=$!
for _ in $(seq 1 50); do grep -q '^start ' "$STUB_LOG" && break; sleep 0.1; done
kill -TERM "$LOOP_PID"; wait "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""
assert_eq "one line" "$(ulines 0001/signal | wc -l | tr -d ' ')" "1"
assert_eq "interrupted" "$(ufield 0001/signal .outcome)" "interrupted"
assert_eq "attempt 1" "$(ufield 0001/signal .attempt)" "1"
assert_eq "and no record" "$(ufield 0001/signal .usage)" "none"
assert_eq "its cost_source is unknown" "$(ufield 0001/signal .cost_source)" "unknown"
assert_eq "its tokens and cost are null, not zero" "$(ufield 0001/signal '[.input_tokens, .output_tokens, .cost_usd] | map(. == null) | all')" "true"

# 35 ------------------------------------------------------------------------------
section "35 · A log that cannot be written changes nothing"
new_swarm
create_task; run_loop
rm -f "$CONDUCTOR_DIR/usage.jsonl"; mkdir -p "$CONDUCTOR_DIR/usage.jsonl"   # a directory where the file should be
sleep 1; signal 0001 signal complete
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the event was handled and recorded" "$(unprocessed)" ""

# 36 ------------------------------------------------------------------------------
section "36 · The loop needs jq"
new_swarm
mkdir -p "$TMP/nojq"; for t in bash env cat sed awk grep tr cut head tail sort uniq mkdir cp rm mv ls find wc date git python3 touch printf basename dirname readlink tee mktemp chmod sleep kill timeout; do p="$(command -v "$t" 2> /dev/null || true)"; [[ -n "$p" ]] && ln -sf "$p" "$TMP/nojq/$t"; done
RC=0
PATH="$TMP/nojq" CONDUCTOR_ADAPTER_FILE="$STUB" "$BASH" "$LOOP" --once > /dev/null 2> "$TMP/loop.err" || RC=$?
assert_eq "exit 3" "$RC" "3"
expect_grep 'needs jq' "$TMP/loop.err" "and says so"

# 37 ------------------------------------------------------------------------------
section "37 · The log has what the window shows, with timestamps"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
run_loop
TS='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}  '
assert_eq "every line of the log is timestamped" "$(grep -vcE "$TS" "$CONDUCTOR_DIR/conductor.log" || true)" "0"
assert_eq "so is every line of the window" "$(grep -vcE "$TS" "$TMP/loop.err" || true)" "0"
assert_eq "the log has what the last run printed" "$(grep -cFxf "$TMP/loop.err" "$CONDUCTOR_DIR/conductor.log" | tr -d ' ')" "$(wc -l < "$TMP/loop.err" | tr -d ' ')"
expect_grep 'started (pid' "$CONDUCTOR_DIR/conductor.log" "it starts with the start"
expect_grep 'stopped' "$CONDUCTOR_DIR/conductor.log" "and ends with the stop"

# 38 ------------------------------------------------------------------------------
section "38 · A finished attempt says how long, what it cost, and what the model said"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_ANSWER="Moved 0001 to merging." STUB_USAGE='{"harness":"claude-code","cost_usd":0.1072}' run_loop
LINE="$(grep ' finished in ' "$CONDUCTOR_DIR/conductor.log" | grep '0001/signal' | tail -1)"
case "$LINE" in *"0001/signal-"*" finished in "*"s, \$0.107 — Moved 0001 to merging."*) ok "event, duration, cost and the model's line: $LINE" ;; *) fail "line: $LINE" ;; esac
assert_eq "the handler is on the line before it" "$(grep -c '0001/signal.* -> conductor/on-signal-complete (attempt 1 of' "$CONDUCTOR_DIR/conductor.log")" "1"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"codex","cost_usd":null,"input_tokens":5}' run_loop
LINE="$(grep ' finished in ' "$CONDUCTOR_DIR/conductor.log" | grep '0001/signal' | tail -1)"
case "$LINE" in *", no cost reported"*) ok "a harness with no cost says so, it is not free" ;; *) fail "line: $LINE" ;; esac
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
run_loop
LINE="$(grep ' finished in ' "$CONDUCTOR_DIR/conductor.log" | grep '0001/signal' | tail -1)"
case "$LINE" in *", no usage record") ok "no record at all says that, with no model line to show" ;; *) fail "line: $LINE" ;; esac

# 39 ------------------------------------------------------------------------------
section "39 · A failed attempt says why"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue 1 0
STUB_ERRMSG="stub: the model call failed" CONDUCTOR_MAX_ATTEMPTS=2 run_loop
LINE="$(grep ' failed with exit ' "$CONDUCTOR_DIR/conductor.log" | head -1)"
case "$LINE" in *"0001/signal-"*" failed with exit 1 after "*"s, no usage record: stub: the model call failed") ok "exit status, duration, usage and the adapter's own message: $LINE" ;; *) fail "line: $LINE" ;; esac
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue 1 1
STUB_ERRMSG="stub: still failing" CONDUCTOR_MAX_ATTEMPTS=2 run_loop
expect_grep 'HALT (failed) at 0001/signal-.*(last error: stub: still failing)' "$CONDUCTOR_DIR/conductor.log" "the halt line carries the last error"

# 40 ------------------------------------------------------------------------------
section "40 · Events with no handler are shown as skipped"
new_swarm
create_task; run_loop
sleep 1; signal 0001 progress
run_loop
expect_grep '0001/progress-.*: no handler for progress, skipped' "$CONDUCTOR_DIR/conductor.log" "a progress artifact"
assert_eq "and nothing was dispatched for it" "$(dispatches)" "0"

# 41 ------------------------------------------------------------------------------
section "41 · An idle loop says it is alive"
new_swarm
create_task; run_loop
CONDUCTOR_HEARTBEAT=1 CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" &
LOOP_PID=$!
sleep 3.5
kill -TERM "$LOOP_PID"; wait "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""
expect_grep 'idle: nothing to do (0 events handled since start)' "$CONDUCTOR_DIR/conductor.log" "an idle line with the count"
new_swarm
create_task; run_loop
CONDUCTOR_HEARTBEAT=0 CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" > "$TMP/loop.out" 2> "$TMP/loop.err" &
LOOP_PID=$!
sleep 3.5
kill -TERM "$LOOP_PID"; wait "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""
assert_eq "CONDUCTOR_HEARTBEAT=0 turns it off" "$(grep -c 'idle:' "$CONDUCTOR_DIR/conductor.log" || true)" "0"

# 42 ------------------------------------------------------------------------------
section "42 · A log that cannot be written changes nothing"
new_swarm
create_task; run_loop
rm -f "$CONDUCTOR_DIR/conductor.log"; mkdir -p "$CONDUCTOR_DIR/conductor.log"   # a directory where the file should be
sleep 1; signal 0001 signal complete
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the event was handled and recorded" "$(unprocessed)" ""
expect_grep ' finished in ' "$TMP/loop.err" "and the window still shows it"

# 43 ------------------------------------------------------------------------------
section "43 · Text a model wrote cannot drive the terminal"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
ESC=$'\033'; BEL=$'\007'
STUB_ANSWER="Moved it ${ESC}[2J${ESC}]0;owned${BEL} done" run_loop
assert_eq "no escape byte in the window" "$(grep -c "$ESC" "$TMP/loop.err" || true)" "0"
assert_eq "none in the log" "$(grep -c "$ESC" "$CONDUCTOR_DIR/conductor.log" || true)" "0"
assert_eq "no bell either" "$(grep -c "$BEL" "$CONDUCTOR_DIR/conductor.log" || true)" "0"
expect_grep 'Moved it' "$CONDUCTOR_DIR/conductor.log" "the readable text is still there"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
queue 1 1
STUB_ERRMSG="stub: ${ESC}[2Jfailed${BEL}" CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "a halt: none in the window" "$(cat "$TMP/loop.out" "$TMP/loop.err" | grep -c "$ESC" || true)" "0"
assert_eq "none in the log" "$(grep -c "$ESC" "$CONDUCTOR_DIR/conductor.log" || true)" "0"
assert_eq "none in the human's notice" "$(grep -c "$ESC" "$(notice human-inbox)" || true)" "0"
assert_eq "none in the architect's" "$(grep -c "$ESC" "$(notice architect-inbox)" || true)" "0"
expect_grep 'failed' "$(notice human-inbox)" "the readable text is still in the notice"

# 44 ------------------------------------------------------------------------------
section "44 · A script handler runs instead of the model"
# CONDUCTOR_HANDLERS_DIR stands in for scripts/handlers: a script named for the resolved skill
# (on-signal-complete.sh for conductor/on-signal-complete) is the handler. No script: the model.
H="$TMP/handlers"
fresh_event() { # a swarm with one task and an unprocessed signal-complete event
  new_swarm
  rm -rf "$H"; mkdir -p "$H"; export CONDUCTOR_HANDLERS_DIR="$H"
  create_task; run_loop; : > "$STUB_LOG"
  sleep 1; signal 0001 signal complete
}
SH_LOG="$TMP/handler.log"
fresh_event
cat > "$H/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo "ran task=$TASK_ID task_file_exists=$([[ -f "$TASK_FILE" ]] && echo yes || echo no) artifact=$(basename "$ARTIFACT") dir=$CONDUCTOR_DIR loop=${CONDUCTOR_LOOP:-}" >> "$SH_LOG"
SH_EOF
chmod +x "$H/on-signal-complete.sh"; : > "$SH_LOG"; export SH_LOG
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the script ran once" "$(grep -c '^ran ' "$SH_LOG" || true)" "1"
expect_grep "^ran task=0001 task_file_exists=yes artifact=signal-.* dir=$CONDUCTOR_DIR loop=1" "$SH_LOG" "with TASK_ID, TASK_FILE, ARTIFACT, CONDUCTOR_DIR and CONDUCTOR_LOOP"
assert_eq "the model was not dispatched" "$(dispatches)" "0"
assert_eq "recorded as processed" "$(unprocessed)" ""
assert_eq "no usage line: no model was called" "$(ulines 0001/signal | wc -l | tr -d ' ')" "0"
expect_grep 'script' "$TMP/loop.err" "the window says it was a script"

section "44a · With no override, the handlers are the ones next to the loop"
# The default is handlers/ beside conductor-loop.sh. The loop runs from a scratch copy of scripts/
# whose handlers/ holds one stub, so this checks where it looks and not which real handlers exist.
RC_ROOT="$TMP/loop-root"; rm -rf "$RC_ROOT"; mkdir -p "$RC_ROOT"
cp -r "$SCRIPTS_DIR" "$RC_ROOT/scripts"
for d in adapters integrations skills prompts topologies workforces; do
  [[ -e "$ROOT_DIR/$d" ]] && ln -s "$ROOT_DIR/$d" "$RC_ROOT/$d"
done
rm -rf "$RC_ROOT/scripts/handlers"; mkdir -p "$RC_ROOT/scripts/handlers"
cat > "$RC_ROOT/scripts/handlers/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo "ran task=$TASK_ID" >> "$SH_LOG"
SH_EOF
chmod +x "$RC_ROOT/scripts/handlers/on-signal-complete.sh"
fresh_event; unset CONDUCTOR_HANDLERS_DIR; : > "$SH_LOG"; export SH_LOG
LOOP="$RC_ROOT/scripts/conductor-loop.sh" run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the handler beside the loop ran" "$(grep -c '^ran task=0001' "$SH_LOG" || true)" "1"
assert_eq "the model was not dispatched" "$(dispatches)" "0"
if [[ -x "$SCRIPTS_DIR/handlers/on-review-approved.sh" && -x "$SCRIPTS_DIR/handlers/on-validation-passed.sh" \
   && -x "$SCRIPTS_DIR/handlers/on-validation-failed.sh" && -x "$SCRIPTS_DIR/handlers/on-review-rejected.sh" \
   && -x "$SCRIPTS_DIR/handlers/on-new-task.sh" \
   && -x "$SCRIPTS_DIR/handlers/on-signal-complete.sh" \
   && -x "$SCRIPTS_DIR/handlers/on-merge-success.sh" \
   && -x "$SCRIPTS_DIR/handlers/reconcile.sh" ]]; then
  ok "and the shipped handlers are executable"
else
  fail "and the shipped handlers are executable"
fi

section "44b · A script that fails is retried, then succeeds"
fresh_event
cat > "$H/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
n=$(cat "$SH_LOG" 2>/dev/null | wc -l | tr -d ' ')
echo "try" >> "$SH_LOG"
[[ "$n" -ge 1 ]]
SH_EOF
chmod +x "$H/on-signal-complete.sh"; : > "$SH_LOG"
CONDUCTOR_MAX_ATTEMPTS=3 run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "two attempts" "$(wc -l < "$SH_LOG" | tr -d ' ')" "2"
assert_eq "recorded" "$(unprocessed)" ""
assert_eq "the model was not dispatched" "$(dispatches)" "0"

section "44c · A script that keeps failing halts and keeps the event"
fresh_event
cat > "$H/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo try >> "$SH_LOG"
echo "no lock check" >&2
exit 1
SH_EOF
chmod +x "$H/on-signal-complete.sh"; : > "$SH_LOG"
CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "two attempts, no more" "$(wc -l < "$SH_LOG" | tr -d ' ')" "2"
assert_eq "halt kind" "$(halt_kind)" "failed"
expect_grep 'no lock check' "$CONDUCTOR_DIR/conductor-loop.halted" "the script's last error is in the halt"
assert_eq "the event is still unprocessed" "$(unprocessed | wc -l | tr -d ' ')" "1"
assert_eq "the model was not asked to take over" "$(dispatches)" "0"

section "44c2 · A script that fails with nothing to say: the log, the halt and the notices say so, and name the restart command"
# The cause in the first real swarm run: a script died with exit 1 and wrote nothing, and the halt said only "last exit 1".
fresh_event
cat > "$H/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo try >> "$SH_LOG"
exit 1
SH_EOF
chmod +x "$H/on-signal-complete.sh"; : > "$SH_LOG"
CONDUCTOR_MAX_ATTEMPTS=2 CONDUCTOR_POLL_INTERVAL=7 run_loop
assert_eq "exit 1" "$RC" "1"
expect_grep 'exited 1 and wrote nothing' "$TMP/loop.err" "the log line for the failed attempt says it wrote nothing"
expect_grep 'exited 1 and wrote nothing' "$CONDUCTOR_DIR/conductor-loop.halted" "so does the halt"
expect_grep '^restart: cd .* && env CONDUCTOR_DIR=.*conductor-loop.sh$' "$CONDUCTOR_DIR/conductor-loop.halted" "the halt records the command that restarts the loop"
expect_grep 'CONDUCTOR_POLL_INTERVAL=7' "$CONDUCTOR_DIR/conductor-loop.halted" "with the settings the loop was started with"
if grep -q 'CONDUCTOR_LOOP=' "$CONDUCTOR_DIR/conductor-loop.halted"; then fail "and not the variable the loop sets itself"; else ok "and not the variable the loop sets itself"; fi
expect_grep 'Restart it with: cd ' "$(find "$CONDUCTOR_DIR/human-inbox" -name 'loop-halt-*.md' | head -1)" "the human's notice has the command to paste"
expect_grep 'Restart:   cd ' "$TMP/loop.out" "and so does the banner in the conductor window"
CMD="$(awk '/^restart: /{sub(/^restart: /, ""); print; exit}' "$CONDUCTOR_DIR/conductor-loop.halted")"
rm -f "$CONDUCTOR_DIR/conductor-loop.halted"; : > "$SH_LOG"
cat > "$H/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo fixed >> "$SH_LOG"
SH_EOF
RC=0; ( eval "$CMD --once" ) > "$TMP/restart.out" 2> "$TMP/restart.err" || RC=$?
assert_eq "the command, pasted as it is, restarts the loop and the waiting event goes through" "$RC $(wc -l < "$SH_LOG" | tr -d ' ')" "0 1"

section "44d · A script that exits 2 halts without a retry"
fresh_event
cat > "$H/on-signal-complete.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo try >> "$SH_LOG"
exit 2
SH_EOF
chmod +x "$H/on-signal-complete.sh"; : > "$SH_LOG"
CONDUCTOR_MAX_ATTEMPTS=3 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "one attempt" "$(wc -l < "$SH_LOG" | tr -d ' ')" "1"
assert_eq "halt kind" "$(halt_kind)" "unusable"

section "44e · A hung script is killed at the deadline"
fresh_event
printf '#!/usr/bin/env bash\nsleep %s\n' "$STUB_SLEEP_ARG" > "$H/on-signal-complete.sh"
chmod +x "$H/on-signal-complete.sh"
START=$SECONDS
CONDUCTOR_MAX_ATTEMPTS=1 CONDUCTOR_DISPATCH_DEADLINE=1 CONDUCTOR_KILL_GRACE=1 run_loop
ELAPSED=$(( SECONDS - START ))
assert_eq "exit 1" "$RC" "1"
if [[ "$ELAPSED" -le 8 ]]; then ok "stopped after ${ELAPSED}s, not 30s"; else fail "took ${ELAPSED}s"; fi
assert_eq "halt kind" "$(halt_kind)" "failed"
sleep 0.5
assert_eq "the script's child process is gone too" "$(children_left)" "0"

section "44f · With no script the model is dispatched as before"
fresh_event
rm -f "$H"/*.sh
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "one dispatch" "$(dispatches)" "1"
expect_grep '^start 0001 signal-.* | # Skill: On Signal Complete' "$STUB_LOG" "the skill went to the model"
assert_eq "and has its usage line" "$(ulines 0001/signal | wc -l | tr -d ' ')" "1"

section "44g · A script that is there but not executable halts, not the model"
fresh_event
cat > "$H/on-signal-complete.sh" << 'SH_EOF'    # deliberately no chmod +x
#!/usr/bin/env bash
echo ran >> "$SH_LOG"
SH_EOF
: > "$SH_LOG"
run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "halt kind" "$(halt_kind)" "unresolvable"
expect_grep 'not executable' "$CONDUCTOR_DIR/conductor-loop.halted" "the halt says why"
assert_eq "the model was not asked instead" "$(dispatches)" "0"
assert_eq "the script did not run" "$(wc -l < "$SH_LOG" | tr -d ' ')" "0"
assert_eq "the event is still unprocessed" "$(unprocessed | wc -l | tr -d ' ')" "1"

section "44h · The startup reconcile is a script when handlers/reconcile.sh exists"
new_swarm
rm -rf "$H"; mkdir -p "$H"; export CONDUCTOR_HANDLERS_DIR="$H"
create_task
cat > "$H/reconcile.sh" << 'SH_EOF'
#!/usr/bin/env bash
echo "reconciled task=[${TASK_ID:-}] file=[${TASK_FILE:-}] artifact=[${ARTIFACT:-}] dir=$CONDUCTOR_DIR loop=${CONDUCTOR_LOOP:-}" >> "$SH_LOG"
SH_EOF
chmod +x "$H/reconcile.sh"; : > "$SH_LOG"; : > "$STUB_LOG"
TASK_ID=leak TASK_FILE=leak ARTIFACT=leak run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the script ran once" "$(grep -c '^reconciled ' "$SH_LOG" || true)" "1"
expect_grep "^reconciled task=\[\] file=\[\] artifact=\[\] dir=$CONDUCTOR_DIR loop=1" "$SH_LOG" "with no task and no artifact, and the conductor dir"
assert_eq "the model was not dispatched for it" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "0"
expect_grep 'conductor/reconcile (script)' "$TMP/loop.err" "the window says it was a script"
assert_eq "no usage line: no model was called" "$([[ -s "$CONDUCTOR_DIR/usage.jsonl" ]] && echo some || echo none)" "none"

section "44i · A failing reconcile script is retried, then halts before any event"
new_swarm; export CONDUCTOR_HANDLERS_DIR="$H"
create_task; signal 0001 signal complete; sleep 1
# shellcheck disable=SC2016  # the script's own $SH_LOG
printf '#!/usr/bin/env bash\necho try >> "$SH_LOG"\necho "board unreadable" >&2\nexit 1\n' > "$H/reconcile.sh"
chmod +x "$H/reconcile.sh"; : > "$SH_LOG"
CONDUCTOR_MAX_ATTEMPTS=2 run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "two attempts" "$(wc -l < "$SH_LOG" | tr -d ' ')" "2"
assert_eq "halt kind" "$(halt_kind)" "failed"
expect_grep '^artifact: startup$' "$CONDUCTOR_DIR/conductor-loop.halted" "the halt names the startup"
expect_grep 'board unreadable' "$CONDUCTOR_DIR/conductor-loop.halted" "with the script's last error"
assert_eq "no event was handled and the model was not asked" "$(dispatches)" "0"

section "44j · With no reconcile script the model is dispatched as before"
new_swarm; export CONDUCTOR_HANDLERS_DIR="$H"
create_task
rm -f "$H"/*.sh
run_loop
assert_eq "exit 0" "$RC" "0"
assert_eq "the reconcile skill went to the model" "$(grep -c '^reconcile # Skill: Reconcile' "$STUB_LOG" || true)" "1"

section "44k · A reconcile script that is not executable halts, not the model"
new_swarm; export CONDUCTOR_HANDLERS_DIR="$H"
create_task
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho ran >> "$SH_LOG"\n' > "$H/reconcile.sh"   # deliberately no chmod +x
: > "$SH_LOG"
run_loop
assert_eq "exit 1" "$RC" "1"
assert_eq "halt kind" "$(halt_kind)" "unresolvable"
expect_grep 'not executable' "$CONDUCTOR_DIR/conductor-loop.halted" "the halt says why"
assert_eq "the model was not asked instead" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "0"
assert_eq "the script did not run" "$(wc -l < "$SH_LOG" | tr -d ' ')" "0"
unset CONDUCTOR_HANDLERS_DIR

# 45 ------------------------------------------------------------------------------
section "45 · A Codex dispatch records what it used of the subscription allowance"
# The adapter is named codex, so the loop notes the allowance before and after each dispatch. The stub
# plays Codex writing a newer event, with the five-hour window 2 points further on, while it runs.
mkdir -p "$TMP/codex-adapter"; cp "$STUB" "$TMP/codex-adapter/codex.sh"
export CODEX_SESSIONS_DIR="$TMP/codex-sessions" CODEX_USAGE_NOW=1793790000
printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}\n' > "$TMP/auth-chatgpt.json"
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$TMP/auth-apikey.json"
export CODEX_AUTH_FILE="$TMP/auth-chatgpt.json"
codex_event() { # <used 5h> <file number>: Codex writes a session whose newest event has this reading
  mkdir -p "$CODEX_SESSIONS_DIR/2026/11/04"
  local f="$CODEX_SESSIONS_DIR/2026/11/04/rollout-$2.jsonl"
  jq -nc '{timestamp: "2026-11-04T05:00:00.000Z", type: "session_meta", payload: {cwd: "/x", cli_version: "0.166.0"}}' > "$f"
  jq -nc --argjson p "$1" --arg ts "2026-11-04T05:0$2:00.000Z" '
    { timestamp: $ts, type: "event_msg", payload: { type: "token_count", info: {},
      rate_limits: { plan_type: "plus", primary: { used_percent: $p, window_minutes: 300, resets_at: 1793800000 },
                     secondary: { used_percent: 20.0, window_minutes: 10080, resets_at: 1794059735 } } } }' >> "$f"
  touch -d "@$(( 1793700000 + $2 ))" "$f"
}
rm -rf "$CODEX_SESSIONS_DIR"; codex_event 10 1
new_swarm
create_task
CONDUCTOR_ADAPTER_FILE="$TMP/codex-adapter/codex.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
sleep 1; signal 0001 signal complete
printf '%s\n' 'codex_event_hook=1' > /dev/null
write_hook() { # what Codex writes while the dispatch runs: the allowance 2 points on, and the model that answered
  cat > "$STUB_HOOK" <<'HOOK_EOF'
n=$(( $(find "$CODEX_SESSIONS_DIR" -type f | wc -l) + 1 ))
mkdir -p "$CODEX_SESSIONS_DIR/2026/11/04"
f="$CODEX_SESSIONS_DIR/2026/11/04/rollout-$n.jsonl"
jq -nc --arg cwd "$(pwd -P)" '{timestamp: "2026-11-04T05:00:00.000Z", type: "session_meta", payload: {cwd: $cwd, cli_version: "0.166.0"}}' > "$f"
jq -nc --arg cwd "$(pwd -P)" '{timestamp: "2026-11-04T05:08:00.000Z", type: "turn_context", payload: {model: "gpt-6.1-sol", cwd: $cwd}}' >> "$f"
printf '%s\n' '{"timestamp":"2026-11-04T05:09:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":105}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1793800000},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1794059735}}}}' >> "$f"
touch -d "@$(( $(date +%s) + 5 ))" "$f"
HOOK_EOF
}
write_hook
STUB_USAGE='{"harness":"codex","model":"gpt-5","input_tokens":100,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":null,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/codex-adapter/codex.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
assert_eq "the dispatch's line carries its allowance: five-hour points" "$(ufield 0001/signal '.allowance.five_hour.points | tostring')" "2"
assert_eq "attributed to the run" "$(ufield 0001/signal .allowance.attributed_to)" "run"
assert_eq "the weekly window did not move" "$(ufield 0001/signal '.allowance.weekly.points | tostring')" "0"
assert_eq "readings were taken around it, as records and not as attempts" \
  "$(jq -r 'select(.record == "allowance") | .moment | sub("[0-9]+-[0-9]+$"; "N")' "$CONDUCTOR_DIR/usage.jsonl" | grep -c 'run-begin:dispatch-N\|run-end:dispatch-N')" "$(jq -r 'select(.record == "allowance") | .moment' "$CONDUCTOR_DIR/usage.jsonl" | wc -l | tr -d ' ')"
assert_eq "no run is left noted" "$(find "$CONDUCTOR_DIR/allowance" -type f 2> /dev/null | wc -l | tr -d ' ')" "0"
assert_eq "the model asked for, and the model that answered" "$(ufield 0001/signal '[.requested_model, .answered_model] | join(" ")')" "gpt-5 gpt-6.1-sol"
assert_eq "a run on another model than asked for is a record of its own" \
  "$(jq -r 'select(.record == "model_mismatch") | [.role, .task, .harness, .requested, .answered] | join(" ")' "$CONDUCTOR_DIR/usage.jsonl")" "conductor 0001 codex gpt-5 gpt-6.1-sol"
new_swarm; write_hook
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"codex","model":"gpt-6.1-sol","input_tokens":100,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":null,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/codex-adapter/codex.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
assert_eq "the model asked for answered" "$(ufield 0001/signal '[.requested_model, .answered_model] | join(" ")')" "gpt-6.1-sol gpt-6.1-sol"
assert_eq "so there is no mismatch" "$(jq -r 'select(.record == "model_mismatch") | 1' "$CONDUCTOR_DIR/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"
new_swarm; write_hook
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"codex","model":null,"input_tokens":100,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":null,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/codex-adapter/codex.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
assert_eq "no model asked for: the answer is still recorded" "$(ufield 0001/signal '[(.requested_model | tostring), .answered_model] | join(" ")')" "null gpt-6.1-sol"
assert_eq "and a default is not a mismatch" "$(jq -r 'select(.record == "model_mismatch") | 1' "$CONDUCTOR_DIR/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.01,"turns":1}' run_loop
assert_eq "a dispatch on another adapter has no allowance" "$(ufield 0001/signal '.allowance | tostring')" "null"
assert_eq "and takes no reading" "$(jq -r 'select(.record == "allowance") | 1' "$CONDUCTOR_DIR/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"
rm -f "$STUB_HOOK"

# 46 ------------------------------------------------------------------------------
section "46 · A Codex conductor on an API key starts, and measures no allowance"
new_swarm
create_task
RC=0; CODEX_AUTH_FILE="$TMP/auth-apikey.json" CONDUCTOR_ADAPTER_FILE="$TMP/codex-adapter/codex.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
assert_eq "it starts" "$RC" "0"
assert_eq "the reconcile went to the model" "$(grep -c '^reconcile ' "$STUB_LOG" || true)" "1"
assert_eq "nothing says it is not starting" "$(grep -c 'not starting' "$CONDUCTOR_DIR/conductor.log" || true)" "0"
assert_eq "the key is not in the log" "$(grep -c 'sk-test-not-real' "$CONDUCTOR_DIR/conductor.log" || true)" "0"
assert_eq "no lock is left behind" "$([[ -e "$CONDUCTOR_DIR/conductor-loop.lock" ]] && echo left || echo none)" "none"
assert_eq "its line is api:openai" "$(ufield startup .pool)" "api:openai"
assert_eq "it has no allowance, and takes no reading" "$(ufield startup '.allowance | tostring')|$(jq -r 'select(.record == "allowance") | 1' "$CONDUCTOR_DIR/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "null|0"
RC=0; CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
assert_eq "another adapter is not asked about Codex" "$RC" "0"
unset CODEX_SESSIONS_DIR CODEX_USAGE_NOW CODEX_AUTH_FILE

# 47 ------------------------------------------------------------------------------
section "47 · A Claude Code dispatch records what it used of the Claude subscription allowance"
# The adapter is named claude-code, so the loop notes the allowance before and after each dispatch,
# from the usage endpoint (a stub curl here). The stub plays the account using more while it runs.
mkdir -p "$TMP/claude-adapter" "$TMP/curl-bin"; cp "$STUB" "$TMP/claude-adapter/claude-code.sh"
cat > "$TMP/curl-bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
[[ -z "$out" ]] || cp "$STUB_CLAUDE_BODY" "$out"
printf '200'
CURL_EOF
chmod +x "$TMP/curl-bin/curl"
export STUB_CLAUDE_BODY="$TMP/claude-body.json" CLAUDE_USAGE_NOW=1793865600
export CLAUDE_CREDENTIALS_FILE="$ROOT_DIR/tests/claude-usage/credentials.json"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
cp "$ROOT_DIR/tests/claude-usage/endpoint.json" "$STUB_CLAUDE_BODY"   # 10 % of five hours, 20 % of the week, $0 of credits
new_swarm
create_task
PATH="$TMP/curl-bin:$PATH" STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.01,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/claude-adapter/claude-code.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
sleep 1; signal 0001 signal complete
cat > "$STUB_HOOK" <<HOOK_EOF
cp "$ROOT_DIR/tests/claude-usage/endpoint-extra.json" "\$STUB_CLAUDE_BODY"
HOOK_EOF
cp "$ROOT_DIR/tests/claude-usage/endpoint.json" "$STUB_CLAUDE_BODY"
PATH="$TMP/curl-bin:$PATH" STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.01,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/claude-adapter/claude-code.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
assert_eq "the dispatch's line carries its allowance, in the Anthropic pool" "$(ufield 0001/signal .allowance.pool)" "subscription:anthropic"
assert_eq "five-hour points" "$(ufield 0001/signal '.allowance.five_hour.points | tostring')" "27.5"
assert_eq "weekly points" "$(ufield 0001/signal '.allowance.weekly.points | tostring')" "41"
assert_eq "points for a model" "$(ufield 0001/signal '.allowance.weekly_by_model.models[] | select(.model == "Fable") | .points | tostring')" "12"
assert_eq "credits, in dollars" "$(ufield 0001/signal '.allowance.credits.dollars | tostring')" "4.25"
assert_eq "attributed to the run" "$(ufield 0001/signal .allowance.attributed_to)" "run"
assert_eq "readings were taken around it, as records" "$(jq -r 'select(.record == "allowance") | .pool' "$CONDUCTOR_DIR/usage.jsonl" | sort -u | tr '\n' ' ')" "subscription:anthropic "
assert_eq "no run is left noted" "$(find "$CONDUCTOR_DIR/allowance" -type f 2> /dev/null | wc -l | tr -d ' ')" "0"
assert_eq "the model is the adapter's, not looked up as for Codex" "$(ufield 0001/signal '[.requested_model, .answered_model] | map(tostring) | join(" ")')" "null null"
RC=0; PATH="$TMP/curl-bin:$PATH" CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json" CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || RC=$?
assert_eq "an adapter that is neither is not asked about any allowance" "$RC" "0"
rm -f "$STUB_HOOK"
unset STUB_CLAUDE_BODY CLAUDE_USAGE_NOW
export CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json"

# 48 ------------------------------------------------------------------------------
section "48 · A budget that is reached is said once in the conductor log, and nothing stops"
new_swarm
printf '[{"pool":"api:anthropic","usd":1.00,"warn_at":80}]\n' > "$CONDUCTOR_DIR/budgets.json"
create_task; run_loop
sleep 1; signal 0001 signal complete
ANTHROPIC_API_KEY=sk-test-not-real STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.45,"turns":1}' run_loop
assert_eq "the signal was dispatched" "$(dispatches)" "1"
assert_eq "90 percent of the budget after the second dispatch (each run also does the startup reconcile): one warning, naming the pool" "$(grep -c "budget api:anthropic: [\$]0.90 of [\$]1.00" "$CONDUCTOR_DIR/conductor.log")" "1"
assert_eq "one record of it in the usage log" "$(jq -r 'select(.record == "budget_warning") | .state' "$CONDUCTOR_DIR/usage.jsonl")" "warn"
sleep 1; signal 0001 signal complete
ANTHROPIC_API_KEY=sk-test-not-real STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.001,"turns":1}' run_loop
assert_eq "the same state on the next dispatch: not said again" "$(grep -c 'budget api:anthropic' "$CONDUCTOR_DIR/conductor.log")" "1"
sleep 1; signal 0001 signal complete
ANTHROPIC_API_KEY=sk-test-not-real STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.05,"turns":1}' run_loop
assert_eq "going over is said, and the loop carried on" "$(grep -c 'over budget api:anthropic' "$CONDUCTOR_DIR/conductor.log")" "1"
assert_eq "exit 0: report only, nothing refused" "$RC" "0"
new_swarm
create_task; run_loop
sleep 1; signal 0001 signal complete
ANTHROPIC_API_KEY=sk-test-not-real STUB_USAGE='{"harness":"claude-code","model":"claude-opus-4-8","input_tokens":8,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.45,"turns":1}' run_loop
assert_eq "no budgets file: no warning" "$(grep -c 'budget' "$CONDUCTOR_DIR/conductor.log" || true)" "0"

# 49 ------------------------------------------------------------------------------
section "49 · A pi dispatch on a ChatGPT plan records what it used of the same allowance as Codex"
# The adapter is named pi, so what draws on the allowance is the pool the workforce gives the conductor, not the adapter.
mkdir -p "$TMP/pi-adapter"; cp "$STUB" "$TMP/pi-adapter/pi.sh"
export CODEX_SESSIONS_DIR="$TMP/codex-sessions" CODEX_USAGE_NOW=1793790000
rm -rf "$CODEX_SESSIONS_DIR"; codex_event 10 1
new_swarm
jq '(.members[] | select(.role == "conductor")) |= (.adapter = "pi" | .pool = "subscription:openai")' "$CONDUCTOR_DIR/workforce.json" > "$CONDUCTOR_DIR/wf.new" && mv "$CONDUCTOR_DIR/wf.new" "$CONDUCTOR_DIR/workforce.json"
create_task
CONDUCTOR_ADAPTER_FILE="$TMP/pi-adapter/pi.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
sleep 1; signal 0001 signal complete
write_hook
STUB_USAGE='{"harness":"pi","model":"openai/gpt-5.5","input_tokens":100,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":null,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/pi-adapter/pi.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
assert_eq "the line is pi's, in the OpenAI pool" "$(ufield 0001/signal '[.harness, .pool] | join(" ")')" "pi subscription:openai"
assert_eq "it carries the allowance: five-hour points, attributed to the run" "$(ufield 0001/signal '.allowance | [.pool, (.five_hour.points | tostring), .attributed_to] | join(" ")')" "subscription:openai 2 run"
assert_eq "readings were taken around each dispatch, in the OpenAI pool, as records" \
  "$(jq -r 'select(.record == "allowance") | select(.pool == "subscription:openai") | .moment | sub("[0-9]+-[0-9]+$"; "N")' "$CONDUCTOR_DIR/usage.jsonl" | grep -c 'run-begin:dispatch-N\|run-end:dispatch-N')" "$(jq -r 'select(.record == "allowance") | .moment' "$CONDUCTOR_DIR/usage.jsonl" | wc -l | tr -d ' ')"
rm -f "$STUB_HOOK"
new_swarm
jq '(.members[] | select(.role == "conductor")) |= (.adapter = "pi" | .pool = "api:openai")' "$CONDUCTOR_DIR/workforce.json" > "$CONDUCTOR_DIR/wf.new" && mv "$CONDUCTOR_DIR/wf.new" "$CONDUCTOR_DIR/workforce.json"
create_task
CONDUCTOR_ADAPTER_FILE="$TMP/pi-adapter/pi.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
sleep 1; signal 0001 signal complete
STUB_USAGE='{"harness":"pi","model":"openai/gpt-5.5","input_tokens":100,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0.01,"turns":1}' \
  CONDUCTOR_ADAPTER_FILE="$TMP/pi-adapter/pi.sh" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
assert_eq "pi on an API key: no allowance on the line" "$(ufield 0001/signal '.allowance | tostring')" "null"
assert_eq "and no reading taken" "$(jq -r 'select(.record == "allowance") | 1' "$CONDUCTOR_DIR/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"

# 50 ------------------------------------------------------------------------------
section "50 · A dependent left in backlog is reported and healed after the event"
# A copy of the scripts with a stage-start.sh that only logs: the real one would spawn a worker.
CP="$TMP/scripts-copy"; rm -rf "$CP"; cp -r "$SCRIPTS_DIR" "$CP"
cat > "$CP/stage-start.sh" << 'S'
#!/usr/bin/env bash
echo "stage-start $*" >> "$STUB_LOG"
S
LOOP="$CP/conductor-loop.sh"
new_swarm
export CONDUCTOR_BACKLOG_CHECK=on
"$SCRIPTS_DIR/task-create.sh" --title A --type chore --description x > /dev/null
"$SCRIPTS_DIR/task-create.sh" --title B --type chore --depends-on 0001 --description x > /dev/null
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
# 0001 finishes without anyone unblocking 0002: the stub handler does nothing for the event.
"$SCRIPTS_DIR/task-move.sh" 0001 "done"
: > "$STUB_LOG"
sleep 1; signal 0001 signal complete
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
expect_grep 'invariant: 0002 was in backlog but its dependencies are done (0001)' "$CONDUCTOR_DIR/conductor.log" "the log names the task and its done dependency"
expect_grep 'invariant: 0002 ' "$TMP/loop.err" "and the window shows it"
assert_eq "the card was healed into ready" "$([[ -f "$CONDUCTOR_DIR/kanban/ready/0002.md" ]] && echo yes)" "yes"
assert_eq "and its stage started" "$(grep -c '^stage-start 0002 ready$' "$STUB_LOG" || true)" "1"
assert_eq "the loop did not halt" "$([[ -f "$CONDUCTOR_DIR/conductor-loop.halted" ]] && echo halted || echo running)" "running"
# A task whose own event is still unhandled is just new, not stranded.
new_swarm
export CONDUCTOR_BACKLOG_CHECK=on
"$SCRIPTS_DIR/task-create.sh" --title A --type chore --description x > /dev/null
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
"$SCRIPTS_DIR/task-move.sh" 0001 "done"
sleep 1; signal 0001 signal complete
"$SCRIPTS_DIR/task-create.sh" --title B --type chore --description x > /dev/null
CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
# (The stub handlers do not register or unblock anything, so 0002 is stranded once its own card
# event has been handled; what matters is that it is not reported before.)
card_line="$(grep -n '0002/card-' "$CONDUCTOR_DIR/conductor.log" | tail -1 | cut -d: -f1 || true)"
inv_line="$(grep -n 'invariant: 0002 ' "$CONDUCTOR_DIR/conductor.log" | head -1 | cut -d: -f1 || true)"
assert_eq "a card is not reported while its own event is unhandled" "$(( inv_line > card_line ? 1 : 0 ))" "1"

# 51 ------------------------------------------------------------------------------
section "51 · A worker window that waits for a person is said once in the conductor log"
new_swarm
create_task
mkdir -p "$CONDUCTOR_DIR/work/0001" "$TMP/wwbin"
echo x > "$CONDUCTOR_DIR/work/0001/assigned.md"
cat > "$TMP/wwbin/tmux" << 'WW'
#!/usr/bin/env bash
case "$1" in
  list-windows) echo coder-0001 ;;
  capture-pane) printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n' ;;
esac
WW
chmod +x "$TMP/wwbin/tmux"
for _ in 1 2; do
  PATH="$TMP/wwbin:$PATH" CONDUCTOR_WATCH_INTERVAL=0 CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > "$TMP/loop.out" 2> "$TMP/loop.err" || true
done
expect_grep 'window coder-0001 (task 0001) is waiting for you: Do you want to proceed?' "$CONDUCTOR_DIR/conductor.log" "the log names the window, the task and the question"
assert_eq "said once over two passes" "$(grep -c 'window coder-0001' "$CONDUCTOR_DIR/conductor.log" || true)" "1"
rm -f "$CONDUCTOR_DIR/window-watch.seen"
PATH="$TMP/wwbin:$PATH" CONDUCTOR_WINDOW_WATCH=off CONDUCTOR_WATCH_INTERVAL=0 CONDUCTOR_ADAPTER_FILE="$STUB" bash "$LOOP" --once > /dev/null 2>&1 || true
assert_eq "CONDUCTOR_WINDOW_WATCH=off says nothing more" "$(grep -c 'window coder-0001' "$CONDUCTOR_DIR/conductor.log" || true)" "1"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
