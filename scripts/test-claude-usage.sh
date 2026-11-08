#!/usr/bin/env bash
# Tests scripts/claude-usage.sh against fixtures in tests/claude-usage/: the response of the usage
# endpoint (one trimmed from a real capture, others made by hand for what a real one does not show on
# demand), and the cached copy in ~/.claude.json. The endpoint is a stub curl on the PATH, so no
# network, no Claude Code and no allowance is touched. Above all that a figure the reader cannot trust
# is unknown, never zero and never 100 %, and that the token never leaves curl's stdin.
#
# Usage: scripts/test-claude-usage.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
READER="$SCRIPTS_DIR/claude-usage.sh"
FX="$SCRIPTS_DIR/../tests/claude-usage"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
has() { if grep -q -- "$1" "$TMP/text"; then ok "$2"; else fail "$2 (in output: $(tr '\n' '|' < "$TMP/text" | cut -c1-300))"; fi; }

NOW=1793865600   # 2026-11-05 08:00 UTC: before the five-hour window resets (09:10) and the weekly one (11-07 04:00)
FIVE_RESETS=1793869800
WEEK_RESETS=1794024000

# A curl that never reaches a network: it answers with $STUB_CODE and the file $STUB_BODY, and keeps
# what it was given (its arguments, and what came on stdin) so the test can see where the token went.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift 2 ;; -D) hdr="$2"; shift 2 ;; *) printf '%s\n' "$1" >> "$STUB_LOG.args"; shift ;; esac
done
cat > "$STUB_LOG.stdin"
echo called >> "$STUB_LOG.calls"
[[ -z "${hdr:-}" ]] || { printf 'HTTP/2 %s\r\n' "${STUB_CODE:-200}"; [[ -z "${STUB_RETRY_AFTER:-}" ]] || printf 'Retry-After: %s\r\n' "$STUB_RETRY_AFTER"; } > "$hdr"
[[ "${STUB_CODE:-200}" != 000 ]] || exit 7
[[ -z "$out" || -z "${STUB_BODY:-}" ]] || cp "$STUB_BODY" "$out"
printf '%s' "${STUB_CODE:-200}"
STUB
chmod +x "$TMP/bin/curl"
export STUB_LOG="$TMP/stub"
# The endpoint's state is the test's own, never ~/.claude, and starts empty at every read (section 10 keeps it).
export CLAUDE_USAGE_STATE_FILE="$TMP/endpoint-state.json"

# read_json <credentials> <state file> <endpoint body or ""> [code] [now]
read_json() {
  rm -f "$STUB_LOG".*
  [[ -n "${KEEP_STATE:-}" ]] || rm -rf "$CLAUDE_USAGE_STATE_FILE" "$CLAUDE_USAGE_STATE_FILE.lock"
  export STUB_BODY="$3" STUB_CODE="${4:-200}"
  RC=0
  OUT="$(PATH="$TMP/bin:$PATH" CLAUDE_CREDENTIALS_FILE="$1" CLAUDE_JSON_FILE="$2" CLAUDE_USAGE_NOW="${5:-$NOW}" \
    CLAUDE_STATUSLINE_FILE="${STATUSLINE:-$TMP/no-statusline.json}" "$READER" 2> "$TMP/err")" || RC=$?
}
j() { jq -r "$1" <<< "$OUT"; }
calls() { if [[ -f "$STUB_LOG.calls" ]]; then wc -l < "$STUB_LOG.calls" | tr -d ' '; else echo 0; fi; }

CRED="$FX/credentials.json"
NOCACHE="$FX/claude-no-cache.json"

