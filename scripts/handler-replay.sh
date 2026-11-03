#!/usr/bin/env bash
set -euo pipefail
# The replay gate: run a script handler against a recorded fixture and compare what it did
# with what the skill did. A handler is converted from a skill to a script only if this passes.
# Record mode writes the fixture's `expect` from a run of the skill.
#
# Usage: handler-replay.sh <fixture-dir> [--handlers-dir <dir>]            check a script handler
#        handler-replay.sh --record <fixture-dir> [--force] [--allow-empty] [--adapter-file <file>]
#                                                                         record the skill's outcome
#   --handlers-dir   where the script handlers live (default: handlers/ next to this script)
#   --record         run the SKILL for the fixture's event through the real conductor-loop.sh and
#                    the conductor adapter, and write `expect` from what happened. This calls a
#                    model (a few cents); run it yourself, not from a test. It refuses to replace
#                    an existing `expect` unless --force is given
#   --adapter-file   record with this adapter instead of the default workforce's conductor adapter
#   --allow-empty    record a run in which the skill made no move and started no worker. Without
#                    it such a run is refused: it is almost always a skill that did not act, and
#                    a fixture saying "nothing happens" would pass a script that does nothing
#
# Exit:  0 the handler did what the fixture expects (or: the outcome was recorded)
#        1 it did something else (a difference is printed), or the handler/skill itself failed
#        2 the fixture or the options are not usable
#        3 there is no script handler for the fixture's event
#
# A fixture (see tests/handler-replay/README.md) is a .conductor-shaped tree plus `event` (the
# artifact that triggers the handler), `locks` (what task-locks.sh reports as locked) and `expect`,
# and optionally `config.md` (the project config a handler reads, test-cmd say).
# The fixture is copied first and never modified, except that --record writes `expect`.
#
# Both modes run against a scratch copy of scripts/. In it worker-spawn.sh, task-notify.sh and
# task-locks.sh are stubs that log (or answer) and nothing else, because stage-start.sh calls them by
# absolute path and a stub on PATH would not be reached; tmux is a stub on PATH. Everything else
# is real: task-move.sh, task-replay.sh, stage-start.sh and topology-load.sh decide the moves and
# the spawns, so a handler is judged on the decisions it makes, not on mocks of them. Recording uses
# the same setup, so a recorded `expect` holds exactly what the stubbed gate can see.
#
# The outcome is three groups of lines, compared exactly and in order:
#   move <task> <stage>      each move the handler made (the `moved` artifacts it wrote)
#   spawn <task> <role>      each worker it started, or  notify <task> <stage>  for a manual stage,
#                            or  shutdown  if it shut the swarm down
#   stage <task> <stage>     where the card ended up
# Notes, timestamps and the wording of artifacts are not compared (the skill side is a model).

SRC_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(dirname "$SRC_SCRIPTS")"
HANDLERS_DIR="$SRC_SCRIPTS/handlers"

usage() {
  echo "Usage: handler-replay.sh <fixture-dir> [--handlers-dir <dir>]" >&2
  echo "       handler-replay.sh --record <fixture-dir> [--force] [--allow-empty] [--adapter-file <file>]" >&2
  exit 2
}
FIXTURE="" MODE=replay FORCE=false ALLOW_EMPTY=false ADAPTER_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --handlers-dir) [[ $# -ge 2 ]] || usage; HANDLERS_DIR="$2"; shift 2 ;;
    --adapter-file) [[ $# -ge 2 ]] || usage; ADAPTER_FILE="$2"; shift 2 ;;
    --record) MODE=record; shift ;;
    --force) FORCE=true; shift ;;
    --allow-empty) ALLOW_EMPTY=true; shift ;;
    -*) usage ;;
    *) [[ -z "$FIXTURE" ]] || usage; FIXTURE="$1"; shift ;;
  esac
done
[[ -n "$FIXTURE" ]] || usage

bad() { echo "handler-replay: $*" >&2; exit 2; }
[[ -d "$FIXTURE" ]] || bad "no such fixture: $FIXTURE"
for f in event tasks work; do
  [[ -e "$FIXTURE/$f" ]] || bad "fixture $FIXTURE has no '$f'"
done
FIXTURE="$(cd "$FIXTURE" && pwd)"
if [[ "$MODE" == replay ]]; then
  [[ -e "$FIXTURE/expect" ]] || bad "fixture $FIXTURE has no 'expect' (record one with --record)"
elif [[ -e "$FIXTURE/expect" && "$FORCE" != true ]]; then
  bad "$FIXTURE/expect exists; --force replaces it"
