#!/usr/bin/env bash
set -euo pipefail
# Changes to the plan after it was released, and before it: proposed by the strategist, approved by the
# architect or a person, and capped (#188). The strategist decides nothing about the board itself: it
# writes a proposal here, and this counts it, keeps it, and tells the ones who approve.
#
# Usage: plan-revision.sh propose <task> <kind> <note>   a task parked after repeated failures: the plan's fault
#        plan-revision.sh reject  <note>                 the plan as the architect made it is not good enough
#        plan-revision.sh rounds  <task|plan>            how many rounds are used so far
#        plan-revision.sh resume  <task>                 send a parked task back to the coder, once a proposal exists
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# <kind> is one of:
#   fix-plan    change the task, or the tasks around it (the tests are a later task, say)
#   split       the task is too large: replace it by smaller ones
#   add-task    something the task needs is missing from the plan
#   ask-person  the strategist cannot tell, or the fault is not the plan's: a person decides.
#               It writes to human-inbox/ only and does not use up a round
#
# Rounds are capped, so that a plan that cannot be fixed does not go round for ever (as the 3-failure
# rule caps a task that cannot be fixed by the coder):
#   a task            at most max-replans proposals (config.md, default 2) of the first three kinds
#   the plan itself   at most max-plan-rejections rejections (config.md, default 2)
# Past the cap the call changes nothing, writes the note to human-inbox/ for a person and exits 1: only a
# person goes on from there. The round count is the number of files in $CONDUCTOR_DIR/revisions/ for the
# task (<task>-<n>.md, or plan-<n>.md), so there is no counter to get out of step with the proposals.
#
# propose and reject write the proposal, then a notice:
#   architect-inbox/  plan-change-<task>-<ts>.md (type: plan-change) or plan-rejected-<ts>.md: the
#                     architect approves it by doing it, or declines it by saying why
#   human-inbox/      a copy of either, as the validation-loop notice has: a person can always step in
# resume moves a task parked in validation to in-progress and starts the coder. It needs a proposal for
# the task (a plan changed for it) and is what the architect or a person runs once the plan is fixed.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
export CONDUCTOR_DIR
REVISIONS="$CONDUCTOR_DIR/revisions"

die() { echo "plan-revision.sh: $*" >&2; exit 1; }

# shellcheck source=scripts/handler-steps.sh
source "$SCRIPTS_DIR/handler-steps.sh"

cap_of() { # <config key> <default>
  local v
  v="$(config_field "$1")"
  if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else echo "$2"; fi
}

rounds_of() { # <key>
  local n=0 f
  for f in "$REVISIONS/$1"-[0-9]*.md; do [[ -f "$f" ]] && n=$(( n + 1 )); done
  echo "$n"
}

notice() { # <inbox> <file name> <type> <key> <round> <note>
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local file i=1
  mkdir -p "$CONDUCTOR_DIR/$1"
  file="$CONDUCTOR_DIR/$1/$2-$ts.md"
  # two notices in one second must not overwrite each other: a lost notice is a lost round
  while [[ -e "$file" ]]; do i=$(( i + 1 )); file="$CONDUCTOR_DIR/$1/$2-$ts-$i.md"; done
  printf -- '---\ntype: %s\ntask-id: %s\nround: %s\ntimestamp: %s\n---\n%s\n' "$3" "$4" "$5" "$ts" "$6" > "$file"
}

# Past the cap: nothing is recorded, a person is told, and the call fails.
over_cap() { # <key> <what> <cap> <note>
  notice human-inbox "plan-cap-$1" plan-cap "$1" "$3" "The strategist's limit of $3 $2 for $1 is used up, and it asked for another. A person decides now. What it wanted to say:
$4"
  die "$1 has used its $3 $2: a person has been told, and nothing more is proposed"
}

cmd_propose() { # <task> <kind> <note>
  local task="${1:?Usage: plan-revision.sh propose <task> <kind> <note>}" kind="${2:?missing kind}" note="${3:?missing note}" n cap
  [[ "$task" =~ ^[0-9]+$ ]] || die "not a task id: $task"
  [[ -f "$CONDUCTOR_DIR/tasks/$task.md" ]] || die "there is no task $task"
  case "$kind" in
    ask-person)
      notice human-inbox "ask-person-$task" ask-person "$task" 0 "$note"
      echo "asked a person about $task"; return 0 ;;
    fix-plan|split|add-task) ;;
    *) die "kind must be fix-plan, split, add-task or ask-person, not $kind" ;;
  esac
  n="$(rounds_of "$task")"; cap="$(cap_of max-replans 2)"
  [[ "$n" -lt "$cap" ]] || over_cap "$task" re-plans "$cap" "$note"
  n=$(( n + 1 ))
  mkdir -p "$REVISIONS"
  printf -- '---\ntype: plan-change\ntask-id: %s\nkind: %s\nround: %s\n---\n%s\n' "$task" "$kind" "$n" "$note" > "$REVISIONS/$task-$n.md"
  notice architect-inbox "plan-change-$task" plan-change "$task" "$n" "Kind: $kind (round $n of $cap)
$note

Approve it by making the change: edit the task files, or task-create.sh. Then send the parked task back with plan-revision.sh resume $task. To decline, say why to the person (human-inbox/)."
  notice human-inbox "plan-change-$task" plan-change "$task" "$n" "Kind: $kind (round $n of $cap)
$note"
  echo "round $n of $cap: $kind proposed for $task"
}

cmd_reject() { # <note>
  local note="${1:?Usage: plan-revision.sh reject <note>}" n cap
  n="$(rounds_of plan)"; cap="$(cap_of max-plan-rejections 2)"
  [[ "$n" -lt "$cap" ]] || over_cap plan "rejections" "$cap" "$note"
  n=$(( n + 1 ))
  mkdir -p "$REVISIONS"
  printf -- '---\ntype: plan-rejected\nround: %s\n---\n%s\n' "$n" "$note" > "$REVISIONS/plan-$n.md"
  notice architect-inbox plan-rejected plan-rejected plan "$n" "Rejection $n of $cap.
$note"
  echo "rejection $n of $cap sent to the architect"
}

cmd_resume() { # <task>
  local task="${1:?Usage: plan-revision.sh resume <task>}" card stage
  [[ "$(rounds_of "$task")" -gt 0 ]] || die "no plan change was proposed for $task, so it is not sent back on a plan's say-so"
  card="$(card_path "$task")" || die "task $task has no card"
  stage="$(basename "$(dirname "$card")")"
  [[ "$stage" == validation ]] || die "task $task is in $stage, not parked in validation: not touched"
  task-move.sh "$task" in-progress
  stage-start.sh "$task" in-progress
  task-signal.sh --task "$task" --type progress --notes "plan changed (revision $(rounds_of "$task")): sent back to the coder" > /dev/null
  echo "$task sent back to in-progress"
}

main() {
  local cmd="${1:-}"; [[ $# -eq 0 ]] || shift
  case "$cmd" in
    propose) cmd_propose "$@" ;;
    reject)  cmd_reject "$@" ;;
    rounds)  rounds_of "${1:?Usage: plan-revision.sh rounds <task|plan>}" ;;
    resume)  cmd_resume "$@" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: plan-revision.sh propose|reject|rounds|resume ..." >&2; exit 1 ;;
  esac
}

main "$@"