section "1 · A reading from the endpoint"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json"
assert_eq "exit 0" "$RC" "0"
assert_eq "the source" "$(j .source)" "endpoint"
# The snapshot is when the endpoint answered, which is the real clock; --now only sets what it is judged by.
# shellcheck disable=SC2016  # a jq program
assert_eq "the snapshot is the moment of the call, not --now" "$(j '(.snapshot_at | fromdateiso8601) as $t | (now - $t) | (. >= 0 and . < 60)')" "true"
assert_eq "the version the shape was checked on is in the reading" "$(j .checked_version)" "2.1.318"
assert_eq "five-hour window: known, percent used" "$(j '.five_hour | [.state, .used_percent] | map(tostring) | join(" ")')" "known 10"
assert_eq "when it resets, and so when it opened" "$(j '.five_hour | [.resets_at, .opened_at] | map(tostring) | join(" ")')" "$FIVE_RESETS $(( FIVE_RESETS - 18000 ))"
assert_eq "weekly window: known, percent used" "$(j '.weekly | [.state, .used_percent] | map(tostring) | join(" ")')" "known 20"
assert_eq "the weekly reset (microseconds dropped)" "$(j '.weekly.resets_at')" "$WEEK_RESETS"
assert_eq "per model: known, one model" "$(j '.weekly_by_model | [.state, (.models | length)] | map(tostring) | join(" ")')" "known 1"
assert_eq "the model is named, and 0 % is a real 0" "$(j '.weekly_by_model.models[0] | [.model, .used_percent] | map(tostring) | join(" ")')" "Fable 0"
assert_eq "a model's window is the week's" "$(j '.weekly_by_model.models[0].resets_at')" "$WEEK_RESETS"
assert_eq "and the reading says that is an assumption" "$(j '.weekly_by_model.models[0].resets_at_source')" "weekly"
assert_eq "credits in dollars, from minor units" "$(j '.credits | [.state, .currency, .used, .limit] | map(tostring) | join(" ")')" "known USD 0 100"
assert_eq "no note when the endpoint answered" "$(j '.note | tostring')" "null"
assert_eq "the endpoint was asked once" "$(calls)" "1"

section "2 · Unknown keys and other values are tolerated"
read_json "$CRED" "$NOCACHE" "$FX/endpoint-extra.json"
assert_eq "a fractional percent is kept" "$(j .five_hour.used_percent)" "37.5"
assert_eq "a reset time with no fraction of a second" "$(j .five_hour.resets_at)" "$FIVE_RESETS"
assert_eq "an unknown kind of limit is not a model" "$(j '[.weekly_by_model.models[].model] | join(" ")')" "Fable Sonnet"
assert_eq "credits drawn" "$(j '.credits | [.used, .limit] | map(tostring) | join(" ")')" "4.25 100"

section "3 · A figure the reader cannot trust is unknown, never zero and never 100"
read_json "$CRED" "$NOCACHE" "$FX/endpoint-reset.json"
assert_eq "a reset five-hour window: unknown, the old percentage no longer applies" \
  "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "and says so" "$(j .five_hour.reason)" "the window reset after the reading"
assert_eq "the other window is not dragged down with it" "$(j .weekly.state)" "known"
read_json "$CRED" "$NOCACHE" "$FX/endpoint-bad-values.json"
assert_eq "a percentage outside 0 to 100: unknown" "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "and says why" "$(j .five_hour.reason)" "utilization is outside 0 to 100"
assert_eq "a window with no utilization: unknown" "$(j '.weekly | [.state, .reason] | join(" ")')" "unknown the window has no utilization"
assert_eq "per model is unknown when the week is" "$(j .weekly_by_model.state)" "unknown"
read_json "$CRED" "$NOCACHE" "$FX/endpoint-no-credits.json"
assert_eq "extra usage switched off: credits unknown, with the reason" "$(j '.credits | [.state, .reason, (.used | tostring)] | join(" / ")')" "unknown / extra usage is not enabled / null"
assert_eq "the windows are still read" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "known known"

section "4 · The endpoint fails: the cached copy, or unknown"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json" 401
assert_eq "a 401: the cache is used" "$(j .source)" "cache"
assert_eq "and the note says why" "$(j .note)" "the endpoint refused the token (401); using the copy Claude Code last stored"
assert_eq "the snapshot is when Claude Code fetched, not now" "$(j .snapshot_at)" "2026-11-04T14:26:00Z"
assert_eq "its age is shown" "$(j .age_seconds)" "$(( NOW - 1793802360 ))"
assert_eq "a cached window that has reset since is unknown" "$(j '.five_hour | [.state, .reason] | join(" ")')" "unknown the window reset after the reading"
assert_eq "a cached window still open is known" "$(j '.weekly | [.state, .used_percent] | map(tostring) | join(" ")')" "known 17"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json" 401
assert_eq "a 401 and no cache: everything unknown" "$(j '[.five_hour.state, .weekly.state, .weekly_by_model.state, .credits.state, (.source | tostring)] | join(" ")')" "unknown unknown unknown unknown null"
assert_eq "the reason names both" "$(j .five_hour.reason)" "the endpoint refused the token (401); no cachedUsageUtilization in ~/.claude.json"
assert_eq "that is an answer, not an error: exit 0" "$RC" "0"
read_json "$CRED" "$NOCACHE" "" 000
assert_eq "unreachable" "$(j .five_hour.reason)" "the endpoint could not be reached; no cachedUsageUtilization in ~/.claude.json"
assert_eq "exit 0" "$RC" "0"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json" 500
assert_eq "a server error" "$(j .five_hour.reason)" "the endpoint answered 500; no cachedUsageUtilization in ~/.claude.json"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint-changed.json"
assert_eq "a shape that has changed: not guessed from, the cache is used" "$(j .source)" "cache"
assert_eq "and the note says the shape" "$(j .note)" "the endpoint answered in a shape this reader does not know; using the copy Claude Code last stored"
read_json "$CRED" "$TMP/missing.json" "$FX/endpoint-changed.json"
assert_eq "no state file at all" "$(j .five_hour.reason)" "the endpoint answered in a shape this reader does not know; no ~/.claude.json"

