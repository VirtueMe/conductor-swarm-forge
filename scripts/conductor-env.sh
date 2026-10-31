#!/usr/bin/env bash
# The environment a conductor process needs so the conductor skills run as written.
#
# The skills call scripts by bare name (task-move.sh, topology-load.sh) and use
# $CONDUCTOR_DIR. A per-event dispatch has no briefing step to substitute paths into
# the text, so the dispatcher sets the environment instead.
#
# Sourced (not executed). It defines one function:
#
#   conductor_env <conductor_dir>
#     Exports CONDUCTOR_DIR (absolute), SCRIPTS_DIR (the directory this file is in)
#     and PATH with the scripts directory first. Calling it twice leaves PATH as it
#     was after the first call. Returns 1 if <conductor_dir> is not a directory.
#     Per-event variables (TASK_ID, ARTIFACT) are the dispatcher's to set.

_CE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

conductor_env() {
  local dir="${1:?Usage: conductor_env <conductor_dir>}"
  [[ -d "$dir" ]] || { echo "conductor_env: not a directory: $dir" >&2; return 1; }
  CONDUCTOR_DIR="$(cd "$dir" && pwd)"
  SCRIPTS_DIR="$_CE_SCRIPTS_DIR"
  case ":$PATH:" in
    *":$SCRIPTS_DIR:"*) ;;
    *) PATH="$SCRIPTS_DIR:$PATH" ;;
  esac
  export CONDUCTOR_DIR SCRIPTS_DIR PATH
}
