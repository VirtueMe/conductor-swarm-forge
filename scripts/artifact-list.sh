#!/usr/bin/env bash
# List a task's work artifacts oldest first.
#
# Artifact files are named <type>-<timestamp>.md, so a glob orders them by type
# and only by time within a type. Anything that replays or renders a task's
# history must sort on the timestamp field instead; this is the one place that
# does it, shared by task-replay.sh and import-github.sh.
#
# Sourced (not executed). Needs CONDUCTOR_DIR set in the caller's shell.
#
#   type_rank <type>        print the type's lifecycle rank (0 = earliest)
#   list_artifacts <task>   print "<timestamp>|<rank>|<name>|<path>" per artifact,
#                           sorted by timestamp, then lifecycle rank, then name

# shellcheck source=scripts/frontmatter.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter.sh"

# Same-second artifacts are ordered by lifecycle, then by name.
type_rank() {
  case "$1" in
    card) echo 0 ;; assigned) echo 1 ;; progress) echo 2 ;; drift) echo 3 ;;
    signal) echo 4 ;; review) echo 5 ;; merge) echo 6 ;; moved) echo 7 ;;
    done) echo 8 ;; *) echo 9 ;;
  esac
}

list_artifacts() { # <task id> -> "<timestamp>|<rank>|<name>|<path>"
  local dir="$CONDUCTOR_DIR/work/$1" f name type ts
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    type="$(fm_field "$f" type)"
    ts="$(fm_field "$f" timestamp)"
    [[ -n "$ts" ]] || { ts="${name#*-}"; ts="${ts%.md}"; }
    printf '%s|%s|%s|%s\n' "$ts" "$(type_rank "$type")" "$name" "$f"
  done | sort
}
