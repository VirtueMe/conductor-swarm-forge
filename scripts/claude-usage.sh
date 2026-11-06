#!/usr/bin/env bash
set -euo pipefail
# Read the Claude Code subscription allowance, the figures /usage shows: the five-hour window, the
# week, the week per model, and the usage credits.
#
# Usage: claude-usage.sh [--now <epoch>] [--text]
# Env:   CLAUDE_CREDENTIALS_FILE  the OAuth login (default ~/.claude/.credentials.json)
#        CLAUDE_JSON_FILE         Claude Code's state file (default ~/.claude.json)
#        CLAUDE_STATUSLINE_FILE   the status line payload saved by claude-statusline-save.sh
#                                 (default ~/.claude/statusline-rate-limits.json)
#        CLAUDE_USAGE_URL         the usage endpoint (default https://api.anthropic.com/api/oauth/usage)
#        CLAUDE_USAGE_NOW         the Unix time to judge staleness against, as --now (for tests)
#
# Prints one JSON object (--text: readable lines instead):
#   snapshot_at, source ("endpoint", "statusline", "cache" or null), age_seconds, checked_version, note
#   five_hour, weekly: { state, reason, window_minutes, used_percent, opened_at, resets_at }
#   weekly_by_model:   { state, reason, models: [ { model, used_percent, opened_at, resets_at, resets_at_source } ] }
#                      The endpoint gives a model's percentage but no reset time of its own, so resets_at is
#                      the week's, and resets_at_source says so ("weekly"). It is an assumption, not a reading.
#   credits:           { state, reason, currency, used, limit }   (dollars, from minor units)
# state is "known" or "unknown". An unknown figure has a null value and says why in reason; it is
# never zero and never 100 %. Times are Unix seconds, except snapshot_at (ISO, UTC), which is when the
# source was read (for the endpoint, when it answered, not the clock --now sets; for the cache, fetchedAtMs).
#
# Where it comes from, in this order (docs/worker-usage-sources.md, "The Claude Code allowance"):
#   1. endpoint  GET /api/oauth/usage with the OAuth token from the credentials file. Not a model
#                call, so it costs no tokens and does not move the allowance. Fresh.
#   2. statusline  the last rate_limits payload a status line command saved (claude-statusline-save.sh):
#                five_hour and weekly only, so per model and credits are unknown from it. No token, no
#                network; age_seconds says how old. A window that has reset since is unknown.
#   3. cache     cachedUsageUtilization in ~/.claude.json: the same shape, no token, no network, but a
#                copy from whenever Claude Code last fetched. age_seconds says how old; a window that
#                has reset since is unknown, because its stored percentage no longer applies.
# The first source that gives a usable answer wins; the other is not mixed in. When the endpoint was
# skipped or failed, note says why (no token, an expired token, a 401, unreachable, a changed shape).
# With no usable source every figure is unknown and the exit status is still 0: that is an answer,
# not an error.
#
# None of the sources is a documented interface. checked_version is the Claude Code release the shapes
# were checked on; unknown keys are ignored, and a shape that has changed turns figures unknown
# rather than guessed. The token is read, sent to the endpoint through curl's stdin, and never
# printed, logged or put on a command line. The credentials and state files are read for the one
# thing needed from each; nothing else in them is copied.
#
# The percentages are whole points in practice, so a run under a point does not show.

CHECKED_VERSION="2.1.318"
CREDENTIALS="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
STATE_FILE="${CLAUDE_JSON_FILE:-$HOME/.claude.json}"
STATUSLINE_FILE="${CLAUDE_STATUSLINE_FILE:-$HOME/.claude/statusline-rate-limits.json}"
URL="${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
NOW="${CLAUDE_USAGE_NOW:-}"
FORMAT=json

usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# The one jq program that turns a /api/oauth/usage response (from either source) into the windows.
# Arguments: $u the response, $source, $snap (ms), $now, $note, $lacks (null, or {weekly_by_model, credits}:
# why the source cannot say that figure, which makes it unknown with that reason).
# shellcheck disable=SC2016  # a jq program: the $names are jq's, not the shell's
READ_PROGRAM='
  def epoch: if type == "string"
      then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null) else null end;
  def pct_ok: type == "number" and . >= 0 and . <= 100;
  def window($w; $minutes):
    ($w // null) as $x
    | def unknown($why): { state: "unknown", reason: $why, window_minutes: $minutes, used_percent: null, opened_at: null,
                           resets_at: (if ($x | type) == "object" then ($x.resets_at | epoch) else null end) };
      if ($x | type) != "object" then unknown("no \($minutes)-minute window in the reading")
      elif ($x.utilization | type) != "number" then unknown("the window has no utilization")
      elif ($x.resets_at | epoch) == null then unknown("the window has no usable resets_at")
      elif ($x.resets_at | epoch) <= $now then unknown("the window reset after the reading")
      elif ($x.utilization | pct_ok | not) then unknown("utilization is outside 0 to 100")
      else { state: "known", reason: null, window_minutes: $minutes, used_percent: ($x.utilization + 0),
             opened_at: (($x.resets_at | epoch) - $minutes * 60), resets_at: ($x.resets_at | epoch) } end;
  def none($why; $minutes): { state: "unknown", reason: $why, window_minutes: $minutes, used_percent: null, opened_at: null, resets_at: null };
  def dollars($m; $places): if ($m | type) == "number" then ($m / pow(10; $places)) else null end;

  if $u == null then
    { five_hour: none($note; 300), weekly: none($note; 10080),
      weekly_by_model: { state: "unknown", reason: $note, models: [] },
      credits: { state: "unknown", reason: $note, currency: null, used: null, limit: null } }
  else
    window($u.five_hour; 300) as $five
    | window($u.seven_day; 10080) as $week
    | ([($u.limits // [])[]? | select(type == "object" and .kind == "weekly_scoped")]) as $scoped
    | ($u.extra_usage // {}) as $extra
    | ($extra.decimal_places | if type == "number" then . else 2 end) as $places
    | { five_hour: $five, weekly: $week,
        weekly_by_model:
          (if $week.state != "known" then { state: "unknown", reason: "the weekly window is unknown: \($week.reason)", models: [] }
           elif ($scoped | any(.percent | pct_ok | not)) then
             { state: "unknown", reason: "a per-model percent is missing or outside 0 to 100", models: [] }
           elif ($scoped | any((.scope.model.display_name | type) != "string")) then
             { state: "unknown", reason: "a per-model limit does not name its model", models: [] }
           else { state: "known", reason: null,
                  models: [$scoped[] | { model: .scope.model.display_name, used_percent: (.percent + 0),
                                         opened_at: $week.opened_at, resets_at: $week.resets_at,
                                         resets_at_source: "weekly" }] } end),
        credits:
          (if ($u.spend | type) != "object" or ($u.spend.used.amount_minor | type) != "number" or ($u.spend.limit.amount_minor | type) != "number"
           then { state: "unknown", reason: "no spend figures in the reading", currency: null, used: null, limit: null }
           elif $extra.is_enabled == false
           then { state: "unknown", reason: "extra usage is not enabled", currency: ($extra.currency // null), used: null, limit: null }
           else { state: "known", reason: null, currency: ($extra.currency // null),
                  used: dollars($u.spend.used.amount_minor; $places), limit: dollars($u.spend.limit.amount_minor; $places) } end) }
  end
  | if ($lacks.weekly_by_model // null) != null
    then .weekly_by_model = { state: "unknown", reason: $lacks.weekly_by_model, models: [] } else . end
  | if ($lacks.credits // null) != null
    then .credits = { state: "unknown", reason: $lacks.credits, currency: null, used: null, limit: null } else . end
  | { snapshot_at: (if $snap == null then null else ($snap / 1000 | floor | todate) end),
      source: (if $source == "" then null else $source end),
      age_seconds: (if $snap == null then null else ([$now - ($snap / 1000 | floor), 0] | max) end),
      checked_version: $ver,
      note: (if $note == "" then null else $note end) } + .'

# Each source answers with one JSON object, {body, note, at, lacks}: the response (null when there is
# none), why there is none, when it was taken (Unix seconds, null if unknown), and which figures it
# cannot give at all (null, or {weekly_by_model, credits} with the reason for each). Nothing is shared
# with the caller through variables, and the token is never in what is printed.
answer() { # <body json or null> <note or ""> <taken at or ""> [lacks json]
  jq -nc --argjson body "$1" --arg note "$2" --arg at "$3" --argjson lacks "${4:-null}" \
    '{ body: $body, note: (if $note == "" then null else $note end), at: (if $at == "" then null else ($at | tonumber) end), lacks: $lacks }'
}

# Tries the endpoint. <dir> is a scratch directory for the response.
fetch_endpoint() { # <dir>
  local token expires body code taken
  if [[ ! -r "$CREDENTIALS" ]]; then answer null "no OAuth login on this machine" ""; return 0; fi
  token="$(jq -r '.claudeAiOauth.accessToken // empty | select(type == "string")' "$CREDENTIALS" 2> /dev/null || true)"
  if [[ -z "$token" ]]; then answer null "no OAuth token in the credentials file" ""; return 0; fi
  # curl's config syntax quotes a value: refuse one that could break out of it.
  if [[ "$token" == *[\"\\[:cntrl:]]* ]]; then answer null "the OAuth token has an unusable form" ""; return 0; fi
  expires="$(jq -r '.claudeAiOauth.expiresAt // empty | select(type == "number")' "$CREDENTIALS" 2> /dev/null || true)"
  if [[ -n "$expires" && "$(( expires / 1000 ))" -le "$NOW" ]]; then
    answer null "the OAuth token has expired (Claude Code refreshes it when it runs)" ""; return 0
  fi
  command -v curl > /dev/null 2>&1 || { answer null "curl is not installed" ""; return 0; }
  body="$1/body"
  code="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$token" \
    | curl -sS --max-time 10 -K - -o "$body" -w '%{http_code}' "$URL" 2> /dev/null)" || code=000
  taken="$(date +%s)"   # when the endpoint answered: the reading's own time, not the clock it is judged by
  case "$code" in
    200) ;;
    401|403) answer null "the endpoint refused the token ($code)" ""; return 0 ;;
    000) answer null "the endpoint could not be reached" ""; return 0 ;;
    *) answer null "the endpoint answered $code" ""; return 0 ;;
  esac
  # The shape: an object with at least one of the windows. Anything else has changed under us.
  if jq -e 'type == "object" and ((.five_hour | type) == "object" or (.seven_day | type) == "object")' "$body" > /dev/null 2>&1; then
    answer "$(cat "$body")" "" "$taken"
  else
    answer null "the endpoint answered in a shape this reader does not know" ""
  fi
}

# The cached copy: {fetchedAtMs, utilization}, and nothing else from the file.
read_cache() {
  if [[ ! -r "$STATE_FILE" ]]; then answer null "no ~/.claude.json" ""; return 0; fi
  local out
  out="$(jq -c '.cachedUsageUtilization | select(type == "object" and (.fetchedAtMs | type) == "number" and (.utilization | type) == "object")
                | { utilization, at: (.fetchedAtMs / 1000 | floor) }' "$STATE_FILE" 2> /dev/null || true)"
  if [[ -z "$out" ]]; then answer null "no cachedUsageUtilization in ~/.claude.json" ""; return 0; fi
  answer "$(jq -c .utilization <<< "$out")" "" "$(jq -r .at <<< "$out")"
}

# The saved status line payload, turned into the endpoint's shape so the one program reads it:
# {used_percentage, resets_at (epoch)} becomes {utilization, resets_at (ISO)}. at is when it was saved.
# It is a source only while it still knows something: with every window it holds already reset (or
# out of range), it gives way to the next source instead of winning with nothing.
read_statusline() {
  if [[ ! -r "$STATUSLINE_FILE" ]]; then answer null "" ""; return 0; fi
  local out
  out="$(jq -c '
    def win: if type == "object"
      then { utilization: .used_percentage, resets_at: (if (.resets_at | type) == "number" then (.resets_at | floor | todate) else null end) }
      else null end;
    def open: type == "object" and (.used_percentage | type) == "number" and .used_percentage >= 0 and .used_percentage <= 100
              and (.resets_at | type) == "number" and .resets_at > $now;
    select(type == "object" and (.taken_at | type) == "number" and (.rate_limits | type) == "object"
           and ((.rate_limits.five_hour | open) or (.rate_limits.seven_day | open)))
    | { body: { five_hour: (.rate_limits.five_hour | win), seven_day: (.rate_limits.seven_day | win) }, at: (.taken_at | floor) }' \
    --argjson now "$NOW" "$STATUSLINE_FILE" 2> /dev/null || true)"
  if [[ -z "$out" ]]; then answer null "" ""; return 0; fi
  answer "$(jq -c .body <<< "$out")" "" "$(jq -r .at <<< "$out")" \
    '{"weekly_by_model":"the status line payload has no per-model figures","credits":"the status line payload has no credits"}'
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --now)      NOW="${2:?--now needs a Unix time}"; shift 2 ;;
      --text)     FORMAT=text; shift ;;
      -h|--help)  usage; return 0 ;;
      *) echo "Usage: claude-usage.sh [--now <epoch>] [--text]" >&2; return 1 ;;
    esac
  done
  [[ -n "$NOW" ]] || NOW="$(date +%s)"
  [[ "$NOW" =~ ^[0-9]+$ ]] || { echo "claude-usage.sh: --now takes a Unix time in seconds" >&2; return 1; }
  command -v jq > /dev/null 2>&1 || { echo "claude-usage.sh needs jq" >&2; return 3; }

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expanded now on purpose: $work is local and gone when the trap runs
  trap "rm -rf '$work'" EXIT

  # The endpoint first; failing that, each fallback in order, and the first with a body wins. A fallback
  # is "<name>|<what the note says it used>", read by read_<name>. A source that is merely absent says
  # nothing; one that has a reason to give (a missing file, a changed shape) adds it to the note.
  local u="null" source="" snap="null" lacks="null" note="" from ans f name using why reasons=""
  from="$(fetch_endpoint "$work")"
  if [[ "$(jq -r '.body == null' <<< "$from")" == false ]]; then
    u="$(jq -c .body <<< "$from")"; source=endpoint; snap="$(jq -r '.at * 1000' <<< "$from")"
  else
    for f in "statusline|using the last status line payload saved" "cache|using the copy Claude Code last stored"; do
      name="${f%%|*}"; using="${f#*|}"
      ans="$("read_$name")"
      if [[ "$(jq -r '.body == null' <<< "$ans")" == false ]]; then
        u="$(jq -c .body <<< "$ans")"; source="$name"; snap="$(jq -r '.at * 1000' <<< "$ans")"
        lacks="$(jq -c .lacks <<< "$ans")"
        note="$(jq -r .note <<< "$from"); $using"
        break
      fi
      why="$(jq -r '.note // empty' <<< "$ans")"
      [[ -z "$why" ]] || reasons+="; $why"
    done
    [[ -n "$source" ]] || note="$(jq -r .note <<< "$from")$reasons"
  fi

  local reading
  reading="$(jq -nc --argjson u "$u" --arg source "$source" --argjson snap "$snap" --argjson now "$NOW" --argjson lacks "$lacks" \
    --arg note "$note" --arg ver "$CHECKED_VERSION" "$READ_PROGRAM")"

  if [[ "$FORMAT" == json ]]; then
    printf '%s\n' "$reading"
  else
    jq -r '
      def row($label; $w): ($label + "          ")[0:10]
        + (if $w.state == "known" then "\($w.used_percent)% used, resets \($w.resets_at | todate)"
           else "unknown (\($w.reason))" end);
      "Claude allowance: from \(.source // "nothing"), read \(.snapshot_at // "never")"
        + (if .source == "cache" then " (\(.age_seconds / 3600 | floor) h old)"
           elif .source == "statusline" then " (\(.age_seconds / 60 | floor) min old)" else "" end),
      row("5-hour"; .five_hour),
      row("weekly"; .weekly),
      (if .weekly_by_model.state == "known"
         then (.weekly_by_model.models[] | row(.model; {state: "known", used_percent, resets_at}))
         else "per model  unknown (\(.weekly_by_model.reason))" end),
      (if .credits.state == "known"
         then "credits    \(.credits.used) of \(.credits.limit) \(.credits.currency // "")"
         else "credits    unknown (\(.credits.reason))" end),
      (if .note then "note       \(.note)" else empty end)' <<< "$reading"
  fi
}

main "$@"
