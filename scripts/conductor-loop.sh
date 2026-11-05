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
#   CONDUCTOR_HANDLERS_DIR      where script handlers live (default: handlers/ next to this script)
#
# A handler is a script when one exists, else the skill goes to the model. For the skill
# conductor/on-x the loop looks for $CONDUCTOR_HANDLERS_DIR/on-x.sh. A script runs under the same
# deadline, retry and halt rules as a dispatch, with CONDUCTOR_DIR (absolute), PATH with the
# scripts, and TASK_ID, TASK_FILE and ARTIFACT set. Its exit status means what an adapter's does:
# 0 finished, 2 cannot be handled (halts, no retry), anything else failed (retried). It costs no
# model call, so it writes no usage line. The startup reconcile is resolved the same way, as
# conductor/reconcile: $CONDUCTOR_HANDLERS_DIR/reconcile.sh, with no TASK_ID, TASK_FILE or ARTIFACT.
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
# shellcheck source=scripts/handler-resolve.sh
source "$SCRIPTS_DIR/handler-resolve.sh"
# shellcheck source=scripts/usage-log.sh
source "$SCRIPTS_DIR/usage-log.sh"

# Sets CONDUCTOR_DIR (absolute), SCRIPTS_DIR and PATH, as a dispatched run needs them.
conductor_env "${CONDUCTOR_DIR:-.conductor}"
export CONDUCTOR_LOOP=1

MAX_ATTEMPTS="${CONDUCTOR_MAX_ATTEMPTS:-3}"
DEADLINE="${CONDUCTOR_DISPATCH_DEADLINE:-600}"
KILL_GRACE="${CONDUCTOR_KILL_GRACE:-10}"
RETRY_DELAY="${CONDUCTOR_RETRY_DELAY:-5}"

WORK_DIR="$CONDUCTOR_DIR/work"
HANDLERS_DIR="${CONDUCTOR_HANDLERS_DIR:-$SCRIPTS_DIR/handlers}"
HANDLER_SCRIPT=""                      # the script handling the current event; empty = the model
LEDGER="$CONDUCTOR_DIR/processed.log"
FLAG="$CONDUCTOR_DIR/shutdown-requested"
HALTED="$CONDUCTOR_DIR/conductor-loop.halted"
LOCK="$CONDUCTOR_DIR/conductor-loop.lock"
export DISPATCH_USAGE_FILE="$CONDUCTOR_DIR/dispatch-usage.json"
DISPATCH_STDERR="$CONDUCTOR_DIR/dispatch-stderr.log"
LAST_ERROR=""
USAGE_LOG="$CONDUCTOR_DIR/usage.jsonl"
CUR_LABEL="" CUR_ATTEMPT=0 CUR_START=0
ALLOWANCE_RUN="" ATTEMPT_EPOCH=0   # the Codex dispatch in flight, for allowance.sh, and when it began
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

# The pool the workforce gives the conductor member, or nothing: the usage line settles what the
# sign-in makes of it (billing-mode.sh).
conductor_pool() {
  [[ -f "$CONDUCTOR_DIR/workforce.json" ]] || return 0
  wf_field "$CONDUCTOR_DIR/workforce.json" conductor pool 2> /dev/null || true
}

