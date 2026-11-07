#!/usr/bin/env bash
set -euo pipefail
# Record a subscription allowance next to the usage log, and work out what one run used of it. The
# vendor is codex (the default; ChatGPT subscription, pool subscription:openai) or claude (Claude
# Code on a Claude subscription, pool subscription:anthropic).
#
# Usage: allowance.sh reading <moment> [--vendor <v>]
#        allowance.sh start <workforce.json> [--vendor <v>]
#        allowance.sh begin <run> --kind dispatch --pid <pid> [--vendor <v>]
#        allowance.sh begin <run> --kind worker --window <tmux-window> [--vendor <v>]
#        allowance.sh end <run> [--vendor <v>]
#        allowance.sh vendor <adapter> [--pool <pool>]
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# reading  takes a reading with the vendor's reader (codex-usage.sh, claude-usage.sh) and appends it to
#          $CONDUCTOR_DIR/usage.jsonl as a record: {"record": "allowance", "pool": ..., "moment": ...,
#          "ts": ...} followed by what the reader printed. A line of any other kind has no "record"
#          field and is an attempt.
# start    takes a "swarm-start" reading for each vendor whose adapter (codex, claude-code) the workforce
#          has a member on, or a pi member on the vendor's subscription pool, and for none other.
#          With --vendor, only that vendor. Called by swarm-start.sh.
# vendor   prints the vendor whose allowance a run draws on, and exits 1, printing nothing, for a run
#          that draws on none. The vendor follows the pool the run is billed to: codex and claude-code
#          each have a pool of their own, so the adapter says it; pi has none, so it is the pool
#          (--pool, as billing-mode.sh pool settled it) that says: subscription:openai is the ChatGPT
#          plan Codex draws on (codex), anything else is a pi run with no window to measure. Pi can not
#          use subscription:anthropic. The one place that maps a run to a vendor, so callers do not
#          each know the names.
# begin    notes that a run starts: a reading, kept with the run (and its vendor) in
#          $CONDUCTOR_DIR/allowance/.
# end      takes a second reading, appends it, and prints the run's allowance as one JSON object for
#          the run's usage line (the vendor is the one the run began with):
#            { pool, overlap, attributed_to ("run" or "batch"), before_snapshot_at, after_snapshot_at,
#              five_hour: {points, reason}, weekly: {points, reason} }
#          and, for claude only,
#              weekly_by_model: {reason, models: [{model, points, reason}]}, credits: {dollars, reason}
#          points is the percentage points a window rose over the run; dollars is what the credits
#          rose by. A value is null, with a reason, and never zero, when a reading was unknown, when
#          the reader had nothing new in between, when the window reset during the run, or when runs
#          overlapped. Prints null when there is no begin to match, and removes the run.
#
# What "nothing new" means differs. Codex is only as fresh as its last event, so two readings with the
# same snapshot_at are no difference at all. Claude's endpoint is read live; its stale copy is not
# fresh enough to subtract, so a Claude difference needs both readings from the endpoint.
#
# Runs overlap when two or more of the same vendor are live at once, and then the difference belongs
# to the batch, not to one run: every live run is marked, and its points are null. Runs of different
# vendors draw on different pools and never overlap each other. The batch's change is in the readings
# the runs appended. A dispatch is live while its process is; a worker while its tmux window is. If
# tmux cannot say, a worker is taken as live, so the doubt makes a run unattributed and never wrongly
# attributed.
#
# The percentages are whole numbers in the log, so one small run often shows 0 or 1 points: the
# numbers mean something added up over several runs.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
RUNS_DIR="$CONDUCTOR_DIR/allowance"
USAGE_LOG="$CONDUCTOR_DIR/usage.jsonl"
VENDOR=codex
VENDORS="codex claude"
VENDOR_FLAG=""   # the --vendor the caller gave, if any
POOL="" READER="" ADAPTER=""   # set from the vendor by set_vendor
TMUX_SESSION="swarm"
# Two readings of the same window put its reset within this many seconds of each other. Codex moves
# resets_at by a few seconds between events in one window; a real reset moves it by hours.
SAME_WINDOW_SECONDS=120

die() { echo "allowance.sh: $*" >&2; exit 1; }

# The vendor decides the pool, the reader, and which adapter (for billing and for the workforce).
set_vendor() { # <vendor>
  case "$1" in
    codex)  VENDOR=codex;  POOL="subscription:openai";    READER="codex-usage.sh";  ADAPTER=codex ;;
    claude) VENDOR=claude; POOL="subscription:anthropic"; READER="claude-usage.sh"; ADAPTER=claude-code ;;
    *) die "--vendor is codex or claude" ;;
  esac
}