fi
# The handlers directory may not exist (no handler has been converted yet): that is "no script
# handler" (exit 3, below), not a bad fixture.

# shellcheck source=scripts/frontmatter.sh
source "$SRC_SCRIPTS/frontmatter.sh"
# shellcheck source=scripts/handler-resolve.sh
source "$SRC_SCRIPTS/handler-resolve.sh"
# shellcheck source=scripts/wf-read.sh
source "$SRC_SCRIPTS/wf-read.sh"

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
# What task-locks.sh answers: the fixture's `locks`, plus whatever the real task-locks.sh reports
# for the scratch board (the files of the cards in merging), so a handler that starts several
# merges sees each lock taken. The real one is kept under another name and called, not copied.
# The real one finds the integration adapter next to the scripts directory, so that is linked in.
mv "$SCR/task-locks.sh" "$SCR/task-locks-real.sh"
ln -s "$SRC_ROOT/integrations" "$TMP/integrations"
cat > "$SCR/task-locks.sh" << 'S'
#!/usr/bin/env bash
set -euo pipefail
{ cat "$REPLAY_LOCKS"; "$SCRIPTS_DIR/task-locks-real.sh"; } | sort -u
S
cat > "$SCR/conductor-shutdown.sh" << 'S'
#!/usr/bin/env bash
echo "shutdown" >> "$REPLAY_CALLS"
S
chmod +x "$SCR"/worker-spawn.sh "$SCR"/task-notify.sh "$SCR"/task-locks.sh "$SCR"/conductor-shutdown.sh
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tmux"; chmod +x "$BIN/tmux"   # no windows, nothing to close

# --- The scratch conductor dir ----------------------------------------------
CD="$TMP/.conductor"
mkdir -p "$CD"
cp -r "$FIXTURE/tasks" "$FIXTURE/work" "$CD/"
[[ -d "$FIXTURE/kanban" ]] && cp -r "$FIXTURE/kanban" "$CD/"
[[ -f "$FIXTURE/config.md" ]] && cp "$FIXTURE/config.md" "$CD/config.md"
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

# --- The event, and which skill handles it ----------------------------------
EVENT_REL="$(head -1 "$FIXTURE/event")"
ARTIFACT="$CD/$EVENT_REL"
[[ -f "$ARTIFACT" ]] || bad "the event names a file the fixture does not have: $EVENT_REL"
TASK_ID="$(basename "$(dirname "$EVENT_REL")")"
type="$(fm_field "$ARTIFACT" type)"
outcome="$(fm_field "$ARTIFACT" outcome)"
skill="$("$SRC_SCRIPTS/topology-load.sh" conductor-skill "$CD/topology.json" "$type" ${outcome:+"$outcome"})" \
  || bad "cannot resolve a handler for $type${outcome:+/$outcome}"
[[ -n "$skill" ]] || bad "no handler for $type${outcome:+/$outcome}: the event is ignored"

# Run <command...> in the scratch setup, as a handler (or the loop) would see it.
in_scratch() {
  env CONDUCTOR_DIR="$CD" SCRIPTS_DIR="$SCR" PATH="$SCR:$BIN:$PATH" CONDUCTOR_LOOP=1 \
      TASK_ID="$TASK_ID" TASK_FILE="$CD/tasks/$TASK_ID.md" ARTIFACT="$ARTIFACT" \
      REPLAY_CALLS="$CALLS" REPLAY_LOCKS="$LOCKS" "$@"
}

