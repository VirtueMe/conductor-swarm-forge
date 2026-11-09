#!/usr/bin/env bash
# Tests a task's strategy (scripts/task-strategy.sh): the file's checks, the floor that no file can lower,
# the tuning merged over a role's params, and route_task skipping a step the strategy skips: the reason
# written on the card first, review and merging never skipped, a skip that cannot be recorded not made.
# task-move, stage-start, task-signal, task-locks and tmux are stubs on PATH; topology-load.sh is the real
# one. No tmux server, no AI.
#
# Usage: scripts/test-task-strategy.sh

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

export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work,strategy}
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp "$topo" "$CONDUCTOR_DIR/topology.json"
S="$SCRIPTS_DIR/task-strategy.sh"
strategy() { printf '%s\n' "$2" > "$CONDUCTOR_DIR/strategy/$1.json"; }

section "1 · The topology says what may be skipped: the rest is the floor"
assert_eq "software-dev lists validation only" "$("$SCRIPTS_DIR/topology-load.sh" skippable software-dev | tr '\n' ' ')" "validation "
assert_eq "validation resumes by validation-passed" "$("$SCRIPTS_DIR/topology-load.sh" skip-event software-dev validation)" "validation-passed"
assert_eq "review has no skip event" "$("$SCRIPTS_DIR/topology-load.sh" skip-event software-dev review)" ""
assert_eq "merging has no skip event" "$("$SCRIPTS_DIR/topology-load.sh" skip-event software-dev merging)" ""
assert_eq "a topology with none lists none" "$("$SCRIPTS_DIR/topology-load.sh" skippable marketing | tr '\n' ' ')" ""
BAD="$TMP/bad.json"
jq '.skippable = {"backlog": "validation-passed"}' "$topo" > "$BAD"
RC=0; "$SCRIPTS_DIR/topology-load.sh" validate "$BAD" > /dev/null 2>&1 || RC=$?
assert_eq "skippable must name a working stage" "$RC" "1"
jq '.skippable = {"validation": "no-such-event"}' "$topo" > "$BAD"
RC=0; "$SCRIPTS_DIR/topology-load.sh" validate "$BAD" > /dev/null 2>&1 || RC=$?
assert_eq "skippable must name a transition" "$RC" "1"

section "2 · A sound strategy"
strategy 0001 '{"skip":{"validation":"docs only"},"workers":{"reviewer":{"model":"claude-sonnet-4-6"}},"weight":3}'
assert_eq "it validates"                 "$("$S" validate 0001 2>&1; echo "rc=$?")" "rc=0"
assert_eq "the reason of a skipped step" "$("$S" skip 0001 validation)" "docs only"
assert_eq "another stage is not skipped" "$("$S" skip 0001 review)" ""
assert_eq "the weight"                   "$("$S" weight 0001)" "3"
assert_eq "no strategy: nothing skipped" "$("$S" skip 0009 validation)" ""
assert_eq "no strategy: no weight"       "$("$S" weight 0009)" ""
assert_eq "no strategy validates"        "$("$S" validate 0009 2>&1; echo "rc=$?")" "rc=0"
assert_eq "show with none is {}"         "$("$S" show 0009)" "{}"

section "3 · The floor: no file can skip review or merging"
strategy 0002 '{"skip":{"review":"too slow","merging":"it is fine","validation":"x"}}'
assert_eq "review is not skipped even if the file says so"  "$("$S" skip 0002 review)" ""
assert_eq "merging is not skipped even if the file says so" "$("$S" skip 0002 merging)" ""
assert_eq "validation still is" "$("$S" skip 0002 validation)" "x"
OUT="$("$S" validate 0002 2>&1 || true)"
if grep -q 'review cannot be skipped: it is a floor step' <<< "$OUT" && grep -q 'merging cannot be skipped' <<< "$OUT"; then ok "validate names each floor step"; else fail "validate: $OUT"; fi
RC=0; "$S" validate 0002 > /dev/null 2>&1 || RC=$?
assert_eq "and fails" "$RC" "1"

