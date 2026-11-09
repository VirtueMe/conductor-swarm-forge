#!/usr/bin/env bash
# Tests the steps a script handler shares (scripts/handler-steps.sh): closing the finishing
# worker's window, the locks guard, and routing a task to its next stage. The guard fails
# closed: when it cannot tell whether the files are locked, it says so and the handler stops,
# where a model handler once read a failing task-locks.sh as "locks free". tmux and the scripts
# that act (task-locks.sh, task-move.sh, stage-start.sh) are stubs on PATH that log their calls;
# topology-load.sh is the real one. No tmux server, no AI.
#
# Usage: scripts/test-handler-steps.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

# --- a scratch conductor dir with one card ------------------------------------
export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work}
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done \
  < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp "$topo" "$CONDUCTOR_DIR/topology.json"
card() { # <stage> [files-changed item...]: the card for task 0001
  rm -f "$CONDUCTOR_DIR"/kanban/*/0001.md
  { printf -- '---\nid: 0001\nstatus: %s\n' "$1"; shift
    if [[ $# -gt 0 ]]; then printf 'files-changed:\n'; printf '  - %s\n' "$@"; fi
    printf -- '---\n\nbody\n'; } > "$CONDUCTOR_DIR/kanban/$STAGE_DIR/0001.md"
}
STAGE_DIR=review

# --- stubs on PATH --------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
export STUB_LOG="$TMP/calls.log" STUB_LOCKED="$TMP/locked" STUB_LOCKS_RC="$TMP/locks.rc" STUB_SIGNAL_RC="$TMP/signal.rc"
cat > "$STUB/task-locks.sh" << 'S'
#!/usr/bin/env bash
echo "task-locks" >> "$STUB_LOG"
[[ -f "$STUB_LOCKS_RC" ]] && exit "$(cat "$STUB_LOCKS_RC")"
cat "$STUB_LOCKED" 2>/dev/null || true
S
cat > "$STUB/task-move.sh" << 'S'
#!/usr/bin/env bash
echo "task-move $*" >> "$STUB_LOG"
S
cat > "$STUB/stage-start.sh" << 'S'
#!/usr/bin/env bash
echo "stage-start $*" >> "$STUB_LOG"
S
cat > "$STUB/task-signal.sh" << 'S'
#!/usr/bin/env bash
echo "task-signal $*" >> "$STUB_LOG"
[[ -f "$STUB_SIGNAL_RC" ]] && exit "$(cat "$STUB_SIGNAL_RC")"
exit 0
S
cat > "$STUB/tmux" << 'S'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
if [[ "$1" == "list-windows" ]]; then printf 'conductor\ncoder-0001\nreviewer-0002\n'; fi
S
chmod +x "$STUB"/*
export PATH="$STUB:$SCRIPTS_DIR:$PATH"
reset() { : > "$STUB_LOG"; : > "$STUB_LOCKED"; rm -f "$STUB_LOCKS_RC" "$STUB_SIGNAL_RC"; }

# shellcheck source=scripts/handler-steps.sh
source "$SCRIPTS_DIR/handler-steps.sh"

section "1 · The locks guard"
reset; card review src/a.txt src/b.txt
printf 'src/z.txt\n' > "$STUB_LOCKED"
assert_eq "no overlap is free" "$(locks_guard 0001)" "free"
printf 'src/z.txt\nsrc/b.txt\n' > "$STUB_LOCKED"
assert_eq "one shared file is held" "$(locks_guard 0001)" "held"
: > "$STUB_LOCKED"
assert_eq "nothing locked is free" "$(locks_guard 0001)" "free"
card review
printf 'src/z.txt\n' > "$STUB_LOCKED"
assert_eq "a card with no files-changed has nothing to clash with" "$(locks_guard 0001)" "free"
card review src/a.txt
printf 'src/a.txt.bak\nsrc/\n' > "$STUB_LOCKED"
assert_eq "a file name must match whole, not as a prefix" "$(locks_guard 0001)" "free"

section "2 · The guard fails closed"
reset; card review src/a.txt
echo 1 > "$STUB_LOCKS_RC"
RC=0; OUT="$(locks_guard 0001 2> "$TMP/err")" || RC=$?
assert_eq "a failing task-locks.sh is a failure" "$RC" "1"
assert_eq "and prints no answer" "$OUT" ""
if grep -q 'task-locks.sh failed' "$TMP/err"; then ok "and says why"; else fail "and says why ($(cat "$TMP/err"))"; fi
reset; rm -f "$CONDUCTOR_DIR"/kanban/*/0001.md
RC=0; OUT="$(locks_guard 0001 2> "$TMP/err")" || RC=$?
assert_eq "no card for the task is a failure" "$RC" "1"
assert_eq "and prints no answer" "$OUT" ""
assert_eq "and does not guess from the locks" "$(grep -c task-locks "$STUB_LOG" || true)" "0"

section "2b · Reading a field of the card"
reset; card review src/a.txt
sed -i 's/^id: 0001$/id: 0001\ntype: chore/' "$CONDUCTOR_DIR"/kanban/review/0001.md
assert_eq "the card's type" "$(card_field 0001 type)" "chore"
RC=0; OUT="$(card_field 0001 priority 2> "$TMP/err")" || RC=$?
assert_eq "a field the card lacks is a failure" "$RC" "1"
assert_eq "and prints no answer" "$OUT" ""
if grep -q 'has no priority' "$TMP/err"; then ok "and says which field"; else fail "and says which field ($(cat "$TMP/err"))"; fi
rm -f "$CONDUCTOR_DIR"/kanban/*/0001.md
RC=0; OUT="$(card_field 0001 type 2> "$TMP/err")" || RC=$?
assert_eq "no card for the task is a failure" "$RC" "1"
assert_eq "and prints no answer" "$OUT" ""

section "2c · The dependency guard"
task_file() { # <depends-on line...>: the task file for 0001 (no argument: depends-on: [])
  { printf -- '---\nid: 0001\ntitle: t\ntype: feature\n'
    if [[ $# -eq 0 ]]; then printf 'depends-on: []\n'; else printf '%s\n' "$@"; fi
    printf -- '---\n\nbody\n'; } > "$CONDUCTOR_DIR/tasks/0001.md"
}
mkdir -p "$CONDUCTOR_DIR/kanban/done" "$CONDUCTOR_DIR/kanban/backlog"
: > "$CONDUCTOR_DIR/kanban/done/0007.md"; : > "$CONDUCTOR_DIR/kanban/backlog/0008.md"
task_file
assert_eq "no dependencies is all-done" "$(deps_done 0001)" "all-done"
task_file 'depends-on:' '  - 0007'
assert_eq "a dependency that is done" "$(deps_done 0001)" "all-done"
task_file 'depends-on:' '  - 0007' '  - 0008'
assert_eq "one dependency not done is pending" "$(deps_done 0001)" "pending"
task_file 'depends-on:' '  - 0009'
assert_eq "a dependency with no card at all is pending" "$(deps_done 0001)" "pending"
task_file 'title: x'
assert_eq "no depends-on field is no dependencies" "$(deps_done 0001)" "all-done"
task_file 'depends-on: [0007]'
RC=0; OUT="$(deps_done 0001 2> "$TMP/err")" || RC=$?
assert_eq "an inline list is a failure, not all-done" "$RC" "1"
assert_eq "and prints no answer" "$OUT" ""
if grep -q 'inline' "$TMP/err"; then ok "and says why"; else fail "and says why ($(cat "$TMP/err"))"; fi
rm -f "$CONDUCTOR_DIR/tasks/0001.md"
RC=0; OUT="$(deps_done 0001 2> "$TMP/err")" || RC=$?
assert_eq "no task file is a failure" "$RC" "1"
assert_eq "and prints no answer" "$OUT" ""
if grep -q 'no task file' "$TMP/err"; then ok "and says why"; else fail "and says why ($(cat "$TMP/err"))"; fi

section "2d · Reading the project config"
cfg() { printf '%s\n' "$@" > "$CONDUCTOR_DIR/config.md"; }
cfg 'lang: bash' 'test-cmd: npm test' 'poll-interval: 3'
assert_eq "a value is read whole, spaces and all" "$(config_field test-cmd)" "npm test"
cfg 'test-cmd: make test A=1'
assert_eq "an equals sign inside the value stays" "$(config_field test-cmd)" "make test A=1"
cfg '---' 'lang: bash' 'test-cmd: ./run-tests' '---'
assert_eq "a config with frontmatter fences reads the same" "$(config_field test-cmd)" "./run-tests"
cfg 'lang: bash' 'test-cmd:' 'poll-interval: 3'
assert_eq "an empty value is empty: not configured" "$(config_field test-cmd)" ""
cfg 'lang: bash' 'test-cmd:    '
assert_eq "so is a value of only spaces" "$(config_field test-cmd)" ""
cfg 'lang: bash'
assert_eq "a key the config lacks is empty" "$(config_field test-cmd)" ""
cfg 'test-cmd-extra: x'
assert_eq "a longer key does not stand in for the shorter" "$(config_field test-cmd)" ""
rm -f "$CONDUCTOR_DIR/config.md"
RC=0; OUT="$(config_field test-cmd)" || RC=$?
assert_eq "no config file is not a failure" "$RC" "0"
assert_eq "and is empty" "$OUT" ""
RC=0; config_field 'a.b' 2> "$TMP/err" > /dev/null || RC=$?
assert_eq "a name that is not a plain key is a failure" "$RC" "1"

section "3 · Closing the finishing worker's window"
reset
close_worker_window 0001
expect="tmux kill-window -t swarm:coder-0001"
assert_eq "the window named for the task is closed" "$(grep -c "^$expect\$" "$STUB_LOG" || true)" "1"
assert_eq "another task's window is left alone" "$(grep -c 'reviewer-0002' "$STUB_LOG" | tr -d ' ' || true)" "0"
reset
RC=0; close_worker_window 0009 || RC=$?
assert_eq "no window is not an error" "$RC" "0"
assert_eq "and nothing is killed" "$(grep -c 'kill-window' "$STUB_LOG" || true)" "0"

section "3b · The progress note"
reset
progress_note 0001 "validation failed" work/0001/validation-20261102-102000.md
assert_eq "one progress signal for the task, pointing at the artifact" "$(cat "$STUB_LOG")" \
  "task-signal --task 0001 --type progress --notes conductor: validation failed — see work/0001/validation-20261102-102000.md"
reset; echo 1 > "$STUB_SIGNAL_RC"
RC=0; progress_note 0001 "review rejected" work/0001/review-x.md || RC=$?
assert_eq "a failing task-signal.sh is a failure, so the handler stops" "$RC" "1"
reset
RC=0; progress_note 0001 "" work/0001/x.md 2> "$TMP/err" || RC=$?
assert_eq "an empty label is a failure" "$RC" "1"
assert_eq "and writes no note" "$(grep -c task-signal "$STUB_LOG" || true)" "0"

section "4 · Route, move, start"
reset; card review src/a.txt
route_task 0001 review-approved locks=free
assert_eq "the destination" "$ROUTED_DEST" "merging"
assert_eq "the task is moved there" "$(sed -n 1p "$STUB_LOG")" "task-move 0001 merging"
assert_eq "and the stage is started" "$(sed -n 2p "$STUB_LOG")" "stage-start 0001 merging"
reset
route_task 0001 review-approved locks=held
assert_eq "held locks park the task" "$ROUTED_DEST" "merge-pending"
reset
RC=0; route_task 0001 no-such-event 2> "$TMP/err" || RC=$?
assert_eq "an event with no route is a failure" "$RC" "1"
assert_eq "and moves nothing" "$(grep -c 'task-move' "$STUB_LOG" || true)" "0"
reset; cat > "$STUB/task-move.sh" << 'S'
#!/usr/bin/env bash
echo "task-move $*" >> "$STUB_LOG"
exit 1
S
RC=0; route_task 0001 review-approved locks=free 2> "$TMP/err" || RC=$?
assert_eq "a failed move is a failure" "$RC" "1"
assert_eq "and the stage is not started" "$(grep -c 'stage-start' "$STUB_LOG" || true)" "0"

section "5 · An event that has no stage to go to"
reset
cat > "$STUB/task-move.sh" << 'S'
#!/usr/bin/env bash
echo "task-move $*" >> "$STUB_LOG"
S
cat > "$STUB/topology-load.sh" << 'S'
#!/usr/bin/env bash
echo "@stay"
S
chmod +x "$STUB/topology-load.sh"
RC=0; route_task 0001 signal-drift 2> "$TMP/err" || RC=$?
rm -f "$STUB/topology-load.sh"
assert_eq "a destination that is not a stage is a failure" "$RC" "1"
assert_eq "and moves nothing" "$(grep -c 'task-move' "$STUB_LOG" || true)" "0"
if grep -q '@stay' "$TMP/err"; then ok "and names it"; else fail "and names it ($(cat "$TMP/err"))"; fi

# --- a small board for the steps that look across tasks ---------------------------
# task-move.sh now moves the card file, and task-locks.sh reports the files of the cards in
# merging (the real task-locks.sh answers that, on top of STUB_LOCKED), so a step that starts several
# merges sees each lock taken.
cat > "$STUB/task-move.sh" << 'S'
#!/usr/bin/env bash
echo "task-move $*" >> "$STUB_LOG"
for f in "$CONDUCTOR_DIR"/kanban/*/"$1".md; do
  [[ -f "$f" ]] && { mkdir -p "$CONDUCTOR_DIR/kanban/$2"; mv "$f" "$CONDUCTOR_DIR/kanban/$2/$1.md"; exit 0; }
done
# no card yet: like the real one, create it
mkdir -p "$CONDUCTOR_DIR/kanban/$2"; printf -- '---\nid: %s\n---\n' "$1" > "$CONDUCTOR_DIR/kanban/$2/$1.md"
exit 0
S
export REAL_TASK_LOCKS="$SCRIPTS_DIR/task-locks.sh"
cat > "$STUB/task-locks.sh" << 'S'
#!/usr/bin/env bash
set -euo pipefail
echo "task-locks" >> "$STUB_LOG"
[[ -f "$STUB_LOCKS_RC" ]] && exit "$(cat "$STUB_LOCKS_RC")"
{ cat "$STUB_LOCKED" 2> /dev/null || true; "$REAL_TASK_LOCKS"; } | sort -u
S
chmod +x "$STUB/task-move.sh" "$STUB/task-locks.sh"
board_reset() { reset; rm -f "$CONDUCTOR_DIR"/kanban/*/*.md "$CONDUCTOR_DIR"/tasks/*.md; }
bcard() { # <id> <stage> [files-changed item...]
  local id="$1" stage="$2"; shift 2
  mkdir -p "$CONDUCTOR_DIR/kanban/$stage"
  { printf -- '---\nid: %s\nstatus: %s\n' "$id" "$stage"
    if [[ $# -gt 0 ]]; then printf 'files-changed:\n'; printf '  - %s\n' "$@"; fi
    printf -- '---\n\nbody\n'; } > "$CONDUCTOR_DIR/kanban/$stage/$id.md"
}
btask() { # <id> [dependency id...]
  local id="$1"; shift
  { printf -- '---\nid: %s\ntitle: t\ntype: feature\n' "$id"
    if [[ $# -eq 0 ]]; then printf 'depends-on: []\n'; else printf 'depends-on:\n'; printf '  - %s\n' "$@"; fi
    printf -- '---\n\nbody\n'; } > "$CONDUCTOR_DIR/tasks/$id.md"
}
calls() { grep -v '^task-locks$' "$STUB_LOG" || true; }

section "6 · A task's dependencies, listed"
board_reset; btask 0001; btask 0002 0001 0003
assert_eq "no dependencies lists nothing" "$(task_deps 0001)" ""
assert_eq "dependencies are listed one per line" "$(task_deps 0002 | tr '\n' ' ')" "0001 0003 "
sed -i 's/^depends-on:$/depends-on: [0001]/; /^  - /d' "$CONDUCTOR_DIR/tasks/0002.md"
RC=0; OUT="$(task_deps 0002 2> "$TMP/err")" || RC=$?
assert_eq "an inline list is a failure" "$RC" "1"
assert_eq "and lists nothing" "$OUT" ""

section "7 · Unblocking the dependents of a finished task"
board_reset
btask 0001; btask 0002 0001; btask 0003 0001 0004; btask 0004; btask 0005 0009; btask 0006 0001; btask 0007
bcard 0001 "done"; bcard 0002 backlog; bcard 0003 backlog; bcard 0004 in-progress; bcard 0005 backlog; bcard 0006 ready; bcard 0007 backlog
unblock_dependents 0001
assert_eq "a dependent with all its dependencies done is moved to ready and started" "$(calls)" "$(printf 'task-move 0002 ready\nstage-start 0002 ready')"
assert_eq "and its card is in ready" "$([[ -f "$CONDUCTOR_DIR/kanban/ready/0002.md" ]] && echo yes)" "yes"
assert_eq "a dependent still waiting on another stays in backlog" "$([[ -f "$CONDUCTOR_DIR/kanban/backlog/0003.md" ]] && echo yes)" "yes"
board_reset
btask 0001; btask 0002 0001
bcard 0001 "done"; bcard 0002 backlog
sed -i 's/^depends-on:$/depends-on: [0001]/; /^  - /d' "$CONDUCTOR_DIR/tasks/0002.md"
RC=0; unblock_dependents 0001 2> "$TMP/err" || RC=$?
assert_eq "a backlog task with an inline list is a failure, not skipped" "$RC" "1"
if grep -q 'inline' "$TMP/err"; then ok "and says why"; else fail "and says why ($(cat "$TMP/err"))"; fi
assert_eq "and moves nothing" "$(calls)" ""
board_reset
btask 0001; bcard 0001 "done"
RC=0; unblock_dependents 0001 || RC=$?
assert_eq "an empty backlog is nothing to do" "$RC" "0"

section "8 · Releasing the merges that were waiting"
board_reset
bcard 0002 merge-pending src/a.txt src/b.txt; bcard 0003 merge-pending src/b.txt src/c.txt; bcard 0004 merge-pending src/d.txt
release_merge_pending
assert_eq "the first is released, the second overlaps it, the third is clear" \
  "$(calls)" "$(printf 'task-move 0002 merging\nstage-start 0002 merging\ntask-move 0004 merging\nstage-start 0004 merging')"
assert_eq "the one that overlaps stays pending" "$([[ -f "$CONDUCTOR_DIR/kanban/merge-pending/0003.md" ]] && echo yes)" "yes"
board_reset
bcard 0002 merge-pending src/a.txt
printf 'src/a.txt\n' > "$STUB_LOCKED"
release_merge_pending
assert_eq "a task whose file is still locked stays" "$(calls)" ""
board_reset
bcard 0002 merge-pending src/a.txt
echo 1 > "$STUB_LOCKS_RC"
RC=0; release_merge_pending 2> "$TMP/err" || RC=$?
assert_eq "a failing lock check is a failure" "$RC" "1"
assert_eq "and moves nothing" "$(calls)" ""
board_reset
RC=0; release_merge_pending || RC=$?
assert_eq "nothing pending is nothing to do" "$RC" "0"

section "9 · Is the whole project done"
board_reset
btask 0001; btask 0002; bcard 0001 "done"; bcard 0002 "done"
RC=0; project_done || RC=$?
assert_eq "every task has a done card" "$RC" "0"
rm -f "$CONDUCTOR_DIR/kanban/done/0002.md"; bcard 0002 merging
RC=0; project_done || RC=$?
assert_eq "one that is not done" "$RC" "1"
board_reset
bcard 0001 "done"; bcard 0002 "done"; btask 0001
RC=0; project_done || RC=$?
assert_eq "a done card with no task file is ignored" "$RC" "0"
board_reset
btask 0001; btask 0002; bcard 0001 "done"; bcard 0003 "done"
RC=0; project_done || RC=$?
assert_eq "a count that matches is not enough: 0002 has no done card" "$RC" "1"
board_reset
bcard 0001 "done"
RC=0; project_done || RC=$?
assert_eq "no task files is not a finished project" "$RC" "1"

# Working stages for the reconcile steps: in-progress (coder), validation (validator), review
# (reviewer), merging (merger) are auto; a manual stage needs its own topology.
cat > "$STUB/worker-spawn.sh" << 'S'
#!/usr/bin/env bash
echo "worker-spawn $*" >> "$STUB_LOG"
S
cat > "$STUB/task-notify.sh" << 'S'
#!/usr/bin/env bash
echo "task-notify $*" >> "$STUB_LOG"
S
chmod +x "$STUB/worker-spawn.sh" "$STUB/task-notify.sh"

section "10 · Registering the tasks that have no card"
board_reset
btask 0001; btask 0002; btask 0003; bcard 0002 review; bcard 0003 "done"
register_untracked
assert_eq "only the task with no card in any column is moved to backlog" "$(calls)" "task-move 0001 backlog"
assert_eq "and gets its card" "$([[ -f "$CONDUCTOR_DIR/kanban/backlog/0001.md" ]] && echo yes)" "yes"
reset; register_untracked
assert_eq "run again it does nothing" "$(calls)" ""
board_reset
RC=0; register_untracked || RC=$?
assert_eq "no tasks is nothing to do" "$RC" "0"

section "11 · Unblocking every backlog card that is ready"
board_reset
btask 0001; btask 0002 0001; btask 0003 0001 0004; btask 0004; btask 0005; btask 0006 0009
bcard 0001 "done"; bcard 0002 backlog; bcard 0003 backlog; bcard 0004 in-progress; bcard 0005 backlog; bcard 0006 backlog
unblock_ready
assert_eq "cards whose dependencies are all done go to ready, and nothing is started" \
  "$(calls)" "$(printf 'task-move 0002 ready\ntask-move 0005 ready')"
assert_eq "one still waiting stays" "$([[ -f "$CONDUCTOR_DIR/kanban/backlog/0003.md" ]] && echo yes)" "yes"
assert_eq "so does one waiting on an ID with no card" "$([[ -f "$CONDUCTOR_DIR/kanban/backlog/0006.md" ]] && echo yes)" "yes"
reset; unblock_ready
assert_eq "run again it does nothing new" "$(calls)" ""
board_reset
btask 0001; bcard 0001 backlog
sed -i 's/^depends-on: \[\]$/depends-on: [0009]/' "$CONDUCTOR_DIR/tasks/0001.md"
RC=0; unblock_ready 2> "$TMP/err" || RC=$?
assert_eq "an unreadable depends-on is a failure, not skipped" "$RC" "1"
assert_eq "and moves nothing" "$(calls)" ""

section "11b · Finding the cards left in backlog"
board_reset
btask 0001; btask 0002 0001; btask 0003 0001 0004; btask 0004; btask 0005; btask 0006 0009
bcard 0001 "done"; bcard 0002 backlog; bcard 0003 backlog; bcard 0004 in-progress; bcard 0005 backlog; bcard 0006 backlog
assert_eq "a card whose dependencies are done, and one with none, are listed with them" \
  "$(stranded_backlog)" "$(printf '0002 0001\n0005')"
assert_eq "and nothing is moved" "$(calls)" ""
bcard 0004 "done"
assert_eq "all dependencies done, all listed" "$(stranded_backlog | grep '^0003')" "0003 0001 0004"
sed -i 's/^depends-on: \[\]$/depends-on: [0001]/' "$CONDUCTOR_DIR/tasks/0005.md"
RC=0; OUT="$(stranded_backlog 2> "$TMP/err")" || RC=$?
assert_eq "an unreadable depends-on does not stop the check" "$RC" "0"
assert_eq "it is left out" "$(grep -c '^0005' <<< "$OUT" || true)" "0"

section "11c · A design task is never given to a coder"
board_reset
btask 0001; btask 0002 0001
sed -i 's/^type: feature/type: design/' "$CONDUCTOR_DIR/tasks/0002.md"
bcard 0001 "done"; bcard 0002 backlog
unblock_ready
assert_eq "a design card whose dependencies are done goes to done, not ready" "$(calls)" "task-move 0002 done"
board_reset
btask 0001; btask 0002 0001
sed -i 's/^type: feature/type: design/' "$CONDUCTOR_DIR/tasks/0002.md"
bcard 0001 "done"; bcard 0002 backlog
unblock_dependents 0001
assert_eq "a design dependent of a finished task goes to done" "$(calls)" "$(printf 'task-move 0002 done\nstage-start 0002 done')"
RC=0; backlog_dest 0009 2> "$TMP/err" || RC=$?
assert_eq "a task with no task file has no route" "$RC" "1"

section "12 · Resuming interrupted work"
# The tmux stub lists the windows conductor, coder-0001 and reviewer-0002.
board_reset
bcard 0001 in-progress; bcard 0002 review; bcard 0003 in-progress; bcard 0004 validation
bcard 0005 backlog; bcard 0006 ready; bcard 0007 merge-pending; bcard 0008 "done"
resume_interrupted
assert_eq "a working-stage card with no window gets its worker; one with its window, and holding columns, do not" \
  "$(calls | grep -v '^tmux ')" "$(printf 'worker-spawn 0003 coder\nworker-spawn 0004 validator')"
assert_eq "the window must be that role's: reviewer-0002 does not stand in for a coder" \
  "$(board_reset; bcard 0002 in-progress; resume_interrupted; calls | grep -v '^tmux ')" "worker-spawn 0002 coder"
RC=0; board_reset; bcard 0001 in-progress; resume_interrupted || RC=$?
assert_eq "all consistent: exit 0" "$RC" "0"
assert_eq "and nothing is spawned" "$(calls | grep -c '^worker-spawn' || true)" "0"

section "13 · Resuming a manual stage"
cp "$CONDUCTOR_DIR/topology.json" "$TMP/topology.auto"
jq '.working_stages["review"] = {"mode":"manual","await":"human-review","skill":"reviewer/review"}' "$TMP/topology.auto" > "$CONDUCTOR_DIR/topology.json" 2> /dev/null || true
if jq -e '.working_stages.review.mode == "manual"' "$CONDUCTOR_DIR/topology.json" > /dev/null 2>&1; then
  board_reset; rm -rf "$CONDUCTOR_DIR/human-inbox"
  bcard 0001 review; bcard 0002 review
  mkdir -p "$CONDUCTOR_DIR/human-inbox"; touch "$CONDUCTOR_DIR/human-inbox/0002-20261103-100000.md"
  resume_interrupted
  assert_eq "the manual card with no inbox file is notified again; the one with a file is not" \
    "$(calls | grep -v '^tmux ')" "task-notify --task 0001 --stage review"
else
  fail "could not build a manual topology (jq missing?)"
fi
cp "$TMP/topology.auto" "$CONDUCTOR_DIR/topology.json"

section "14 · A failing spawn stops the resume"
board_reset
bcard 0003 in-progress; bcard 0004 validation
# shellcheck disable=SC2016  # the stub's own $* and $STUB_LOG
printf '#!/usr/bin/env bash\necho "worker-spawn $*" >> "$STUB_LOG"\nexit 1\n' > "$STUB/worker-spawn.sh"
RC=0; resume_interrupted || RC=$?
assert_eq "exit 1" "$RC" "1"
assert_eq "at the first failure" "$(calls | grep -c '^worker-spawn' || true)" "1"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "worker-spawn $*" >> "$STUB_LOG"\n' > "$STUB/worker-spawn.sh"

section "15 · Starting the ready cards"
board_reset
bcard 0001 ready; bcard 0002 ready; bcard 0003 backlog; bcard 0004 in-progress
start_ready
assert_eq "each ready card is started" "$(calls)" "$(printf 'stage-start 0001 ready\nstage-start 0002 ready')"
board_reset
RC=0; start_ready || RC=$?
assert_eq "none ready is nothing to do" "$RC" "0"

section "E · A step that fails names the command that failed"
# A script handler that dies silently leaves a person with an exit status. With the steps sourced, the
# command that failed is printed on stderr, so the loop's last error says which step it was.
cat > "$TMP/failing-handler.sh" << 'SH_EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$STEPS"
some_step() { /bin/false; }
mode="${1:-fail}"
case "$mode" in
  fail)    some_step ;;
  nested)  echo "$(some_step)" ;;
  handled) some_step || true; if ! some_step; then :; fi; x="$(some_step)" || true; some_step && true; exit 0 ;;
esac
SH_EOF
chmod +x "$TMP/failing-handler.sh"
RC=0; STEPS="$SCRIPTS_DIR/handler-steps.sh" "$TMP/failing-handler.sh" fail > /dev/null 2> "$TMP/e.err" || RC=$?
assert_eq "a failing command inside a step: the handler fails" "$RC" "1"
assert_eq "and the command that failed is on stderr, with its exit status" "$(grep -c 'failing-handler.sh: "/bin/false" exited 1' "$TMP/e.err")" "1"
RC=0; STEPS="$SCRIPTS_DIR/handler-steps.sh" "$TMP/failing-handler.sh" handled > /dev/null 2> "$TMP/e.err" || RC=$?
assert_eq "failures the handler handles itself (|| true, if, &&) are not reported" "$RC $(wc -c < "$TMP/e.err" | tr -d ' ')" "0 0"

section "F · Validation failures in a row, and the notice when a task is parked (#185)"
# failed_validations counts the failed validation artifacts back from the newest, up to the first pass.
STEPS_LIB="$SCRIPTS_DIR/handler-steps.sh"
vfile() { # <task> <timestamp> <outcome>
  mkdir -p "$CONDUCTOR_DIR/work/$1"
  printf -- '---\ntype: validation\ntask-id: %s\ntimestamp: %s\noutcome: %s\n---\nNO TESTS RAN: found no tests.\n' "$1" "$2" "$3" > "$CONDUCTOR_DIR/work/$1/validation-$2.md"
}
# shellcheck source=scripts/handler-steps.sh
count_for() { ( source "$STEPS_LIB"; failed_validations "$1" ); }
rm -rf "$CONDUCTOR_DIR/work/0009"
assert_eq "no validations: 0" "$(count_for 0009)" "0"
vfile 0009 20261108-100000 failed
assert_eq "one failure: 1" "$(count_for 0009)" "1"
vfile 0009 20261108-110000 failed; vfile 0009 20261108-120000 failed
assert_eq "three in a row: 3" "$(count_for 0009)" "3"
vfile 0009 20261108-130000 passed
assert_eq "a pass as the newest ends the run: 0" "$(count_for 0009)" "0"
vfile 0009 20261108-140000 failed
assert_eq "failures before a pass do not count" "$(count_for 0009)" "1"
# other artifacts in work/ are not validations
printf -- '---\ntype: signal\noutcome: failed\n---\n' > "$CONDUCTOR_DIR/work/0009/signal-20261108-150000.md"
assert_eq "a signal artifact is not counted" "$(count_for 0009)" "1"

# the notice: one file for the architect, one for the human, the card is not touched
export DISPATCH_ANSWER_FILE="$TMP/answer.txt"
mkdir -p "$CONDUCTOR_DIR/tasks"
printf -- '---\nid: 0009\ntitle: Implement conversion module\n---\n' > "$CONDUCTOR_DIR/tasks/0009.md"
: > "$STUB_LOG"
# shellcheck source=scripts/handler-steps.sh
( source "$STEPS_LIB"; escalate_validation_loop 0009 3 "$CONDUCTOR_DIR/work/0009/validation-20261108-140000.md" )
A="$(find "$CONDUCTOR_DIR/architect-inbox" -name 'validation-loop-0009-*.md')"; H="$(find "$CONDUCTOR_DIR/human-inbox" -name 'validation-loop-0009-*.md')"
assert_eq "one notice in the architect's inbox" "$(printf '%s\n' "$A" | grep -c .)" "1"
assert_eq "and one in the human's" "$(printf '%s\n' "$H" | grep -c .)" "1"
assert_eq "typed validation-loop, which the architect prompt maps to a skill" "$(grep -c '^type: validation-loop$' "$A")" "1"
assert_eq "naming the task and the failures" "$(grep -c '^task-id: 0009$' "$A") $(grep -c '^failures: 3$' "$A")" "1 1"
assert_eq "the title and the last failure are in the text" "$(grep -c 'Implement conversion module' "$H") $(grep -c 'NO TESTS RAN' "$H")" "1 1"
assert_eq "it says how to send the card back" "$(grep -c 'task-move.sh 0009 in-progress && stage-start.sh 0009 in-progress' "$H")" "1"
assert_eq "a progress note was written, nothing was moved or started" "$(grep -c '^task-signal.*--type progress.*parked after 3 validation failures' "$STUB_LOG") $(grep -c '^task-move\|^stage-start' "$STUB_LOG" || true)" "1 0"
assert_eq "the loop's log line is left for it to show" "$(grep -c 'task 0009 parked in validation after 3 failed validations' "$DISPATCH_ANSWER_FILE")" "1"
assert_eq "no strategist inbox, no strategist notice" "$(find "$CONDUCTOR_DIR" -path '*strategist-inbox*' | grep -c .)" "0"
# with a strategist (its inbox exists) it is told too, before anyone decides what to do
mkdir -p "$CONDUCTOR_DIR/strategist-inbox"
# shellcheck source=scripts/handler-steps.sh
( source "$STEPS_LIB"; escalate_validation_loop 0009 3 "$CONDUCTOR_DIR/work/0009/validation-20261108-140000.md" )
S="$(find "$CONDUCTOR_DIR/strategist-inbox" -name 'exception-0009-*.md')"
assert_eq "the strategist gets an exception notice" "$(printf '%s\n' "$S" | grep -c .)" "1"
assert_eq "typed exception, naming the task and the failures" "$(grep -c '^type: exception$' "$S") $(grep -c '^task-id: 0009$' "$S") $(grep -c '^failures: 3$' "$S")" "1 1 1"
unset DISPATCH_ANSWER_FILE
rm -rf "$CONDUCTOR_DIR/strategist-inbox"
rm -rf "$CONDUCTOR_DIR/work/0009" "$CONDUCTOR_DIR/architect-inbox" "$CONDUCTOR_DIR/human-inbox" "$CONDUCTOR_DIR/tasks/0009.md"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
