#!/usr/bin/env bash
# Tests that task-replay.sh replays a task's artifacts oldest first. Artifact
# names are <type>-<timestamp>.md, so the file-name glob orders by type; replay
# has to order on the timestamp field instead, breaking same-second ties by
# lifecycle order. Runs the real task-replay.sh on hand-built artifacts; no
# tmux, no AI.
#
# Usage: scripts/test-task-replay.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work}
while IFS= read -r stage; do
  mkdir -p "$CONDUCTOR_DIR/kanban/$stage"
done < <("$SCRIPTS_DIR/topology-load.sh" stages software-dev)
cp "$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)" "$CONDUCTOR_DIR/topology.json"
"$SCRIPTS_DIR/task-create.sh" --title "Mixed" --type chore --description "x" > /dev/null
ID=0001
W="$CONDUCTOR_DIR/work/$ID"
rm -rf "$W"; mkdir -p "$W"

# artifact <type> <timestamp> [extra frontmatter line] [body]
artifact() {
  {
    printf -- '---\ntype: %s\ntimestamp: %s\n' "$1" "$2"
    [[ -n "${3:-}" ]] && printf '%s\n' "$3"
    printf -- '---\n\n%s\n' "${4:-$1 note}"
  } > "$W/$1-$2.md"
}

# The glob order of these names is assigned, card, moved, progress, signal, but
# the time order is card = assigned (same second), progress, signal, moved.
artifact card     20261031-100000 'priority: high'
artifact assigned 20261031-100000 $'worker-type: dev\nbranch: b1\nworktree: w1'
artifact progress 20261031-100200
artifact signal   20261031-100300 'outcome: done'
artifact moved    20261031-100900 'to: review'

"$SCRIPTS_DIR/task-replay.sh" "$ID" > /dev/null
CARD="$(find "$CONDUCTOR_DIR/kanban" -name "$ID.md")"

echo "── history is oldest first"
HIST="$(awk '/^## History/{f=1; next} f && /^- /{print $3}' "$CARD" | tr '\n' ' ')"
assert_eq "history kinds in time order (card before assigned on a tie)" \
  "$HIST" "card assigned progress: signal: moved "

echo "── last-updated is the newest artifact"
assert_eq "last-updated" "$(awk -F': ' '/^last-updated: /{print $2; exit}' "$CARD")" "20261031-100900"

echo
if (( FAILS > 0 )); then echo "$FAILS failure(s)" >&2; exit 1; fi
echo "all passed"
