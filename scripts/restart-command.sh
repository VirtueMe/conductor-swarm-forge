#!/usr/bin/env bash
# The command that starts the conductor loop again, as one line that can be pasted.
#
# Sourced (not executed).
#
#   loop_env_assignments
#     Prints the settings the loop is started with, as shell words each preceded by a space, for
#     `env`: every exported CONDUCTOR_* and PI_ABORT_GRACE variable, except CONDUCTOR_DIR (given
#     apart) and CONDUCTOR_LOOP (the loop sets it itself). Values are quoted (printf %q), so
#     spaces, quotes and newlines survive. Used for the window swarm-start.sh opens and for the
#     command printed when the loop halts, so the two cannot differ.
#
#   loop_restart_command <project dir> <conductor dir> <scripts dir>
#     Prints: cd <project dir> && env CONDUCTOR_DIR=<conductor dir> <settings> <scripts dir>/conductor-loop.sh
#     The ledger, the board and the usage log are files, so running the loop again resumes the
#     swarm: the startup reconcile picks up work that is unblocked and the event that halted the
#     loop is retried first.

loop_env_assignments() {
  local name out=""
  while IFS= read -r name; do
    case "$name" in CONDUCTOR_DIR|CONDUCTOR_LOOP) continue ;; esac
    out+=" $(printf '%q' "$name=${!name}")"
  done < <(compgen -e | grep -E '^(CONDUCTOR_[A-Z_]+|PI_ABORT_GRACE)$' || true)
  printf '%s' "$out"
}

loop_restart_command() { # <project dir> <conductor dir> <scripts dir>
  printf 'cd %q && env CONDUCTOR_DIR=%q%s %q\n' "$1" "$2" "$(loop_env_assignments)" "$3/conductor-loop.sh"
}
