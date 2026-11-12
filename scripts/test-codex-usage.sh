#!/usr/bin/env bash
# Tests scripts/codex-usage.sh against Codex session logs: a real one (the one taken for #132) and
# hand-made ones in tests/codex-usage/ for the cases a real log does not show on demand. Above all
# that a window the reader cannot trust is unknown, never zero and never 100 %, and that the
# newest reading wins without the older sessions being read. Needs no Codex and no allowance.
#
# Usage: scripts/test-codex-usage.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
READER="$SCRIPTS_DIR/codex-usage.sh"
FX="$SCRIPTS_DIR/../tests/codex-usage"
REAL="$SCRIPTS_DIR/../tests/worker-usage/codex/rollout.jsonl"

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

NOW=1793790000   # after the five-hour window of the fixtures opened (1793782000), before it resets (1793800000)

# root <fixture>...: a sessions directory holding them, in the order given, the last the newest
root() {
  local r="$TMP/root.$RANDOM" i=0 f
  mkdir -p "$r/2026/11/04"
  for f in "$@"; do
    i=$(( i + 1 ))
    cp "$f" "$r/2026/11/04/rollout-$i.jsonl"
    touch -d "2026-11-04 05:0$i:00" "$r/2026/11/04/rollout-$i.jsonl"
  done
  echo "$r"
}
read_json() { # <sessions-dir> [now]
  RC=0; OUT="$("$READER" --sessions "$1" --now "${2:-$NOW}" 2> "$TMP/err")" || RC=$?
}
j() { jq -r "$1" <<< "$OUT"; }

section "1 · A reading"
read_json "$(root "$FX/normal.jsonl")"
assert_eq "exit 0" "$RC" "0"
assert_eq "the snapshot is the newest event, not the first" "$(j .snapshot_at)" "2026-11-04T05:40:00.000Z"
assert_eq "the plan" "$(j .plan_type)" "plus"
assert_eq "the Codex version is pinned in the reading" "$(j .codex_version)" "0.166.0"
assert_eq "five-hour window: known, percent used" "$(j '.five_hour | [.state, .used_percent] | map(tostring) | join(" ")')" "known 7.5"
assert_eq "when it resets, and so when it opened" "$(j '.five_hour | [.resets_at, .opened_at] | map(tostring) | join(" ")')" "1793800000 1793782000"
assert_eq "weekly window: known, percent used" "$(j '.weekly | [.state, .used_percent] | map(tostring) | join(" ")')" "known 12"
assert_eq "when it resets" "$(j '.weekly.resets_at')" "1794059735"
assert_eq "a line that is not JSON is skipped" "$(j .five_hour.state)" "known"

section "2 · A real session log"
read_json "$(root "$REAL")" 1793780000
assert_eq "both windows read" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "known known"
assert_eq "the percentages the log holds" "$(j '[.five_hour.used_percent, .weekly.used_percent] | map(tostring) | join(" ")')" "0 1"
assert_eq "the plan is not there, so it is unknown" "$(j '.plan_type | tostring')" "null"
read_json "$(root "$REAL")"
assert_eq "later, the five-hour window has reset: unknown, not the old percentage" \
  "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"

section "3 · A window the reader cannot trust is unknown, never zero and never 100"
read_json "$(root "$FX/missing-window.jsonl")"
assert_eq "no weekly window: unknown" "$(j '.weekly | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "and says why" "$(j .weekly.reason)" "no 10080-minute window in the reading"
assert_eq "the other window is still read" "$(j .five_hour.state)" "known"
read_json "$(root "$FX/no-used-percent.jsonl")"
assert_eq "a window with no used_percent: unknown" "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "and says why" "$(j .five_hour.reason)" "the window has no used_percent"
read_json "$(root "$FX/past-reset.jsonl")"
assert_eq "a resets_at in the past: unknown, the percentage no longer applies" "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "and says so" "$(j .five_hour.reason)" "the window reset after the last reading"
assert_eq "the reset time is kept" "$(j .five_hour.resets_at)" "1793780000"
assert_eq "the other window is not dragged down with it" "$(j .weekly.state)" "known"
read_json "$(root "$FX/out-of-range.jsonl")"
assert_eq "a percentage outside 0 to 100: unknown" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "unknown unknown"
assert_eq "and says why" "$(j .five_hour.reason)" "used_percent is outside 0 to 100"
read_json "$(root "$FX/no-resets-at.jsonl")"
assert_eq "no reset time to judge staleness by: unknown" "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "and says why" "$(j .five_hour.reason)" "the window has no resets_at"

