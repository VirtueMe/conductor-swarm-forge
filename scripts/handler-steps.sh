#!/usr/bin/env bash
# The steps a script handler shares with its siblings. on-review-approved,
# on-validation-passed and on-validation-failed repeat the same few (close the finishing
# worker's window, compute the locks guard, route, move and start the next stage); here they
# are once.
#
# Sourced (not executed) by a handler under scripts/handlers/. It needs what the loop
# gives a handler: CONDUCTOR_DIR set, and the scripts on PATH. It defines:
#
#   close_worker_window <task>      close the tmux window named <role>-<task> and record what the
#                                   worker spent (worker-close.sh); always returns 0, a missing
#                                   window is not an error
#   card_field <task> <field>       print a field of the task's current card (its type, say).
#                                   Fails closed: with no card, or an empty field, it prints
#                                   nothing, says why on stderr and returns 1. A missing type
#                                   would otherwise route as "not a chore" and send a task to
#                                   review without anyone having decided it
#   locks_guard <task>              print "free" or "held": whether any file in the
#                                   task's files-changed is locked by an active merge.
#                                   Fails closed: if it cannot tell (no card, or
#                                   task-locks.sh fails) it prints nothing, says why on
#                                   stderr and returns 1, so the handler stops. A model
#                                   once read a failing task-locks.sh as "free" and let
#                                   a merge go ahead on a guard that had not run
#   config_field <name>             print the value of a key in the project's config.md (test-cmd,
#                                   say), the whole line after "name:" without its surrounding
#                                   spaces. Unlike the others it does not fail closed: an empty
#                                   value, a key the file lacks and no config file all print
#                                   nothing and return 0, because the topology reads "empty" as
#                                   "not configured" and that is a real answer, not an unknown.
#                                   Only a name that is not a plain key (letters, digits, - and _)
#                                   is a failure
#   deps_done <task>                print "all-done" or "pending": whether every task the task's
#                                   depends-on lists has a card in kanban/done/. No depends-on
#                                   (or an empty one) is all-done. Fails closed: with no task
#                                   file, or a depends-on written as an inline list (which the
#                                   list reader would take for empty and so for "no dependencies"),
#                                   it prints nothing, says why on stderr and returns 1, so a task
#                                   is never started early on a list nobody read. An ID with no card
#                                   at all is "pending", the same as one still in progress: a
#                                   mistyped ID keeps its task in backlog, and this is where to look
#   task_deps <task>                print the IDs the task's depends-on lists, one per line. The
#                                   same fail-closed rules as deps_done, which uses it
#   unblock_dependents <task>       for each task in backlog whose depends-on lists <task> and whose
#                                   dependencies are now all done, move it to ready and start the
#                                   entry stage. A backlog task whose depends-on cannot be read
#                                   (an inline list, say) stops it: skipping would leave a task
#                                   waiting forever on a list nobody read
#   release_merge_pending           for each task in merge-pending whose files are no longer locked,
#                                   move it to merging and start it. The lock set is read again
#                                   for every task, because starting a merge locks its files and
#                                   the next task may overlap it. A failing lock check stops it
#   register_untracked              for each task file with no card in any column, move it to backlog
#                                   (task-move.sh creates the card). Starts nothing
#   unblock_ready                   for each card in backlog whose depends-on are all done, move it to
#                                   ready. Moves only: start_ready starts them. Unlike
#                                   unblock_dependents it looks at every backlog card, not at the
#                                   dependents of one task. A card whose depends-on cannot be read
#                                   stops it, for the same reason
#   resume_interrupted              for each card in a working stage, check that what the stage is
#                                   waiting on exists: an auto stage needs the window <role>-<task>,
#                                   else the worker is spawned again; a manual stage needs a file
#                                   human-inbox/<task>-*.md, else the human is notified again. Cards
#                                   in holding columns are left alone
#   start_ready                     stage-start.sh for each card in ready: spawn the entry stage's
#                                   worker, or notify. stage-start.sh skips a task with a live worker
#   project_done                    return 0 if there is at least one task file and every task
#                                   file has a card in done, else 1. It compares task by task, not
#                                   by count, so a stray done card cannot make up for a missing one
#   progress_note <task> <label> <artifact>
#                                   write a progress note for the next worker: "conductor:
#                                   <label> — see <artifact>". The skills have the model
#                                   summarise the failure here; a script cannot, so it points
#                                   at the artifact, which the next worker's briefing already
#                                   carries in full. Returns 1 (no note) on an empty label or
#                                   artifact, or if task-signal.sh fails
#   route_task <task> <event> [guard=value...]
#                                   ask the topology where the event sends the task,
#                                   move it there and start the stage. Sets ROUTED_DEST.
#                                   Returns 1, moving nothing, if there is no route; a
#                                   failed move does not start the stage
#
# Callers use these under `set -e`; a failing step ends the handler and so is retried or
# halted by the loop.

