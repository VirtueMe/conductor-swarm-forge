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

# A held project of its own: 0001 is a design task already done, 0002 a feature in backlog that depends on it.
fresh_project() { # <dir>
  local d="$1/.conductor" st
  mkdir -p "$d"/{tasks,work,strategy}
  while IFS= read -r st; do mkdir -p "$d/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
  cp "$topo" "$d/topology.json"
  printf -- '---\nid: 0001\ntype: design\ntitle: t0001\ndepends-on: []\n---\n\nDesign.\n' > "$d/tasks/0001.md"
  printf -- '---\nid: 0002\ntype: feature\ntitle: t0002\ndepends-on:\n  - 0001\n---\n\nBuild it, with tests.\n' > "$d/tasks/0002.md"
  cp "$d/tasks/0001.md" "$d/kanban/done/0001.md"
  cp "$d/tasks/0002.md" "$d/kanban/backlog/0002.md"
  CONDUCTOR_DIR="$d" "$H" hold > /dev/null
}
stage_in() { (CONDUCTOR_DIR="$1/.conductor"; stage_of "$2"); }

section "9 · Release from a window with no scripts on its PATH (#197)"
# The strategist's window is given SCRIPTS_DIR in its briefing and calls scripts by absolute path; nothing
# puts that directory on PATH. Release used to remove the hold, then die on 'topology-load.sh: command not
# found', leaving the card in backlog and the plan 'released' for nothing to start.
P9="$TMP/p9"; fresh_project "$P9"
RC=0; env CONDUCTOR_DIR="$P9/.conductor" PATH="$STUB:/usr/bin:/bin" "$H" release > "$TMP/out9" 2>&1 || RC=$?
assert_eq "release succeeds" "$RC" "0"
assert_eq "the hold is gone" "$(CONDUCTOR_DIR="$P9/.conductor" "$H" status || true)" "released"
assert_eq "0002 (its dependency is done) is ready" "$(stage_in "$P9" 0002)" "ready"

