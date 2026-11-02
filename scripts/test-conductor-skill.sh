#!/usr/bin/env bash
# Tests `topology-load.sh conductor-skill`, the one rule that says which conductor
# skill handles an artifact. The interactive conductor (startup.md) and the
# headless loop (conductor-loop.sh) both resolve events through it, so a new task
# (a `card` artifact) has to resolve here or the interactive conductor never
# starts it. No tmux, no AI.
#
# Usage: scripts/test-conductor-skill.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOAD="$SCRIPTS_DIR/topology-load.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

TOPOLOGY="$("$LOAD" resolve software-dev)"
skill() { "$LOAD" conductor-skill "$TOPOLOGY" "$@"; }

echo "── a new task resolves to the new-task handler"
assert_eq "card"                      "$(skill card)"                    "conductor/on-new-task"
assert_eq "card ignores an outcome"   "$(skill card ignored)"            "conductor/on-new-task"

echo "── the other events are unchanged"
assert_eq "signal complete"           "$(skill signal complete)"         "conductor/on-signal-complete"
assert_eq "review approved"           "$(skill review approved)"         "conductor/on-review-approved"
assert_eq "assigned is ignored"       "$(skill assigned)"                ""
assert_eq "progress is ignored"       "$(skill progress)"                ""
assert_eq "moved is ignored"          "$(skill moved)"                   ""
assert_eq "an unknown type is ignored" "$(skill whatever)"               ""

echo "── a topology can still override card"
python3 - "$TOPOLOGY" "$TMP/custom.json" << 'PY'
import json, sys
t = json.load(open(sys.argv[1]))
t["conductor_skills"] = {"card": "conductor/custom-intake"}
json.dump(t, open(sys.argv[2], "w"))
PY
assert_eq "override wins" "$("$LOAD" conductor-skill "$TMP/custom.json" card)" "conductor/custom-intake"

echo ""
if (( FAILS > 0 )); then echo "$FAILS failure(s)" >&2; exit 1; fi
echo "all passed"