section "5 · No usable token: the endpoint is not called"
read_json "$FX/credentials-no-token.json" "$NOCACHE" "$FX/endpoint.json"
assert_eq "a file with no token" "$(j .five_hour.reason)" "no OAuth token in the credentials file; no cachedUsageUtilization in ~/.claude.json"
assert_eq "curl was not run" "$(calls)" "0"
read_json "$FX/credentials-bad-token.json" "$NOCACHE" "$FX/endpoint.json"
assert_eq "a token that could break out of curl's config is refused" "$(j .five_hour.reason)" "the OAuth token has an unusable form; no cachedUsageUtilization in ~/.claude.json"
assert_eq "curl was not run" "$(calls)" "0"
read_json "$TMP/missing.json" "$FX/claude.json" "$FX/endpoint.json"
assert_eq "no credentials file: the cache is used" "$(j .source)" "cache"
assert_eq "curl was not run" "$(calls)" "0"
read_json "$FX/credentials-expired.json" "$NOCACHE" "$FX/endpoint.json"
assert_eq "an expired token is not sent" "$(j '.note | startswith("the OAuth token has expired")')" "true"
assert_eq "curl was not run" "$(calls)" "0"

section "6 · The token goes only through curl's stdin"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json"
assert_eq "curl got the token on stdin, as a header" "$(grep -c 'Authorization: Bearer sk-ant-oat01-FAKE-TOKEN-FOR-TESTS' "$STUB_LOG.stdin")" "1"
assert_eq "and the beta header" "$(grep -c 'anthropic-beta: oauth-2025-04-20' "$STUB_LOG.stdin")" "1"
assert_eq "the token is not in curl's arguments" "$(grep -c 'FAKE-TOKEN' "$STUB_LOG.args" || true)" "0"
assert_eq "not in the reading" "$(grep -c 'FAKE' <<< "$OUT" || true)" "0"
assert_eq "not on stderr" "$(grep -c 'FAKE' "$TMP/err" || true)" "0"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json" 401
assert_eq "the rest of the state file is not copied" "$(grep -c 'do-not-copy\|accountUuid\|00000000' <<< "$OUT" || true)" "0"

section "7 · Readable output"
rm -f "$STUB_LOG".*; export STUB_BODY="$FX/endpoint-extra.json" STUB_CODE=200
RC=0; PATH="$TMP/bin:$PATH" CLAUDE_CREDENTIALS_FILE="$CRED" CLAUDE_JSON_FILE="$NOCACHE" CLAUDE_USAGE_NOW="$NOW" \
  "$READER" --text > "$TMP/text" 2> /dev/null || RC=$?
assert_eq "exit 0" "$RC" "0"
has '^5-hour  *37.5% used' "the five-hour window shows its percentage"
has '^weekly  *61% used' "the weekly window"
has '^Fable  *12% used' "a model's window"
has '^credits  *4.25 of 100 USD' "the credits"
rm -f "$CLAUDE_USAGE_STATE_FILE"; RC=0; PATH="$TMP/bin:$PATH" CLAUDE_CREDENTIALS_FILE="$CRED" CLAUDE_JSON_FILE="$FX/claude.json" CLAUDE_USAGE_NOW="$NOW" STUB_CODE=401 \
  "$READER" --text > "$TMP/text" 2> /dev/null || RC=$?
has 'from cache.* (17 h old)' "a cached reading says how old it is"
has '^5-hour  *unknown' "a reset cached window reads as unknown"

