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
LOOP_PID=""
# shellcheck disable=SC2329  # invoked via trap, not a direct call
cleanup() {
  [[ -n "$LOOP_PID" ]] && kill "$LOOP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

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
  {
    echo "start $TASK_ID $(basename "$art") | $(printf '%s' "$skill" | head -1)"
    echo "env CONDUCTOR_DIR=$CONDUCTOR_DIR LOOP=${CONDUCTOR_LOOP:-} DEADLINE=${DISPATCH_DEADLINE:-} USAGE=${DISPATCH_USAGE_FILE:-}"
    echo "env task_file_exists=$([[ -f "$TASK_FILE" ]] && echo yes || echo no) artifact_exists=$([[ -f "$ARTIFACT" ]] && echo yes || echo no) task-list=$(command -v task-list.sh)"
  } >> "$STUB_LOG"
  if [[ -s "$STUB_RC" ]]; then
    rc="$(head -1 "$STUB_RC")"
    tail -n +2 "$STUB_RC" > "$STUB_RC.next"; mv "$STUB_RC.next" "$STUB_RC"
  fi
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
  unset CONDUCTOR_MAX_ATTEMPTS CONDUCTOR_DISPATCH_DEADLINE CONDUCTOR_KILL_GRACE CONDUCTOR_TIMEOUT_CMD
  export CONDUCTOR_RETRY_DELAY=0
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
for _ in $(seq 1 60); do grep -q '^end ' "$STUB_LOG" && break; sleep 0.1; done
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

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
