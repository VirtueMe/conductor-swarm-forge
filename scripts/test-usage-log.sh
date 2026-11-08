#!/usr/bin/env bash
# Tests usage_append (scripts/usage-log.sh) on the two fields that say what a line was billed to:
# pool (<billing>:<vendor>, or unknown) and billing (api, subscription or unknown). The pool comes
# from the harness's sign-in when it can be read, else from the pool the writer says the workforce
# declared, else it is unknown; billing is the first half of the pool. Needs no Claude and no Codex.
#
# Usage: scripts/test-usage-log.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

# shellcheck source=scripts/usage-log.sh
source "$SCRIPTS_DIR/usage-log.sh"

export CLAUDE_CREDENTIALS_FILE="$TMP/claude.json" CODEX_AUTH_FILE="$TMP/codex.json"
# The endpoint's state is the test's own (never ~/.claude) and nothing is reused: every read asks the stub (#173).
export CLAUDE_USAGE_STATE_FILE="$TMP/endpoint-state.json" CLAUDE_USAGE_FRESH_SECONDS=0
unset ANTHROPIC_API_KEY
LOG="$TMP/usage.jsonl"
SECRET="sk-test-do-not-print-0123456789"

login() { printf '%s\n' '{"claudeAiOauth":{"accessToken":"oauth-test-token"}}' > "$CLAUDE_CREDENTIALS_FILE"; }
no_login() { rm -f "$CLAUDE_CREDENTIALS_FILE" "$CODEX_AUTH_FILE"; }
# append <record json> ; field <jq> : the last line's field
append() { : > "$LOG"; usage_append "$LOG" "$1"; }
field() { jq -r "$1" "$LOG" | tail -1; }

section "0 · The 1-hour cache write is kept on the line and priced"
no_login; login
append '{"harness":"claude-code","model":"claude-haiku-4-5-20251001","input_tokens":10,"output_tokens":40,"cache_read_tokens":14595,"cache_write_tokens":9581,"cache_write_1h_tokens":9581,"cost_usd":0.0208315}'
assert_eq "the line carries it" "$(field .cache_write_1h_tokens)" "9581"
assert_eq "and the estimate is the reported cost" "$(field .estimated_cost_usd)" "0.0208315"
append '{"harness":"claude-code","model":"claude-haiku-4-5-20251001","input_tokens":10,"output_tokens":40,"cache_read_tokens":14595,"cache_write_tokens":9581}'
assert_eq "a record without it has null, not 0" "$(field .cache_write_1h_tokens)" "null"

section "1 · The pool comes from the sign-in"
no_login; login
append '{"harness":"claude-code","role":"coder"}'
assert_eq "claude-code on a login: subscription:anthropic" "$(field .pool)" "subscription:anthropic"
assert_eq "and billing: subscription" "$(field .billing)" "subscription"
ANTHROPIC_API_KEY="$SECRET" append '{"harness":"claude-code","role":"coder"}'
assert_eq "claude-code with a key in the environment: api:anthropic" "$(field .pool)" "api:anthropic"
assert_eq "and billing: api" "$(field .billing)" "api"
assert_eq "the key is not in the log" "$(grep -c -- "$SECRET" "$LOG" || true)" "0"
printf '%s\n' '{"auth_mode":"chatgpt"}' > "$CODEX_AUTH_FILE"
append '{"harness":"codex"}'
assert_eq "codex on ChatGPT: subscription:openai" "$(field .pool)" "subscription:openai"
printf '%s\n' "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"$SECRET\"}" > "$CODEX_AUTH_FILE"
append '{"harness":"codex"}'
assert_eq "codex on a key: api:openai" "$(field .pool)" "api:openai"
assert_eq "the key is not in the log" "$(grep -c -- "$SECRET" "$LOG" || true)" "0"

section "2 · A declaration stands when nothing can be detected, and detection wins when it can"
no_login
append '{"harness":"claude-code","declared_pool":"api:anthropic"}'
assert_eq "no sign-in found, declared api:anthropic: that pool" "$(field .pool)" "api:anthropic"
assert_eq "and its billing" "$(field .billing)" "api"
login
append '{"harness":"claude-code","declared_pool":"api:anthropic"}'
assert_eq "a login but api declared: the sign-in wins" "$(field .pool)" "subscription:anthropic"
no_login
append '{"harness":"pi","declared_pool":"api:anthropic"}'
assert_eq "pi has nothing to detect: its declaration stands" "$(field .pool)" "api:anthropic"