section "8 · The status line payload: after the endpoint, before the cached copy"
STATUSLINE="$FX/statusline.json"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json" 401
assert_eq "endpoint refused, a saved payload and a cache: the payload wins" "$(j .source)" "statusline"
assert_eq "the note says why, and what was used" "$(j .note)" "the endpoint refused the token (401); using the last status line payload saved"
assert_eq "the snapshot is when the payload was saved" "$(j .snapshot_at)" "2026-11-05T07:50:00Z"
assert_eq "its age is shown" "$(j .age_seconds)" "$(( NOW - 1793865000 ))"
assert_eq "five-hour: known, percent used" "$(j '.five_hour | [.state, .used_percent] | map(tostring) | join(" ")')" "known 10"
assert_eq "when it resets, and so when it opened" "$(j '.five_hour | [.resets_at, .opened_at] | map(tostring) | join(" ")')" "$FIVE_RESETS $(( FIVE_RESETS - 18000 ))"
assert_eq "weekly: known, the payload's own percent" "$(j '.weekly | [.state, .used_percent, .resets_at] | map(tostring) | join(" ")')" "known 19 $WEEK_RESETS"
assert_eq "per model is unknown, not an empty known list" "$(j '.weekly_by_model | [.state, (.models | length)] | map(tostring) | join(" ")')" "unknown 0"
assert_eq "and says the payload does not carry it" "$(j .weekly_by_model.reason)" "the status line payload has no per-model figures"
assert_eq "credits are unknown too" "$(j '.credits | [.state, .reason, (.used | tostring)] | join(" / ")')" "unknown / the status line payload has no credits / null"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json"
assert_eq "an endpoint that answers wins over the payload" "$(j .source)" "endpoint"
STATUSLINE="$FX/statusline-lapsed.json"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json" 401
assert_eq "a payload whose windows have all reset knows nothing: the cache gets its turn" "$(j .source)" "cache"
assert_eq "and the cache's week is read" "$(j '.weekly | [.state, .used_percent] | map(tostring) | join(" ")')" "known 17"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json" 401
assert_eq "all reset and no cache: everything unknown, no source, the old reason" "$(j '[.five_hour.state, .weekly.state, (.source | tostring)] | join(" ")')" "unknown unknown null"
STATUSLINE="$FX/statusline.json"
STATUSLINE="$FX/statusline-reset.json"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json" 401
assert_eq "one window reset since it was saved: that one is unknown" "$(j '.five_hour | [.state, .reason] | join(" ")')" "unknown the window reset after the reading"
assert_eq "the other is still read" "$(j '.weekly | [.state, .used_percent] | map(tostring) | join(" ")')" "known 19"
STATUSLINE="$FX/statusline-empty.json"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json" 401
assert_eq "a saved file with no rate_limits is not a source: the cache is used" "$(j .source)" "cache"
assert_eq "and the note is the cache's, as before" "$(j .note)" "the endpoint refused the token (401); using the copy Claude Code last stored"
echo '{"taken_at":' > "$TMP/broken.json"; STATUSLINE="$TMP/broken.json"
read_json "$CRED" "$FX/claude.json" "$FX/endpoint.json" 401
assert_eq "a broken file is not a source either" "$(j .source)" "cache"
STATUSLINE="$TMP/missing.json"
read_json "$CRED" "$NOCACHE" "$FX/endpoint.json" 401
assert_eq "no file, no cache: unknown, with the old reason (the missing payload adds no noise)" "$(j .five_hour.reason)" "the endpoint refused the token (401); no cachedUsageUtilization in ~/.claude.json"
STATUSLINE="$FX/statusline.json"
rm -f "$STUB_LOG".* "$CLAUDE_USAGE_STATE_FILE"; export STUB_BODY="$FX/endpoint.json" STUB_CODE=401
RC=0; PATH="$TMP/bin:$PATH" CLAUDE_CREDENTIALS_FILE="$CRED" CLAUDE_JSON_FILE="$NOCACHE" CLAUDE_USAGE_NOW="$NOW" CLAUDE_STATUSLINE_FILE="$STATUSLINE" \
  "$READER" --text > "$TMP/text" 2> /dev/null || RC=$?
has 'from statusline.* (10 min old)' "text output says the payload's age"
has '^per model  *unknown' "and per model reads as unknown"
unset STATUSLINE

section "10 · A swarm's burst: a fresh answer is reused, and a 429 is waited out"
CLOCK=1000000
read_clock() { KEEP_STATE=1 CLAUDE_USAGE_CLOCK="$CLOCK" read_json "$@"; }
rm -rf "$CLAUDE_USAGE_STATE_FILE" "$CLAUDE_USAGE_STATE_FILE.lock"
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "the first read asks the endpoint" "$(calls)" "1"
assert_eq "and keeps the answer" "$(jq -r '.taken_at' "$CLAUDE_USAGE_STATE_FILE")" "$CLOCK"
FIRST="$OUT"
CLOCK=1000030
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "30 s later nobody asks again" "$(calls)" "0"
assert_eq "it is still the endpoint's answer" "$(j .source)" "endpoint"
assert_eq "with the figures of the first" "$(j .five_hour.used_percent)" "$(jq -r .five_hour.used_percent <<< "$FIRST")"
assert_eq "and its own time, so the age shows" "$(j .snapshot_at)" "$(jq -r .snapshot_at <<< "$FIRST")"
assert_eq "no note: nothing went wrong" "$(j '.note | tostring')" "null"
CLOCK=1000061
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "after the minute it asks again" "$(calls)" "1"

