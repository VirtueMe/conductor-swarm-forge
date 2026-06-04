#!/usr/bin/env bash
set -euo pipefail

# Print the resource ids currently locked by in-flight consolidations, one per
# line. Locking is integration-specific, so this delegates to the active
# integration adapter's `integration_locks`. Defaults to git when no topology is
# present (e.g. standalone test harnesses), preserving the original behavior.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
TOPOLOGY_JSON="$CONDUCTOR_DIR/topology.json"

# shellcheck source=scripts/integration-resolve.sh
source "$SCRIPTS_DIR/integration-resolve.sh"
source_integration "$TOPOLOGY_JSON" || exit 1

integration_locks
