#!/usr/bin/env bash
set -euo pipefail
# How a workforce member is billed, and the pool that follows from it.
#
# Usage: billing-mode.sh detect <adapter>
#        billing-mode.sh pool <adapter> [--declared <pool>] [--json]
#        billing-mode.sh pi-pool <provider>
# Env:   ANTHROPIC_API_KEY, CLAUDE_CREDENTIALS_FILE (default ~/.claude/.credentials.json)
#        CODEX_HOME (default ~/.codex), CODEX_AUTH_FILE (default $CODEX_HOME/auth.json)
#        PI_AUTH_FILE (default ~/.pi/agent/auth.json)
#
# detect  prints api, subscription or unknown, from the harness's own sign-in:
#           claude-code  CLAUDE_CODE_USE_BEDROCK, _VERTEX or _FOUNDRY set (not empty, 0 or false), or
#                        an ANTHROPIC_AUTH_TOKEN: unknown, the run is billed to a provider or gateway
#                        and a login on disk is not what pays for it. Else ANTHROPIC_API_KEY set and
#                        not empty: api (a key in the environment takes over from a login). Else a
#                        claudeAiOauth login with a token: subscription.
#           codex        auth.json: an auth_mode of chatgpt is a subscription; one that names an API
#                        key, or no auth_mode and a stored key, is api. The same reading as
#                        codex-billing.sh.
#           pi           unknown: what it costs depends on the provider it talks to.
#         Anything it does not recognise (no file, a shape it does not know, not JSON) is unknown,
#         never a guess, and still exit 0: doubt does not stop a run. Only the shape is read; no key
#         or token reaches the output. The sign-in files are the harnesses' own and not documented
#         interfaces.
# pool    prints the pool: <billing>:<vendor>, one of api:anthropic, subscription:anthropic,
#         api:openai, subscription:openai, or "unknown". --declared is what the workforce says. A
#         detected mode wins over it, and when they disagree a "mismatch" note goes to stderr (exit
#         stays 0). When nothing is detected the declaration stands; with neither the pool is
#         unknown. A declared pool must be a known one, and for claude-code or codex it must belong
#         to that adapter's vendor, or the exit is 1. pi may declare any known pool but subscription:anthropic:
#         Anthropic does not permit a Claude subscription login in a third-party harness (OpenAI lists pi
#         for ChatGPT plan usage, so subscription:openai stands).
#         With --json it prints what was decided as one object instead of a word, so a caller never
#         has to read a sentence: {"pool", "declared", "mismatch", "rejected"}. mismatch is true when a
#         detected mode overrode a different declared pool. rejected is true when the declared pool
#         was not a pool, or not this adapter's vendor's; the declaration is then set aside, the exit is
#         0, and the sign-in settles the pool as if nothing had been declared. No note goes to stderr.
# pi-pool prints the pool of one Pi message, from its provider (the log names it on every assistant
#         message) and the `type` Pi's auth.json holds for that provider; the log never names the
#         sign-in. openai-codex with oauth is subscription:openai (the ChatGPT plan), openai with
#         api_key is api:openai, anthropic with api_key is api:anthropic. Every other pairing, a
#         provider with no entry, a type it does not know, a missing or unreadable file is "unknown",
#         exit 0: a pairing nobody has seen is not guessed, and an Anthropic login is not what pays
#         for a Pi run (#156). Only the type is read; no key or token reaches the output.
#         auth.json is the best guess, not proof: a runtime --api-key outranks it and leaves no trace.

POOLS="api:anthropic subscription:anthropic api:openai subscription:openai"

die() { echo "billing-mode.sh: $*" >&2; exit 1; }

vendor_of() { # <adapter>: the vendor whose pools it may use, or "any"
  case "$1" in
    claude-code) echo anthropic ;;
    codex) echo openai ;;
    pi) echo any ;;
    *) return 1 ;;
  esac
}

# An environment switch counts when it is set to something other than nothing, 0 or false.
switched_on() { local v="${!1:-}"; [[ -n "$v" && "$v" != 0 && "$v" != false ]]; }

detect_claude() {
  local v
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do
    if switched_on "$v"; then echo unknown; return; fi
  done
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then echo unknown; return; fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then echo api; return; fi
  local file="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
  [[ -r "$file" ]] || { echo unknown; return; }
  jq -r 'if ((.claudeAiOauth.accessToken // "") | type == "string" and length > 0) then "subscription" else "unknown" end' \
    "$file" 2> /dev/null || echo unknown
}

