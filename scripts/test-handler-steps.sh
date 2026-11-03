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
export STUB_LOG="$TMP/calls.log" STUB_LOCKED="$TMP/locked" STUB_LOCKS_RC="$TMP/locks.rc"
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
cat > "$STUB/tmux" << 'S'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
if [[ "$1" == "list-windows" ]]; then printf 'conductor\ncoder-0001\nreviewer-0002\n'; fi
S
chmod +x "$STUB"/*
export PATH="$STUB:$SCRIPTS_DIR:$PATH"
reset() { : > "$STUB_LOG"; : > "$STUB_LOCKED"; rm -f "$STUB_LOCKS_RC"; }

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

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
