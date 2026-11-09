#!/usr/bin/env bash
set -euo pipefail
# A task's strategy: which steps to skip and which model each role uses, as data the scripted
# conductor executes. Nothing here decides anything: whoever writes the file (the strategist,
# #188, or a person) decides, and this reads it, checks it and answers two questions for the conductor.
#
# Usage: task-strategy.sh show     <task>
#        task-strategy.sh validate <task> | --file <path>
#        task-strategy.sh skip     <task> <stage>
#        task-strategy.sh params   <task> <role> [<base-params-json>]
#        task-strategy.sh weight   <task>
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# The file is $CONDUCTOR_DIR/strategy/<task>.json, and a task with none runs exactly as before:
#
#   { "skip":    { "validation": "docs only: no test applies" },
#     "workers": { "reviewer": { "model": "claude-sonnet-4-6" } },
#     "weight":  3 }
#
#   skip     stage -> the reason. Only a stage the topology lists as `skippable` can be skipped; every
#            other stage is a floor step (review and merging in software-dev), and `skip` prints nothing
#            for it even if the file says otherwise, so a bad file cannot take the floor away. The reason
#            is required: it is written on the card when the step is skipped.
#   workers  role -> tuning merged over the workforce's params for that role, for this task only. Only
#            model and effort may be set; the adapter and the pool stay the workforce's.
#   weight   the planned weight of the task (a number): what task-record.sh files its cost against.
#
# show      prints the file, or {} if there is none.
# validate  checks the file against the topology ($CONDUCTOR_DIR/topology.json): exit 1 with one line
#           per problem, 0 if it is sound or there is no file.
# skip      prints the reason if the strategy skips <stage> (and the topology allows it), else nothing.
# params    prints the base params with the task's tuning for <role> merged over them.
#           Without a usable file it prints the base params unchanged: a broken strategy never stops a spawn.
# weight    prints the planned weight, or nothing.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
TOPOLOGY="$CONDUCTOR_DIR/topology.json"

die() { echo "task-strategy.sh: $*" >&2; exit 1; }
command -v jq > /dev/null 2>&1 || { echo "task-strategy.sh needs jq" >&2; exit 3; }

file_of() { echo "$CONDUCTOR_DIR/strategy/$1.json"; }

# The strategy as JSON: the file, or {} when there is none or it is not an object. A file that is not
# JSON reads as {} here (the conductor must carry on) and is reported by validate.
read_strategy() { # <task>
  local f
  f="$(file_of "$1")"
  [[ -s "$f" ]] && jq -ec 'if type == "object" then . else empty end' "$f" 2> /dev/null || echo '{}'
}

cmd_validate() { # <task> | --file <path>
  local f problems skippable roles
  if [[ "${1:-}" == --file ]]; then f="${2:?--file needs a path}"; else f="$(file_of "${1:?Usage: task-strategy.sh validate <task>}")"; fi
  [[ -e "$f" ]] || return 0
  jq -e 'type == "object"' "$f" > /dev/null 2>&1 || { echo "$f: not a JSON object" >&2; return 1; }
  if [[ -f "$TOPOLOGY" ]]; then
    skippable="$("$SCRIPTS_DIR/topology-load.sh" skippable "$TOPOLOGY" | jq -R . | jq -sc .)"
    roles="$("$SCRIPTS_DIR/topology-load.sh" roles "$TOPOLOGY" | jq -R . | jq -sc .)"
  else
    skippable='[]'; roles='[]'
  fi
  problems="$(jq -r --argjson skippable "$skippable" --argjson roles "$roles" '
    ( keys - ["skip", "workers", "weight", "task"] | map("unknown key: \(.)") ),
    ( if has("skip") then
        ( if (.skip | type) != "object" then ["skip must be an object (stage -> reason)"]
          else (.skip | to_entries | map(
            if (.key as $k | $skippable | index($k) | not)
              then "\(.key) cannot be skipped: it is a floor step (the topology lists as skippable: \($skippable | join(", ") | if . == "" then "none" else . end))"
            elif ((.value | type) != "string" or (.value | gsub("\\s"; "") | length) == 0)
              then "skipping \(.key) needs a reason, written on the card"
            else empty end)) end )
      else [] end ),
    ( if has("workers") then
        ( if (.workers | type) != "object" then ["workers must be an object (role -> tuning)"]
          else (.workers | to_entries | map(
            .key as $role
            | if ($roles | index($role) | not) then ["workers: \($role) is not a role of the topology (\($roles | join(", ")))"]
              elif (.value | type) != "object" then ["workers.\($role) must be an object"]
              else ( (.value | keys - ["model", "effort"] | map("workers.\($role): only model and effort can be set, not \(.)")),
                     (.value | to_entries | map(select(.key == "model" or .key == "effort")
                        | select((.value | type) != "string" or .value == "") | "workers.\($role): \(.key) must be a non-empty string")) ) end)
            | flatten) end )
      else [] end ),
    ( if has("weight") and ((.weight | type) != "number" or .weight < 0) then ["weight must be a number, zero or more"] else [] end )
    | .[]' "$f")"
  [[ -z "$problems" ]] && return 0
  while IFS= read -r line; do echo "$f: $line" >&2; done <<< "$problems"
  return 1
}

cmd_skip() { # <task> <stage>
  local task="${1:?Usage: task-strategy.sh skip <task> <stage>}" stage="${2:?missing stage}"
  # The floor is the topology's, not the file's: a stage it does not list is never skipped.
  [[ -f "$TOPOLOGY" ]] || return 0
  [[ -n "$("$SCRIPTS_DIR/topology-load.sh" skip-event "$TOPOLOGY" "$stage")" ]] || return 0
  read_strategy "$task" | jq -r --arg s "$stage" '.skip[$s]? | select(type == "string" and (gsub("\\s"; "") | length) > 0)'
}

cmd_params() { # <task> <role> [<base>]
  local task="${1:?Usage: task-strategy.sh params <task> <role> [<base-params-json>]}" role="${2:?missing role}" base="${3:-}"
  [[ -n "$base" ]] || base='{}'
  jq -e 'type == "object"' <<< "$base" > /dev/null 2>&1 || die "the base params are not a JSON object"
  read_strategy "$task" | jq -c --argjson base "$base" --arg r "$role" '
    $base + ((.workers[$r]? // {}) | if type == "object" then with_entries(select((.key == "model" or .key == "effort") and (.value | type) == "string" and .value != "")) else {} end)'
}

cmd_weight() { # <task>
  read_strategy "${1:?Usage: task-strategy.sh weight <task>}" | jq -r '.weight? | select(type == "number")'
}

main() {
  local cmd="${1:-}"; [[ $# -eq 0 ]] || shift
  case "$cmd" in
    show)     read_strategy "${1:?Usage: task-strategy.sh show <task>}" ;;
    validate) cmd_validate "$@" ;;
    skip)     cmd_skip "$@" ;;
    params)   cmd_params "$@" ;;
    weight)   cmd_weight "$@" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: task-strategy.sh show|validate|skip|params|weight ..." >&2; exit 1 ;;
  esac
}

main "$@"
