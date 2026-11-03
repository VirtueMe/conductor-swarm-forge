#!/usr/bin/env bash
# The startup reconcile as a script: the mechanical steps of skills/conductor/reconcile.md, with
# no model. The loop runs it first on every start, with CONDUCTOR_DIR set and the scripts on
# PATH. There is no artifact and no task for this event, so TASK_ID, TASK_FILE and ARTIFACT are
# not set.
#
#   2. register the tasks that have no card (into backlog)
#   3. unblock the backlog cards whose dependencies are all done (into ready)
#   4. resume interrupted work: respawn a worker whose window is gone (auto stage), or notify
#      again where the human's inbox file is gone (manual stage)
#   5. start the entry stage of every card in ready
#
# Every step acts only on what is missing, so running it again changes nothing. The order is the
# skill's: a task registered in step 2 can be unblocked in step 3 and started in step 5, in one
# run.
# The skill's task-list.sh steps (1 and 6) only print the board for a model to read.

set -euo pipefail

# shellcheck source=scripts/handler-steps.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../handler-steps.sh"

register_untracked
unblock_ready
resume_interrupted
start_ready
