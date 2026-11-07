#!/usr/bin/env bash
# Tests scripts/trust-project.sh: reading whether Claude Code trusts a project directory, and the opt-in
# that records the trust the way the trust dialog does. The file is Claude Code's own (~/.claude.json),
# which holds more than trust and is rewritten by running sessions, so the write must keep everything
# else, be atomic, leave a backup, and refuse a file it cannot read as JSON. Uses a scratch file, never
# the real one.
#
# Usage: scripts/test-trust-project.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TP="$SCRIPTS_DIR/trust-project.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { echo ""; echo "── $1"; }

export CLAUDE_JSON_FILE="$TMP/claude.json"
DIR="$TMP/proj"; mkdir -p "$DIR"
PHYS="$(cd "$DIR" && pwd -P)"
run() { RC=0; "$TP" "$@" > "$TMP/out" 2> "$TMP/err" || RC=$?; }
out() { cat "$TMP/out"; }

section "1 · check: trusted, untrusted or unknown, never a guess"
rm -f "$CLAUDE_JSON_FILE"
run check "$DIR"
assert_eq "no Claude file: unknown" "$(out)" "unknown"
printf 'not json' > "$CLAUDE_JSON_FILE"
run check "$DIR"
assert_eq "a file that is not JSON: unknown" "$(out)" "unknown"
printf '{"projects":{}}' > "$CLAUDE_JSON_FILE"
run check "$DIR"
assert_eq "no entry for the project: untrusted" "$(out)" "untrusted"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}' "$PHYS" > "$CLAUDE_JSON_FILE"
run check "$DIR"
assert_eq "an entry that says false: untrusted" "$(out)" "untrusted"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$PHYS" > "$CLAUDE_JSON_FILE"
run check "$DIR"
assert_eq "an entry that says true: trusted" "$(out)" "trusted"
assert_eq "exit 0 for every answer" "$RC" "0"

section "2 · grant: records the trust and keeps everything else"
cat > "$CLAUDE_JSON_FILE" << EOF2
{"numStartups": 7, "oauthAccount": {"emailAddress": "someone@example.com"},
 "projects": {"/other": {"hasTrustDialogAccepted": true, "allowedTools": ["x"]},
              "$PHYS": {"allowedTools": ["y"], "history": []}}}
EOF2
run grant "$DIR"
assert_eq "exit 0" "$RC" "0"
assert_eq "now trusted" "$("$TP" check "$DIR")" "trusted"
assert_eq "the project's other keys are kept" "$(jq -c '.projects["'"$PHYS"'"].allowedTools' "$CLAUDE_JSON_FILE")" '["y"]'
assert_eq "other projects are kept" "$(jq -c '.projects["/other"].allowedTools' "$CLAUDE_JSON_FILE")" '["x"]'
assert_eq "other top-level keys are kept" "$(jq -r '.numStartups' "$CLAUDE_JSON_FILE")" "7"
assert_eq "a backup of the file as it was" "$(find "$TMP" -maxdepth 1 -name 'claude.json.swarm-backup-*' | wc -l | tr -d ' ')" "1"
assert_eq "the backup is the old content" "$(jq -r '.projects["'"$PHYS"'"].hasTrustDialogAccepted // "absent"' "$(find "$TMP" -maxdepth 1 -name 'claude.json.swarm-backup-*' | head -1)")" "absent"
assert_eq "no temp file is left behind" "$(find "$TMP" -maxdepth 1 -name 'claude.json.new*' | wc -l | tr -d ' ')" "0"
assert_eq "nothing secret is printed" "$(grep -c 'someone@example.com' "$TMP/out" "$TMP/err" | awk -F: '{s+=$2} END{print s+0}')" "0"
run grant "$DIR"
assert_eq "granting what is already granted changes nothing and says so" "$(grep -c 'already' "$TMP/out" || true)" "1"

section "3 · grant refuses what it cannot do safely"
printf 'not json' > "$CLAUDE_JSON_FILE"
run grant "$DIR"
assert_eq "a file that is not JSON: exit 1" "$RC" "1"
assert_eq "and it is left exactly as it was" "$(cat "$CLAUDE_JSON_FILE")" "not json"
rm -f "$CLAUDE_JSON_FILE"
run grant "$DIR"
assert_eq "no Claude file: exit 1, nothing created (run claude once first)" "$RC $([[ -e "$CLAUDE_JSON_FILE" ]] && echo created || echo none)" "1 none"
run grant "$TMP/missing-dir"
assert_eq "a directory that does not exist: exit 1" "$RC" "1"
run bogus
assert_eq "an unknown command: exit 1" "$RC" "1"

section "4 · the key is the physical path"
ln -s "$DIR" "$TMP/link"
printf '{"projects":{}}' > "$CLAUDE_JSON_FILE"
run grant "$TMP/link"
assert_eq "granting through a symlink records the real path" "$(jq -r '.projects | keys[0]' "$CLAUDE_JSON_FILE")" "$PHYS"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All trust-project checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