section "4 · Windows are found by length, not by name"
read_json "$(root "$FX/renamed-windows.jsonl")"
assert_eq "five-hour found under another name" "$(j '.five_hour | [.state, .used_percent] | map(tostring) | join(" ")')" "known 2"
assert_eq "weekly found under another name" "$(j '.weekly | [.state, .used_percent] | map(tostring) | join(" ")')" "known 4"
assert_eq "a window of another length is not mistaken for either" "$(j '[.five_hour.window_minutes, .weekly.window_minutes] | map(tostring) | join(" ")')" "300 10080"

section "5 · No plan, a reached cap, no reading"
read_json "$(root "$FX/no-plan.jsonl")"
assert_eq "no plan_type: null, and the windows are still read" "$(j '[(.plan_type | tostring), .five_hour.state] | join(" ")')" "null known"
read_json "$(root "$FX/cap-reached.jsonl")"
assert_eq "a window at 100 % that the log really says is 100" "$(j '.five_hour.used_percent')" "100"
assert_eq "and which limit was reached" "$(j .rate_limit_reached_type)" "primary"
read_json "$(root "$FX/no-rate-limits.jsonl")"
assert_eq "events with no rate_limits: no snapshot" "$(j '.snapshot_at | tostring')" "null"
assert_eq "both windows unknown" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "unknown unknown"
assert_eq "and says there was no reading" "$(j .five_hour.reason)" "no rate_limits in any Codex session"
assert_eq "that is an answer, not an error: exit 0" "$RC" "0"
read_json "$TMP/does-not-exist"
assert_eq "no sessions directory: the same answer" "$(j '[.five_hour.state, .reason_none // "x"] | join(" ")')" "unknown x"
assert_eq "and exit 0" "$RC" "0"

section "6 · The newest session wins, and older ones are not read"
read_json "$(root "$FX/older-usable.jsonl" "$FX/normal.jsonl")"
assert_eq "the newest file's reading" "$(j .snapshot_at)" "2026-11-04T05:40:00.000Z"
R="$(root "$FX/older-usable.jsonl" "$FX/normal.jsonl")"
chmod 000 "$R/2026/11/04/rollout-1.jsonl"
read_json "$R"
assert_eq "an older file that cannot be opened is never touched" "$(cat "$TMP/err")" ""
chmod 644 "$R/2026/11/04/rollout-1.jsonl"
read_json "$(root "$FX/older-usable.jsonl" "$FX/no-rate-limits.jsonl")"
assert_eq "a newest file with no reading falls back to the older one" "$(j .snapshot_at)" "2026-11-04T04:00:00.000Z"
assert_eq "and the older reading's percent is the one used" "$(j .five_hour.used_percent)" "1"

section "7 · Readable output"
RC=0; "$READER" --sessions "$(root "$FX/past-reset.jsonl")" --now "$NOW" --text > "$TMP/text" 2> /dev/null || RC=$?
assert_eq "exit 0" "$RC" "0"
has '^5-hour  *unknown' "the reset five-hour window reads as unknown"
has '^weekly  *12%' "the weekly window shows its percentage"
has 'plus' "the plan is shown"

section "8 · Arguments"
RC=0; "$READER" --bogus > /dev/null 2>&1 || RC=$?
assert_eq "an unknown flag: exit 1" "$RC" "1"
RC=0; "$READER" --now abc > /dev/null 2>&1 || RC=$?
assert_eq "a --now that is not a number: exit 1" "$RC" "1"
RC=0; "$READER" --help > /dev/null 2>&1 || RC=$?
assert_eq "--help: exit 0" "$RC" "0"