detect_codex() {
  local file="${CODEX_AUTH_FILE:-${CODEX_HOME:-$HOME/.codex}/auth.json}"
  [[ -r "$file" ]] || { echo unknown; return; }
  jq -r '
    (.auth_mode // "") as $m
    | if ($m | ascii_downcase) == "chatgpt" then "subscription"
      elif ($m | ascii_downcase | test("api")) then "api"
      elif $m == "" and ((.OPENAI_API_KEY // "") | type == "string") and ((.OPENAI_API_KEY // "") != "") then "api"
      else "unknown" end' "$file" 2> /dev/null || echo unknown
}

detect() { # <adapter>
  case "$1" in
    claude-code) detect_claude ;;
    codex) detect_codex ;;
    pi) echo unknown ;;
    *) die "unknown adapter: $1" ;;
  esac
}

# pi_pool <provider>: see the header. The provider is a name from Pi's log, never from a prompt.
pi_pool() {
  local provider="${1:-}" file="${PI_AUTH_FILE:-$HOME/.pi/agent/auth.json}" type=""
  if [[ -n "$provider" && -r "$file" ]]; then
    type="$(jq -r --arg p "$provider" 'if type == "object" and (.[$p] | type) == "object" and (.[$p].type | type) == "string" then .[$p].type else empty end' "$file" 2> /dev/null)" || type=""
  fi
  case "$provider:$type" in
    openai-codex:oauth) echo subscription:openai ;;
    openai:api_key) echo api:openai ;;
    anthropic:api_key) echo api:anthropic ;;
    *) echo unknown ;;
  esac
}

# pool <adapter> <declared> <json?>: see the header. Prints the pool, or the object with json=true.
pool() {
  local adapter="$1" declared="${2:-}" json="${3:-false}" vendor mode detected result mismatch=false rejected=false
  vendor="$(vendor_of "$adapter")" || die "unknown adapter: $adapter"

  if [[ -n "$declared" ]]; then
    local problem=""
    if [[ " $POOLS " != *" $declared "* ]]; then problem="unknown pool '$declared' (known: $POOLS)"
    elif [[ "$vendor" != any && "${declared#*:}" != "$vendor" ]]; then problem="pool '$declared' does not belong to $adapter, which bills to $vendor"
    elif [[ "$adapter" == pi && "$declared" == subscription:anthropic ]]; then problem="pool '$declared' is not allowed for pi: a Claude subscription login is for Claude Code and Anthropic's own apps, not a third-party harness"
    fi
    if [[ -n "$problem" ]]; then
      [[ "$json" == true ]] || die "$problem"
      rejected=true
    fi
  fi

  mode="$(detect "$adapter")"
  if [[ "$mode" == unknown ]]; then
    result="unknown"
    [[ -z "$declared" || "$rejected" == true ]] || result="$declared"
  else
    detected="$mode:$vendor"
    result="$detected"
    if [[ -n "$declared" && "$rejected" == false && "$declared" != "$detected" ]]; then
      mismatch=true
      [[ "$json" == true ]] || echo "billing-mode.sh: mismatch: $adapter declared $declared but its sign-in says $mode; using $detected" >&2
    fi
  fi

  if [[ "$json" == true ]]; then
    jq -nc --arg pool "$result" --arg declared "$declared" --argjson mismatch "$mismatch" --argjson rejected "$rejected" \
      '{ pool: $pool, declared: (if $declared == "" then null else $declared end), mismatch: $mismatch, rejected: $rejected }'
  else
    echo "$result"
  fi
}

main() {
  command -v jq > /dev/null 2>&1 || die "needs jq"
  case "${1:-}" in
    detect)
      [[ $# -eq 2 ]] || die "Usage: billing-mode.sh detect <adapter>"
      detect "$2" ;;
    pool)
      [[ $# -ge 2 ]] || die "Usage: billing-mode.sh pool <adapter> [--declared <pool>] [--json]"
      local adapter="$2" declared="" json=false
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --declared) [[ $# -ge 2 ]] || die "--declared needs a pool"; declared="$2"; shift 2 ;;
          --json) json=true; shift ;;
          *) die "unknown argument: $1" ;;
        esac
      done
      pool "$adapter" "$declared" "$json" ;;
    pi-pool)
      [[ $# -eq 2 ]] || die "Usage: billing-mode.sh pi-pool <provider>"
      pi_pool "$2" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) die "Usage: billing-mode.sh detect <adapter> | pool <adapter> [--declared <pool>] [--json]" ;;
  esac
}

main "$@"
