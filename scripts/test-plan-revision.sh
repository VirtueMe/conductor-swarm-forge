#!/usr/bin/env bash
# Tests plan changes (scripts/plan-revision.sh, #188): a proposal is kept, counted and announced to the
# architect and the person; the rounds are capped for a task and for the plan itself, and past the cap a
# person is told and nothing more is proposed; ask-person is free; resume sends a parked task back only
# when a proposal exists. task-move, stage-start and task-signal are stubs on PATH. No tmux, no AI.
#
# Usage: scripts/test-plan-revision.sh

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
mkdir -p "$CONDUCTOR_DIR"/{tasks,work}
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp "$topo" "$CONDUCTOR_DIR/topology.json"

STUB="$TMP/stub"; mkdir -p "$STUB"
export STUB_LOG="$TMP/calls.log"
for n in task-move stage-start task-signal; do
  # shellcheck disable=SC2016  # $STUB_LOG is expanded by the stub when it runs
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$n" > "$STUB/$n.sh"
done
chmod +x "$STUB"/*
export PATH="$STUB:$SCRIPTS_DIR:$PATH"
R="$SCRIPTS_DIR/plan-revision.sh"

printf -- '---\nid: 0001\ntype: feature\ntitle: One\ndepends-on: []\n---\n\nbody\n' > "$CONDUCTOR_DIR/tasks/0001.md"
printf -- '---\nid: 0002\ntype: feature\ntitle: Two\ndepends-on: []\n---\n\nbody\n' > "$CONDUCTOR_DIR/tasks/0002.md"
count() { find "$CONDUCTOR_DIR/$1" -name "$2" 2> /dev/null | grep -c . || true; }
rc() { local r=0; "$@" > /dev/null 2>&1 || r=$?; echo "$r"; }

section "1 · A proposal is kept, counted and announced"
assert_eq "no rounds yet" "$("$R" rounds 0001)" "0"
OUT="$("$R" propose 0001 fix-plan "the tests are in 0004; fold them into 0001")"
assert_eq "it says which round" "$OUT" "round 1 of 2: fix-plan proposed for 0001"
assert_eq "one round used"            "$("$R" rounds 0001)" "1"
assert_eq "the architect is told"     "$(count architect-inbox 'plan-change-0001-*.md')" "1"
assert_eq "so is the person"          "$(count human-inbox 'plan-change-0001-*.md')" "1"
A="$(find "$CONDUCTOR_DIR/architect-inbox" -name 'plan-change-0001-*.md')"
assert_eq "typed plan-change, with task and round" "$(grep -c '^type: plan-change$' "$A") $(grep -c '^task-id: 0001$' "$A") $(grep -c '^round: 1$' "$A")" "1 1 1"
assert_eq "the note is in it" "$(grep -c 'fold them into 0001' "$A")" "1"
assert_eq "it says how to approve and resume" "$(grep -c 'plan-revision.sh resume 0001' "$A")" "1"
assert_eq "another task is untouched" "$("$R" rounds 0002)" "0"

section "2 · A task's rounds are capped"
"$R" propose 0001 split "still too large" > /dev/null
assert_eq "two rounds used" "$("$R" rounds 0001)" "2"
assert_eq "the third is refused" "$(rc "$R" propose 0001 add-task "one more")" "1"
assert_eq "still two rounds"    "$("$R" rounds 0001)" "2"
assert_eq "the architect got no third notice" "$(count architect-inbox 'plan-change-0001-*.md')" "2"
assert_eq "a person is told it is over the cap" "$(count human-inbox 'plan-cap-0001-*.md')" "1"
assert_eq "and the note is there" "$(grep -c 'one more' "$(find "$CONDUCTOR_DIR/human-inbox" -name 'plan-cap-0001-*.md')")" "1"
assert_eq "the cap is per task" "$(rc "$R" propose 0002 fix-plan "x")" "0"
printf 'max-replans: 1\n' > "$CONDUCTOR_DIR/config.md"
assert_eq "config.md lowers the cap: 0002 has used its 1" "$(rc "$R" propose 0002 split "y")" "1"
printf 'max-replans: lots\n' > "$CONDUCTOR_DIR/config.md"
assert_eq "a cap that is not a number is the default (2)" "$(rc "$R" propose 0002 split "y")" "0"
rm -f "$CONDUCTOR_DIR/config.md"

section "3 · ask-person is free and writes for the person only"
"$R" propose 0002 ask-person "I cannot tell whether the tests or the code is wrong" > /dev/null
assert_eq "it does not use a round" "$("$R" rounds 0002)" "2"
assert_eq "it reaches the human inbox" "$(count human-inbox 'ask-person-0002-*.md')" "1"
assert_eq "and not the architect's" "$(count architect-inbox 'ask-person-*.md')" "0"
assert_eq "it works past the cap too" "$(rc "$R" propose 0001 ask-person "now what")" "0"

section "4 · Bad calls change nothing"
assert_eq "an unknown kind" "$(rc "$R" propose 0002 rewrite-everything "x")" "1"
assert_eq "a task that does not exist" "$(rc "$R" propose 0099 fix-plan "x")" "1"
assert_eq "a task id that is not a number" "$(rc "$R" propose ../x fix-plan "x")" "1"
assert_eq "no rounds were added" "$("$R" rounds 0002) $("$R" rounds 0001)" "2 2"

section "5 · The plan's own rejections are capped"
assert_eq "none yet" "$("$R" rounds plan)" "0"
"$R" reject "the brief asks for a CLI and no task builds one" > /dev/null
"$R" reject "still no CLI" > /dev/null
assert_eq "two rejections" "$("$R" rounds plan)" "2"
assert_eq "the architect got both" "$(count architect-inbox 'plan-rejected-*.md')" "2"
assert_eq "typed plan-rejected, which the architect prompt maps to a skill" "$(grep -l '^type: plan-rejected$' "$CONDUCTOR_DIR"/architect-inbox/plan-rejected-*.md | grep -c .)" "2"
assert_eq "the third is refused" "$(rc "$R" reject "yet again")" "1"
assert_eq "and goes to a person" "$(count human-inbox 'plan-cap-plan-*.md')" "1"

section "6 · resume sends a parked task back, on a proposal only"
: > "$STUB_LOG"
printf -- '---\nid: 0002\ntype: feature\n---\n' > "$CONDUCTOR_DIR/kanban/validation/0002.md"
assert_eq "0002 has proposals, so it resumes" "$(rc "$R" resume 0002)" "0"
assert_eq "moved and started" "$(grep -c '^task-move 0002 in-progress' "$STUB_LOG") $(grep -c '^stage-start 0002 in-progress' "$STUB_LOG")" "1 1"
assert_eq "and noted on the card" "$(grep -c '^task-signal --task 0002 --type progress --notes plan changed' "$STUB_LOG")" "1"
rm -f "$CONDUCTOR_DIR/kanban/validation/0002.md"
: > "$STUB_LOG"
printf -- '---\nid: 0003\ntype: feature\ntitle: Three\ndepends-on: []\n---\n' > "$CONDUCTOR_DIR/tasks/0003.md"
printf -- '---\nid: 0003\ntype: feature\n---\n' > "$CONDUCTOR_DIR/kanban/validation/0003.md"
assert_eq "no proposal: not resumed" "$(rc "$R" resume 0003)" "1"
"$R" propose 0003 fix-plan "x" > /dev/null
mv "$CONDUCTOR_DIR/kanban/validation/0003.md" "$CONDUCTOR_DIR/kanban/in-progress/0003.md"
assert_eq "not parked in validation: not touched" "$(rc "$R" resume 0003)" "1"
assert_eq "nothing was moved" "$(grep -c '^task-move' "$STUB_LOG" || true)" "0"
rm -f "$CONDUCTOR_DIR/kanban/in-progress/0003.md"
assert_eq "no card: refused" "$(rc "$R" resume 0003)" "1"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All plan-revision tests passed."; else echo "$FAILS plan-revision test(s) failed." >&2; exit 1; fi
