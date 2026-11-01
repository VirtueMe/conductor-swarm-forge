#!/usr/bin/env bash
set -euo pipefail
# The headless conductor loop: drain unprocessed work artifacts one at a time, hand
# each to the conductor adapter's adapter_dispatch, and record it as processed only
# once its handler has succeeded.
#
# Usage: conductor-loop.sh [--once]
#   --once   drain what is there and exit instead of polling (used by the tests)
#
# Env:
#   CONDUCTOR_DIR               the conductor directory (default: .conductor)
#   CONDUCTOR_ADAPTER_FILE      adapter to source instead of the workforce's conductor
#                               adapter (the tests use this)
#   CONDUCTOR_MAX_ATTEMPTS      attempts per event before halting (default 3)
#   CONDUCTOR_DISPATCH_DEADLINE seconds one dispatch may take (default 600)
#   CONDUCTOR_KILL_GRACE        seconds between the deadline and a hard kill (default 10)
#   CONDUCTOR_RETRY_DELAY       seconds to wait between attempts at one event (default 5)
#   CONDUCTOR_TIMEOUT_CMD       the timeout command (default: timeout, else gtimeout)
#   CONDUCTOR_HEARTBEAT         seconds of idleness between 'idle' lines in the log (default 600; 0 = never)
#
# The adapter contract, called as `adapter_dispatch <skill_content> <event>`, where <event>
# is an artifact path or the word "startup" (the reconcile, which has no artifact or task):
#   environment  CONDUCTOR_DIR (absolute), PATH with the scripts, TASK_ID, TASK_FILE,
#                ARTIFACT (these three only for an artifact event), DISPATCH_DEADLINE
#                (seconds), DISPATCH_USAGE_FILE
#   exit 0       the handler finished
#   exit 2       the event cannot be handled; retrying will not help
#   other        the handler failed; the loop retries
#   answer       the adapter may write the model's last line to $DISPATCH_ANSWER_FILE
#                (dispatch_finish does it); the loop shows it in conductor.log
#   usage        the adapter may write one JSON line to $DISPATCH_USAGE_FILE; the loop
#                appends it, with the event, the handler and the outcome, to
#                $CONDUCTOR_DIR/usage.jsonl, one line per dispatch attempt (read it with
#                usage-summary.sh)
#
# The loop first runs the startup reconcile (see reconcile below), then drains events.
#
# Everything the loop says is printed on stderr (the conductor window) and appended, with a
# timestamp, to $CONDUCTOR_DIR/conductor.log: what it started, each event and the handler
# chosen, how each attempt ended (duration, cost when known, and the model's own last line),
# events skipped for having no handler, an 'idle' line now and then so that a quiet loop can be
# told from a hung one, and a halt. The log is a convenience: a line that cannot be written
# never changes what the loop does.
#
# Failure rules:
#   - A failed or timed-out handler (the reconcile included) is retried, then the loop halts.
#     It never skips an
#     event: skipping can strand a task without anyone noticing.
#   - An artifact whose handler cannot be resolved, or whose skill file is missing,
#     halts at once. Retrying cannot fix it.
#   - An artifact with no handler (assigned, progress, moved, ...) is recorded as
#     processed without a dispatch.
#   - A killed loop stops the whole dispatch (the adapter's child processes too) and
#     leaves the ledger as it was, so the event runs again on restart. Handlers must be
#     safe to replay (the spawn guard covers the worker side).
#
# A halt writes $CONDUCTOR_DIR/conductor-loop.halted, tells the human and the architect
# (loop-halt-notify.sh: a banner here, a file in human-inbox/ and in architect-inbox/, and a
# desktop notification if config.md has notify-channel: push), and exits 1. The next start
# removes those notices along with the halt file.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

ONCE=false
case "${1:-}" in
  "") ;;
  --once) ONCE=true ;;
  *) echo "Usage: conductor-loop.sh [--once]" >&2; exit 1 ;;
esac

# shellcheck source=scripts/conductor-env.sh
source "$SCRIPTS_DIR/conductor-env.sh"
# shellcheck source=scripts/frontmatter.sh
source "$SCRIPTS_DIR/frontmatter.sh"
# shellcheck source=scripts/wf-read.sh
source "$SCRIPTS_DIR/wf-read.sh"