section "9 · The app-server fills a window the log cannot give"
# A stand-in for `codex`: --version, and `app-server`, which answers initialize and
# account/rateLimits/read on stdio the way the real one does (no jsonrpc field, ids echoed). What it
# was asked is written to $STUB_LOG, one method per line. The real Codex is never started.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.166.0"; exit 0 ;;
  app-server) ;;
  *) exit 2 ;;
esac
while IFS= read -r line; do
  method="$(jq -r '.method // empty' <<< "$line")"; id="$(jq -r '.id // empty' <<< "$line")"
  echo "$method" >> "$STUB_LOG"
  case "$method" in
    initialize) jq -nc --argjson id "$id" '{id: $id, result: {userAgent: "codex_cli_rs/0.166.0 (stub)"}}' ;;
    account/rateLimits/read)
      case "${STUB_MODE:-ok}" in
        ok)      jq -nc --argjson id "$id" --slurpfile r "$STUB_RESULT" '{id: $id, result: $r[0]}' ;;
        error)   jq -nc --argjson id "$id" '{id: $id, error: {code: -32000, message: "not signed in"}}' ;;
        garbage) echo "this is not json"; exit 0 ;;
        hang)    sleep 30 ;;
        deaf)    trap '' TERM; sleep 30 ;;
      esac ;;
  esac
done
STUB
chmod +x "$TMP/bin/codex"
export STUB_LOG="$TMP/stub.log" STUB_RESULT="$TMP/stub-result.json"
cat > "$STUB_RESULT" <<'JSON'
{"rateLimits":{"limitId":"codex","planType":"plus","rateLimitReachedType":null,
 "primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1793800000},
 "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1794059735}},
 "rateLimitsByLimitId":null}
JSON
live() { # <sessions-dir> [env...]: a reading with the stub as the Codex binary
  local dir="$1"; shift
  : > "$STUB_LOG"
  RC=0; OUT="$(env CODEX_BIN="$TMP/bin/codex" CODEX_APP_SERVER_TIMEOUT=5 "$@" "$READER" --sessions "$dir" --now "$NOW" 2> "$TMP/err")" || RC=$?
}
EMPTY="$TMP/no-sessions"; mkdir -p "$EMPTY"

live "$EMPTY"
assert_eq "no session log at all: the app-server's windows are read" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "known known"
assert_eq "the percentages it gave" "$(j '[.five_hour.used_percent, .weekly.used_percent] | map(tostring) | join(" ")')" "7 12"
assert_eq "when each resets, and so when each opened" "$(j '[.five_hour.resets_at, .five_hour.opened_at, .weekly.resets_at] | map(tostring) | join(" ")')" "1793800000 1793782000 1794059735"
assert_eq "the plan and the limit" "$(j '[.plan_type, .limit_id] | join(" ")')" "plus codex"
assert_eq "the source says where it came from" "$(j .source)" "codex app-server"
assert_eq "the Codex version is pinned in the reading" "$(j .codex_version)" "0.166.0"
assert_eq "the snapshot is the time of the read" "$(j .snapshot_at)" "2026-11-04T11:00:00Z"
assert_eq "it was asked to initialize, said initialized, then read the limits" "$(tr '\n' ' ' < "$STUB_LOG")" "initialize initialized account/rateLimits/read "
assert_eq "exit 0" "$RC" "0"

live "$(root "$FX/past-reset.jsonl")"
assert_eq "a log whose five-hour window has reset: the live reading replaces it" "$(j '[.five_hour.state, .five_hour.used_percent, .source] | map(tostring) | join(" ")')" "known 7 codex app-server"

live "$(root "$FX/normal.jsonl")"
assert_eq "a log with both windows known: the app-server is not asked" "$(wc -c < "$STUB_LOG" | tr -d ' ')" "0"
assert_eq "and the log's reading stands" "$(j '.source | endswith("rollout-1.jsonl")')" "true"

cat > "$STUB_RESULT" <<'JSON'
{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1793780000},
 "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1794059735}}}
JSON
live "$EMPTY"
assert_eq "a live window whose reset is in the past is still unknown" "$(j '.five_hour | [.state, (.used_percent | tostring)] | join(" ")')" "unknown null"
assert_eq "the other live window is read" "$(j .weekly.state)" "known"
cat > "$STUB_RESULT" <<'JSON'
{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1793800000},"secondary":null}}
JSON
live "$EMPTY"
assert_eq "a live reading with no weekly window: that window is unknown, the other known" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "known unknown"
assert_eq "and says why" "$(j .weekly.reason)" "no 10080-minute window in the reading"

