#!/usr/bin/env bash
set -euo pipefail
# Record the Codex subscription allowance next to the usage log, and work out what one Codex run
# used of it.
#
# Usage: allowance.sh reading <moment>
#        allowance.sh start <workforce.json>
#        allowance.sh begin <run> --kind dispatch --pid <pid>
#        allowance.sh begin <run> --kind worker --window <tmux-window>
#        allowance.sh end <run>
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# reading  takes a reading with codex-usage.sh and appends it to $CONDUCTOR_DIR/usage.jsonl as a
#          record: {"record": "allowance", "pool": "subscription:openai", "moment": ..., "ts": ...}
#          followed by what the reader printed. A line of any other kind has no "record" field and
#          is an attempt.
# start    takes a "swarm-start" reading if the workforce has a member on the codex adapter, and does
#          nothing otherwise. Called by swarm-start.sh.
# begin    notes that a Codex run starts: a reading, kept with the run in $CONDUCTOR_DIR/allowance/.
# end      takes a second reading, appends it, and prints the run's allowance as one JSON object for
#          the run's usage line:
#            { pool, overlap, attributed_to ("run" or "batch"), before_snapshot_at, after_snapshot_at,
#              five_hour: {points, reason}, weekly: {points, reason} }
#          points is the percentage points the window rose over the run. It is null, with a reason,
#          and never zero, when a reading was unknown, when Codex wrote nothing new in between (the
#          reading is only as fresh as the last Codex event), when the window reset during the run,
#          or when runs overlapped. Prints null when there is no begin to match, and removes the run.
#
# Runs overlap when two or more are live at once, and then the difference belongs to the batch, not
# to one run: every live run is marked, and its points are null. The batch's change is in the
# readings the runs appended. A dispatch is live while its process is; a worker while its tmux
# window is. If tmux cannot say, a worker is taken as live, so the doubt makes a run unattributed
# and never wrongly attributed.
#
# The percentages are whole numbers in the log, so one small run often shows 0 or 1 points: the
# numbers mean something added up over several runs.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
RUNS_DIR="$CONDUCTOR_DIR/allowance"
USAGE_LOG="$CONDUCTOR_DIR/usage.jsonl"
POOL="subscription:openai"
TMUX_SESSION="swarm"
# Two readings of the same window put its reset within this many seconds of each other. Codex moves
# resets_at by a few seconds between events in one window; a real reset moves it by hours.
SAME_WINDOW_SECONDS=120

die() { echo "allowance.sh: $*" >&2; exit 1; }

# A reading, always: the reader's, or an unknown one if it could not run.
take_reading() {
  local out
  out="$("$SCRIPTS_DIR/codex-usage.sh" 2> /dev/null)" || out=""
  if jq -e 'type == "object" and has("five_hour") and has("weekly")' <<< "$out" > /dev/null 2>&1; then
    printf '%s' "$out"
  else
    jq -nc '{ snapshot_at: null, codex_version: null, plan_type: null, limit_id: null, rate_limit_reached_type: null,
              five_hour: { state: "unknown", reason: "the reader could not run", window_minutes: 300, used_percent: null, opened_at: null, resets_at: null },
              weekly:    { state: "unknown", reason: "the reader could not run", window_minutes: 10080, used_percent: null, opened_at: null, resets_at: null } }'
  fi
}

append_reading() { # <moment> <reading>
  jq -nc --arg pool "$POOL" --arg moment "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$2" \
    '{ record: "allowance", pool: $pool, moment: $moment, ts: $ts } + ($r | del(.source))' >> "$USAGE_LOG" 2> /dev/null || true
}

run_file() { echo "$RUNS_DIR/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').json"; } # <run>

is_live() { # <run file>
  local kind windows
  kind="$(jq -r '.kind' "$1" 2> /dev/null)" || return 1
  case "$kind" in
    dispatch) kill -0 "$(jq -r '.pid' "$1")" 2> /dev/null ;;
    worker)
      windows="$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2> /dev/null)" || return 0
      grep -qxF -- "$(jq -r '.window' "$1")" <<< "$windows" ;;
    *) return 1 ;;
  esac
}