# Sets CONDUCTOR_DIR (absolute), SCRIPTS_DIR and PATH, as a dispatched run needs them.
conductor_env "${CONDUCTOR_DIR:-.conductor}"
export CONDUCTOR_LOOP=1

MAX_ATTEMPTS="${CONDUCTOR_MAX_ATTEMPTS:-3}"
DEADLINE="${CONDUCTOR_DISPATCH_DEADLINE:-600}"
KILL_GRACE="${CONDUCTOR_KILL_GRACE:-10}"
RETRY_DELAY="${CONDUCTOR_RETRY_DELAY:-5}"

WORK_DIR="$CONDUCTOR_DIR/work"
LEDGER="$CONDUCTOR_DIR/processed.log"
FLAG="$CONDUCTOR_DIR/shutdown-requested"
HALTED="$CONDUCTOR_DIR/conductor-loop.halted"
LOCK="$CONDUCTOR_DIR/conductor-loop.lock"
export DISPATCH_USAGE_FILE="$CONDUCTOR_DIR/dispatch-usage.json"
DISPATCH_STDERR="$CONDUCTOR_DIR/dispatch-stderr.log"
LAST_ERROR=""
USAGE_LOG="$CONDUCTOR_DIR/usage.jsonl"
CUR_LABEL="" CUR_ATTEMPT=0 CUR_START=0
export DISPATCH_ANSWER_FILE="$CONDUCTOR_DIR/dispatch-answer.txt"
LOG_FILE="$CONDUCTOR_DIR/conductor.log"
HEARTBEAT="${CONDUCTOR_HEARTBEAT:-600}"
LAST_BEAT=$SECONDS EVENTS_DONE=0

# Every message passes through here, and some carry text a model wrote (its last line, an adapter's
# error) that may have come from a task or a file nobody trusts. A terminal obeys escape sequences,
# so control characters are removed: the message stays readable and cannot move the cursor, clear the
# screen or retitle the window.
log() {
  local msg line
  msg="$(printf '%s' "$*" | LC_ALL=C tr -d '\000-\037\177')"
  line="$(date '+%Y-%m-%d %H:%M:%S')  $msg"
  echo "$line" >&2
  { echo "$line" >> "$LOG_FILE"; } 2> /dev/null || true
}

# --- The timeout command ----------------------------------------------------

# GNU timeout is not on macOS by default (brew install coreutils gives gtimeout). Say so
# here, once, rather than let every dispatch fail with "command not found" (exit 127),
# which would be retried and then reported as a failed handler.
TIMEOUT_CMD="${CONDUCTOR_TIMEOUT_CMD:-}"
if [[ -z "$TIMEOUT_CMD" ]]; then
  if command -v timeout > /dev/null 2>&1; then TIMEOUT_CMD=timeout
  elif command -v gtimeout > /dev/null 2>&1; then TIMEOUT_CMD=gtimeout
  fi
fi
if [[ -z "$TIMEOUT_CMD" ]] || ! command -v "$TIMEOUT_CMD" > /dev/null 2>&1; then
  log "needs GNU timeout (timeout or gtimeout); on macOS: brew install coreutils"
  exit 3
fi

# --- jq ---------------------------------------------------------------------

# The usage log is written with jq (the adapters need it too).
if ! command -v jq > /dev/null 2>&1; then
  log "needs jq (apt install jq / brew install jq)"
  exit 3
fi

# --- Adapter ----------------------------------------------------------------

if [[ -n "${CONDUCTOR_ADAPTER_FILE:-}" ]]; then
  ADAPTER_FILE="$CONDUCTOR_ADAPTER_FILE"
else
  adapter_name="$(wf_field "$CONDUCTOR_DIR/workforce.json" conductor adapter)"
  ADAPTER_FILE="$ROOT_DIR/adapters/${adapter_name}.sh"
fi
[[ -f "$ADAPTER_FILE" ]] || { log "adapter not found: $ADAPTER_FILE"; exit 3; }
if ! bash -c 'source "$1"; declare -F adapter_dispatch >/dev/null' _ "$ADAPTER_FILE"; then
  log "adapter has no adapter_dispatch: $ADAPTER_FILE"
  exit 3
fi

# --- One loop per conductor dir ---------------------------------------------

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; return 0; fi
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "already running (pid $pid)"
    return 1
  fi
  rm -rf "$LOCK"                       # left behind by a loop that was killed
  mkdir "$LOCK" && echo "$$" > "$LOCK/pid"
}

