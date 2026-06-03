#!/usr/bin/env bash
# Watches a directory for new files, printing each path as it appears.
# Uses fswatch if available, falls back to a polling loop.
#
# Usage: watch-dir.sh <directory> [interval-seconds]

set -euo pipefail

DIR="${1:?Usage: watch-dir.sh <directory> [interval]}"
INTERVAL="${2:-0.5}"

if command -v fswatch &>/dev/null; then
  fswatch -r --event Created --latency "$INTERVAL" "$DIR"
else
  # Polling fallback — no external dependencies
  SEEN=$(mktemp)
  trap 'rm -f "$SEEN" "$SEEN.new"' EXIT

  find "$DIR" -type f 2>/dev/null | sort > "$SEEN"

  while true; do
    sleep "$INTERVAL"
    find "$DIR" -type f 2>/dev/null | sort > "$SEEN.new"
    diff "$SEEN" "$SEEN.new" 2>/dev/null | grep '^>' | sed 's/^> //' || true
    mv "$SEEN.new" "$SEEN"
  done
fi