# Forget runs that ended without an end (a crash), except <keep>.
prune() { # [<file to keep>]
  local f
  [[ -d "$RUNS_DIR" ]] || return 0
  for f in "$RUNS_DIR"/*.json; do
    [[ -e "$f" && "$f" != "${1:-}" ]] || continue
    is_live "$f" || rm -f "$f"
  done
}

# Mark every run in the directory as overlapping, if there are two or more.
mark_overlap() {
  local files=() f
  for f in "$RUNS_DIR"/*.json; do [[ -e "$f" ]] && files+=("$f"); done
  [[ ${#files[@]} -ge 2 ]] || return 0
  for f in "${files[@]}"; do
    jq '.overlap = true' "$f" > "$f.new.$$" && mv "$f.new.$$" "$f"
  done
}

cmd_reading() {
  local moment="${1:?Usage: allowance.sh reading <moment>}" reading
  reading="$(take_reading)"
  append_reading "$moment" "$reading"
  printf '%s\n' "$reading"
}

# Codex on an API key has no subscription allowance to measure: its work is billed per token and its
# dollars are on the usage line. Only evidence of an API key skips a reading; when the sign-in cannot
# be read the reading is taken, because a reading is what could settle it.
on_api_key() { [[ "$("$SCRIPTS_DIR/billing-mode.sh" detect codex 2> /dev/null || true)" == api ]]; }

cmd_start() {
  local workforce="${1:?Usage: allowance.sh start <workforce.json>}"
  jq -e '[.members[]? | .adapter] | index("codex") != null' "$workforce" > /dev/null 2>&1 || return 0
  ! on_api_key || return 0
  cmd_reading swarm-start > /dev/null
}

cmd_begin() {
  local run="${1:?Usage: allowance.sh begin <run> --kind dispatch|worker ...}"; shift
  local kind="" pid="" window=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)   kind="${2:?--kind needs a value}"; shift 2 ;;
      --pid)    pid="${2:?--pid needs a value}"; shift 2 ;;
      --window) window="${2:?--window needs a value}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$kind" in
    dispatch) [[ "$pid" =~ ^[0-9]+$ ]] || die "--kind dispatch needs --pid" ;;
    worker)   [[ -n "$window" ]] || die "--kind worker needs --window" ;;
    *) die "--kind is dispatch or worker" ;;
  esac
  mkdir -p "$RUNS_DIR"
  # Nothing to measure on an API key. The decision is made here, once, and left as a marker for end to
  # read, so a sign-in that changes mid-run cannot half-measure the run. The marker is not a run
  # (*.json), so it takes no part in overlap.
  if on_api_key; then : > "$(run_file "$run").skipped"; return 0; fi
  prune
  local reading file
  reading="$(take_reading)"
  append_reading "run-begin:$run" "$reading"
  file="$(run_file "$run")"
  jq -nc --arg run "$run" --arg kind "$kind" --arg pid "$pid" --arg window "$window" --argjson before "$reading" \
    '{ run: $run, kind: $kind, pid: ($pid | tonumber? // null), window: (if $window == "" then null else $window end),
       overlap: false, before: $before }' > "$file.new.$$"
  mv "$file.new.$$" "$file"
  mark_overlap
}

cmd_end() {
  local run="${1:?Usage: allowance.sh end <run>}" file after
  file="$(run_file "$run")"
  # begin decided there was nothing to measure (an API key): no reading, no difference.
  if [[ -f "$file.skipped" ]]; then rm -f "$file.skipped"; echo null; return 0; fi
  after="$(take_reading)"
  append_reading "run-end:$run" "$after"
  if [[ ! -f "$file" ]]; then echo null; return 0; fi
  # The run itself may already look dead (its window is closed), so it is kept; only the others are
  # asked whether they are still live.
  prune "$file"
  mark_overlap
  jq -c --argjson after "$after" --arg pool "$POOL" --argjson tol "$SAME_WINDOW_SECONDS" '
    .before as $b
    | def points($w):
        if $b[$w].state != "known" then { points: null, reason: "the reading before the run was unknown: \($b[$w].reason)" }
        elif $after[$w].state != "known" then { points: null, reason: "the reading after the run was unknown: \($after[$w].reason)" }
        elif $b.snapshot_at == $after.snapshot_at then { points: null, reason: "Codex wrote nothing new since the run began" }
        elif (($b[$w].resets_at - $after[$w].resets_at) | fabs) > $tol then { points: null, reason: "the window reset during the run" }
        elif $after[$w].used_percent < $b[$w].used_percent then { points: null, reason: "the percentage fell" }
        else { points: ((($after[$w].used_percent - $b[$w].used_percent) * 10000 | round) / 10000), reason: null } end;
      def batch($w): { points: null, reason: "runs overlapped; the difference belongs to the batch" };
      { pool: $pool,
        overlap: .overlap,
        attributed_to: (if .overlap then "batch" else "run" end),
        before_snapshot_at: $b.snapshot_at,
        after_snapshot_at: $after.snapshot_at,
        five_hour: (if .overlap then batch("five_hour") else points("five_hour") end),
        weekly: (if .overlap then batch("weekly") else points("weekly") end) }' "$file"
  rm -f "$file"
}

main() {
  command -v jq > /dev/null 2>&1 || { echo "allowance.sh needs jq" >&2; exit 3; }
  local cmd="${1:-}"; [[ $# -eq 0 ]] || shift
  case "$cmd" in
    reading) cmd_reading "$@" ;;
    start)   cmd_start "$@" ;;
    begin)   cmd_begin "$@" ;;
    end)     cmd_end "$@" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: allowance.sh reading|start|begin|end ..." >&2; exit 1 ;;
  esac
}

main "$@"
