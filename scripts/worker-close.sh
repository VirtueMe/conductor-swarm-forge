#!/usr/bin/env bash
set -euo pipefail
# Close the finishing worker's tmux window and record what the worker spent.
#
# Usage: worker-close.sh <task>
# Env:   CONDUCTOR_DIR (default: .conductor)
#        WORKER_CLOSE_WAIT  seconds to give a harness that writes its cost on exit (default 3)
#
# The window is named <role>-<task>, so it is found by the task id rather than by assuming which
# role just finished. The window is closed first and read after: Claude Code writes its cost
# only when it exits, and it exits because the window closed. worker-usage.sh then appends the
# worker's line to usage.jsonl, and reads as interrupted any other worker whose window is gone.
#
# Always exits 0. A missing window is not an error, and a reading that fails must not stop the
# handler that closed the worker: the usage log is a convenience.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

main() {
  local task="${1:?Usage: worker-close.sh <task>}" win role=""
  win="$(tmux list-windows -t swarm -F '#{window_name}' 2> /dev/null | grep -E -- "-$task\$" | head -1 || true)"
  if [[ -n "$win" ]]; then
    tmux kill-window -t "swarm:$win" 2> /dev/null || true
    role="${win%-"$task"}"
  fi

  # Nothing to read for a task that never had a worker: no window, and no record of one.
  if [[ -n "$role" ]] || compgen -G "$CONDUCTOR_DIR/workers/*-$task.json" > /dev/null; then
    "$SCRIPTS_DIR/worker-usage.sh" read "$task" --wait "${WORKER_CLOSE_WAIT:-3}" ${role:+--role "$role"} \
      || echo "worker-close.sh: could not record the usage of the worker for task $task" >&2
  fi
  "$SCRIPTS_DIR/worker-usage.sh" sweep \
    || echo "worker-close.sh: could not sweep the workers whose windows are gone" >&2
  return 0
}

main "$@"
