#!/usr/bin/env bash
set -euo pipefail
# The plan hold (#188): while it is on, no task leaves backlog for a working stage, so the strategist
# can check the plan and write each task's strategy before any worker starts. Releasing it is the one
# way out, and release is all-or-nothing: it checks everything first and releases nothing if anything
# is wrong.
#
# Usage: plan-hold.sh hold            put the hold on (swarm-start does it when the workforce has a strategist)
#        plan-hold.sh status          print held or released, and exit 0 if held, 1 if not
#        plan-hold.sh release [--force]
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# release, in this order:
#   1. plan-check.sh: a plan with an error is not released (--force releases it anyway, for a person
#      who has read the report; warnings never hold it back)
#   2. every file in strategy/ is validated (task-strategy.sh validate), and must belong to a task. One
#      bad file and nothing at all applies: a half-applied strategy would skip a step for one task and
#      not another, and no one could say why
#   3. strategy/*.json is copied to strategy-released/: from then on that copy is the strategy
#      task-strategy.sh reads, so a later edit of a draft changes nothing for a run in flight
#   4. the hold file is removed, plan-released is written, and every backlog card whose dependencies are
#      done is released (the others wait for their dependencies, as always)
#
# The conductor's own steps (handler-steps.sh) honour the hold file: new-task, unblock_dependents,
# unblock_ready and the backlog check all leave backlog cards where they are while it exists. A design
# task still goes to done on arrival: nobody works on it, and it holds nothing back.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
export CONDUCTOR_DIR
HOLD="$CONDUCTOR_DIR/plan-hold"
RELEASED="$CONDUCTOR_DIR/plan-released"

die() { echo "plan-hold.sh: $*" >&2; exit 1; }

cmd_hold() {
  [[ -d "$CONDUCTOR_DIR" ]] || die "no conductor directory: $CONDUCTOR_DIR"
  date +%Y-%m-%dT%H:%M:%S > "$HOLD"
  rm -rf "$CONDUCTOR_DIR/strategy-released" "$RELEASED"
  echo "held"
}

cmd_status() {
  if [[ -f "$HOLD" ]]; then echo held; return 0; fi
  echo released; return 1
}

cmd_release() {
  local force=0 f task problems=0 report
  case "${1:-}" in --force) force=1 ;; "") ;; *) die "Usage: plan-hold.sh release [--force]" ;; esac
  [[ -f "$HOLD" ]] || die "nothing to release: the plan is not held"
  command -v jq > /dev/null 2>&1 || { echo "plan-hold.sh release needs jq" >&2; exit 3; }

  if ! report="$("$SCRIPTS_DIR/plan-check.sh" 2>&1)"; then
    if [[ "$force" -eq 1 ]]; then echo "plan-hold.sh: releasing despite plan errors (--force):" >&2; echo "$report" >&2
    else echo "$report" >&2; die "the plan has errors, so it is not released (fix it, or release --force)"; fi
  fi

  for f in "$CONDUCTOR_DIR"/strategy/*.json; do
    [[ -f "$f" ]] || continue
    task="$(basename "$f" .json)"
    if [[ ! -f "$CONDUCTOR_DIR/tasks/$task.md" ]]; then echo "$f: there is no task $task" >&2; problems=1; continue; fi
    "$SCRIPTS_DIR/task-strategy.sh" validate "$task" || problems=1
  done
  [[ "$problems" -eq 0 ]] || die "a strategy file is invalid: nothing is released and no strategy applies"

  if compgen -G "$CONDUCTOR_DIR/strategy/*.json" > /dev/null; then
    rm -rf "$CONDUCTOR_DIR/strategy-released"
    mkdir -p "$CONDUCTOR_DIR/strategy-released"
    cp "$CONDUCTOR_DIR"/strategy/*.json "$CONDUCTOR_DIR/strategy-released/"
  fi
  date +%Y-%m-%dT%H:%M:%S > "$RELEASED"
  rm -f "$HOLD"

  # shellcheck source=scripts/handler-steps.sh
  source "$SCRIPTS_DIR/handler-steps.sh"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    release_backlog_card "${line%% *}"
  done < <(stranded_backlog)
  echo "released"
}

main() {
  local cmd="${1:-}"; [[ $# -eq 0 ]] || shift
  case "$cmd" in
    hold)    cmd_hold ;;
    status)  cmd_status ;;
    release) cmd_release "$@" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: plan-hold.sh hold|status|release [--force]" >&2; exit 1 ;;
  esac
}

main "$@"