live "$EMPTY" CODEX_BIN="$TMP/does-not-exist"
assert_eq "no codex binary: unknown, never a guess" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "unknown unknown"
case "$(j .five_hour.reason)" in *"no rate_limits in any Codex session"*"no codex binary"*) ok "and the reason says both: no log, and no binary to ask" ;; *) fail "reason: $(j .five_hour.reason)" ;; esac
assert_eq "that is an answer, not an error: exit 0" "$RC" "0"

live "$EMPTY" STUB_MODE=error
case "$(j .five_hour.reason)" in *"app-server answered with an error"*) ok "an error from the app-server (not signed in) is named in the reason" ;; *) fail "reason: $(j .five_hour.reason)" ;; esac
assert_eq "and the windows are unknown" "$(j '[.five_hour.state, .weekly.state] | join(" ")')" "unknown unknown"
live "$EMPTY" STUB_MODE=garbage
case "$(j .five_hour.reason)" in *"app-server gave no reading"*) ok "an answer that is not JSON gives no reading" ;; *) fail "reason: $(j .five_hour.reason)" ;; esac
START="$(date +%s)"
live "$EMPTY" STUB_MODE=hang CODEX_APP_SERVER_TIMEOUT=1
assert_eq "an app-server that never answers is given up on" "$(( $(date +%s) - START < 6 ))" "1"
case "$(j .five_hour.reason)" in *"timed out"*) ok "and the reason says it timed out" ;; *) fail "reason: $(j .five_hour.reason)" ;; esac
sleep 0.3; assert_eq "no stub process is left behind" "$(pgrep -f "$TMP/bin/codex" | wc -l | tr -d ' ')" "0"

START="$(date +%s)"
live "$EMPTY" STUB_MODE=deaf CODEX_APP_SERVER_TIMEOUT=1
assert_eq "an app-server that ignores TERM does not hang the reader" "$(( $(date +%s) - START < 8 ))" "1"
assert_eq "and the reading is still an answer: exit 0" "$RC" "0"
sleep 0.3; assert_eq "and the stand-in itself is gone" "$(pgrep -f "$TMP/bin/codex" | wc -l | tr -d ' ')" "0"

live "$EMPTY" CODEX_APP_SERVER=off
assert_eq "CODEX_APP_SERVER=off: not asked" "$(wc -c < "$STUB_LOG" | tr -d ' ')" "0"
assert_eq "and the reading is the log's: unknown" "$(j .five_hour.state)" "unknown"

# A test or a replay names its own sessions directory. That never starts a real codex found on PATH.
: > "$STUB_LOG"
RC=0; OUT="$(PATH="$TMP/bin:$PATH" "$READER" --sessions "$EMPTY" --now "$NOW" 2> /dev/null)" || RC=$?
assert_eq "a sessions directory given and no CODEX_BIN: the codex on PATH is not asked" "$(wc -c < "$STUB_LOG" | tr -d ' ')" "0"
RC=0; OUT="$(CODEX_HOME="$TMP/no-home" PATH="$TMP/bin:$PATH" "$READER" --now "$NOW" 2> /dev/null)" || RC=$?
assert_eq "the default sessions directory: the codex on PATH is asked" "$(tr '\n' ' ' < "$STUB_LOG")" "initialize initialized account/rateLimits/read "

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
