#!/usr/bin/env bash
# Tests scripts/usage-price.sh and the price table: one record per adapter, shaped like the
# fixtures in the adapter tests, lands on the same basis; an unknown model, no model, a joined
# list of models and missing token counts give null and never a guess or zero; and the table
# carries a date and a source for every price.
#
# Usage: scripts/test-usage-price.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PRICE="$SCRIPTS_DIR/usage-price.sh"
TABLE="$SCRIPTS_DIR/usage-prices.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
est() { "$PRICE" estimate <<< "$1"; }
rec() { # model input output cache_read cache_write
  jq -nc --arg m "$1" --argjson i "$2" --argjson o "$3" --argjson cr "$4" --argjson cw "$5" \
    '{harness: "x", model: (if $m == "" then null else $m end), input_tokens: $i, output_tokens: $o,
      cache_read_tokens: $cr, cache_write_tokens: $cw, cost_usd: null, turns: 1}'
}

section "1 · One record per adapter, on one basis"
# The token counts are the ones in each adapter's own test fixture. Worked by hand, in dollars
# per million tokens: input*in + cache_read*cr + cache_write*cw + output*out.
assert_eq "claude-code: modelUsage of claude-opus-4-8 (5 / 0.5 / 6.25 / 25)" \
  "$(est "$(rec claude-opus-4-8 8 701 20055 7429)")" "0.07402375"
assert_eq "codex: gpt-5, input already minus the cached part (1.25 / 0.125 / 1.25 / 10)" \
  "$(est "$(rec gpt-5 2965 5 12288 0)")" "0.00529225"
assert_eq "pi: claude-opus-4-8 with cache read and write apart" \
  "$(est "$(rec claude-opus-4-8 100 20 300 50)")" "0.0014625"
assert_eq "zero tokens on a known model cost nothing, and that is a number" \
  "$(est "$(rec claude-sonnet-4-6 0 0 0 0)")" "0"

section "2 · Null, never a guess and never zero"
assert_eq "a model the table does not know" "$(est "$(rec not-a-model 1000 1000 0 0)")" "null"
assert_eq "no model (Codex without --model)" "$(est "$(rec '' 1000 1000 0 0)")" "null"
assert_eq "several models joined with +" "$(est "$(rec claude-opus-4-8+claude-haiku-4-5 1000 1000 0 0)")" "null"
assert_eq "no token counts (an attempt with no record)" \
  "$(est '{"model":"claude-opus-4-8","input_tokens":null,"output_tokens":null,"cache_read_tokens":null,"cache_write_tokens":null}')" "null"
assert_eq "not a JSON record" "$(est 'garbage')" "null"
assert_eq "a missing table prices nothing" \
  "$(CONDUCTOR_PRICES="$TMP/nope.json" "$PRICE" estimate <<< "$(rec gpt-5 1000 1000 0 0)")" "null"
assert_eq "so does a table that is not JSON" \
  "$(echo 'nope' > "$TMP/bad.json"; CONDUCTOR_PRICES="$TMP/bad.json" "$PRICE" estimate <<< "$(rec gpt-5 1000 1000 0 0)")" "null"

section "3 · The table"
assert_eq "it is valid JSON with a basis and models" "$(jq -r '(.basis | type) + " " + (.models | type)' "$TABLE")" "string object"
assert_eq "every price has all four rates" \
  "$(jq -r '[.models[] | select(([.input, .cache_read, .cache_write, .output] | all(type == "number")) | not)] | length' "$TABLE")" "0"
assert_eq "every price has a date" \
  "$(jq -r '[.models[] | select((.as_of // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)] | length' "$TABLE")" "0"
assert_eq "and a source" "$(jq -r '[.models[] | select((.source // "") | startswith("https://") | not)] | length' "$TABLE")" "0"
assert_eq "the basis names the four counts" \
  "$(jq -r '.basis | test("input.*cache_read.*cache_write.*output")' "$TABLE")" "true"
assert_eq "the models the default workforce uses are priced" \
  "$(jq -r --slurpfile t "$TABLE" '[.members[].params.model // empty] | unique | map(select($t[0].models[.] == null)) | length' "$SCRIPTS_DIR/../workforces/default.json")" "0"

section "4 · Which models a log does not know"
LOG="$TMP/usage.jsonl"
{
  echo '{"event":"a","model":"claude-opus-4-8","cost_usd":0.1,"estimated_cost_usd":0.07}'
  echo '{"event":"b","model":"mystery","cost_usd":null,"estimated_cost_usd":null}'
  echo '{"event":"c","model":"mystery","cost_usd":null,"estimated_cost_usd":null}'
  echo '{"event":"d","model":null,"cost_usd":null,"estimated_cost_usd":null}'
  echo '{"record":"allowance","pool":"subscription:openai","moment":"swarm-start","five_hour":{"state":"known"}}'
  echo 'not json'
} > "$LOG"
OUT="$("$PRICE" unknown --file "$LOG")"
case "$OUT" in *"mystery"*"2"*) ok "the unknown model, counted" ;; *) fail "output: $OUT" ;; esac
case "$OUT" in *"(no model)"*"1"*) ok "attempts with no model, counted" ;; *) fail "output: $OUT" ;; esac
case "$OUT" in *"(no model)"*" 1"*) ok "and an allowance reading is not one of them" ;; *) fail "output: $OUT" ;; esac
case "$OUT" in *"claude-opus-4-8"*) fail "a priced model is listed" ;; *) ok "a priced model is not listed" ;; esac
echo '{"event":"a","model":"gpt-5"}' > "$TMP/known.jsonl"
case "$("$PRICE" unknown --file "$TMP/known.jsonl")" in *"Every attempt"*) ok "a clean log says so" ;; *) fail "clean log" ;; esac
case "$("$PRICE" unknown --file "$TMP/none.jsonl")" in *"No usage recorded yet"*) ok "no log is not an error" ;; *) fail "no log" ;; esac

section "5 · Reported against estimated"
OUT="$("$PRICE" compare --file "$LOG")"
case "$OUT" in *"claude-opus-4-8"*"0.1000"*"0.0700"*"-0.0300"*) ok "both costs and the difference" ;; *) fail "output: $OUT" ;; esac
case "$OUT" in *"mystery"*) fail "an attempt with no estimate is listed" ;; *) ok "attempts missing either cost are left out" ;; esac

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
