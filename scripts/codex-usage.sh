#!/usr/bin/env bash
set -euo pipefail
# Read the Codex subscription allowance from Codex's own session logs: how much of the five-hour
# and the weekly window is used, and when each resets.
#
# Usage: codex-usage.sh [--sessions <dir>] [--now <epoch>] [--text]
# Env:   CODEX_SESSIONS_DIR  the sessions directory (default: $CODEX_HOME/sessions, ~/.codex/sessions)
#        CODEX_USAGE_NOW     the Unix time to judge staleness against, as --now (for tests)
#        CODEX_BIN           the codex binary the app-server is asked (default: codex on PATH)
#        CODEX_APP_SERVER    off: never ask the app-server
#        CODEX_APP_SERVER_TIMEOUT  seconds to wait for it (default 15)
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
# When the log cannot give a window (no session at all, or the window has reset since the last
# event) and Codex is installed, `codex app-server` is asked instead: initialize, initialized, then
# account/rateLimits/read, over stdio, with Codex's own login (this script never sees the token). Its
# windows replace the log's, source says "codex app-server", and snapshot_at is the time of the read.
# A log that gives both windows is never replaced and the app-server is not started. If the
# app-server cannot answer (no binary, not signed in, no JSON, no answer in time) the log's reading
# stands and its reason says why the app-server gave nothing. It is not asked when a test or replay
# names its own sessions directory (--sessions or CODEX_SESSIONS_DIR) unless CODEX_BIN says which
# codex to ask, so a codex on PATH is never started by accident. The protocol is experimental.
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

build_reading() { # <event or null> <source> <version>: the reading, from an event shaped like a token_count
  jq -nc --argjson e "$1" --arg source "$2" --arg version "$3" --argjson now "$NOW" '
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
      weekly: pick($rl; 10080) }'
}

# --- The app-server --------------------------------------------------------------

# One exchange with `codex app-server` on two named pipes (bash 3.2 has no coproc, and macOS ships
# it): initialize, initialized, account/rateLimits/read. Prints the answer to the read, or nothing,
# and why on fd 3. The initialize answer's userAgent goes to fd 4 (the version is in it).
live_exchange() { # <codex binary> <dir for the pipes> <seconds>
  local bin="$1" dir="$2" limit="$3" line id deadline now pid result="" ua=""
  mkfifo "$dir/in" "$dir/out" || { echo "the codex app-server could not be started" >&3; return 1; }
  ( exec "$bin" app-server < "$dir/in" > "$dir/out" 2> /dev/null ) &
  pid=$!
  exec 8> "$dir/in" 9< "$dir/out"
  trap '' PIPE
  { printf '%s\n' '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"conductor","version":"1"}}}' \
      '{"method":"initialized"}' '{"method":"account/rateLimits/read","id":2}' >&8; } 2> /dev/null || true
  trap - PIPE
  deadline=$(( $(date +%s) + limit ))
  while now="$(date +%s)"; [[ "$now" -lt "$deadline" ]]; do
    line=""
    read -r -t "$(( deadline - now ))" -u 9 line || { [[ -z "$line" ]] && break; }
    id="$(jq -r 'if type == "object" then (.id // empty) else empty end' <<< "$line" 2> /dev/null || true)"
    if [[ "$id" == 1 ]]; then ua="$(jq -r '.result.userAgent // empty' <<< "$line" 2> /dev/null || true)"; fi
    if [[ "$id" == 2 ]]; then result="$line"; break; fi
  done
  exec 8>&- 9<&-
  kill "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
  if [[ -z "$result" ]]; then
    if [[ "$(date +%s)" -ge "$deadline" ]]; then echo "the codex app-server timed out" >&3; else echo "the codex app-server gave no reading" >&3; fi
    return 1
  fi
  printf '%s\n' "$ua" >&4
  printf '%s\n' "$result"
}

