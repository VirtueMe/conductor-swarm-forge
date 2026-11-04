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

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