# A reading, always: the reader's, or an unknown one if it could not run.
take_reading() {
  local out shape='type == "object" and has("five_hour") and has("weekly")'
  [[ "$VENDOR" != claude ]] || shape="$shape and has(\"weekly_by_model\") and has(\"credits\")"
  out="$("$SCRIPTS_DIR/$READER" 2> /dev/null)" || out=""
  if jq -e "$shape" <<< "$out" > /dev/null 2>&1; then
    printf '%s' "$out"
  elif [[ "$VENDOR" == claude ]]; then
    jq -nc '{ snapshot_at: null, source: null, checked_version: null,
              five_hour: { state: "unknown", reason: "the reader could not run", window_minutes: 300, used_percent: null, opened_at: null, resets_at: null },
              weekly:    { state: "unknown", reason: "the reader could not run", window_minutes: 10080, used_percent: null, opened_at: null, resets_at: null },
              weekly_by_model: { state: "unknown", reason: "the reader could not run", models: [] },
              credits: { state: "unknown", reason: "the reader could not run", currency: null, used: null, limit: null } }'
  else
    jq -nc '{ snapshot_at: null, codex_version: null, plan_type: null, limit_id: null, rate_limit_reached_type: null,
              five_hour: { state: "unknown", reason: "the reader could not run", window_minutes: 300, used_percent: null, opened_at: null, resets_at: null },
              weekly:    { state: "unknown", reason: "the reader could not run", window_minutes: 10080, used_percent: null, opened_at: null, resets_at: null } }'
  fi
}

