#!/usr/bin/env bash
# Resolve (and optionally source) the integration adapter for a topology.
#
# The "read the topology's integration field -> build integrations/<name>.sh ->
# check it exists -> source it" sequence was duplicated across worker-spawn.sh,
# task-locks.sh, and swarm-start.sh. This is its single source of truth.
#
# Sourced (not executed) — it defines functions and a DEFAULT_INTEGRATION
# constant in the caller's shell. It self-locates via BASH_SOURCE, so callers
# need not pass their own SCRIPTS_DIR/ROOT_DIR.
#
#   integration_file <topology_json>      print the adapter path (no side effects)
#   source_integration <topology_json>    source the adapter into the caller

_IR_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IR_ROOT_DIR="$(cd "$(dirname "$_IR_SCRIPTS_DIR")" && pwd)"

# Assumed integration when no topology is present (e.g. standalone test
# harnesses) — git was the only model before topologies existed. Named because
# this assumption outlives the test-harness reason that birthed it.
DEFAULT_INTEGRATION="git"

# integration_file <topology_json>
#   Print the path to the active integration adapter. Reads the topology's
#   `integration` field, falling back to DEFAULT_INTEGRATION when the topology
#   file is absent. Returns non-zero (message on stderr) if the resolved adapter
#   does not exist — callers use this as the fail-fast existence check.
integration_file() {
  local topology_json="$1"
  local integration="$DEFAULT_INTEGRATION"
  if [[ -f "$topology_json" ]]; then
    integration=$("$_IR_SCRIPTS_DIR/topology-load.sh" integration "$topology_json")
  fi
  local file="$_IR_ROOT_DIR/integrations/${integration}.sh"
  [[ -f "$file" ]] || { echo "Integration adapter not found: $file" >&2; return 1; }
  printf '%s\n' "$file"
}

# source_integration <topology_json>
#   Source the active integration adapter into the caller's shell, making its
#   integration_* contract functions available.
source_integration() {
  local file
  file=$(integration_file "$1") || return 1
  # shellcheck source=/dev/null
  source "$file"
}