acquire_lock || exit 4

DISPATCH_PID=""
SLEEP_PID=""

# One line per dispatch attempt in $USAGE_LOG, whatever the outcome: a retried event costs money
# each time, and an attempt that left no record (a killed or failed run) is logged with
# usage "none" so that unknown spend is not mistaken for none. The record the adapter left
# is read here, before the next attempt deletes it. The log is a convenience: a line that
# cannot be written never changes what the loop does.
log_usage() { # <event> <attempt> <outcome> <rc> <duration_s>
  local record="{}" usage=none
  if [[ -s "$DISPATCH_USAGE_FILE" ]] && jq -e . "$DISPATCH_USAGE_FILE" > /dev/null 2>&1; then
    record="$(cat "$DISPATCH_USAGE_FILE")"
    usage=reported
  fi
  jq -nc --argjson r "$record" --arg usage "$usage" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$1" --arg attempt "$2" --arg outcome "$3" --arg rc "$4" --arg duration "$5" \
    --arg handler "${SKILL_NAME:-}" --arg adapter "$(basename "$ADAPTER_FILE" .sh)" '
    { ts: $ts,
      event: $event,
      task: (if ($event | contains("/")) then ($event | split("/")[0]) else null end),
      handler: $handler,
      attempt: ($attempt | tonumber),
      outcome: $outcome,
      rc: ($rc | tonumber),
      duration_s: ($duration | tonumber),
      harness: ($r.harness // $adapter),
      model: ($r.model // null),
      input_tokens: ($r.input_tokens // null),
      output_tokens: ($r.output_tokens // null),
      cache_read_tokens: ($r.cache_read_tokens // null),
      cache_write_tokens: ($r.cache_write_tokens // null),
      cost_usd: ($r.cost_usd // null),
      turns: ($r.turns // null),
      usage: $usage }' >> "$USAGE_LOG" 2> /dev/null || true
}

# Killing the loop forwards TERM to timeout, which passes it to the dispatch's whole
# process group and escalates to KILL after the grace period (test 12 checks that
# nothing from the dispatch is left running).
cleanup() {
  if [[ -n "$DISPATCH_PID" ]]; then
    kill -TERM "$DISPATCH_PID" 2>/dev/null || true
    # The attempt in flight is lost with the loop; leave a line so its spend is not invisible.
    log_usage "$CUR_LABEL" "$CUR_ATTEMPT" interrupted 143 "$(( SECONDS - CUR_START ))"
  fi
  if [[ -n "$SLEEP_PID" ]]; then kill "$SLEEP_PID" 2>/dev/null || true; fi
  if [[ "$(cat "$LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then rm -rf "$LOCK"; fi
}
trap cleanup EXIT
trap 'log "terminated"; exit 143' TERM INT

# --- Ledger -----------------------------------------------------------------

# The first start has no ledger, and `unprocessed` would list the whole history. Seed
# the ledger with what exists: the startup reconcile owns that, the loop owns what
# comes after. The ledger is written whole or not at all, so a crash here cannot leave
# half the history to be replayed.
bootstrap_ledger() {
  [[ -f "$LEDGER" ]] && return 0
  "$SCRIPTS_DIR/artifact-ledger.sh" unprocessed > "$LEDGER.new"
  mv "$LEDGER.new" "$LEDGER"
  log "ledger created with $(wc -l < "$LEDGER" | tr -d ' ') existing artifact(s)"
}

mark() { "$SCRIPTS_DIR/artifact-ledger.sh" mark "$1"; }

# --- One event --------------------------------------------------------------

halt() { # <kind> <artifact> <detail>
  {
    echo "kind: $1"
    echo "artifact: $2"
    echo "handler: ${SKILL_NAME:-none}"
    echo "detail: $3"
    [[ -n "$LAST_ERROR" ]] && echo "last-error: $LAST_ERROR"
  } > "$HALTED"
  log "HALT ($1) at $2: $3${LAST_ERROR:+ (last error: $LAST_ERROR)}"
  # Best effort: a notice that cannot be written must not change the halt or its exit status.
  "$SCRIPTS_DIR/loop-halt-notify.sh" --kind "$1" --artifact "$2" --handler "${SKILL_NAME:-none}" \
    --detail "$3" --last-error "$LAST_ERROR" || true
  exit 1
}

# Run adapter_dispatch under the deadline. `timeout` cannot call a shell function, so
# the adapter is sourced in a child shell. The outer limit is the adapter's deadline
# plus a grace period, as a backstop for an adapter that does not stop itself.
run_dispatch() { # <skill_content> <artifact>
  rm -f "$DISPATCH_USAGE_FILE" "$DISPATCH_STDERR" "$DISPATCH_ANSWER_FILE"
  # shellcheck disable=SC2016  # $1 and $@ belong to the child shell
  DISPATCH_DEADLINE="$DEADLINE" "$TIMEOUT_CMD" -k "$KILL_GRACE" "$((DEADLINE + KILL_GRACE))" \
    bash -c 'source "$1"; shift; adapter_dispatch "$@"' _ "$ADAPTER_FILE" "$1" "$2" 2> "$DISPATCH_STDERR" &
  DISPATCH_PID=$!
  local rc=0
  wait "$DISPATCH_PID" || rc=$?
  DISPATCH_PID=""
  # The adapter's stderr was held back in a file and is shown now, so progress output would
  # appear only at the end. The adapters print one line, about a failure. The last line is the
  # last error a halt reports.
  if [[ -s "$DISPATCH_STDERR" ]]; then
    # Shown as it was, minus control characters other than newline and tab (see log()).
    LC_ALL=C tr -d '\000-\010\013-\037\177' < "$DISPATCH_STDERR" >&2
    LAST_ERROR="$(awk 'NF{l=$0} END{print substr(l, 1, 300)}' "$DISPATCH_STDERR")"
  else
    LAST_ERROR=""
  fi
  return "$rc"
}

# ", $0.107", ", no cost reported" or ", no usage record": what the attempt that just ended cost,
# in words that do not call an unknown cost free.
cost_note() {
  local cost
  if [[ -s "$DISPATCH_USAGE_FILE" ]] && jq -e . "$DISPATCH_USAGE_FILE" > /dev/null 2>&1; then
    cost="$(jq -r '.cost_usd // empty' "$DISPATCH_USAGE_FILE" 2> /dev/null || true)"
    if [[ -n "$cost" ]]; then printf ', $%.3f' "$cost"; else printf ', no cost reported'; fi
  else
    printf ', no usage record'
  fi
}

# " — <what the model said last>", when the adapter left it.
answer_note() {
  local line
  line="$(awk 'NF{l=$0} END{print substr(l, 1, 300)}' "$DISPATCH_ANSWER_FILE" 2> /dev/null || true)"
  [[ -n "$line" ]] && printf ' — %s' "$line"
  return 0
}

# Dispatch one event until its handler succeeds, retrying a failure, or halt. Returns only on
# success. <label> names the event in logs and halt notices.
dispatch_until_done() { # <label> <skill_content> <event: an artifact path, or "startup">
  local label="$1" skill_content="$2" event="$3" attempt rc=0 outcome
  for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
    log "$label -> $SKILL_NAME (attempt $attempt of $MAX_ATTEMPTS)"
    rc=0
    CUR_LABEL="$label" CUR_ATTEMPT="$attempt" CUR_START=$SECONDS
    run_dispatch "$skill_content" "$event" || rc=$?
    case "$rc" in
      0) outcome=finished ;;
      2) outcome=unusable ;;
      124|137) outcome=timeout ;;
      *) outcome=failed ;;
    esac
    local took=$(( SECONDS - CUR_START ))
    log_usage "$label" "$attempt" "$outcome" "$rc" "$took"
    CUR_LABEL="" CUR_ATTEMPT=0
    if [[ "$rc" -eq 0 ]]; then
      log "$label finished in ${took}s$(cost_note)$(answer_note)"
      return 0
    fi
    [[ "$rc" -eq 2 ]] && halt unusable "$label" "the adapter reported that this event cannot be handled"
    log "$label failed with exit $rc after ${took}s$(cost_note)${LAST_ERROR:+: $LAST_ERROR}"
    if (( attempt < MAX_ATTEMPTS )); then
      sleep "$RETRY_DELAY" &
      SLEEP_PID=$!
      wait "$SLEEP_PID" || true
      SLEEP_PID=""
    fi
  done
  halt failed "$label" "the handler failed $MAX_ATTEMPTS time(s); last exit $rc"
}

SKILL_NAME=""
handle_event() { # <artifact path relative to the work dir>
  local rel="$1" art type outcome skill_file skill_content
  art="$WORK_DIR/$rel"
  SKILL_NAME=""
  LAST_ERROR=""

  type="$(fm_field "$art" type)"
  outcome="$(fm_field "$art" outcome)"
  [[ -n "$type" ]] || halt unresolvable "$rel" "the artifact has no type"

  local resolved
  if ! resolved="$("$SCRIPTS_DIR/topology-load.sh" conductor-skill \
        "$CONDUCTOR_DIR/topology.json" "$type" ${outcome:+"$outcome"} 2>&1)"; then
    halt unresolvable "$rel" "cannot resolve a handler: $resolved"
  fi
  SKILL_NAME="$resolved"

  # A new task is a `card` artifact. conductor-skill ignores it, so the loop maps it to
  # the new-task handler itself rather than changing what the interactive conductor sees.
  if [[ -z "$SKILL_NAME" && "$type" == "card" ]]; then
    SKILL_NAME="conductor/on-new-task"
  fi

  if [[ -z "$SKILL_NAME" ]]; then
    mark "$rel"                        # no handler: nothing to run, but never list it again
    log "$rel: no handler for ${type}${outcome:+/$outcome}, skipped"
    EVENTS_DONE=$(( EVENTS_DONE + 1 ))
    return 0
  fi

  skill_file="$CONDUCTOR_DIR/skills/${SKILL_NAME}.md"
  [[ -f "$skill_file" ]] || halt unresolvable "$rel" "no skill file: $skill_file"
  skill_content="$(cat "$skill_file")"

  TASK_ID="${rel%%/*}"
  export TASK_ID
  export ARTIFACT="$art"
  export TASK_FILE="$CONDUCTOR_DIR/tasks/$TASK_ID.md"

  dispatch_until_done "$rel" "$skill_content" "$art"
  mark "$rel"
  EVENTS_DONE=$(( EVENTS_DONE + 1 ))
}

# The startup reconcile (skills/conductor/reconcile.md) runs first, on every start: register
# untracked tasks, unblock ready ones, respawn a worker whose window was lost, start the entry
# stage. It is the same skill the interactive conductor runs from startup.md, it is safe to run
# again, and it has no artifact or task of its own, so the event is the word "startup". A fresh
# swarm has nothing to reconcile and skips the model call.
reconcile() {
  if ! compgen -G "$CONDUCTOR_DIR/tasks/*.md" > /dev/null && ! compgen -G "$CONDUCTOR_DIR/kanban/*/*.md" > /dev/null; then
    log "nothing to reconcile"
    return 0
  fi
  SKILL_NAME="conductor/reconcile"
  LAST_ERROR=""
  local skill_file="$CONDUCTOR_DIR/skills/${SKILL_NAME}.md"
  [[ -f "$skill_file" ]] || halt unresolvable startup "no skill file: $skill_file"
  unset TASK_ID TASK_FILE ARTIFACT
  dispatch_until_done startup "$(cat "$skill_file")" startup
  SKILL_NAME=""
}

# --- Main -------------------------------------------------------------------

poll_interval() {
  local p
  p="$(awk '/^poll-interval:/{print $2; exit}' "$CONDUCTOR_DIR/config.md" 2>/dev/null || true)"
  echo "${p:-3}"
}

rm -f "$FLAG" "$HALTED" "$CONDUCTOR_DIR"/human-inbox/loop-halt-*.md "$CONDUCTOR_DIR"/architect-inbox/loop-halt-*.md
bootstrap_ledger
log "started (pid $$)"
reconcile

while :; do
  if [[ -f "$FLAG" ]]; then log "shutdown requested"; break; fi
  rel=""
  read -r rel < <("$SCRIPTS_DIR/artifact-ledger.sh" unprocessed) || true
  if [[ -z "$rel" ]]; then
    "$ONCE" && break
    if (( HEARTBEAT > 0 && SECONDS - LAST_BEAT >= HEARTBEAT )); then
      log "idle: nothing to do ($EVENTS_DONE events handled since start)"
      LAST_BEAT=$SECONDS
    fi
    sleep "$(poll_interval)" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=""
    continue
  fi
  handle_event "$rel"
  LAST_BEAT=$SECONDS
done

log "stopped"
