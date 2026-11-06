#!/usr/bin/env bash
# Tests scripts/billing-mode.sh: how a workforce member is billed (an API key or a subscription), found
# from the harness's own sign-in, and the pool that follows from it. A detected mode overrides what a
# workforce declares, and a mismatch is said on stderr. Doubt is "unknown", never a guess, and no
# key or token reaches the output. Needs no Claude, no Codex and no account.
#
# Usage: scripts/test-billing-mode.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BM="$SCRIPTS_DIR/billing-mode.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

SECRET="sk-test-do-not-print-0123456789"
TOKEN="oauth-test-do-not-print-abcdef"

# The sign-in files and the environment are the test's own; nothing reads the real ones.
export CLAUDE_CREDENTIALS_FILE="$TMP/claude-credentials.json"
export CODEX_AUTH_FILE="$TMP/codex-auth.json"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

# claude_login <json|-> : Claude's sign-in file ('-' for none)
claude_login() { if [[ "$1" == - ]]; then rm -f "$CLAUDE_CREDENTIALS_FILE"; else printf '%s\n' "$1" > "$CLAUDE_CREDENTIALS_FILE"; fi; }
codex_login() { if [[ "$1" == - ]]; then rm -f "$CODEX_AUTH_FILE"; else printf '%s\n' "$1" > "$CODEX_AUTH_FILE"; fi; }
run() { RC=0; "$BM" "$@" > "$TMP/out" 2> "$TMP/err" || RC=$?; }
out() { cat "$TMP/out"; }
err() { cat "$TMP/err"; }
leaked() { grep -c -- "$SECRET\|$TOKEN" "$TMP/out" "$TMP/err" | awk -F: '{s+=$2} END{print s+0}'; }

SUBSCRIPTION_LOGIN="{\"claudeAiOauth\":{\"accessToken\":\"$TOKEN\",\"subscriptionType\":\"max\"}}"

section "1 · Claude Code: a login is a subscription"
claude_login "$SUBSCRIPTION_LOGIN"
run detect claude-code
assert_eq "a claudeAiOauth login: subscription" "$(out)" "subscription"
assert_eq "exit 0" "$RC" "0"
assert_eq "the token is not in the output" "$(leaked)" "0"

section "2 · Claude Code: an API key in the environment wins over a login"
ANTHROPIC_API_KEY="$SECRET" run detect claude-code
assert_eq "ANTHROPIC_API_KEY set next to a login: api" "$(out)" "api"
assert_eq "the key is not in the output" "$(leaked)" "0"
claude_login -
ANTHROPIC_API_KEY="$SECRET" run detect claude-code
assert_eq "ANTHROPIC_API_KEY set and no login: api" "$(out)" "api"
ANTHROPIC_API_KEY="" run detect claude-code
assert_eq "ANTHROPIC_API_KEY empty and no login: unknown, an empty key is no key" "$(out)" "unknown"

section "3 · Claude Code: doubt is unknown, not a guess"
claude_login -
run detect claude-code
assert_eq "no login file and no key: unknown" "$(out)" "unknown"
assert_eq "and still exit 0, doubt does not stop a run" "$RC" "0"
claude_login '{"somethingElse":true}'
run detect claude-code
assert_eq "a file with no claudeAiOauth: unknown" "$(out)" "unknown"
claude_login '{"claudeAiOauth":{"accessToken":""}}'
run detect claude-code
assert_eq "a claudeAiOauth with an empty token: unknown" "$(out)" "unknown"
claude_login 'not json at all'
run detect claude-code
assert_eq "a file that is not JSON: unknown" "$(out)" "unknown"

section "3b · A provider override means the login is not what is billed"
claude_login "$SUBSCRIPTION_LOGIN"
for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AUTH_TOKEN; do
  env "$v=1" "$BM" detect claude-code > "$TMP/out"
  assert_eq "$v set next to a login: unknown, the run is billed elsewhere" "$(out)" "unknown"
done
env CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_API_KEY="$SECRET" "$BM" detect claude-code > "$TMP/out"
assert_eq "an override beats a key in the environment too" "$(out)" "unknown"
env CLAUDE_CODE_USE_BEDROCK=0 "$BM" detect claude-code > "$TMP/out"
assert_eq "an override set to 0 is not set" "$(out)" "subscription"
env CLAUDE_CODE_USE_BEDROCK=false "$BM" detect claude-code > "$TMP/out"
assert_eq "nor is false" "$(out)" "subscription"
env CLAUDE_CODE_USE_BEDROCK= "$BM" detect claude-code > "$TMP/out"
assert_eq "nor is an empty one" "$(out)" "subscription"

section "4 · Codex: the sign-in decides"
codex_login '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{}}'
run detect codex
assert_eq "auth_mode chatgpt: subscription" "$(out)" "subscription"
codex_login "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"$SECRET\"}"
run detect codex
assert_eq "auth_mode apikey: api" "$(out)" "api"
assert_eq "the key is not in the output" "$(leaked)" "0"
codex_login "{\"auth_mode\":\"api_key\",\"OPENAI_API_KEY\":\"$SECRET\"}"
run detect codex
assert_eq "another spelling of the mode: api" "$(out)" "api"
codex_login "{\"OPENAI_API_KEY\":\"$SECRET\"}"
run detect codex
assert_eq "no auth_mode but a stored key: api" "$(out)" "api"
codex_login '{"auth_mode":"something-new"}'
run detect codex
assert_eq "an auth_mode it does not know: unknown" "$(out)" "unknown"
codex_login -
run detect codex
assert_eq "no auth file: unknown" "$(out)" "unknown"