# Ask `codex app-server` for the plan's windows. Prints one JSON object: {"event", "version"}, with
# the event shaped like a token_count's (payload.rate_limits, the log's own key names) so
# build_reading reads it as it reads the log; or {"why"}, one line saying why there is none.
live_event() { # <codex binary>
  local bin="$1" dir limit="${CODEX_APP_SERVER_TIMEOUT:-15}" result="" why="" ua="" version=""
  [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || limit=15
  if ! command -v "$bin" > /dev/null 2>&1; then jq -nc '{why: "no codex binary"}'; return; fi
  dir="$(mktemp -d)"
  { result="$(live_exchange "$bin" "$dir" "$limit" 3> "$dir/why" 4> "$dir/ua")" || result=""; } 2> /dev/null
  why="$(head -n 1 "$dir/why" 2> /dev/null || true)"; ua="$(head -n 1 "$dir/ua" 2> /dev/null || true)"
  rm -rf "$dir"
  version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$ua" | head -n 1 || true)"
  if [[ -z "$result" ]]; then jq -nc --arg why "${why:-the codex app-server gave no reading}" '{why: $why}'; return; fi
  if jq -e 'has("error")' <<< "$result" > /dev/null 2>&1; then jq -nc '{why: "the codex app-server answered with an error"}'; return; fi
  jq -c --argjson now "$NOW" --arg version "$version" '
    def w: if type == "object" then { used_percent: .usedPercent, window_minutes: .windowDurationMins, resets_at: .resetsAt } else null end;
    ((.result.rateLimits // null) | select(type == "object")) as $r
    | if $r == null then { why: "the codex app-server gave no reading" }
      else { version: $version,
             event: { timestamp: ($now | todate),
                      payload: { rate_limits: { plan_type: $r.planType, limit_id: $r.limitId, rate_limit_reached_type: $r.rateLimitReachedType,
                                                primary: ($r.primary | w), secondary: ($r.secondary | w) } } } } end' <<< "$result" 2> /dev/null \
    || jq -nc '{why: "the codex app-server gave no reading"}'
}

# with_live <reading> <explicit sessions dir: yes|no>: the reading, with the app-server's windows
# in place of the log's when the log cannot give both. Never replaces a log that gives both.
# Whether the app-server may be asked at all is decided here and nowhere else: CODEX_APP_SERVER=off
# says no; CODEX_BIN names the binary to ask; otherwise the codex on PATH, except when the sessions
# directory was named (--sessions, CODEX_SESSIONS_DIR), which is what a test or a replay does.
with_live() {
  local reading="$1" explicit="$2" bin="" answer why=""
  [[ "$(jq -r '[.five_hour.state, .weekly.state] | all(. == "known")' <<< "$reading")" == true ]] && { printf '%s\n' "$reading"; return; }
  [[ "${CODEX_APP_SERVER:-}" != off ]] || { printf '%s\n' "$reading"; return; }
  if [[ -n "${CODEX_BIN:-}" ]]; then bin="$CODEX_BIN"
  elif [[ "$explicit" == yes ]]; then printf '%s\n' "$reading"; return
  else bin=codex; fi
  answer="$(live_event "$bin")"
  if jq -e 'has("event")' <<< "$answer" > /dev/null 2>&1; then
    local live
    live="$(build_reading "$(jq -c .event <<< "$answer")" "codex app-server" "$(jq -r .version <<< "$answer")")"
    if [[ "$(jq -r '[.five_hour.state, .weekly.state] | any(. == "known")' <<< "$live")" == true ]]; then
      printf '%s\n' "$live"; return
    fi
    why="the codex app-server had no window that is known"
  else
    why="$(jq -r '.why // ""' <<< "$answer" 2> /dev/null || true)"
  fi
  # The log's reading stands, and each unknown window says why the app-server did not fill it.
  jq -c --arg why "$why" '
    def note: if .state == "unknown" and $why != "" then .reason += "; " + $why else . end;
    .five_hour |= note | .weekly |= note' <<< "$reading"
}

main() {
  local explicit_sessions=no
  [[ -z "${CODEX_SESSIONS_DIR:-}" ]] || explicit_sessions=yes
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sessions) SESSIONS="${2:?--sessions needs a directory}"; explicit_sessions=yes; shift 2 ;;
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
  reading="$(build_reading "$event" "$source" "$version")"
  reading="$(with_live "$reading" "$explicit_sessions")"

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