# A handler that fails inside one of these steps used to end with an exit status and nothing else,
# and the loop could only report "last exit 1". The ERR trap prints the command that failed, on stderr,
# which the loop keeps as the last error. -E makes functions and subshells use it too. It fires where
# set -e would exit, so a failure the handler handles itself (|| true, an if, &&) says nothing.
set -E
_handler_step_failed() { echo "${0##*/}: \"$2\" exited $1" >&2; }
trap '_handler_step_failed "$?" "$BASH_COMMAND"' ERR

# shellcheck source=scripts/frontmatter.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter.sh"

# shellcheck disable=SC2034  # set for the handler that sources this file
ROUTED_DEST=""

close_worker_window() { # <task>
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worker-close.sh" "$1"
}

# The path of the task's current card, or nothing (returns 1) if it has none.
card_path() { # <task>
  local f
  for f in "$CONDUCTOR_DIR"/kanban/*/"$1".md; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

card_field() { # <task> <field>
  local card value
  if ! card="$(card_path "$1")"; then
    echo "card_field: no card for task $1, so its $2 is unknown" >&2
    return 1
  fi
  value="$(fm_field "$card" "$2")"
  if [[ -z "$value" ]]; then
    echo "card_field: the card for task $1 has no $2" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

locks_guard() { # <task>
  local card locked item
  if ! card="$(card_path "$1")"; then
    echo "locks_guard: no card for task $1, so its files are unknown" >&2
    return 1
  fi
  if ! locked="$(task-locks.sh)"; then
    echo "locks_guard: task-locks.sh failed; cannot tell whether task $1's files are locked" >&2
    return 1
  fi
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if grep -qxF -- "$item" <<< "$locked"; then echo held; return 0; fi
  done < <(fm_list "$card" files-changed)
  echo free
}

config_field() { # <name>
  if [[ ! "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "config_field: '${1:-}' is not a plain config key" >&2
    return 1
  fi
  [[ -f "$CONDUCTOR_DIR/config.md" ]] || return 0
  # The first "name:" line; no match is not an error. The config has no fixed shape (the loop's
  # own readers take it with or without frontmatter fences), so this reads lines, not frontmatter.
  sed -n "s/^$1:[[:space:]]*//p" "$CONDUCTOR_DIR/config.md" | sed -n '1s/[[:space:]]*$//p'
}

task_deps() { # <task>
  local file inline
  file="$CONDUCTOR_DIR/tasks/$1.md"
  if [[ ! -f "$file" ]]; then
    echo "task_deps: no task file for $1 ($file), so its dependencies are unknown" >&2
    return 1
  fi
  inline="$(fm_field "$file" depends-on)"
  if [[ -n "$inline" && "$inline" != "[]" ]]; then
    echo "task_deps: task $1 writes depends-on as an inline list ($inline); use one '  - id' line per task" >&2
    return 1
  fi
  fm_list "$file" depends-on
}

deps_done() { # <task>
  local deps dep
  deps="$(task_deps "$1")" || return 1
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ -f "$CONDUCTOR_DIR/kanban/done/$dep.md" ]] || { echo pending; return 0; }
  done <<< "$deps"
  echo all-done
}

