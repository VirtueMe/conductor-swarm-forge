#!/usr/bin/env bash
set -euo pipefail
# The replay gate: run a script handler against a recorded fixture and compare what it did
# with what the skill did. A handler is converted from a skill to a script only if this passes.
#
# Usage: handler-replay.sh <fixture-dir> [--handlers-dir <dir>]
#   --handlers-dir   where the script handlers live (default: handlers/ next to this script)
#
# Exit:  0 the handler did what the fixture expects
#        1 it did something else (a difference is printed), or the handler itself failed
#        2 the fixture is not usable
#        3 there is no script handler for the fixture's event
#
# A fixture (see tests/handler-replay/README.md) is a .conductor-shaped tree plus three files:
# `event` (the artifact that triggers the handler), `locks` (what task-locks.sh reports as
# locked) and `expect`. The fixture is copied first and never modified.
#
# The handler runs against a scratch copy of scripts/. In it worker-spawn.sh, task-notify.sh and
# task-locks.sh are stubs that log (or answer) and nothing else, because stage-start.sh calls them by
# absolute path and a stub on PATH would not be reached; tmux is a stub on PATH. Everything else
# is real: task-move.sh, task-replay.sh, stage-start.sh and topology-load.sh decide the moves and
# the spawns, so a handler is judged on the decisions it makes, not on mocks of them.
#
# The outcome is three groups of lines, compared exactly and in order:
#   move <task> <stage>      each move the handler made (the `moved` artifacts it wrote)
#   spawn <task> <role>      each worker it started, or  notify <task> <stage>  for a manual stage
#   stage <task> <stage>     where the card ended up
# Notes, timestamps and the wording of artifacts are not compared (the skill side is a model).

SRC_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
HANDLERS_DIR="$SRC_SCRIPTS/handlers"

