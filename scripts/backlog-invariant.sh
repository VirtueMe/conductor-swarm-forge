#!/usr/bin/env bash
set -euo pipefail
# The invariant the loop checks after each event: no card sits in backlog while everything it
# depends on is done. A handler that moves a task to done without unblocking its dependents
# breaks it (#165 did), and nothing else notices until the next startup reconcile quietly
# repairs it. This finds such cards, heals each the way the reconcile does (move to ready, start
# the entry stage) and prints one line per card, so the caller can say so loudly:
#
#   <task> healed <dependency>...        released from backlog (to ready and started, or to done)
#   <task> failed release <dependency>... the move or the start failed
#
# A card whose task still has an event the loop has not handled is left alone: a task that was
# just created sits in backlog until its new-task handler has run, and that is not stranded.
#
# Usage: backlog-invariant.sh
# Env:   CONDUCTOR_DIR (default: .conductor)
# Exits 0 whatever it found; it is a check, not a gate.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
export CONDUCTOR_DIR

# shellcheck source=scripts/handler-steps.sh
source "$SCRIPTS_DIR/handler-steps.sh"

pending="$("$SCRIPTS_DIR/artifact-ledger.sh" unprocessed 2> /dev/null || true)"

stranded="$(stranded_backlog)"
[[ -n "$stranded" ]] || exit 0

while IFS= read -r line; do
  task="${line%% *}"
  deps="${line#"$task"}"; deps="${deps# }"
  grep -q -- "^$task/" <<< "$pending" && continue
  if release_backlog_card "$task" > /dev/null 2>&1; then
    echo "$task healed $deps"
  else
    echo "$task failed release $deps"
  fi
done <<< "$stranded"
exit 0
