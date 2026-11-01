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
  unset CONDUCTOR_MAX_ATTEMPTS CONDUCTOR_DISPATCH_DEADLINE CONDUCTOR_KILL_GRACE CONDUCTOR_TIMEOUT_CMD STUB_RECONCILE_RC STUB_ERRMSG
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

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
