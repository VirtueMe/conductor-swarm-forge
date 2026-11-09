#!/usr/bin/env bash
# shellcheck disable=SC2016  # the dollar signs in the patterns below are regular-expression text
# Tests task-record.sh (the record of a finished task), usage-combine.sh, and the weight and tasks
# groupings of usage-summary.sh, in a throwaway git repo. Needs no Claude, no Codex and no tmux.
#
# Usage: scripts/test-task-record.sh

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
has() { if grep -qE -- "$1" "$OUT"; then ok "$2"; else fail "$2 (in output: $(tr '\n' '|' < "$OUT" | cut -c1-400))"; fi; }
section() { echo ""; echo "── $1"; }

PROJECT="$TMP/project"
mkdir -p "$PROJECT"
cd "$PROJECT"
git init -q -b main
git config user.email t@example.com; git config user.name t
echo 1 > a; git add a; git commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
git checkout -q -b feature/0001-x
printf 'x\ny\n' > b; echo 2 >> a; git add .; git commit -qm one
echo z >> b; git commit -qam two
HEAD_SHA="$(git rev-parse HEAD)"
git checkout -q main; git merge -q --ff-only feature/0001-x; git branch -q -D feature/0001-x   # the branch is gone

export CONDUCTOR_DIR="$PROJECT/.conductor"
mkdir -p "$CONDUCTOR_DIR/work/0001" "$CONDUCTOR_DIR/work/0002" "$CONDUCTOR_DIR/tasks"
printf -- '---\ntitle: T one\ntype: feature\nweight: 3\n---\n' > "$CONDUCTOR_DIR/tasks/0001.md"
printf -- '---\ntitle: T two\ntype: feature\n---\n' > "$CONDUCTOR_DIR/tasks/0002.md"
W="$CONDUCTOR_DIR/work"
printf -- '---\ntype: merge\ntimestamp: 20261109-120000\noutcome: success\nbase-sha: %s\nhead-sha: %s\n---\n' "$BASE_SHA" "$HEAD_SHA" > "$W/0001/merge-20261109-120000.md"
printf -- '---\ntype: review\noutcome: rejected\n---\n' > "$W/0001/review-20261109-110000.md"
printf -- '---\ntype: review\noutcome: approved\n---\n' > "$W/0001/review-20261109-113000.md"
printf -- '---\ntype: validation\noutcome: failed\n---\n' > "$W/0001/validation-20261109-100000.md"
printf -- '---\ntype: merge\ntimestamp: 20261109-130000\noutcome: success\n---\n' > "$W/0002/merge-20261109-130000.md"
printf '%s\n' \
  '{"task":"0001","role":"coder","pool":"subscription:anthropic","billing":"subscription","cost_usd":0.5,"estimated_cost_usd":0.4,"event":"e"}' \
  '{"task":"0001","role":"reviewer","pool":"subscription:anthropic","billing":"subscription","cost_usd":null,"estimated_cost_usd":0.25,"event":"e"}' \
  '{"task":"0001","role":"reviewer","pool":"api:openai","billing":"api","cost_usd":null,"estimated_cost_usd":null,"event":"e"}' \
  '{"task":"0001","role":"conductor","pool":"api:anthropic","billing":"api","cost_usd":0.1,"event":"e"}' \
  '{"task":"0002","role":"coder","pool":"api:anthropic","billing":"api","cost_usd":1,"event":"e"}' \
  '{"record":"allowance","task":"0001"}' > "$CONDUCTOR_DIR/usage.jsonl"

R1="$("$SCRIPTS_DIR/task-record.sh" 0001 --print)"
f() { jq -r "$1" <<< "$R1"; }

section "1 · A task's record: size from the two shas, with the branch deleted"
assert_eq "it is a task record"       "$(f .record)" "task"
assert_eq "two commits"               "$(f .git.commits)" "2"
assert_eq "lines added"               "$(f .git.lines_added)" "4"
assert_eq "no lines removed"          "$(f .git.lines_removed)" "0"
assert_eq "files touched"             "$(f '.files | join(",")')" "a,b"
assert_eq "the weight is the task's own" "$(f .weight)" "3"