append_reading() { # <moment> <reading>
  # Codex's source is the path of a session file, which stays out of the log. Claude's is "endpoint" or "cache".
  jq -nc --arg pool "$POOL" --arg moment "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg vendor "$VENDOR" --argjson r "$2" \
    '{ record: "allowance", pool: $pool, moment: $moment, ts: $ts } + ($r | if $vendor == "codex" then del(.source) else . end)' >> "$USAGE_LOG" 2> /dev/null || true
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

# Mark every run of this vendor in the directory as overlapping, if there are two or more. Runs of
# another vendor draw on another pool and are left alone.
mark_overlap() {
  local files=() f
  for f in "$RUNS_DIR"/*.json; do
    [[ -e "$f" && "$(jq -r '.vendor // "codex"' "$f" 2> /dev/null)" == "$VENDOR" ]] && files+=("$f")
  done
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

# A harness on an API key has no subscription allowance to measure: its work is billed per token and its
# dollars are on the usage line. Only evidence of an API key skips a reading; when the sign-in cannot
# be read the reading is taken, because a reading is what could settle it.
on_api_key() { [[ "$("$SCRIPTS_DIR/billing-mode.sh" detect "$ADAPTER" 2> /dev/null || true)" == api ]]; }

start_one() { # <workforce.json>, for the current vendor
  # A pi member on this vendor's subscription pool draws on the same window as the vendor's own adapter,
  # whatever that adapter's sign-in on this machine says: it is not what pi uses.
  if ! jq -e --arg p "$POOL" '[.members[]? | select(.adapter == "pi" and .pool == $p)] | length > 0' "$1" > /dev/null 2>&1; then
    jq -e --arg a "$ADAPTER" '[.members[]? | .adapter] | index($a) != null' "$1" > /dev/null 2>&1 || return 0
    ! on_api_key || return 0
  fi
  cmd_reading swarm-start > /dev/null
}

cmd_start() {
  local workforce="${1:?Usage: allowance.sh start <workforce.json>}" v
  if [[ -n "$VENDOR_FLAG" ]]; then start_one "$workforce"; return 0; fi
  for v in $VENDORS; do set_vendor "$v"; start_one "$workforce"; done
}

cmd_vendor() {
  local adapter="${1:?Usage: allowance.sh vendor <adapter> [--pool <pool>]}" pool=""
  shift
  if [[ "${1:-}" == --pool ]]; then pool="${2:-}"; fi
  case "$adapter" in
    codex) echo codex ;;
    claude-code) echo claude ;;
    pi) [[ "$pool" == subscription:openai ]] || return 1; echo codex ;;
    *) return 1 ;;
  esac
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
  jq -nc --arg run "$run" --arg vendor "$VENDOR" --arg kind "$kind" --arg pid "$pid" --arg window "$window" --argjson before "$reading" \
    '{ run: $run, vendor: $vendor, kind: $kind, pid: ($pid | tonumber? // null), window: (if $window == "" then null else $window end),
       overlap: false, before: $before }' > "$file.new.$$"
  mv "$file.new.$$" "$file"
  mark_overlap
}

cmd_end() {
  local run="${1:?Usage: allowance.sh end <run>}" file after
  file="$(run_file "$run")"
  # The run knows its vendor (begin wrote it), and that is the only place end takes it from. A
  # --vendor that disagrees is a mistake by the caller, not something to overrule quietly. With no
  # run to ask, the flag or the default stands.
  if [[ -f "$file" ]]; then
    local began; began="$(jq -r '.vendor // "codex"' "$file")"
    [[ -z "$VENDOR_FLAG" || "$VENDOR_FLAG" == "$began" ]] || die "run $run began as $began, not $VENDOR_FLAG"
    set_vendor "$began"
  fi
  # begin decided there was nothing to measure (an API key): no reading, no difference.
  if [[ -f "$file.skipped" ]]; then rm -f "$file.skipped"; echo null; return 0; fi
  after="$(take_reading)"
  append_reading "run-end:$run" "$after"
  if [[ ! -f "$file" ]]; then echo null; return 0; fi
  # The run itself may already look dead (its window is closed), so it is kept; only the others are
  # asked whether they are still live.
  prune "$file"
  mark_overlap
  jq -c --argjson after "$after" --arg pool "$POOL" --arg vendor "$VENDOR" --argjson tol "$SAME_WINDOW_SECONDS" '
    .before as $b
    | def r4: (. * 10000 | round) / 10000;
      def src_ok: $vendor != "claude" or ($b.source == "endpoint" and $after.source == "endpoint");
      def src_reason: "a difference needs two endpoint readings (before: \($b.source // "none"), after: \($after.source // "none"))";
      # Why a section cannot be subtracted, or null if it can: the same three questions for every figure.
      def why($bs; $as):
        if $bs.state != "known" then "the reading before the run was unknown: \($bs.reason)"
        elif $as.state != "known" then "the reading after the run was unknown: \($as.reason)"
        elif (src_ok | not) then src_reason
        else null end;
      def reset($w): (($b[$w].resets_at - $after[$w].resets_at) | fabs) > $tol;
      def points($w):
        why($b[$w]; $after[$w]) as $x
        | if $x != null then { points: null, reason: $x }
          elif $vendor == "codex" and $b.snapshot_at == $after.snapshot_at then { points: null, reason: "Codex wrote nothing new since the run began" }
          elif reset($w) then { points: null, reason: "the window reset during the run" }
          elif $after[$w].used_percent < $b[$w].used_percent then { points: null, reason: "the percentage fell" }
          else { points: (($after[$w].used_percent - $b[$w].used_percent) | r4), reason: null } end;
      def by_model:
        why($b.weekly_by_model; $after.weekly_by_model) as $x
        | if $x != null then { reason: $x, models: [] }
          elif reset("weekly") then { reason: "the window reset during the run", models: [] }
          else { reason: null,
                 models: ([$b.weekly_by_model.models[].model, $after.weekly_by_model.models[].model] | unique | map(. as $m
                   | ($b.weekly_by_model.models | map(select(.model == $m)) | first) as $mb
                   | ($after.weekly_by_model.models | map(select(.model == $m)) | first) as $ma
                   | if $mb == null or $ma == null then { model: $m, points: null, reason: "the model is not in both readings" }
                     elif $ma.used_percent < $mb.used_percent then { model: $m, points: null, reason: "the percentage fell" }
                     else { model: $m, points: (($ma.used_percent - $mb.used_percent) | r4), reason: null } end)) } end;
      def credits_used:
        why($b.credits; $after.credits) as $x
        | if $x != null then { dollars: null, reason: $x }
          elif $after.credits.used < $b.credits.used then { dollars: null, reason: "the amount fell" }
          else { dollars: (($after.credits.used - $b.credits.used) | r4), reason: null } end;
      def batch: { points: null, reason: "runs overlapped; the difference belongs to the batch" };
      { pool: $pool,
        overlap: .overlap,
        attributed_to: (if .overlap then "batch" else "run" end),
        before_snapshot_at: $b.snapshot_at,
        after_snapshot_at: $after.snapshot_at,
        five_hour: (if .overlap then batch else points("five_hour") end),
        weekly: (if .overlap then batch else points("weekly") end) }
      + (if $vendor == "claude" then
           { weekly_by_model: (if .overlap then { reason: batch.reason, models: [] } else by_model end),
             credits: (if .overlap then { dollars: null, reason: batch.reason } else credits_used end) }
         else {} end)' "$file"
  rm -f "$file"
}

main() {
  command -v jq > /dev/null 2>&1 || { echo "allowance.sh needs jq" >&2; exit 3; }
  local cmd="${1:-}"; [[ $# -eq 0 ]] || shift
  # --vendor may come anywhere after the command; the rest is the command's own.
  local vendor="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vendor) vendor="${2:?--vendor needs a value}"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  VENDOR_FLAG="$vendor"
  set_vendor "${vendor:-codex}"
  case "$cmd" in
    reading) cmd_reading ${args[@]+"${args[@]}"} ;;
    start)   cmd_start ${args[@]+"${args[@]}"} ;;
    begin)   cmd_begin ${args[@]+"${args[@]}"} ;;
    end)     cmd_end ${args[@]+"${args[@]}"} ;;
    vendor)  cmd_vendor ${args[@]+"${args[@]}"} ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: allowance.sh reading|start|begin|end|vendor ... [--vendor codex|claude]" >&2; exit 1 ;;
  esac
}

main "$@"
