#!/usr/bin/env bash
set -euo pipefail
# Check that Codex is billed to a subscription, not to an API key. The swarm no longer asks: Codex
# may run on either, and billing-mode.sh says which (pool and billing on every usage line). What
# still needs a subscription is a check of the allowance readers against real Codex
# (codex-allowance-run.sh), because on an API key there is no allowance to read.
#
# Usage: codex-billing.sh check
# Env:   CODEX_HOME (default ~/.codex), CODEX_AUTH_FILE (default $CODEX_HOME/auth.json)
#        and what codex-usage.sh reads (CODEX_SESSIONS_DIR)
#
# check exits 0 if the swarm may use Codex, and 2, with the reason on stderr, if it may not:
#   - Codex is signed in with an API key. Its work is then billed per token, not against the
#     subscription allowance this swarm measures. The sign-in is read from auth.json: an auth_mode
#     of "chatgpt" is a subscription; an auth_mode that names an API key, or, when there is no
#     auth_mode, a stored API key, is not. Only the shape is read, never printed: no key or token
#     reaches the output.
#   - the newest Codex reading has no plan_type, so it does not look like a subscription reading.
# When neither is the case it exits 0, and says nothing if the sign-in is a subscription. When it
# cannot tell (no readable auth.json, an auth_mode it does not know, and no reading yet) it exits
# 0 as well and says so on stderr: refusing would stop a first run that could never produce the
# reading that settles it. It refuses on evidence, not on doubt.
#
# The sign-in is Codex's own file and not a documented interface; a shape this does not recognise
# is "cannot tell", never a guess.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
AUTH_FILE="${CODEX_AUTH_FILE:-$CODEX_DIR/auth.json}"

# subscription, apikey or unknown: billing-mode.sh reads the sign-in, so there is one reading of it
sign_in() {
  local mode
  mode="$(CODEX_AUTH_FILE="$AUTH_FILE" "$SCRIPTS_DIR/billing-mode.sh" detect codex 2> /dev/null)" || mode=unknown
  case "$mode" in api) echo apikey ;; subscription) echo subscription ;; *) echo unknown ;; esac
}

main() {
  case "${1:-}" in
    check) ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) echo "Usage: codex-billing.sh check" >&2; return 1 ;;
  esac
  command -v jq > /dev/null 2>&1 || { echo "codex-billing.sh needs jq" >&2; return 3; }

  local mode reading snapshot plan
  mode="$(sign_in)"
  if [[ "$mode" == apikey ]]; then
    echo "Codex is signed in with an API key ($AUTH_FILE): its work would be billed per token, not against the subscription allowance. Sign in with a ChatGPT account (codex login) to use it in the swarm." >&2
    return 2
  fi

  reading="$("$SCRIPTS_DIR/codex-usage.sh" 2> /dev/null)" || reading=""
  snapshot="$(jq -r '.snapshot_at // empty' <<< "$reading" 2> /dev/null || true)"
  plan="$(jq -r '.plan_type // empty' <<< "$reading" 2> /dev/null || true)"
  if [[ -n "$snapshot" && -z "$plan" ]]; then
    echo "The newest Codex reading ($snapshot) has no plan_type, so it does not look like a subscription: Codex may be signed in with an API key. Check codex login status before the swarm uses it." >&2
    return 2
  fi

  if [[ "$mode" == unknown && -z "$snapshot" ]]; then
    echo "Could not verify how Codex is signed in (no readable $AUTH_FILE with a known auth_mode, and no Codex session with a plan yet); allowing it." >&2
  fi
  return 0
}

main "$@"
