#!/usr/bin/env bash
set -euo pipefail

# Stops the kanban board server for a given project directory.
# Usage:
#   scripts/swarm-stop.sh [target-dir]

TARGET_DIR="${1:-$(pwd)}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
PID_FILE="$TARGET_DIR/$CONDUCTOR_DIR/kanban-server.pid"
PORT_FILE="$TARGET_DIR/$CONDUCTOR_DIR/kanban-server.port"

if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "unknown")
  if kill "$PID" 2>/dev/null; then
    echo "Kanban server stopped (pid $PID, was on port $PORT)"
  else
    echo "Kanban server was not running (pid $PID)"
  fi
  rm -f "$PID_FILE" "$PORT_FILE"
else
  echo "No kanban server PID file found at $PID_FILE"
fi