section "2 · Rework, steps and cost, with pools kept apart"
assert_eq "one review rejected"       "$(f .rework.review_rejected)" "1"
assert_eq "one validation failed"     "$(f .rework.validation_failed)" "1"
assert_eq "rounds add up"             "$(f .rework.rounds)" "2"
assert_eq "steps leave out the conductor" "$(f .steps)" "3"
assert_eq "the allowance record is not a step" "$(f '.steps_by_role.coder')" "1"
assert_eq "one row per pool" "$(f '.cost | length')" "3"
assert_eq "reported dollars in the subscription pool" "$(f '.cost[] | select(.pool == "subscription:anthropic") | .reported_usd')" "0.5"
assert_eq "estimated only where nothing was reported" "$(f '.cost[] | select(.pool == "subscription:anthropic") | .estimated_usd')" "0.25"
assert_eq "no cost is unknown, never free" "$(f '.cost[] | select(.pool == "api:openai") | .unknown')" "1"

section "3 · No shas: the size is unknown, not zero"
R2="$("$SCRIPTS_DIR/task-record.sh" 0002 --print)"
assert_eq "git says why it is unknown" "$(jq -r '.git.unknown' <<< "$R2")" "the merger noted no base-sha and head-sha"
assert_eq "no weight is null"          "$(jq -r '.weight' <<< "$R2")" "null"
assert_eq "no files"                   "$(jq -r '.files | length' <<< "$R2")" "0"

section "4 · It appends to the log, and the summary groups by weight"
"$SCRIPTS_DIR/task-record.sh" 0001
"$SCRIPTS_DIR/task-record.sh" 0002
"$SCRIPTS_DIR/task-record.sh" 0001   # a handler retry: it must not add a second record
assert_eq "two task records in the log" "$(jq -c 'select(.record == "task")' "$CONDUCTOR_DIR/usage.jsonl" | wc -l | tr -d ' ')" "2"
OUT="$TMP/out"
"$SCRIPTS_DIR/usage-summary.sh" --by weight --by tasks > "$OUT"
has 'By weight' "a section by weight"
has '^3 +4 ' "the four attempts of weight 3 (the conductor's included)"
has 'no weight' "a task with no weight is its own row"
has 'Tasks, by weight' "a section of the task records"
has '\[1\]' "a task of unknown size is counted"

section "5 · Combining runs"
COMB="$TMP/combined.jsonl"
"$SCRIPTS_DIR/usage-combine.sh" --into "$COMB" --run run-a > /dev/null
assert_eq "every line is copied with its run" "$(jq -r '.run' "$COMB" | sort -u)" "run-a"
N="$(wc -l < "$COMB" | tr -d ' ')"
"$SCRIPTS_DIR/usage-combine.sh" --into "$COMB" --run run-a > /dev/null
assert_eq "the same run twice adds nothing" "$(wc -l < "$COMB" | tr -d ' ')" "$N"
"$SCRIPTS_DIR/usage-combine.sh" --into "$COMB" --run run-b > /dev/null
assert_eq "a second run is added" "$(jq -r '.run' "$COMB" | sort -u | tr '\n' ' ')" "run-a run-b "
"$SCRIPTS_DIR/usage-summary.sh" --file "$COMB" --by tasks > "$OUT"
has '^3 +2 ' "the summary reads many runs: two tasks of weight 3"

section "6 · Task ids repeat across runs: a weight belongs to its own run's task"
MIX="$TMP/mix.jsonl"
printf '%s\n' \
  '{"run":"r1","task":"0001","role":"coder","cost_usd":1,"pool":"api:x","billing":"api","event":"e"}' \
  '{"run":"r1","record":"task","task":"0001","weight":1,"steps":1,"rework":{"rounds":0},"git":{"lines_added":1,"lines_removed":0,"files":1}}' \
  '{"run":"r2","task":"0001","role":"coder","cost_usd":2,"pool":"api:x","billing":"api","event":"e"}' \
  '{"run":"r2","record":"task","task":"0001","weight":5,"steps":1,"rework":{"rounds":0},"git":{"lines_added":1,"lines_removed":0,"files":1}}' > "$MIX"
"$SCRIPTS_DIR/usage-summary.sh" --file "$MIX" --by weight > "$OUT"
has '^1 +1 +\$1\.0000' "run r1's attempt is weight 1"
has '^5 +1 +\$2\.0000' "run r2's attempt is weight 5"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All task-record tests passed."; else echo "$FAILS failed." >&2; exit 1; fi