section "4 · A skip needs a reason; other mistakes are named"
strategy 0003 '{"skip":{"validation":"  "}}'
assert_eq "a blank reason skips nothing" "$("$S" skip 0003 validation)" ""
OUT="$("$S" validate 0003 2>&1 || true)"
if grep -q 'needs a reason' <<< "$OUT"; then ok "validate asks for the reason"; else fail "no reason complaint"; fi
strategy 0004 '{"workers":{"nobody":{"model":"x"},"coder":{"adapter":"pi","model":""}},"weight":-1,"extra":1}'
OUT="$("$S" validate 0004 2>&1 || true)"
for want in 'unknown key: extra' 'nobody is not a role' 'only model and effort can be set, not adapter' 'model must be a non-empty string' 'weight must be a number'; do
  if grep -q "$want" <<< "$OUT"; then ok "validate says: $want"; else fail "missing '$want' in: $OUT"; fi
done
echo 'not json' > "$CONDUCTOR_DIR/strategy/0005.json"
RC=0; "$S" validate 0005 > /dev/null 2>&1 || RC=$?
assert_eq "a file that is not JSON fails validation" "$RC" "1"
assert_eq "but reads as no strategy: the conductor carries on" "$("$S" skip 0005 validation; "$S" show 0005)" "{}"

section "5 · Tuning merged over the role's params"
BASE='{"model":"claude-opus-4-8","effort":"low"}'
assert_eq "the task's model wins"        "$("$S" params 0001 reviewer "$BASE")" '{"model":"claude-sonnet-4-6","effort":"low"}'
assert_eq "another role is untouched"    "$("$S" params 0001 coder "$BASE")" "$BASE"
assert_eq "no strategy: params unchanged" "$("$S" params 0009 reviewer "$BASE")" "$BASE"
assert_eq "no base params"               "$("$S" params 0001 reviewer)" '{"model":"claude-sonnet-4-6"}'
strategy 0006 '{"workers":{"coder":{"model":"m","adapter":"pi","pool":"api:x","effort":3}}}'
assert_eq "only a string model and effort get through" "$("$S" params 0006 coder '{}')" '{"model":"m"}'

# --- route_task, with stubs ------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
export STUB_LOG="$TMP/calls.log" STUB_LOCKED="$TMP/locked" STUB_SIGNAL_RC="$TMP/signal.rc"
cat > "$STUB/task-locks.sh" << 'X'
#!/usr/bin/env bash
cat "$STUB_LOCKED" 2>/dev/null || true
X
# shellcheck disable=SC2016  # $STUB_LOG is expanded by the stub when it runs
for n in task-move stage-start; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$n" > "$STUB/$n.sh"
done
cat > "$STUB/task-signal.sh" << 'X'
#!/usr/bin/env bash
echo "task-signal $*" >> "$STUB_LOG"
[[ -f "$STUB_SIGNAL_RC" ]] && exit "$(cat "$STUB_SIGNAL_RC")"
exit 0
X
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/tmux"
chmod +x "$STUB"/*
export PATH="$STUB:$SCRIPTS_DIR:$PATH"
reset() { : > "$STUB_LOG"; : > "$STUB_LOCKED"; rm -f "$STUB_SIGNAL_RC"; }
card() { # <stage> <type> [files-changed item]: the card of task 0001
  rm -f "$CONDUCTOR_DIR"/kanban/*/0001.md
  { printf -- '---\nid: 0001\ntype: %s\nstatus: %s\n' "$2" "$1"
    if [[ -n "${3:-}" ]]; then printf 'files-changed:\n  - %s\n' "$3"; fi
    printf -- '---\n\nbody\n'; } > "$CONDUCTOR_DIR/kanban/$1/0001.md"
}
moves() { grep -c '^task-move' "$STUB_LOG" || true; }
# shellcheck source=scripts/handler-steps.sh
source "$SCRIPTS_DIR/handler-steps.sh"

section "6 · route_task: no strategy runs every step"
reset; card in-progress feature; rm -f "$CONDUCTOR_DIR/strategy/0001.json"
route_task 0001 signal-complete type=feature config.test-cmd=make locks=free
assert_eq "validation is entered"  "$ROUTED_DEST" "validation"
assert_eq "nothing recorded"       "$(grep -c '^task-signal' "$STUB_LOG" || true)" "0"

