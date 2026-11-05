#!/usr/bin/env bash
# Tests workforces/workforce.schema.json on the member's `pool`: which pools a member may declare, and
# that a pool must belong to the member's adapter's vendor. Also that every shipped workforce is
# still valid. Needs python3 with jsonschema (the workforce-schema CI job installs it); skips, and
# says so, when it is missing.
#
# Usage: scripts/test-workforce-schema.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$SCRIPTS_DIR/../workforces/workforce.schema.json"
WORKFORCES="$SCRIPTS_DIR/../workforces"

if ! python3 -c 'import jsonschema' 2> /dev/null; then
  echo "skipped: python3 with jsonschema is not installed"
  exit 0
fi

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
section() { echo ""; echo "── $1"; }

# valid <json> : exit 0 if the document passes the schema
valid() {
  python3 -I - "$SCHEMA" "$1" << 'PY'
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1]))
errors = list(Draft7Validator(schema).iter_errors(json.loads(sys.argv[2])))
sys.exit(1 if errors else 0)
PY
}
accepts() { if valid "$2"; then ok "$1"; else fail "$1 (rejected)"; fi; }
rejects() { if valid "$2"; then fail "$1 (accepted)"; else ok "$1"; fi; }

# wf <adapter> [<pool>] : a one-member workforce
wf() {
  if [[ -n "${2:-}" ]]; then
    printf '{"name":"t","members":[{"role":"coder","adapter":"%s","pool":"%s"}]}' "$1" "$2"
  else
    printf '{"name":"t","members":[{"role":"coder","adapter":"%s"}]}' "$1"
  fi
}

section "1 · A pool is optional"
accepts "a member with no pool: still valid" "$(wf claude-code)"

section "2 · The four pools"
accepts "claude-code on subscription:anthropic" "$(wf claude-code subscription:anthropic)"
accepts "claude-code on api:anthropic" "$(wf claude-code api:anthropic)"
accepts "codex on subscription:openai" "$(wf codex subscription:openai)"
accepts "codex on api:openai (the swarm no longer refuses a key)" "$(wf codex api:openai)"

section "3 · A pool belongs to the adapter's vendor"
rejects "claude-code on an openai pool" "$(wf claude-code api:openai)"
rejects "codex on an anthropic pool" "$(wf codex subscription:anthropic)"
accepts "pi may declare any known pool: api:anthropic" "$(wf pi api:anthropic)"
accepts "pi may declare any known pool: subscription:openai" "$(wf pi subscription:openai)"

section "4 · Only known pools"
rejects "a pool that does not exist" "$(wf claude-code bananas)"
rejects "unknown is not something to declare, it is what is left when nothing is" "$(wf claude-code unknown)"
rejects "a pool that is not a string" '{"name":"t","members":[{"role":"coder","adapter":"codex","pool":7}]}'

section "5 · The shipped workforces"
for f in "$WORKFORCES"/*.json; do
  [[ "$f" == *workforce.schema.json ]] && continue
  accepts "$(basename "$f") is valid" "$(cat "$f")"
done

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All workforce-schema checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
