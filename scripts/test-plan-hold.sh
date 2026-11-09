#!/usr/bin/env bash
# Tests the plan hold (scripts/plan-hold.sh, #188): while it is on, new tasks and unblocked tasks stay in
# backlog; release is all-or-nothing (a plan error or one bad strategy file releases nothing), takes a
# snapshot of the strategy, and releases the cards that can start. task-move, stage-start and tmux are
# stubs on PATH; the rest is real. No tmux server, no AI.
#
# Usage: scripts/test-plan-hold.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { echo ""; echo "── $1"; }

export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work,strategy}
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp "$topo" "$CONDUCTOR_DIR/topology.json"

STUB="$TMP/stub"; mkdir -p "$STUB"
export STUB_LOG="$TMP/calls.log"
cat > "$STUB/task-move.sh" << 'X'
#!/usr/bin/env bash
echo "task-move $*" >> "$STUB_LOG"
for f in "$CONDUCTOR_DIR"/kanban/*/"$1".md; do [[ -f "$f" ]] && rm -f "$f"; done
mkdir -p "$CONDUCTOR_DIR/kanban/$2"
printf -- '---\nid: %s\n---\n' "$1" > "$CONDUCTOR_DIR/kanban/$2/$1.md"
X
# shellcheck disable=SC2016  # $STUB_LOG is expanded by the stub when it runs
printf '#!/usr/bin/env bash\necho "stage-start $*" >> "$STUB_LOG"\n' > "$STUB/stage-start.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/tmux"
chmod +x "$STUB"/*
export PATH="$STUB:$SCRIPTS_DIR:$PATH"
H="$SCRIPTS_DIR/plan-hold.sh"
NEW="$SCRIPTS_DIR/handlers/on-new-task.sh"

task() { # <id> <type> <body> [dep]
  { printf -- '---\nid: %s\ntype: %s\ntitle: t%s\n' "$1" "$2" "$1"
    if [[ -n "${4:-}" ]]; then printf 'depends-on:\n  - %s\n' "$4"; else printf 'depends-on: []\n'; fi
    printf -- '---\n\n%s\n' "$3"; } > "$CONDUCTOR_DIR/tasks/$1.md"
}
stage_of() { for f in "$CONDUCTOR_DIR"/kanban/*/"$1".md; do [[ -f "$f" ]] && { basename "$(dirname "$f")"; return; }; done; echo none; }
new_task() { TASK_ID="$1" TASK_FILE="$CONDUCTOR_DIR/tasks/$1.md" "$NEW" 2> /dev/null; }

section "1 · No hold: a new task goes to ready as before"
task 0001 feature "Build it, with tests."
new_task 0001
assert_eq "0001 is in ready" "$(stage_of 0001)" "ready"
rm -f "$CONDUCTOR_DIR"/kanban/*/0001.md

section "2 · Held: new tasks wait in backlog, a design task does not"
"$H" hold > /dev/null
assert_eq "status says held" "$("$H" status)" "held"
task 0001 feature "Build it, with tests."
task 0002 feature "Build more, with tests." 0001
task 0003 design "Design."
: > "$STUB_LOG"
new_task 0001; new_task 0002; new_task 0003
assert_eq "0001 waits in backlog"     "$(stage_of 0001)" "backlog"
assert_eq "0002 waits in backlog"     "$(stage_of 0002)" "backlog"
assert_eq "a design task is done"     "$(stage_of 0003)" "done"
new_task 0001
assert_eq "a replayed event holds it again" "$(stage_of 0001)" "backlog"
assert_eq "no working stage was started" "$(grep -c '^stage-start .* \(ready\|in-progress\)$' "$STUB_LOG" || true)" "0"

section "3 · Held: nothing heals or unblocks a card"
# shellcheck source=scripts/handler-steps.sh
source "$SCRIPTS_DIR/handler-steps.sh"
assert_eq "no stranded backlog while held" "$(stranded_backlog)" ""
unblock_ready
assert_eq "unblock_ready leaves 0001" "$(stage_of 0001)" "backlog"
release_backlog_card 0001
assert_eq "release_backlog_card leaves 0001" "$(stage_of 0001)" "backlog"

section "4 · Release refuses a plan with an error"
task 0004 feature "No word of it." 0099
RC=0; "$H" release > /dev/null 2>&1 || RC=$?
assert_eq "a dangling dependency stops the release" "$RC" "1"
assert_eq "still held" "$("$H" status)" "held"
assert_eq "0001 untouched" "$(stage_of 0001)" "backlog"
rm -f "$CONDUCTOR_DIR/tasks/0004.md"

section "5 · Release is all-or-nothing on the strategy"
printf '%s\n' '{"skip":{"validation":"docs only"}}' > "$CONDUCTOR_DIR/strategy/0001.json"
printf '%s\n' '{"skip":{"review":"too slow"}}' > "$CONDUCTOR_DIR/strategy/0002.json"
RC=0; "$H" release > /dev/null 2>&1 || RC=$?
assert_eq "one bad file stops the release" "$RC" "1"
assert_eq "still held" "$("$H" status)" "held"
assert_eq "no snapshot"  "$([[ -e "$CONDUCTOR_DIR/strategy-released" ]] && echo yes || echo no)" "no"
assert_eq "the good file does not apply either" "$("$SCRIPTS_DIR/task-strategy.sh" skip 0001 validation)" "docs only"
printf '%s\n' '{}' > "$CONDUCTOR_DIR/strategy/0009.json"
RC=0; "$H" release > /dev/null 2>&1 || RC=$?
assert_eq "a strategy for no task stops it too" "$RC" "1"
rm -f "$CONDUCTOR_DIR/strategy/0009.json"
printf '%s\n' '{"skip":{"validation":"docs only"}}' > "$CONDUCTOR_DIR/strategy/0002.json"

section "6 · Release: snapshot, and the cards that can start start"
: > "$STUB_LOG"
"$H" release > /dev/null
assert_eq "status says released"          "$("$H" status || true)" "released"
assert_eq "0001 (no dependencies) is ready" "$(stage_of 0001)" "ready"
assert_eq "0002 waits for 0001"           "$(stage_of 0002)" "backlog"
assert_eq "0001 was started"              "$(grep -c '^stage-start 0001 ready' "$STUB_LOG" || true)" "1"
assert_eq "the snapshot has both files"   "$(find "$CONDUCTOR_DIR/strategy-released" -name '*.json' | sort | xargs -n1 basename | tr '\n' ' ')" "0001.json 0002.json "
printf '%s\n' '{"skip":{"validation":"changed after release"}}' > "$CONDUCTOR_DIR/strategy/0001.json"
assert_eq "an edited draft changes nothing" "$("$SCRIPTS_DIR/task-strategy.sh" skip 0001 validation)" "docs only"
RC=0; "$H" release > /dev/null 2>&1 || RC=$?
assert_eq "releasing twice is refused" "$RC" "1"

section "7 · After release, dependents unblock as usual"
mv "$CONDUCTOR_DIR/kanban/ready/0001.md" "$CONDUCTOR_DIR/kanban/done/0001.md"
unblock_dependents 0001
assert_eq "0002 is ready" "$(stage_of 0002)" "ready"

section "8 · --force releases a plan with an error"
rm -rf "$CONDUCTOR_DIR/plan-released" "$CONDUCTOR_DIR/strategy-released"
"$H" hold > /dev/null
task 0004 feature "No word of it." 0099
"$H" release --force > /dev/null 2>&1
assert_eq "released" "$("$H" status || true)" "released"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All plan-hold tests passed."; else echo "$FAILS plan-hold test(s) failed." >&2; exit 1; fi
