#!/usr/bin/env bash
# Resolve the kanban stage list for the active topology.
#
# The runtime task-* scripts (task-move, task-replay, task-list, task-timing)
# each used to carry a private hardcoded copy of the software-dev stage list.
# This is its single source of truth — the same "read the active topology, fall
# back to a named default when none is present" pattern that
# integration-resolve.sh applies to the integration field.
#
# Sourced (not executed) — it defines a function and a DEFAULT_TOPOLOGY constant
# in the caller's shell. It self-locates via BASH_SOURCE, so callers need not
# pass their own SCRIPTS_DIR.
#
#   topology_stages [conductor_dir]   print the ordered stage list, one per line

_SR_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Topology assumed when no project topology is present (e.g. task-create before
# swarm-start, or a standalone test harness). The default owns its own stage
# list — software-dev.json — so the list is never re-hardcoded here.
DEFAULT_TOPOLOGY="software-dev"

# topology_stages [conductor_dir]
#   Print the active topology's ordered stages, one per line. Reads
#   <conductor_dir>/topology.json (copied in by swarm-start); falls back to the
#   DEFAULT_TOPOLOGY when that file is absent.
topology_stages() {
  local conductor_dir="${1:-${CONDUCTOR_DIR:-.conductor}}"
  local topology_json="$conductor_dir/topology.json"
  if [[ -f "$topology_json" ]]; then
    "$_SR_SCRIPTS_DIR/topology-load.sh" stages "$topology_json"
  else
    "$_SR_SCRIPTS_DIR/topology-load.sh" stages "$DEFAULT_TOPOLOGY"
  fi
}