# One line per dispatch attempt in $USAGE_LOG, whatever the outcome: a retried event costs money
# each time, and an attempt that left no record (a killed or failed run) is logged with
# usage "none" so that unknown spend is not mistaken for none. The record the adapter left
# is read here, before the next attempt deletes it. The log is a convenience: a line that
# cannot be written never changes what the loop does.
log_usage() { # <event> <attempt> <outcome> <rc> <duration_s>
  local record="{}" usage=none allowance=null requested="" answered=""
  if [[ -s "$DISPATCH_USAGE_FILE" ]] && jq -e . "$DISPATCH_USAGE_FILE" > /dev/null 2>&1; then
    record="$(cat "$DISPATCH_USAGE_FILE")"
    usage=reported
  fi
  # What a Codex dispatch used of the subscription allowance: the reading from before it, and now.
  if [[ -n "$ALLOWANCE_RUN" ]]; then
    allowance="$("$SCRIPTS_DIR/allowance.sh" end "$ALLOWANCE_RUN" 2> /dev/null)" || allowance=null
    jq -e . <<< "$allowance" > /dev/null 2>&1 || allowance=null
    ALLOWANCE_RUN=""
    # The adapter reports the model it asked for; the session says which one answered.
    requested="$(jq -r '.model // empty' <<< "$record" 2> /dev/null || true)"
    answered="$("$SCRIPTS_DIR/worker-usage.sh" model codex "$PWD" "$ATTEMPT_EPOCH" 2> /dev/null || true)"
  fi
  # What this writer knows; usage_append adds the timestamp, the estimate and cost_source.
  local line
  line="$(jq -nc --argjson r "$record" --arg usage "$usage" --argjson allowance "$allowance" \
    --arg requested "$requested" --arg answered "$answered" \
    --arg event "$1" --arg attempt "$2" --arg outcome "$3" --arg rc "$4" --arg duration "$5" \
    --arg handler "${SKILL_NAME:-}" --arg adapter "$(basename "$ADAPTER_FILE" .sh)" --arg declared "$(conductor_pool)" '
    { event: $event,
      task: (if ($event | contains("/")) then ($event | split("/")[0]) else null end),
      handler: $handler,
      role: "conductor",
      attempt: ($attempt | tonumber),
      outcome: $outcome,
      rc: ($rc | tonumber),
      duration_s: ($duration | tonumber),
      harness: ($r.harness // $adapter),
      declared_pool: (if $declared == "" then null else $declared end),
      model: $r.model,
      input_tokens: $r.input_tokens,
      output_tokens: $r.output_tokens,
      cache_read_tokens: $r.cache_read_tokens,
      cache_write_tokens: $r.cache_write_tokens,
      cache_write_1h_tokens: $r.cache_write_1h_tokens,
      cost_usd: $r.cost_usd,
      turns: $r.turns,
      usage: $usage,
      allowance: $allowance,
      requested_model: (if $requested == "" then null else $requested end),
      answered_model: (if $answered == "" then null else $answered end) }' 2> /dev/null)" || return 0
  usage_append "$USAGE_LOG" "$line"
  usage_model_check "$USAGE_LOG" conductor "$(jq -r '.task // empty' <<< "$line")" "$1" codex "$requested" "$answered"
}

# Killing the loop forwards TERM to timeout, which passes it to the dispatch's whole
# process group and escalates to KILL after the grace period (test 12 checks that
# nothing from the dispatch is left running).
cleanup() {
  if [[ -n "$DISPATCH_PID" ]]; then
    kill -TERM "$DISPATCH_PID" 2>/dev/null || true
    # The attempt in flight is lost with the loop; leave a line so its spend is not invisible.
    # A script spends nothing, so it leaves none.
    [[ -n "$HANDLER_SCRIPT" ]] || log_usage "$CUR_LABEL" "$CUR_ATTEMPT" interrupted 143 "$(( SECONDS - CUR_START ))"
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

# Wait for the dispatch just started in the background (DISPATCH_PID) and return its status. The
# child's stderr was held back in a file and is shown now, so progress output would appear only at
# the end. The adapters print one line, about a failure. The last line is the last error a halt
# reports.
wait_dispatch() {
  local rc=0
  wait "$DISPATCH_PID" || rc=$?
  DISPATCH_PID=""
  if [[ -s "$DISPATCH_STDERR" ]]; then
    # Shown as it was, minus control characters other than newline and tab (see log()).
    LC_ALL=C tr -d '\000-\010\013-\037\177' < "$DISPATCH_STDERR" >&2
    LAST_ERROR="$(awk 'NF{l=$0} END{print substr(l, 1, 300)}' "$DISPATCH_STDERR")"
  else
    LAST_ERROR=""
  fi
  return "$rc"
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
  wait_dispatch
}

# Run the script handler under the same deadline. It inherits the loop's environment, which
# handle_event has set for the event.
run_script() {
  rm -f "$DISPATCH_USAGE_FILE" "$DISPATCH_STDERR" "$DISPATCH_ANSWER_FILE"
  "$TIMEOUT_CMD" -k "$KILL_GRACE" "$DEADLINE" "$HANDLER_SCRIPT" 2> "$DISPATCH_STDERR" &
  DISPATCH_PID=$!
  wait_dispatch
}

# ", $0.107", ", no cost reported" or ", no usage record": what the attempt that just ended cost,
# in words that do not call an unknown cost free.
cost_note() {
  local cost
  [[ -z "$HANDLER_SCRIPT" ]] || return 0
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
# success. <label> names the event in logs and halt notices. HANDLER_SCRIPT, set by handle_event,
# says how: a path means run that script, empty means dispatch <skill_content> to the model.
dispatch_until_done() { # <label> <skill_content> <event: an artifact path, or "startup">
  local label="$1" skill_content="$2" event="$3" attempt rc=0 outcome
  for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
    log "$label -> $SKILL_NAME${HANDLER_SCRIPT:+ (script)} (attempt $attempt of $MAX_ATTEMPTS)"
    rc=0
    CUR_LABEL="$label" CUR_ATTEMPT="$attempt" CUR_START=$SECONDS
    if [[ -n "$HANDLER_SCRIPT" ]]; then
      run_script || rc=$?
    else
      # A Codex dispatch draws on the subscription allowance: note where it stood. log_usage reads it again.
      if [[ "$(basename "$ADAPTER_FILE" .sh)" == codex ]]; then
        ALLOWANCE_RUN="dispatch-$$-$attempt"; ATTEMPT_EPOCH="$(date +%s)"
        "$SCRIPTS_DIR/allowance.sh" begin "$ALLOWANCE_RUN" --kind dispatch --pid $$ 2> /dev/null || ALLOWANCE_RUN=""
      fi
      run_dispatch "$skill_content" "$event" || rc=$?
    fi
    case "$rc" in
      0) outcome=finished ;;
      2) outcome=unusable ;;
      124|137) outcome=timeout ;;
      *) outcome=failed ;;
    esac
    local took=$(( SECONDS - CUR_START ))
    [[ -n "$HANDLER_SCRIPT" ]] || log_usage "$label" "$attempt" "$outcome" "$rc" "$took"
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