# What happened, as the three groups of lines, into $ACTUAL.
ACTUAL="$TMP/actual"
collect_outcome() {
  {
    find "$CD/work" -name 'moved-*.md' | sort | comm -13 "$TMP/before" - | while IFS= read -r f; do
      echo "move $(fm_field "$f" task-id) $(fm_field "$f" to)"
    done
    cat "$CALLS"
    for c in "$CD"/kanban/*/"$TASK_ID".md; do
      [[ -f "$c" ]] && echo "stage $TASK_ID $(basename "$(dirname "$c")")"
    done
  } > "$ACTUAL"
}

TIMEOUT=()
command -v timeout > /dev/null 2>&1 && TIMEOUT=(timeout 120)

# --- Record: run the skill through the real loop ----------------------------
if [[ "$MODE" == record ]]; then
  REAL_ADAPTER="$ADAPTER_FILE"
  if [[ -z "$REAL_ADAPTER" ]]; then
    name="$(wf_field "$SRC_ROOT/workforces/default.json" conductor adapter)"
    REAL_ADAPTER="$SRC_ROOT/adapters/${name}.sh"
  fi
  [[ -f "$REAL_ADAPTER" ]] || bad "adapter not found: $REAL_ADAPTER"
  REAL_ADAPTER="$(cd "$(dirname "$REAL_ADAPTER")" && pwd)/$(basename "$REAL_ADAPTER")"

  # What swarm-start.sh puts in a conductor dir and the loop reads: the skills, the prompts, the config.
  cp -r "$SRC_ROOT/skills" "$CD/skills"
  cp -r "$SRC_ROOT/prompts" "$CD/prompts"
  cp "$SRC_ROOT/workforces/default.json" "$CD/workforce.json"
  [[ -f "$CD/config.md" ]] || printf 'lang: bash\npoll-interval: 1\n' > "$CD/config.md"

  # The loop handles what the ledger does not list. List everything but the event, so it handles
  # exactly the event (without a ledger it would list the whole history as already done).
  (cd "$CD/work" && find . -name '*.md' | sed 's|^\./||' | grep -vxF -- "${EVENT_REL#work/}" || true) > "$CD/processed.log"

  # The startup reconcile would send the whole board to the model and could move cards before the
  # event; it is not what is being recorded. Everything else goes to the real adapter.
  WRAP="$TMP/adapter.sh"
  cat > "$WRAP" << S
source "$REAL_ADAPTER"
eval "real_\$(declare -f adapter_dispatch)"
adapter_dispatch() {
  [[ "\$2" == startup ]] && return 0
  real_adapter_dispatch "\$@"
}
S
  mkdir -p "$TMP/no-handlers"   # record the skill, even if a script handler exists

  echo "handler-replay: recording the skill ${skill} for $(basename "$FIXTURE"): this calls the adapter, up to \$${CONDUCTOR_MAX_BUDGET_USD:-1}" >&2
  RC=0
  # From the scratch directory, not from wherever this was started: the adapter lets the model run
  # Bash, and its "project" is the directory it runs in.
  (cd "$TMP" && in_scratch env CONDUCTOR_ADAPTER_FILE="$WRAP" CONDUCTOR_HANDLERS_DIR="$TMP/no-handlers" \
      CONDUCTOR_MAX_ATTEMPTS=1 CONDUCTOR_RETRY_DELAY=0 \
      ${TIMEOUT[@]+"${TIMEOUT[@]}"} "$SCR/conductor-loop.sh" --once > "$TMP/loop.out" 2>&1) || RC=$?
  if [[ "$RC" -ne 0 ]]; then
    echo "handler-replay: the loop exited $RC; nothing was recorded" >&2
    cat "$TMP/loop.out" >&2
    exit 1
  fi
  collect_outcome
  if [[ "$ALLOW_EMPTY" != true ]] && ! grep -qE '^(move|spawn|notify) ' "$ACTUAL"; then
    echo "handler-replay: the skill made no move and started no worker; nothing was recorded" >&2
    echo "(--allow-empty records it, if \"no change\" is the right answer). The loop said:" >&2
    tail -n 8 "$TMP/loop.out" >&2
    exit 1
  fi
  cp "$ACTUAL" "$FIXTURE/expect"
  echo "handler-replay: recorded $FIXTURE/expect; read it before you rely on it:" >&2
  sed 's/^/  /' "$ACTUAL" >&2
  exit 0
fi

# --- Replay: run the script handler -----------------------------------------
SCRIPT="$(handler_script "$HANDLERS_DIR" "$skill")"
if [[ ! -x "$SCRIPT" ]]; then
  echo "handler-replay: no script handler: $SCRIPT" >&2
  exit 3
fi
RC=0
in_scratch ${TIMEOUT[@]+"${TIMEOUT[@]}"} "$SCRIPT" > "$TMP/handler.out" 2>&1 || RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo "handler-replay: $(basename "$SCRIPT") exited $RC for $(basename "$FIXTURE")" >&2
  cat "$TMP/handler.out" >&2
  exit 1
fi

collect_outcome
if diff -u --label "expected ($(basename "$FIXTURE")/expect)" --label "actual ($(basename "$SCRIPT"))" \
     "$FIXTURE/expect" "$ACTUAL" > "$TMP/diff"; then
  echo "handler-replay: $(basename "$SCRIPT") matches $(basename "$FIXTURE")"
  exit 0
fi
echo "handler-replay: $(basename "$SCRIPT") does not match $(basename "$FIXTURE")" >&2
cat "$TMP/diff" >&2
exit 1
