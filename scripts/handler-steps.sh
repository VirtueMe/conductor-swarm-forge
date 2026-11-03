#!/usr/bin/env bash
# The steps a script handler shares with its siblings. on-review-approved,
# on-validation-passed and on-validation-failed repeat the same few (close the finishing
# worker's window, compute the locks guard, route, move and start the next stage); here they
# are once.
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

deps_done() { # <task>
  local file inline dep
  file="$CONDUCTOR_DIR/tasks/$1.md"
  if [[ ! -f "$file" ]]; then
    echo "deps_done: no task file for $1 ($file), so its dependencies are unknown" >&2
    return 1
  fi
  inline="$(fm_field "$file" depends-on)"
  if [[ -n "$inline" && "$inline" != "[]" ]]; then
    echo "deps_done: task $1 writes depends-on as an inline list ($inline); use one '  - id' line per task" >&2
    return 1
  fi
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ -f "$CONDUCTOR_DIR/kanban/done/$dep.md" ]] || { echo pending; return 0; }
  done < <(fm_list "$file" depends-on)
  echo all-done
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
