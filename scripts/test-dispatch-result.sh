#!/usr/bin/env bash
# Tests the helpers every adapter_dispatch shares: the usage record and the last-line
# check (scripts/dispatch-result.sh).
#
# Usage: scripts/test-dispatch-result.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/dispatch-prompt.sh
source "$SCRIPTS_DIR/dispatch-prompt.sh"
# shellcheck source=scripts/dispatch-result.sh
source "$SCRIPTS_DIR/dispatch-result.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
export DISPATCH_USAGE_FILE="$TMP/usage.json"
field() { jq -c ".$1" "$DISPATCH_USAGE_FILE"; }

echo "── a full record"
dispatch_write_usage claude-code claude-opus-4-8 8 701 20055 7429 0.1019 4
assert_eq "one line" "$(wc -l < "$DISPATCH_USAGE_FILE" | tr -d ' ')" "1"
assert_eq "harness" "$(field harness)" '"claude-code"'
assert_eq "model" "$(field model)" '"claude-opus-4-8"'
assert_eq "input tokens are numbers" "$(field input_tokens)" "8"
assert_eq "output tokens" "$(field output_tokens)" "701"
assert_eq "cache read tokens" "$(field cache_read_tokens)" "20055"
assert_eq "cache write tokens" "$(field cache_write_tokens)" "7429"
assert_eq "cost" "$(field cost_usd)" "0.1019"
assert_eq "turns" "$(field turns)" "4"
assert_eq "exactly the agreed fields" "$(jq -c 'keys' "$DISPATCH_USAGE_FILE")" '["cache_read_tokens","cache_write_tokens","cost_usd","harness","input_tokens","model","output_tokens","turns"]'

echo "── values a harness does not report"
dispatch_write_usage codex "-" 2965 5 12288 0 "-" "-"
assert_eq "model is null" "$(field model)" "null"
assert_eq "cost is null, not 0" "$(field cost_usd)" "null"
assert_eq "turns is null" "$(field turns)" "null"
assert_eq "tokens are still numbers" "$(field input_tokens)" "2965"
dispatch_write_usage pi "" "" "" "" "" "" ""
assert_eq "empty strings behave like a dash: model" "$(field model)" "null"
assert_eq "empty tokens become 0" "$(field output_tokens)" "0"
dispatch_write_usage pi m abc 5 not-a-number 0 x y
assert_eq "a value that is not a number becomes 0 for tokens" "$(field input_tokens)" "0"
assert_eq "and null for cost" "$(field cost_usd)" "null"

echo "── no usage file asked for"
unset DISPATCH_USAGE_FILE
rm -f "$TMP/usage.json"
dispatch_write_usage pi m 1 2 3 4 5 6
assert_eq "nothing is written" "$([[ -e "$TMP/usage.json" ]] && echo written || echo none)" "none"
export DISPATCH_USAGE_FILE="$TMP/usage.json"

echo "── the last-line check"
if dispatch_finish pi "Moved the card."; then ok "a normal answer passes"; else fail "normal answer failed"; fi
if ERR="$(dispatch_finish codex "task-locks.sh failed.
HANDLER-FAILED: task-locks.sh exited 1" 2>&1)"; then fail "a failed answer passed"; else ok "a HANDLER-FAILED last line fails"; fi
case "$ERR" in *"codex: handler reported failure: HANDLER-FAILED: task-locks.sh exited 1"*) ok "names the harness and quotes the line" ;; *) fail "message: $ERR" ;; esac
if dispatch_finish pi ""; then ok "an empty answer passes (the exit code decides)"; else fail "empty answer failed"; fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
