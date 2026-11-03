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
  [[ -f "$f" ]] && { mkdir -p "$CONDUCTOR_DIR/kanban/$2"; mv "$f" "$CONDUCTOR_DIR/kanban/$2/$1.md"; break; }
done
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

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
