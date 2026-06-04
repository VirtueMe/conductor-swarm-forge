#!/usr/bin/env bash
set -euo pipefail

# Print the resource ids currently locked by in-flight consolidations, one per
# line. Locking is integration-specific, so this delegates to the active
# integration adapter's `integration_locks`. Defaults to git when no topology is
# present (e.g. standalone test harnesses), preserving the original behavior.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
TOPOLOGY_JSON="$CONDUCTOR_DIR/topology.json"

# Assumed integration when no topology is present (e.g. standalone test
# harnesses) — git was the only model before topologies existed. Named because
# this assumption outlives the test-harness reason that birthed it.
DEFAULT_INTEGRATION="git"

INTEGRATION="$DEFAULT_INTEGRATION"
if [[ -f "$TOPOLOGY_JSON" ]]; then
  INTEGRATION=$("$SCRIPTS_DIR/topology-load.sh" integration "$TOPOLOGY_JSON")
fi

INTEGRATION_FILE="$ROOT_DIR/integrations/${INTEGRATION}.sh"
[[ -f "$INTEGRATION_FILE" ]] || { echo "Integration adapter not found: $INTEGRATION_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$INTEGRATION_FILE"

integration_locks
