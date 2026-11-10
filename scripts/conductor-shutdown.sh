#!/usr/bin/env bash
set -euo pipefail
# Shut the swarm down once the project is complete. Called by the on-merge-success
# handler.
#
# Usage: conductor-shutdown.sh
# Env:   CONDUCTOR_DIR (default: .conductor)
#        CONDUCTOR_LOOP  set by conductor-loop.sh
#
# It closes the architect and strategist windows and stops the kanban server either
# way. The conductor's own window is the difference. In an interactive conductor the
# handler closes it, as before. Under conductor-loop.sh the handler runs inside that
# window, so closing it would kill the loop before it marked the event done; the loop owns its
# own exit, and this only asks for it by writing a flag the loop checks.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

echo "Shutting down swarm."

# The planning windows are closed and then read as finished: a shutdown is how they end (#198).
# Claude Code writes its cost only when it exits, which the closed window makes it do, so give it
# the same few seconds a closing worker gets. A swarm that never opened one has no record to read.
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
for role in architect strategist; do
  tmux kill-window -t "swarm:$role" 2>/dev/null || true
  if compgen -G "$CONDUCTOR_DIR/workers/$role-plan-$role.json" > /dev/null; then
    "$SCRIPTS_DIR/worker-usage.sh" read "plan-$role" --role "$role" --wait "${WORKER_CLOSE_WAIT:-3}" 2>/dev/null || true
  fi
done

# A worker whose window was closed by hand left no usage line; read what it left now, as
# interrupted, while the swarm still knows who it was.
"$SCRIPTS_DIR/worker-usage.sh" sweep 2>/dev/null || true

pid="$(cat "$CONDUCTOR_DIR/kanban-server.pid" 2>/dev/null || true)"
if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi

if [[ -n "${CONDUCTOR_LOOP:-}" ]]; then
  touch "$CONDUCTOR_DIR/shutdown-requested"
  echo "Shutdown requested; the loop exits after this event."
else
  tmux kill-window -t "swarm:conductor"
fi