section "7 · route_task: a skipped step is recorded and not entered"
strategy 0001 '{"skip":{"validation":"docs only: no test applies"}}'
reset; card in-progress feature
route_task 0001 signal-complete type=feature config.test-cmd=make locks=free
assert_eq "the task goes on to review"     "$ROUTED_DEST" "review"
assert_eq "validation was never entered"   "$(grep -c 'task-move 0001 validation' "$STUB_LOG" || true)" "0"
assert_eq "one move, to review"            "$(moves)" "1"
if grep -q 'task-signal --task 0001 --type progress --notes conductor: skipped validation — docs only: no test applies' "$STUB_LOG"; then ok "the reason is written on the card"; else fail "no reason on the card: $(cat "$STUB_LOG")"; fi
reset; card in-progress chore
route_task 0001 signal-complete type=chore config.test-cmd=make locks=free
assert_eq "a chore skips on to merging"    "$ROUTED_DEST" "merging"
reset; card in-progress chore src/a.txt
printf 'src/a.txt\n' > "$STUB_LOCKED"
route_task 0001 signal-complete type=chore config.test-cmd=make locks=held
assert_eq "locks held: the skip is not the end, the lock guard still applies" "$ROUTED_DEST" "merge-pending"

section "8 · route_task: the floor holds"
strategy 0001 '{"skip":{"review":"i want it quick","merging":"just land it"}}'
reset; card validation feature
route_task 0001 validation-passed type=feature locks=free
assert_eq "review is entered"   "$ROUTED_DEST" "review"
reset; card review feature
route_task 0001 review-approved locks=free
assert_eq "merging is entered"  "$ROUTED_DEST" "merging"
assert_eq "no skip recorded"    "$(grep -c '^task-signal' "$STUB_LOG" || true)" "0"

section "9 · route_task: a skip that cannot be recorded is not made"
strategy 0001 '{"skip":{"validation":"docs only"}}'
reset; card in-progress feature; echo 1 > "$STUB_SIGNAL_RC"
route_task 0001 signal-complete type=feature config.test-cmd=make locks=free 2> "$TMP/err"
assert_eq "the step runs instead" "$ROUTED_DEST" "validation"
if grep -q 'could not record the skip of validation' "$TMP/err"; then ok "and it says why"; else fail "no warning: $(cat "$TMP/err")"; fi

section "10 · route_task: a skip chain ends"
LOOP="$TMP/loop.json"
jq '.transitions["validation-passed"] = [{"to": "validation"}]' "$topo" > "$LOOP"
cp "$LOOP" "$CONDUCTOR_DIR/topology.json"
reset; card in-progress feature
route_task 0001 signal-complete type=feature config.test-cmd=make locks=free
assert_eq "it stops, entering the step"  "$ROUTED_DEST" "validation"
assert_eq "after four skips"             "$(grep -c '^task-signal' "$STUB_LOG" || true)" "4"
cp "$topo" "$CONDUCTOR_DIR/topology.json"

section "11 · The task's record takes its weight from the strategy"
mkdir -p "$CONDUCTOR_DIR/work/0001"
printf -- '---\nid: 0001\ntitle: T\ntype: feature\nweight: 9\n---\n' > "$CONDUCTOR_DIR/tasks/0001.md"
printf -- '---\ntype: merge\ntimestamp: 20261109-120000\noutcome: success\n---\n' > "$CONDUCTOR_DIR/work/0001/merge-20261109-120000.md"
strategy 0001 '{"weight":2}'
assert_eq "the strategy's weight wins" "$("$SCRIPTS_DIR/task-record.sh" 0001 --print | jq -r .weight)" "2"
rm "$CONDUCTOR_DIR/strategy/0001.json"
assert_eq "else the task file's"       "$("$SCRIPTS_DIR/task-record.sh" 0001 --print | jq -r .weight)" "9"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All task-strategy tests passed."; else echo "$FAILS failed." >&2; exit 1; fi