# A 429 with a Retry-After: nobody asks until it is over; the cache stands in and the note says why.
rm -rf "$CLAUDE_USAGE_STATE_FILE"; CLOCK=2000000
export STUB_RETRY_AFTER=90
read_clock "$CRED" "$FX/claude.json" "" 429
assert_eq "a 429 is asked once" "$(calls)" "1"
assert_eq "the cache stands in" "$(j .source)" "cache"
assert_eq "the note says 429 and for how long, then what was used" "$(j .note)" "the endpoint answered 429; not asking again for 90 s; using the copy Claude Code last stored"
assert_eq "the state holds the end of the wait" "$(jq -r .blocked_until "$CLAUDE_USAGE_STATE_FILE")" "2000090"
unset STUB_RETRY_AFTER
CLOCK=2000040
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "inside the wait the endpoint is left alone" "$(calls)" "0"
assert_eq "the note counts down" "$(j .note)" "the endpoint answered 429; not asking again for 50 s; using the copy Claude Code last stored"
CLOCK=2000090
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "when it is over it asks again" "$(calls)" "1"
assert_eq "and the endpoint answers" "$(j .source)" "endpoint"
assert_eq "a good answer ends the wait" "$(jq -r .blocked_until "$CLAUDE_USAGE_STATE_FILE")" "null"

# No Retry-After: the default; a huge one is capped.
rm -rf "$CLAUDE_USAGE_STATE_FILE"; CLOCK=3000000
read_clock "$CRED" "$FX/claude.json" "" 429
assert_eq "no Retry-After: 120 s" "$(jq -r .blocked_until "$CLAUDE_USAGE_STATE_FILE")" "3000120"
rm -rf "$CLAUDE_USAGE_STATE_FILE"; export STUB_RETRY_AFTER=999999
read_clock "$CRED" "$FX/claude.json" "" 429
assert_eq "a huge Retry-After is capped at 15 minutes" "$(jq -r .blocked_until "$CLAUDE_USAGE_STATE_FILE")" "3000900"
unset STUB_RETRY_AFTER

# A state file that is not ours is not trusted; a lock left by a dead caller does not block for ever.
echo 'not json' > "$CLAUDE_USAGE_STATE_FILE"
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "a broken state file is no state" "$(calls)" "1"
rm -rf "$CLAUDE_USAGE_STATE_FILE"; mkdir "$CLAUDE_USAGE_STATE_FILE.lock"; touch -d '10 minutes ago' "$CLAUDE_USAGE_STATE_FILE.lock"
read_clock "$CRED" "$FX/claude.json" "$FX/endpoint.json" 200
assert_eq "a stale lock is cleared" "$(calls)" "1"
assert_eq "and released" "$([[ -d "$CLAUDE_USAGE_STATE_FILE.lock" ]] && echo held || echo free)" "free"

# Callers in a burst take turns: five at once make one request.
rm -rf "$CLAUDE_USAGE_STATE_FILE"; rm -f "$STUB_LOG".*; CLOCK=4000000
export STUB_BODY="$FX/endpoint.json" STUB_CODE=200
for i in 1 2 3 4 5; do
  ( PATH="$TMP/bin:$PATH" CLAUDE_CREDENTIALS_FILE="$CRED" CLAUDE_JSON_FILE="$FX/claude.json" CLAUDE_USAGE_NOW="$NOW" CLAUDE_USAGE_CLOCK="$CLOCK" \
      CLAUDE_STATUSLINE_FILE="$TMP/no-statusline.json" "$READER" > "$TMP/burst.$i" 2> /dev/null ) &
done
wait
assert_eq "five callers at once: one request" "$(calls)" "1"
assert_eq "and all five got the endpoint's answer" "$(cat "$TMP"/burst.* | jq -r .source | sort -u)" "endpoint"
unset KEEP_STATE

section "9 · Arguments"
RC=0; "$READER" --bogus > /dev/null 2>&1 || RC=$?
assert_eq "an unknown flag: exit 1" "$RC" "1"
RC=0; "$READER" --now abc > /dev/null 2>&1 || RC=$?
assert_eq "a --now that is not a number: exit 1" "$RC" "1"
RC=0; "$READER" --help > /dev/null 2>&1 || RC=$?
assert_eq "--help: exit 0" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