section "3 · Doubt is unknown, never a guess"
no_login
append '{"harness":"claude-code"}'
assert_eq "nothing detected and nothing declared: pool unknown" "$(field .pool)" "unknown"
assert_eq "and billing unknown" "$(field .billing)" "unknown"
append '{"harness":"mystery-harness"}'
assert_eq "a harness it has never heard of: pool unknown" "$(field .pool)" "unknown"
assert_eq "and the line is still written" "$(wc -l < "$LOG" | tr -d ' ')" "1"
append '{"role":"coder"}'
assert_eq "no harness at all: pool unknown" "$(field .pool)" "unknown"
append '{"harness":"claude-code","declared_pool":"bananas"}'
assert_eq "a declaration that is not a pool is not trusted: unknown" "$(field .pool)" "unknown"
assert_eq "and the line is still written (beside its mismatch record)" "$(jq -c 'select(.record == null)' "$LOG" | wc -l | tr -d ' ')" "1"

section "4 · A writer that already knows the pool says so"
login
append '{"harness":"claude-code","pool":"api:anthropic"}'
assert_eq "pool in the record is taken as it is" "$(field .pool)" "api:anthropic"
assert_eq "and billing follows it" "$(field .billing)" "api"
append '{"harness":"claude-code","pool":"unknown"}'
assert_eq "pool unknown in the record is unknown, not re-detected" "$(field .billing)" "unknown"

section "4b · A sign-in that disagrees with the declaration is recorded"
login
append '{"harness":"claude-code","role":"coder","task":"0001","declared_pool":"api:anthropic"}'
assert_eq "one mismatch record, before the line it is about" "$(jq -r 'select(.record == "pool_mismatch") | [.role, .task, .declared, .detected] | join(",")' "$LOG")" "coder,0001,api:anthropic,subscription:anthropic"
assert_eq "and the usage line itself has no record field" "$(jq -r 'select(.record == null) | .pool' "$LOG")" "subscription:anthropic"
append '{"harness":"claude-code","declared_pool":"subscription:anthropic"}'
assert_eq "a declaration the sign-in agrees with leaves no mismatch" "$(jq -c 'select(.record == "pool_mismatch")' "$LOG" | wc -l | tr -d ' ')" "0"
no_login
append '{"harness":"claude-code","declared_pool":"api:anthropic"}'
assert_eq "a declaration filling a doubt is no mismatch either" "$(jq -c 'select(.record == "pool_mismatch")' "$LOG" | wc -l | tr -d ' ')" "0"

section "4c · A declaration that is not a pool is recorded, not swallowed"
login
append '{"harness":"claude-code","role":"coder","task":"0002","declared_pool":"bananas"}'
assert_eq "one record, marked rejected" "$(jq -r 'select(.record == "pool_mismatch") | [.declared, .detected, (.rejected | tostring)] | join(",")' "$LOG")" "bananas,subscription:anthropic,true"
assert_eq "the line still gets the sign-in's pool" "$(jq -r 'select(.record == null) | .pool' "$LOG")" "subscription:anthropic"
append '{"harness":"claude-code","declared_pool":"api:anthropic"}'
assert_eq "an ordinary mismatch is not marked rejected" "$(jq -r 'select(.record == "pool_mismatch") | .rejected | tostring' "$LOG")" "false"

section "4d · A writer that settled the pool earlier hands over what it decided"
no_login
append '{"harness":"claude-code","pool_check":{"pool":"subscription:anthropic","declared":"api:anthropic","mismatch":true,"rejected":false}}'
assert_eq "the pool is the earlier decision, though no sign-in can be read now" "$(jq -r 'select(.record == null) | .pool' "$LOG")" "subscription:anthropic"
assert_eq "and its mismatch is recorded" "$(jq -r 'select(.record == "pool_mismatch") | [.declared, .detected] | join(",")' "$LOG")" "api:anthropic,subscription:anthropic"
append '{"harness":"claude-code","pool_check":{"pool":"api:anthropic","declared":"api:anthropic","mismatch":false,"rejected":false}}'
assert_eq "a decision with no mismatch records none" "$(jq -c 'select(.record == "pool_mismatch")' "$LOG" | wc -l | tr -d ' ')" "0"

section "5 · The other fields are untouched"
login
append '{"harness":"claude-code","cost_usd":0.5}'
assert_eq "cost_source is still reported" "$(field .cost_source)" "reported"
assert_eq "and the fields appear in every line, never missing" "$(jq -r 'has("pool") and has("billing")' "$LOG")" "true"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All usage-log checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
