#!/usr/bin/env bash
# Tests scripts/stage-start.sh with no tmux and no AI: the real stage-start.sh and
# topology-load.sh run in an isolated scripts tree whose worker-spawn.sh and
# task-notify.sh are stubs that log their calls. Covers the shipped topologies
# plus two custom ones (a manual entry stage, and a third holding column).
#
# Usage: scripts/test-stage-start.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

# --- isolated scripts tree: real helper + real topology reader, stub effects --
TREE="$WORK/scripts"; mkdir -p "$TREE"
cp "$SCRIPTS_DIR/stage-start.sh" "$SCRIPTS_DIR/topology-load.sh" "$TREE/"
LOG="$WORK/calls.log"
cat > "$TREE/worker-spawn.sh" << 'EOF'
#!/usr/bin/env bash
echo "spawn $1 $2" >> "$CALLS_LOG"
EOF
cat > "$TREE/task-notify.sh" << 'EOF'
#!/usr/bin/env bash
# called as: --task <id> --stage <stage>
echo "notify $2 $4" >> "$CALLS_LOG"
EOF
chmod +x "$TREE"/*.sh
export CALLS_LOG="$LOG"

export CONDUCTOR_DIR="$WORK/.conductor"
mkdir -p "$CONDUCTOR_DIR"

# Install a topology and run the helper for one stage; prints the logged call.
use_topology() { cp "$1" "$CONDUCTOR_DIR/topology.json"; }
start() {
  : > "$LOG"
  "$TREE/stage-start.sh" 0001 "$1" > "$WORK/out.txt" 2>&1 || true
  tr '\n' ';' < "$LOG" | sed 's/;$//'
}

echo "── software-dev"
use_topology "$ROOT_DIR/topologies/software-dev.json"
assert_eq "working stage spawns its role"        "$(start in-progress)"   "spawn 0001 coder"
assert_eq "review spawns the reviewer"           "$(start review)"        "spawn 0001 reviewer"
assert_eq "merging spawns the merger"            "$(start merging)"       "spawn 0001 merger"
assert_eq "ready starts the entry stage"         "$(start ready)"         "spawn 0001 coder"
assert_eq "backlog is a hold"                    "$(start backlog)"       ""
assert_eq "merge-pending is a hold"              "$(start merge-pending)" ""
assert_eq "done is a hold"                       "$(start "done")"        ""

echo "── marketing (different roles and stage names)"
use_topology "$ROOT_DIR/topologies/marketing.json"
assert_eq "ready starts the drafter"             "$(start ready)"         "spawn 0001 drafter"
assert_eq "publish spawns the publisher"         "$(start publish)"       "spawn 0001 publisher"
assert_eq "backlog is a hold"                    "$(start backlog)"       ""

echo "── a manual entry stage notifies instead of spawning"
python3 - "$ROOT_DIR/topologies/marketing.json" "$WORK/manual-entry.json" << 'EOF'
import json, sys
t = json.load(open(sys.argv[1]))
t["working_stages"]["draft"] = {
    "mode": "manual",
    "notify": {"channel": "push", "message": "Task {id} needs a draft"},
    "await": ["done"],
}
json.dump(t, open(sys.argv[2], "w"))
EOF
use_topology "$WORK/manual-entry.json"
assert_eq "the manual stage itself notifies"     "$(start draft)"         "notify 0001 draft"
assert_eq "ready notifies the entry stage"       "$(start ready)"         "notify 0001 draft"

echo "── a third holding column is a hold, not an entry"
python3 - "$ROOT_DIR/topologies/software-dev.json" "$WORK/parked.json" << 'EOF'
import json, sys
t = json.load(open(sys.argv[1]))
t["stages"].insert(1, "parked")          # backlog, parked, ready, in-progress, ...
json.dump(t, open(sys.argv[2], "w"))
EOF
use_topology "$WORK/parked.json"
assert_eq "parked is a hold"                     "$(start parked)"        ""
assert_eq "ready still starts the entry stage"   "$(start ready)"         "spawn 0001 coder"

echo "── an unknown stage fails instead of being treated as a hold"
use_topology "$ROOT_DIR/topologies/software-dev.json"
: > "$LOG"
if "$TREE/stage-start.sh" 0001 no-such-stage > "$WORK/out.txt" 2>&1; then
  fail "unknown stage exits non-zero"
else
  ok "unknown stage exits non-zero"
fi
assert_eq "nothing was spawned or notified"      "$(tr '\n' ';' < "$LOG")" ""
case "$(cat "$WORK/out.txt")" in *"unknown stage"*) ok "says why" ;; *) fail "says why" ;; esac

echo ""
if (( FAILS > 0 )); then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "All checks passed"
