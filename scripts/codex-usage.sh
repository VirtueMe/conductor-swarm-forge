#!/usr/bin/env bash
set -euo pipefail
# Read the Codex subscription allowance from Codex's own session logs: how much of the five-hour
# and the weekly window is used, and when each resets.
#
# Usage: codex-usage.sh [--sessions <dir>] [--now <epoch>] [--text]
# Env:   CODEX_SESSIONS_DIR  the sessions directory (default: $CODEX_HOME/sessions, ~/.codex/sessions)
#        CODEX_USAGE_NOW     the Unix time to judge staleness against, as --now (for tests)
#
# Prints one JSON object (--text: two readable lines instead):
#   snapshot_at, source, codex_version, plan_type, limit_id, rate_limit_reached_type
#   five_hour, weekly: { state, reason, window_minutes, used_percent, opened_at, resets_at }
# state is "known" or "unknown". An unknown window has a null used_percent and says why in reason;
# it is never zero and never 100 %. Times are Unix seconds, except snapshot_at, which is the
# event's own timestamp.
#
# Where it comes from. Every token_count event in $CODEX_HOME/sessions/**/rollout-*.jsonl carries
# payload.rate_limits, written by Codex itself, so no model call and no screen scraping is needed.
# The reading is only as fresh as the last Codex event. It takes the newest event with a
# rate_limits object: the newest session file first (by modification time), the newest event in
# it, and it stops there instead of scanning every file. It does not fill a window from an older
# event: a window that is missing in the newest reading is unknown.
#
# A window is identified by its length (window_minutes 300 and 10080), not by the names primary
# and secondary. It is unknown when it is missing from the reading, has no used_percent, has no
# resets_at to tell whether it is stale, has a resets_at that is not in the future (the window has
# reset since the last event, so the stored percentage no longer applies), or has a percentage
# outside 0 to 100. With no rate_limits in any session at all both windows are unknown and the
# exit status is still 0: that is an answer, not an error.
#
# The log format is Codex's own, not a documented interface. The Codex version the reading came
# from (the session's cli_version) is in the output; when the shape changes the windows turn
# unknown, not a guess.

SESSIONS="${CODEX_SESSIONS_DIR:-${CODEX_HOME:-$HOME/.codex}/sessions}"
NOW="${CODEX_USAGE_NOW:-}"   # a test seam: the clock the reading is judged against
FORMAT=json

usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# The newest event with a rate_limits object in one session file, or nothing. grep keeps only the
# token_count lines (measured: 12 ms on a 65 MB session), so reversing them is cheap.
newest_reading() { # <file>
  grep -a 'token_count' "$1" 2> /dev/null | tac \
    | jq -nRc 'first(inputs | fromjson? // empty | select(.payload.rate_limits | type == "object"))' 2> /dev/null \
    || true
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sessions) SESSIONS="${2:?--sessions needs a directory}"; shift 2 ;;
      --now)      NOW="${2:?--now needs a Unix time}"; shift 2 ;;
      --text)     FORMAT=text; shift ;;
      -h|--help)  usage; return 0 ;;
      *) echo "Usage: codex-usage.sh [--sessions <dir>] [--now <epoch>] [--text]" >&2; return 1 ;;
    esac
  done
  [[ -n "$NOW" ]] || NOW="$(date +%s)"
  [[ "$NOW" =~ ^[0-9]+$ ]] || { echo "codex-usage.sh: --now takes a Unix time in seconds" >&2; return 1; }
  command -v jq > /dev/null 2>&1 || { echo "codex-usage.sh needs jq" >&2; return 3; }

  local file event="" source="" version=""
  if [[ -d "$SESSIONS" ]]; then
    while IFS= read -r file; do
      event="$(newest_reading "$file")"
      if [[ -n "$event" ]]; then
        source="$file"
        version="$(head -n 1 "$file" 2> /dev/null | jq -r 'select(.type == "session_meta") | .payload.cli_version // empty' 2> /dev/null || true)"
        break
      fi
    done < <(find "$SESSIONS" -type f -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2> /dev/null | sort -rn | cut -d' ' -f2-)
  fi
  [[ -n "$event" ]] || event=null

  local reading
  reading="$(jq -nc --argjson e "$event" --arg source "$source" --arg version "$version" --argjson now "$NOW" '
    def window($rl; $minutes):
      ([$rl | to_entries[] | .value | select(type == "object" and .window_minutes? == $minutes)] | first) as $w
      | def unknown($why): { state: "unknown", reason: $why, window_minutes: $minutes, used_percent: null,
                             opened_at: null, resets_at: ($w.resets_at? | if type == "number" then . else null end) };
        if $w == null then unknown("no \($minutes)-minute window in the reading")
        elif ($w.used_percent | type) != "number" then unknown("the window has no used_percent")
        elif ($w.resets_at | type) != "number" then unknown("the window has no resets_at")
        elif $w.resets_at <= $now then unknown("the window reset after the last reading")
        elif $w.used_percent < 0 or $w.used_percent > 100 then unknown("used_percent is outside 0 to 100")
        else { state: "known", reason: null, window_minutes: $minutes, used_percent: ($w.used_percent + 0),
               opened_at: ($w.resets_at - $minutes * 60), resets_at: $w.resets_at } end;
    ($e.payload.rate_limits // {}) as $rl
    | def pick($rl; $m): if $e == null then
        { state: "unknown", reason: "no rate_limits in any Codex session", window_minutes: $m, used_percent: null, opened_at: null, resets_at: null }
      else window($rl; $m) end;
    { snapshot_at: ($e.timestamp // null),
      source: (if $source == "" then null else $source end),
      codex_version: (if $version == "" then null else $version end),
      plan_type: ($rl.plan_type // null),
      limit_id: ($rl.limit_id // null),
      rate_limit_reached_type: ($rl.rate_limit_reached_type // null),
      five_hour: pick($rl; 300),
      weekly: pick($rl; 10080) }')"

  if [[ "$FORMAT" == json ]]; then
    printf '%s\n' "$reading"
  else
    jq -r '
      def row($label; $w): ($label + "          ")[0:10]
        + (if $w.state == "known" then "\($w.used_percent)% used, resets \($w.resets_at | todate)"
           else "unknown (\($w.reason))" end);
      "Codex allowance: plan \(.plan_type // "unknown"), Codex \(.codex_version // "unknown"), read \(.snapshot_at // "never")",
      row("5-hour"; .five_hour),
      row("weekly"; .weekly)' <<< "$reading"
  fi
}

main "$@"
