#!/usr/bin/env bash
# Tests plan-check.sh against hand-written plans: a good one, and one for each fault it names,
# including the two shapes the real runs produced (tests as a later task; tests last). Needs only jq.
#
# Usage: scripts/test-plan-check.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPTS_DIR/plan-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

# plan <name>: a fresh conductor dir; task <name> <id> <title> <type> <deps, comma> <description>
plan() { rm -rf "${TMP:?}/$1"; mkdir -p "$TMP/$1/tasks"; }
task() {
  local deps="depends-on: []" d
  if [[ -n "$5" ]]; then
    deps="depends-on:"
    IFS=',' read -ra ds <<< "$5"
    for d in "${ds[@]}"; do deps+=$'\n'"  - $d"; done
  fi
  printf -- '---\nid: %s\ntitle: %s\ntype: %s\n%s\n---\n\n## Description\n%s\n\n## Acceptance Criteria\n- [ ] \n' \
    "$2" "$3" "$4" "$deps" "$6" > "$TMP/$1/tasks/$2.md"
}
# codes <name>: the finding codes, space separated; rc <name>: the exit status
codes() { CONDUCTOR_DIR="$TMP/$1" "$CHECK" --json | jq -r 'map(.code) | join(" ")'; }
rc() { local r=0; CONDUCTOR_DIR="$TMP/$1" "$CHECK" > /dev/null || r=$?; echo "$r"; }

section "1 · A good plan has no findings"
plan good
task good 0001 "Model" design "" "Define the model."
task good 0002 "Graph" feature "0001" "Build the graph. Write its tests with the code."
task good 0003 "Player" feature "0001" "Player state. Tests come with it."
task good 0004 "Game loop" feature "0002,0003" "The loop, with tests."
task good 0005 "Whole-program tests" test "0004" "End-to-end behaviour."
assert_eq "no findings"  "$(codes good)" ""
assert_eq "exit 0"       "$(rc good)" "0"

section "2 · Tests as a later task: the fault of run #68d and the second real run"
plan later
task later 0001 "Model" design "" "Define the model."
task later 0002 "Graph" feature "0001" "Build the graph."
task later 0003 "Tests for the graph" test "0002" "Cover the graph."
assert_eq "the feature is flagged"  "$(codes later)" "feature-no-tests"
assert_eq "it names the later test task" "$(CONDUCTOR_DIR="$TMP/later" "$CHECK" --json | jq -r '.[0].message' | grep -c 'task 0003, which waits on it')" "1"
assert_eq "an error: exit 1" "$(rc later)" "1"

section "3 · Tests that come first, or with the code, are fine"
plan first
task first 0001 "Tests for the graph" test "" "Write the tests."
task first 0002 "Graph" feature "0001" "Build the graph."
assert_eq "a feature that depends on a test task passes" "$(codes first)" ""

section "4 · Dependencies"
plan dangling
task dangling 0001 "A" feature "0009" "A, with tests."
assert_eq "a dependency that is not a task" "$(codes dangling)" "dangling-dependency"
plan cycle
task cycle 0001 "A" feature "0002" "A, with tests."
task cycle 0002 "B" feature "0001" "B, with tests."
task cycle 0003 "C" feature "0002" "C, with tests."
assert_eq "a cycle, once" "$(codes cycle)" "dependency-cycle"
assert_eq "the cycle names what waits on it" "$(CONDUCTOR_DIR="$TMP/cycle" "$CHECK" --json | jq -r '.[0].message' | grep -c '0001, 0002, 0003')" "1"

section "5 · Warnings do not fail the plan"
plan warn
task warn 0001 "Graph" feature "" "Build the graph, with tests."
task warn 0002 "Orphan tests" test "" "Tests of nothing."
assert_eq "a test task that covers nothing and that nothing waits on" "$(codes warn)" "test-covers-nothing"
assert_eq "a warning alone is exit 0" "$(rc warn)" "0"
plan big
task big 0001 "Everything" feature "" "$(printf 'word %.0s' $(seq 1 400)) with tests"
assert_eq "a description too large to review" "$(codes big)" "task-too-large"
assert_eq "the limit is a setting" "$(CONDUCTOR_DIR="$TMP/big" PLAN_CHECK_MAX_DESCRIPTION=5000 "$CHECK" --json | jq -r 'map(.code) | join(" ")')" ""

section "6 · An empty plan, and the words in the description"
plan empty
assert_eq "no tasks is an error" "$(codes empty)" "empty-plan"
plan words
task words 0001 "Graph" feature "" "Build the graph. Make sure it is tested."
assert_eq "'tested' is not 'test': still flagged" "$(codes words)" "feature-no-tests"
task words 0001 "Graph" feature "" "Build the graph. Add a Test."
assert_eq "'Test' in any case counts" "$(codes words)" ""
task words 0001 "Graph" chore "" "Wire the tooling."
assert_eq "only a feature must carry tests" "$(codes words)" ""

section "7 · The text report"
OUT="$(CONDUCTOR_DIR="$TMP/later" "$CHECK" || true)"
if grep -q 'Plan: 3 tasks, 1 error(s), 0 warning(s).' <<< "$OUT"; then ok "it says how many tasks and findings"; else fail "report header: $OUT"; fi
if grep -q 'feature-no-tests' <<< "$OUT"; then ok "it prints the finding"; else fail "no finding in: $OUT"; fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All plan-check tests passed."; else echo "$FAILS failed." >&2; exit 1; fi
