#!/usr/bin/env bash
set -euo pipefail
# Shut the swarm down once the project is complete. Called by the on-merge-success
# handler.
#
# Usage: conductor-shutdown.sh
# Env:   CONDUCTOR_DIR (default: .conductor)
#        CONDUCTOR_LOOP  set by conductor-loop.sh
#
# It closes the architect window and stops the kanban server either way. The
# conductor's own window is the difference. In an interactive conductor the handler
# closes it, as before. Under conductor-loop.sh the handler runs inside that window,
# so closing it would kill the loop before it marked the event done; the loop owns its
# own exit, and this only asks for it by writing a flag the loop checks.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

echo "Shutting down swarm."

tmux kill-window -t "swarm:architect" 2>/dev/null || true

pid="$(cat "$CONDUCTOR_DIR/kanban-server.pid" 2>/dev/null || true)"
if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi

if [[ -n "${CONDUCTOR_LOOP:-}" ]]; then
  touch "$CONDUCTOR_DIR/shutdown-requested"
  echo "Shutdown requested; the loop exits after this event."
else
  tmux kill-window -t "swarm:conductor"
fi
