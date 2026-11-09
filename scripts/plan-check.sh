#!/usr/bin/env bash
set -euo pipefail
# Check the architect's plan: the tasks in $CONDUCTOR_DIR/tasks, as data, before anyone relies on them.
#
# Usage: plan-check.sh [--json]
# Env:   CONDUCTOR_DIR (default: .conductor)
#        PLAN_CHECK_MAX_DESCRIPTION  characters of description after which a task is called too large
#                                    to review (default 1500)
#
# Report only. It moves no card, creates no task and holds nothing back: the architect runs it after
# creating the tasks (skills/architect/on-brief.md), and a person can run it any time. Exit status is
# 0 if the plan has no error (warnings do not count), 1 if it has one, 3 if jq is missing.
#
# Errors (the plan will not work as written):
#   empty-plan            there are no tasks
#   dangling-dependency   a task depends on an id that is not a task
#   dependency-cycle      tasks wait on each other, so none of them can start
#   feature-no-tests      a feature task whose description does not ask for tests and that does not
#                         depend on a test task: it reaches validation with no tests (run #68d, and
#                         the 11 failed validations of the second real run). The message names the later
#                         test task that waits on it, if there is one: that is the usual shape of the fault
# Warnings (probably wrong, a person decides):
#   test-covers-nothing   a test task that depends on nothing and that nothing waits on: it tests nothing
#                         in the plan (a test task a feature waits on is tests-first, and is fine)
#   task-too-large        a description longer than the limit above: likely more than one coder session
#
# Not checked here: whether the plan covers the brief. That takes judgment, not a script.
# A description counts as asking for tests if it contains the word "test" or "tests".

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
MAX_DESCRIPTION="${PLAN_CHECK_MAX_DESCRIPTION:-1500}"
JSON=0
case "${1:-}" in
  --json) JSON=1 ;;
  -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "Usage: plan-check.sh [--json]" >&2; exit 1 ;;
esac

command -v jq > /dev/null 2>&1 || { echo "plan-check.sh needs jq" >&2; exit 3; }
# shellcheck source=scripts/frontmatter.sh
source "$SCRIPTS_DIR/frontmatter.sh"

TASKS_DIR="$CONDUCTOR_DIR/tasks"

# One JSON line per task: id, type, title, depends-on, and its description (the coder's whole brief).
rows="$(
  for f in "$TASKS_DIR"/[0-9]*.md; do
    [[ -f "$f" ]] || continue
    id="${f##*/}"; id="${id%.md}"
    deps="$(fm_list "$f" depends-on | jq -R . | jq -sc .)"
    # fm_list prints nothing for the inline `depends-on: []`, and jq -s of nothing is [], so no dependency
    desc="$(fm_body "$f" | awk '/^## Acceptance Criteria/{exit} {print}')"
    jq -nc --arg id "$id" --arg type "$(fm_field "$f" type)" --arg title "$(fm_field "$f" title)" \
      --argjson deps "$deps" --arg desc "$desc" '{id: $id, type: $type, title: $title, deps: $deps, desc: $desc}'
  done
)"

# An empty $rows is no tasks at all: with --slurp jq still runs the program once, on [].
report="$(jq -sc --argjson max "$MAX_DESCRIPTION" '
  . as $tasks
  | ($tasks | map(.id)) as $ids
  | def finding($sev; $code; $task; $msg): {severity: $sev, code: $code, task: $task, message: $msg};
    def is_test($id): $tasks | any(.id == $id and .type == "test");
    [
      ( if ($tasks | length) == 0 then finding("error"; "empty-plan"; null; "there are no tasks") else empty end ),
      ( $tasks[] | . as $t | $t.deps[] | select(. as $d | $ids | index($d) | not)
        | finding("error"; "dangling-dependency"; $t.id; "depends on \(.), which is not a task") ),
      # Kahn: peel off the tasks whose (existing) dependencies are all gone; what is left waits on a cycle
      ( ( { left: ($tasks | map({id, deps: (.deps | map(select(. as $d | $ids | index($d))))})) }
          | until( (.left | map(select(.deps | length == 0)) | length) == 0;
                   ([.left[] | select(.deps | length == 0) | .id]) as $done
                   | .left |= (map(select(.deps | length > 0) | .deps -= $done)) )
          | .left | map(.id) ) as $stuck
        | if ($stuck | length) > 0
          then finding("error"; "dependency-cycle"; null; "tasks \($stuck | join(", ")) wait on each other, or on a cycle, and can never start")
          else empty end ),
      ( $tasks[] | select(.type == "feature")
        | select((.desc | test("\\btests?\\b"; "i")) | not)
        | select(.deps | any(is_test(.)) | not)
        | . as $t
        | ([$tasks[] | select(.type == "test" and (.deps | index($t.id))) | .id]) as $later
        | finding("error"; "feature-no-tests"; $t.id;
            "a feature whose description does not ask for tests and that depends on no test task: it reaches validation with nothing to run"
            + (if ($later | length) > 0 then "; its tests are in task \($later | join(", ")), which waits on it" else "" end)) ),
      ( $tasks[] | select(.type == "test" and (.deps | length) == 0) | . as $t
        | select([$tasks[] | select(.deps | index($t.id))] | length == 0)
        | finding("warning"; "test-covers-nothing"; .id; "a test task that depends on nothing and that nothing waits on tests nothing in the plan") ),
      ( $tasks[] | select((.desc | length) > $max)
        | finding("warning"; "task-too-large"; .id; "the description is \(.desc | length) characters (limit \($max)): likely more than one coder session") )
    ]' <<< "$rows")"

errors="$(jq '[.[] | select(.severity == "error")] | length' <<< "$report")"
if [[ "$JSON" -eq 1 ]]; then
  echo "$report"
else
  count=0
  [[ -z "$rows" ]] || count="$(jq -s 'length' <<< "$rows")"
  if [[ "$(jq length <<< "$report")" -eq 0 ]]; then
    echo "Plan: $count tasks, no findings."
  else
    echo "Plan: $count tasks, $errors error(s), $(jq '[.[] | select(.severity == "warning")] | length' <<< "$report") warning(s)."
    jq -r '.[] | "  \(.severity)\t\(.code)\t\(.task // "-")\t\(.message)"' <<< "$report" | column -t -s $'\t' 2> /dev/null \
      || jq -r '.[] | "  \(.severity) \(.code) \(.task // "-") \(.message)"' <<< "$report"
  fi
fi
[[ "$errors" -eq 0 ]]
