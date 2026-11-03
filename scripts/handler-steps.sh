#!/usr/bin/env bash
# The steps a script handler shares with its siblings. on-review-approved and
# on-validation-passed repeat the same four (close the finishing worker's window,
# compute the locks guard, route, move and start the next stage); here they are once.
#
# Sourced (not executed) by a handler under scripts/handlers/. It needs what the loop
# gives a handler: CONDUCTOR_DIR set, and the scripts on PATH. It defines:
#
#   close_worker_window <task>      close the tmux window named <role>-<task>; always
#                                   returns 0, a missing window is not an error
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
#   route_task <task> <event> [guard=value...]
#                                   ask the topology where the event sends the task,
#                                   move it there and start the stage. Sets ROUTED_DEST.
#                                   Returns 1, moving nothing, if there is no route; a
#                                   failed move does not start the stage
#
# Callers use these under `set -e`; a failing step ends the handler and so is retried or
# halted by the loop.

# shellcheck source=scripts/frontmatter.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter.sh"

# shellcheck disable=SC2034  # set for the handler that sources this file
ROUTED_DEST=""

close_worker_window() { # <task>
  local win
  win="$(tmux list-windows -t swarm -F '#{window_name}' 2> /dev/null | grep -E -- "-$1\$" | head -1 || true)"
  [[ -z "$win" ]] || tmux kill-window -t "swarm:$win" 2> /dev/null || true
  return 0
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
