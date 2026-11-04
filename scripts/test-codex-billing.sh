#!/usr/bin/env bash
# Tests scripts/codex-billing.sh: Codex used by the swarm must be billed to a subscription. It
# refuses on evidence (an API key sign-in, or a reading with no plan), allows with a note when it
# cannot tell, and never prints a key. Needs no Codex and no account.
#
# Usage: scripts/test-codex-billing.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPTS_DIR/codex-billing.sh"
FX="$SCRIPTS_DIR/../tests/codex-usage"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

export CODEX_USAGE_NOW=1793790000
SECRET="sk-test-do-not-print-0123456789"

# auth <json|-> : the sign-in file ('-' for none); sessions <fixture|-> : what Codex has written
auth() { if [[ "$1" == - ]]; then rm -f "$TMP/auth.json"; else printf '%s\n' "$1" > "$TMP/auth.json"; fi; export CODEX_AUTH_FILE="$TMP/auth.json"; }
sessions() {
  rm -rf "$TMP/sessions"; mkdir -p "$TMP/sessions/2026/11/04"
  [[ "$1" == - ]] || cp "$FX/$1" "$TMP/sessions/2026/11/04/rollout-1.jsonl"
  export CODEX_SESSIONS_DIR="$TMP/sessions"
}
check() { RC=0; "$CHECK" check > "$TMP/out" 2> "$TMP/err" || RC=$?; }
err() { cat "$TMP/err"; }

section "1 · A subscription"
auth '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{}}'; sessions normal.jsonl
check
assert_eq "signed in with ChatGPT and a plan on record: allowed" "$RC" "0"
assert_eq "and says nothing" "$(err)" ""
sessions -
check
assert_eq "signed in with ChatGPT, no reading yet: allowed" "$RC" "0"
assert_eq "and says nothing, because the sign-in settles it" "$(err)" ""
auth "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":\"$SECRET\"}"
check
assert_eq "an API key stored next to a ChatGPT sign-in: the auth_mode decides, allowed" "$RC" "0"

section "2 · An API key is refused, and never printed"
auth "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"$SECRET\"}"; sessions normal.jsonl
check
assert_eq "auth_mode apikey: refused with exit 2" "$RC" "2"
case "$(err)" in *"API key"*"subscription"*) ok "and says why" ;; *) fail "reason: $(err)" ;; esac
assert_eq "the key is not in the output" "$(grep -c -- "$SECRET" "$TMP/err" "$TMP/out" | awk -F: '{s+=$2} END{print s+0}')" "0"
assert_eq "even when the newest reading shows a plan, the sign-in wins" "$RC" "2"
auth "{\"auth_mode\":\"api_key\",\"OPENAI_API_KEY\":\"$SECRET\"}"
check
assert_eq "another spelling of the mode: refused" "$RC" "2"
auth "{\"OPENAI_API_KEY\":\"$SECRET\",\"tokens\":null}"
check
assert_eq "no auth_mode but a stored key: refused" "$RC" "2"
assert_eq "and the key is still not printed" "$(grep -c -- "$SECRET" "$TMP/err" | tr -d ' ')" "0"

section "3 · A reading with no plan"
auth '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}'; sessions no-plan.jsonl
check
assert_eq "the newest reading has no plan_type: refused" "$RC" "2"
case "$(err)" in *"plan_type"*) ok "and says so" ;; *) fail "reason: $(err)" ;; esac
auth -; sessions no-plan.jsonl
check
assert_eq "with no sign-in file either, a reading with no plan still refuses" "$RC" "2"

section "4 · It cannot tell: allowed, with a note"
auth -; sessions -
check
assert_eq "no sign-in file and no reading: allowed" "$RC" "0"
case "$(err)" in *"Could not verify"*) ok "and says it could not verify" ;; *) fail "note: $(err)" ;; esac
auth 'this is not json'; sessions -
check
assert_eq "a sign-in file that is not JSON: allowed" "$RC" "0"
case "$(err)" in *"Could not verify"*) ok "with the same note" ;; *) fail "note: $(err)" ;; esac
auth '{"auth_mode":"something-new","OPENAI_API_KEY":null}'; sessions -
check
assert_eq "an auth_mode it does not know: allowed, not guessed at" "$RC" "0"
case "$(err)" in *"Could not verify"*) ok "with the note" ;; *) fail "note: $(err)" ;; esac
auth -; sessions normal.jsonl
check
assert_eq "no sign-in file but a reading with a plan: allowed" "$RC" "0"
assert_eq "and silent, the reading is the evidence" "$(err)" ""

section "5 · Arguments"
RC=0; "$CHECK" > /dev/null 2>&1 || RC=$?
assert_eq "no command: exit 1" "$RC" "1"
RC=0; "$CHECK" --help > /dev/null 2>&1 || RC=$?
assert_eq "--help: exit 0" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