unblock_dependents() { # <task>
  local card id deps dep listed
  for card in "$CONDUCTOR_DIR"/kanban/backlog/*.md; do
    [[ -f "$card" ]] || continue
    id="$(basename "$card" .md)"
    deps="$(task_deps "$id")" || return 1
    listed=false
    while IFS= read -r dep; do
      [[ "$dep" == "$1" ]] && listed=true
    done <<< "$deps"
    [[ "$listed" == true ]] || continue
    [[ "$(deps_done "$id")" == all-done ]] || continue
    task-move.sh "$id" ready || return 1
    stage-start.sh "$id" ready || return 1
  done
}

release_merge_pending() {
  local card id guard
  for card in "$CONDUCTOR_DIR"/kanban/merge-pending/*.md; do
    [[ -f "$card" ]] || continue
    id="$(basename "$card" .md)"
    guard="$(locks_guard "$id")" || return 1
    [[ "$guard" == free ]] || continue
    task-move.sh "$id" merging || return 1
    stage-start.sh "$id" merging || return 1
  done
}

register_untracked() {
  local file id
  for file in "$CONDUCTOR_DIR"/tasks/*.md; do
    [[ -f "$file" ]] || continue
    id="$(basename "$file" .md)"
    card_path "$id" > /dev/null && continue
    task-move.sh "$id" backlog || return 1
  done
}

unblock_ready() {
  local card id deps
  for card in "$CONDUCTOR_DIR"/kanban/backlog/*.md; do
    [[ -f "$card" ]] || continue
    id="$(basename "$card" .md)"
    deps="$(deps_done "$id")" || return 1
    [[ "$deps" == all-done ]] || continue
    task-move.sh "$id" ready || return 1
  done
}

resume_interrupted() {
  local card id stage role mode windows
  windows="$(tmux list-windows -t swarm -F '#{window_name}' 2> /dev/null || true)"
  for card in "$CONDUCTOR_DIR"/kanban/*/*.md; do
    [[ -f "$card" ]] || continue
    id="$(basename "$card" .md)"
    stage="$(basename "$(dirname "$card")")"
    role="$(topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$stage")" || return 1
    mode="$(topology-load.sh mode "$CONDUCTOR_DIR/topology.json" "$stage")" || return 1
    if [[ -n "$role" ]]; then
      grep -qxF -- "$role-$id" <<< "$windows" || worker-spawn.sh "$id" "$role" || return 1
    elif [[ "$mode" == manual ]]; then
      compgen -G "$CONDUCTOR_DIR/human-inbox/$id-*.md" > /dev/null 2>&1 \
        || task-notify.sh --task "$id" --stage "$stage" || return 1
    fi
  done
}

start_ready() {
  local card
  for card in "$CONDUCTOR_DIR"/kanban/ready/*.md; do
    [[ -f "$card" ]] || continue
    stage-start.sh "$(basename "$card" .md)" ready || return 1
  done
}

project_done() {
  local file found=false
  for file in "$CONDUCTOR_DIR"/tasks/*.md; do
    [[ -f "$file" ]] || continue
    found=true
    [[ -f "$CONDUCTOR_DIR/kanban/done/$(basename "$file")" ]] || return 1
  done
  [[ "$found" == true ]]
}

progress_note() { # <task> <label> <artifact>
  if [[ -z "${2:-}" || -z "${3:-}" ]]; then
    echo "progress_note: needs a label and an artifact" >&2
    return 1
  fi
  task-signal.sh --task "$1" --type progress --notes "conductor: $2 — see $3"
}

route_task() { # <task> <event> [guard=value...]
  local id="$1" event="$2"
  shift 2
  ROUTED_DEST=""
  local dest
  if ! dest="$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" "$event" "$@")" || [[ -z "$dest" ]]; then
    echo "route_task: no route for $event${*:+ ($*)}" >&2
    return 1
  fi
  # @escalate and @stay come back from the topology as they are: they mean "do not move the
  # card", which is a judgment this handler does not make.
  if [[ "$dest" == @* ]]; then
    echo "route_task: $event routes to $dest, which is not a stage; this handler cannot move the task" >&2
    return 1
  fi
  task-move.sh "$id" "$dest" || return 1
  stage-start.sh "$id" "$dest" || return 1
  # shellcheck disable=SC2034  # read by the handler that sourced this file
  ROUTED_DEST="$dest"
}