usage() { echo "Usage: handler-replay.sh <fixture-dir> [--handlers-dir <dir>]" >&2; exit 2; }
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --handlers-dir) [[ $# -ge 2 ]] || usage; HANDLERS_DIR="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$FIXTURE" ]] || usage; FIXTURE="$1"; shift ;;
  esac
done
[[ -n "$FIXTURE" ]] || usage

bad() { echo "handler-replay: $*" >&2; exit 2; }
[[ -d "$FIXTURE" ]] || bad "no such fixture: $FIXTURE"
for f in event expect tasks work; do
  [[ -e "$FIXTURE/$f" ]] || bad "fixture $FIXTURE has no '$f'"
done
FIXTURE="$(cd "$FIXTURE" && pwd)"
# The handlers directory may not exist (no handler has been converted yet): that is "no script
# handler" (exit 3, below), not a bad fixture.

# shellcheck source=scripts/frontmatter.sh
source "$SRC_SCRIPTS/frontmatter.sh"
# shellcheck source=scripts/handler-resolve.sh
source "$SRC_SCRIPTS/handler-resolve.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- The scratch scripts ----------------------------------------------------
SCR="$TMP/scripts"
cp -r "$SRC_SCRIPTS" "$SCR"
CALLS="$TMP/calls.log"; : > "$CALLS"
cat > "$SCR/worker-spawn.sh" << 'S'
#!/usr/bin/env bash
echo "spawn $1 $2" >> "$REPLAY_CALLS"
S
cat > "$SCR/task-notify.sh" << 'S'
#!/usr/bin/env bash
task="" stage=""
while [[ $# -gt 0 ]]; do
  case "$1" in --task) task="$2"; shift 2 ;; --stage) stage="$2"; shift 2 ;; *) shift ;; esac
done
echo "notify $task $stage" >> "$REPLAY_CALLS"
S
cat > "$SCR/task-locks.sh" << 'S'
#!/usr/bin/env bash
cat "$REPLAY_LOCKS"
S
chmod +x "$SCR"/worker-spawn.sh "$SCR"/task-notify.sh "$SCR"/task-locks.sh
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tmux"; chmod +x "$BIN/tmux"   # no windows, nothing to close

# --- The scratch conductor dir ----------------------------------------------
CD="$TMP/.conductor"
mkdir -p "$CD"
cp -r "$FIXTURE/tasks" "$FIXTURE/work" "$CD/"
[[ -d "$FIXTURE/kanban" ]] && cp -r "$FIXTURE/kanban" "$CD/"
if [[ -f "$FIXTURE/topology.json" ]]; then
  cp "$FIXTURE/topology.json" "$CD/topology.json"
else
  cp "$("$SRC_SCRIPTS/topology-load.sh" resolve software-dev)" "$CD/topology.json"
fi
while IFS= read -r stage; do mkdir -p "$CD/kanban/$stage"; done \
  < <("$SRC_SCRIPTS/topology-load.sh" stages "$CD/topology.json")
LOCKS="$TMP/locks"
if [[ -f "$FIXTURE/locks" ]]; then cp "$FIXTURE/locks" "$LOCKS"; else : > "$LOCKS"; fi
find "$CD/work" -name '*.md' | sort > "$TMP/before"

# --- Which handler ----------------------------------------------------------
EVENT_REL="$(head -1 "$FIXTURE/event")"
ARTIFACT="$CD/$EVENT_REL"
[[ -f "$ARTIFACT" ]] || bad "the event names a file the fixture does not have: $EVENT_REL"
TASK_ID="$(basename "$(dirname "$EVENT_REL")")"
type="$(fm_field "$ARTIFACT" type)"
outcome="$(fm_field "$ARTIFACT" outcome)"
skill="$("$SRC_SCRIPTS/topology-load.sh" conductor-skill "$CD/topology.json" "$type" ${outcome:+"$outcome"})" \
  || bad "cannot resolve a handler for $type${outcome:+/$outcome}"
[[ -n "$skill" ]] || bad "no handler for $type${outcome:+/$outcome}: the event is ignored"
SCRIPT="$(handler_script "$HANDLERS_DIR" "$skill")"
if [[ ! -x "$SCRIPT" ]]; then
  echo "handler-replay: no script handler: $SCRIPT" >&2
  exit 3
fi

# --- Run it -----------------------------------------------------------------
TIMEOUT=()
command -v timeout > /dev/null 2>&1 && TIMEOUT=(timeout 120)
RC=0
env CONDUCTOR_DIR="$CD" SCRIPTS_DIR="$SCR" PATH="$SCR:$BIN:$PATH" CONDUCTOR_LOOP=1 \
    TASK_ID="$TASK_ID" TASK_FILE="$CD/tasks/$TASK_ID.md" ARTIFACT="$ARTIFACT" \
    REPLAY_CALLS="$CALLS" REPLAY_LOCKS="$LOCKS" \
    ${TIMEOUT[@]+"${TIMEOUT[@]}"} "$SCRIPT" > "$TMP/handler.out" 2>&1 || RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo "handler-replay: $(basename "$SCRIPT") exited $RC for $(basename "$FIXTURE")" >&2
  cat "$TMP/handler.out" >&2
  exit 1
fi

# --- What it did ------------------------------------------------------------
ACTUAL="$TMP/actual"
{
  find "$CD/work" -name 'moved-*.md' | sort | comm -13 "$TMP/before" - | while IFS= read -r f; do
    echo "move $(fm_field "$f" task-id) $(fm_field "$f" to)"
  done
  cat "$CALLS"
  for c in "$CD"/kanban/*/"$TASK_ID".md; do
    [[ -f "$c" ]] && echo "stage $TASK_ID $(basename "$(dirname "$c")")"
  done
} > "$ACTUAL"

if diff -u --label "expected ($(basename "$FIXTURE")/expect)" --label "actual ($(basename "$SCRIPT"))" \
     "$FIXTURE/expect" "$ACTUAL" > "$TMP/diff"; then
  echo "handler-replay: $(basename "$SCRIPT") matches $(basename "$FIXTURE")"
  exit 0
fi
echo "handler-replay: $(basename "$SCRIPT") does not match $(basename "$FIXTURE")" >&2
cat "$TMP/diff" >&2
exit 1
