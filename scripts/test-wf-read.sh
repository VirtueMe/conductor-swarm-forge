#!/usr/bin/env bash
# Tests scripts/wf-read.sh (wf_field) with no tmux and no AI: field lookup by
# role, the params JSON-string contract, defaults for absent params, and the
# error path for an absent adapter.
#
# Usage: scripts/test-wf-read.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

# shellcheck source=scripts/wf-read.sh
source "$SCRIPTS_DIR/wf-read.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

WF="$WORK/workforce.json"
cat > "$WF" << 'EOF'
{
  "name": "fixture",
  "members": [
    { "role": "conductor", "adapter": "claude-code", "params": { "model": "m1", "effort": "high" } },
    { "role": "coder",     "adapter": "codex" },
    { "role": "reviewer",  "adapter": "pi",          "params": {} }
  ]
}
EOF

echo "── adapter lookup by role"
assert_eq "conductor adapter"   "$(wf_field "$WF" conductor adapter)" "claude-code"
assert_eq "coder adapter"       "$(wf_field "$WF" coder adapter)"     "codex"
assert_eq "reviewer adapter"    "$(wf_field "$WF" reviewer adapter)"  "pi"

echo "── params is a JSON string"
PARAMS=$(wf_field "$WF" conductor params)
assert_eq "params round-trips" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["model"])' "$PARAMS")" "m1"
assert_eq "empty params object"     "$(wf_field "$WF" reviewer params)" "{}"

echo "── absent params default to {}"
assert_eq "member without params"   "$(wf_field "$WF" coder params)"    "{}"
assert_eq "unknown role"            "$(wf_field "$WF" nosuchrole params)" "{}"

echo "── absent adapter is an error"
if OUT=$(wf_field "$WF" nosuchrole adapter 2>&1); then
  fail "unknown role adapter rejected"
else
  ok "unknown role adapter rejected"
  assert_eq "error names the role" "$OUT" "No adapter found for role: nosuchrole"
fi

echo "── shipped workforces resolve every member"
for f in "$ROOT_DIR"/workforces/*.json; do
  [[ "$f" == *.schema.json ]] && continue
  while IFS= read -r role; do
    if [[ -n "$(wf_field "$f" "$role" adapter 2>/dev/null)" ]]; then
      ok "$(basename "$f"): $role"
    else
      fail "$(basename "$f"): $role has no adapter"
    fi
  done < <(python3 -c 'import json,sys; [print(m["role"]) for m in json.load(open(sys.argv[1]))["members"]]' "$f")
done

echo ""
if (( FAILS > 0 )); then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "All checks passed"