section "5 · An adapter with no sign-in to read"
run detect pi
assert_eq "pi: unknown, its billing depends on the provider" "$(out)" "unknown"
assert_eq "exit 0" "$RC" "0"
run detect nonesuch
assert_eq "an adapter it has never heard of: exit 1" "$RC" "1"

section "6 · The pool follows adapter and mode"
claude_login "$SUBSCRIPTION_LOGIN"
run pool claude-code
assert_eq "claude-code on a login: subscription:anthropic" "$(out)" "subscription:anthropic"
ANTHROPIC_API_KEY="$SECRET" run pool claude-code
assert_eq "claude-code on a key: api:anthropic" "$(out)" "api:anthropic"
codex_login '{"auth_mode":"chatgpt"}'
run pool codex
assert_eq "codex on ChatGPT: subscription:openai" "$(out)" "subscription:openai"
codex_login "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"$SECRET\"}"
run pool codex
assert_eq "codex on a key: api:openai (the swarm no longer refuses it)" "$(out)" "api:openai"
assert_eq "exit 0" "$RC" "0"

section "7 · A declaration fills a doubt, and detection overrides it"
claude_login -
run pool claude-code --declared subscription:anthropic
assert_eq "no sign-in found, declared subscription:anthropic: that pool" "$(out)" "subscription:anthropic"
assert_eq "and nothing on stderr, a declaration filling a doubt is not a mismatch" "$(err)" ""
run pool claude-code
assert_eq "no sign-in found, nothing declared: unknown" "$(out)" "unknown"
claude_login "$SUBSCRIPTION_LOGIN"
run pool claude-code --declared api:anthropic
assert_eq "a login but api declared: detection wins, subscription:anthropic" "$(out)" "subscription:anthropic"
case "$(err)" in *mismatch*api:anthropic*subscription*) ok "and a mismatch is said on stderr" ;; *) fail "mismatch note: $(err)" ;; esac
assert_eq "still exit 0, a mismatch does not stop a run" "$RC" "0"
run pool claude-code --declared subscription:anthropic
assert_eq "a login and the same declared: no note" "$(err)" ""
run pool pi --declared api:anthropic
assert_eq "pi has no detection, so its declaration stands" "$(out)" "api:anthropic"
run pool pi --declared subscription:openai
assert_eq "pi on a ChatGPT plan is allowed (OpenAI lists pi for plan usage)" "$(out)" "subscription:openai"
run pool pi --declared subscription:anthropic
assert_eq "pi on a Claude subscription: exit 1 (Anthropic does not permit it)" "$RC" "1"
case "$(err)" in *subscription:anthropic*not\ allowed*pi*) ok "and says why" ;; *) fail "reason: $(err)" ;; esac
run pool pi --declared subscription:anthropic --json
assert_eq "as json: rejected, set aside, exit 0, no pool guessed" "$(jq -c . "$TMP/out")" '{"pool":"unknown","declared":"subscription:anthropic","mismatch":false,"rejected":true}'

section "8 · A declaration must be a known pool"
run pool claude-code --declared bananas
assert_eq "an unknown pool name: exit 1" "$RC" "1"
case "$(err)" in *bananas*) ok "and names it" ;; *) fail "reason: $(err)" ;; esac
run pool claude-code --declared subscription:openai
assert_eq "a pool of the other vendor on claude-code: exit 1" "$RC" "1"

section "9 · --json says what was decided, so nobody parses a sentence"
claude_login "$SUBSCRIPTION_LOGIN"
run pool claude-code --json
assert_eq "no declaration: the pool, nothing declared, no mismatch" "$(jq -c . "$TMP/out")" '{"pool":"subscription:anthropic","declared":null,"mismatch":false,"rejected":false}'
run pool claude-code --declared api:anthropic --json
assert_eq "a login but api declared: the sign-in wins, and it is a mismatch" "$(jq -c . "$TMP/out")" '{"pool":"subscription:anthropic","declared":"api:anthropic","mismatch":true,"rejected":false}'
assert_eq "exit 0" "$RC" "0"
run pool claude-code --declared subscription:anthropic --json
assert_eq "a declaration the sign-in agrees with: no mismatch" "$(jq -c '[.mismatch, .rejected]' "$TMP/out")" "[false,false]"
claude_login -
run pool claude-code --declared api:anthropic --json
assert_eq "a declaration filling a doubt: no mismatch" "$(jq -c . "$TMP/out")" '{"pool":"api:anthropic","declared":"api:anthropic","mismatch":false,"rejected":false}'
run pool claude-code --declared bananas --json
assert_eq "a declaration that is not a pool is rejected, not an error: exit 0" "$RC" "0"
assert_eq "and the pool falls back to what the sign-in says" "$(jq -c . "$TMP/out")" '{"pool":"unknown","declared":"bananas","mismatch":false,"rejected":true}'
claude_login "$SUBSCRIPTION_LOGIN"
run pool claude-code --declared api:openai --json
assert_eq "another vendor's pool is rejected too, and the sign-in still settles it" "$(jq -c '[.pool, .rejected]' "$TMP/out")" '["subscription:anthropic",true]'
run pool claude-code --declared bananas
assert_eq "without --json a bad declaration is still an error" "$RC" "1"
run pool nonesuch --json
assert_eq "an adapter it does not know is an error with --json too" "$RC" "1"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All billing-mode checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