# Decide how SKILL_NAME is handled, for the artifact (or "startup") named <label> in halt notices:
# a script named for the skill is the handler; without one the skill goes to the model. Sets
# HANDLER_SCRIPT (empty when the model handles it) and SKILL_CONTENT (empty when a script does).
# This is the one place that says so for the loop, as handler-resolve.sh is for finding the script.
SKILL_CONTENT=""
resolve_handler() { # <label>
  SKILL_CONTENT=""
  HANDLER_SCRIPT="$(handler_script "$HANDLERS_DIR" "$SKILL_NAME")"
  if [[ -x "$HANDLER_SCRIPT" ]]; then
    :
  elif [[ -e "$HANDLER_SCRIPT" ]]; then
    # There, but it cannot run (a lost +x bit): the model must not quietly take over.
    halt unresolvable "$1" "handler script is not executable: $HANDLER_SCRIPT"
  else
    HANDLER_SCRIPT=""
    local skill_file="$CONDUCTOR_DIR/skills/${SKILL_NAME}.md"
    [[ -f "$skill_file" ]] || halt unresolvable "$1" "no skill file: $skill_file"
    SKILL_CONTENT="$(cat "$skill_file")"
  fi
}

SKILL_NAME=""
handle_event() { # <artifact path relative to the work dir>
  local rel="$1" art type outcome
  art="$WORK_DIR/$rel"
  SKILL_NAME=""
  HANDLER_SCRIPT=""
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

  if [[ -z "$SKILL_NAME" ]]; then
    mark "$rel"                        # no handler: nothing to run, but never list it again
    log "$rel: no handler for ${type}${outcome:+/$outcome}, skipped"
    EVENTS_DONE=$(( EVENTS_DONE + 1 ))
    return 0
  fi

  resolve_handler "$rel"

  TASK_ID="${rel%%/*}"
  export TASK_ID
  export ARTIFACT="$art"
  export TASK_FILE="$CONDUCTOR_DIR/tasks/$TASK_ID.md"

  dispatch_until_done "$rel" "$SKILL_CONTENT" "$art"
  mark "$rel"
  EVENTS_DONE=$(( EVENTS_DONE + 1 ))
}

# The startup reconcile (skills/conductor/reconcile.md) runs first, on every start: register
# untracked tasks, unblock ready ones, respawn a worker whose window was lost, start the entry
# stage. It is the same skill the interactive conductor runs from startup.md, it is safe to run
# again, and it has no artifact or task of its own, so the event is the word "startup". Like any
# handler it is a script when handlers/reconcile.sh exists, else the model's. A fresh swarm has
# nothing to reconcile and skips it either way.
reconcile() {
  if ! compgen -G "$CONDUCTOR_DIR/tasks/*.md" > /dev/null && ! compgen -G "$CONDUCTOR_DIR/kanban/*/*.md" > /dev/null; then
    log "nothing to reconcile"
    return 0
  fi
  SKILL_NAME="conductor/reconcile"
  LAST_ERROR=""
  resolve_handler startup
  unset TASK_ID TASK_FILE ARTIFACT
  dispatch_until_done startup "$SKILL_CONTENT" startup
  HANDLER_SCRIPT=""
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