section "10 · A card that cannot be released puts the hold back (#197)"
P10="$TMP/p10"; fresh_project "$P10"
cat > "$STUB/task-move.sh" << 'X'
#!/usr/bin/env bash
[[ "${STUB_FAIL_MOVE:-}" != "$1" ]] || { echo "task-move: cannot move $1" >&2; exit 1; }
for f in "$CONDUCTOR_DIR"/kanban/*/"$1".md; do [[ -f "$f" ]] && rm -f "$f"; done
mkdir -p "$CONDUCTOR_DIR/kanban/$2"
printf -- '---\nid: %s\n---\n' "$1" > "$CONDUCTOR_DIR/kanban/$2/$1.md"
X
RC=0; env CONDUCTOR_DIR="$P10/.conductor" STUB_FAIL_MOVE=0002 "$H" release > "$TMP/out10" 2>&1 || RC=$?
assert_eq "release fails" "$RC" "1"
assert_eq "the plan is held again" "$(CONDUCTOR_DIR="$P10/.conductor" "$H" status || true)" "held"
assert_eq "no 'released' marker is left" "$([[ -e "$P10/.conductor/plan-released" ]] && echo yes || echo no)" "no"
assert_eq "0002 is still in backlog" "$(stage_in "$P10" 0002)" "backlog"
assert_eq "the message says the plan is held again" "$(grep -c "held again" "$TMP/out10" || true)" "1"
RC=0; env CONDUCTOR_DIR="$P10/.conductor" "$H" release > /dev/null 2>&1 || RC=$?
assert_eq "once the cause is gone, release works again" "$RC" "0"
assert_eq "and 0002 is ready" "$(stage_in "$P10" 0002)" "ready"

section "11 · A failed release says which cards had already started (#197)"
P11="$TMP/p11"; fresh_project "$P11"
printf -- '---\nid: 0003\ntype: feature\ntitle: t0003\ndepends-on:\n  - 0001\n---\n\nBuild more, with tests.\n' > "$P11/.conductor/tasks/0003.md"
cp "$P11/.conductor/tasks/0003.md" "$P11/.conductor/kanban/backlog/0003.md"
RC=0; env CONDUCTOR_DIR="$P11/.conductor" STUB_FAIL_MOVE=0003 "$H" release > "$TMP/out11" 2>&1 || RC=$?
assert_eq "release fails" "$RC" "1"
assert_eq "0002 had already started" "$(stage_in "$P11" 0002)" "ready"
assert_eq "0003 is still in backlog" "$(stage_in "$P11" 0003)" "backlog"
assert_eq "the message names the failed card" "$(grep -c 'task 0003 could not be released' "$TMP/out11" || true)" "1"
assert_eq "and the card that had already started" "$(grep -c 'already released and started: 0002' "$TMP/out11" || true)" "1"
assert_eq "a failure with nothing started says nothing about it" "$(grep -c 'already released' "$TMP/out10" || true)" "0"

section "12 · Release warns about a task with no weight, and releases anyway (#201)"
# Every task a worker runs gets a weight from the strategist, so a cost can be filed against it. A task with
# none is named in a warning that never holds the plan back. A design task costs nothing and is not named.
add_feature() { # <dir> <id> <dependency> [<extra front matter line>]
  printf -- '---\nid: %s\ntype: feature\ntitle: t%s\ndepends-on:\n  - %s\n%s---\n\nBuild it, with tests.\n' "$2" "$2" "$3" "${4:+$4
}" > "$1/.conductor/tasks/$2.md"
  cp "$1/.conductor/tasks/$2.md" "$1/.conductor/kanban/backlog/$2.md"
}
release_in() { # <dir>: sets RC and the output file
  RC=0; env CONDUCTOR_DIR="$1/.conductor" "$H" release > "$TMP/out12" 2>&1 || RC=$?
}
P12="$TMP/p12"; fresh_project "$P12"          # 0001 design (done), 0002 feature, no weight
add_feature "$P12" 0003 0001                  # no weight either
add_feature "$P12" 0004 0001 'weight: 2'      # weighted in its task file
add_feature "$P12" 0005 0001                  # weighted in a strategy file
echo '{ "weight": 3 }' > "$P12/.conductor/strategy/0005.json"
release_in "$P12"
assert_eq "release succeeds" "$RC" "0"
assert_eq "the plan is released" "$(CONDUCTOR_DIR="$P12/.conductor" "$H" status || true)" "released"
assert_eq "it warns, naming both unweighted tasks" "$(grep -c 'warning: no weight for 0002, 0003' "$TMP/out12" || true)" "1"
assert_eq "a task weighted in its task file is not named" "$(grep -c '0004' "$TMP/out12" || true)" "0"
assert_eq "a task weighted in a strategy file is not named" "$(grep -c '0005' "$TMP/out12" || true)" "0"
assert_eq "the design task is not named" "$(grep -c '0001' "$TMP/out12" || true)" "0"
assert_eq "and the unweighted task still started" "$(stage_in "$P12" 0002)" "ready"

# Whether a task needs a weight is the topology's call, not a literal type: this topology sends a chore straight
# to done as well, so a chore costs nothing and is not named, while an unweighted feature still is.
P12c="$TMP/p12c"; fresh_project "$P12c"
jq '.transitions["new-task"][0].when.type += ["chore"]' "$P12c/.conductor/topology.json" > "$P12c/.conductor/topology.new" && mv "$P12c/.conductor/topology.new" "$P12c/.conductor/topology.json"
printf -- '---\nid: 0006\ntype: chore\ntitle: t0006\ndepends-on:\n  - 0001\n---\n\nTidy up.\n' > "$P12c/.conductor/tasks/0006.md"
cp "$P12c/.conductor/tasks/0006.md" "$P12c/.conductor/kanban/backlog/0006.md"
release_in "$P12c"
assert_eq "a task this topology sends straight to done is not named" "$(grep -c '0006' "$TMP/out12" || true)" "0"
assert_eq "the unweighted feature still is" "$(grep -c 'warning: no weight for 0002;' "$TMP/out12" || true)" "1"

P12b="$TMP/p12b"; fresh_project "$P12b"
echo '{ "weight": 1 }' > "$P12b/.conductor/strategy/0002.json"
release_in "$P12b"
assert_eq "every task weighted: release succeeds" "$RC" "0"
assert_eq "and says nothing about weight" "$(grep -c 'weight' "$TMP/out12" || true)" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All plan-hold tests passed."; else echo "$FAILS plan-hold test(s) failed." >&2; exit 1; fi
