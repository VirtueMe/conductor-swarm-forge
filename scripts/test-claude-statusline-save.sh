#!/usr/bin/env bash
# Tests scripts/claude-statusline-save.sh, the status line command that keeps the last non-null
# rate_limits payload for claude-usage.sh. Nothing from the payload but rate_limits is kept, a null
# payload never overwrites a saved one, and the wrapped status line command still gets the payload.
#
# Usage: scripts/test-claude-statusline-save.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SAVER="$SCRIPTS_DIR/claude-statusline-save.sh"
FX="$SCRIPTS_DIR/../tests/claude-usage"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

export CLAUDE_STATUSLINE_FILE="$TMP/dir/saved.json"
run() { RC=0; OUT="$("$SAVER" "${@:2}" < "$1" 2> "$TMP/err")" || RC=$?; }

section "1 · A payload with rate_limits is saved"
run "$FX/statusline-payload.json"
assert_eq "exit 0" "$RC" "0"
assert_eq "nothing printed when there is no command to wrap" "$OUT" ""
assert_eq "the file was written, directory made" "$(test -f "$CLAUDE_STATUSLINE_FILE" && echo yes)" "yes"
assert_eq "it holds the five-hour window" "$(jq -c '.rate_limits.five_hour' "$CLAUDE_STATUSLINE_FILE")" '{"used_percentage":10,"resets_at":1793869800}'
assert_eq "and the week" "$(jq -c '.rate_limits.seven_day' "$CLAUDE_STATUSLINE_FILE")" '{"used_percentage":19,"resets_at":1794024000}'
# shellcheck disable=SC2016  # a jq program
assert_eq "with the time it was taken" "$(jq '(now - .taken_at) | (. >= 0 and . < 60)' "$CLAUDE_STATUSLINE_FILE")" "true"
assert_eq "and only those keys" "$(jq -c 'keys' "$CLAUDE_STATUSLINE_FILE")" '["rate_limits","taken_at"]'
assert_eq "nothing else from the payload is kept" "$(grep -c 'do-not-copy\|secret' "$CLAUDE_STATUSLINE_FILE" || true)" "0"
assert_eq "the file is private to the user" "$(stat -c %a "$CLAUDE_STATUSLINE_FILE")" "600"

section "2 · A null payload keeps the last good one"
cp "$CLAUDE_STATUSLINE_FILE" "$TMP/before.json"
run "$FX/statusline-payload-null.json"
assert_eq "exit 0" "$RC" "0"
assert_eq "the saved file is untouched" "$(cmp -s "$CLAUDE_STATUSLINE_FILE" "$TMP/before.json" && echo same)" "same"
rm -f "$CLAUDE_STATUSLINE_FILE"
run "$FX/statusline-payload-null.json"
assert_eq "a null payload and nothing saved: nothing is written" "$(test -e "$CLAUDE_STATUSLINE_FILE" && echo yes || echo no)" "no"
echo 'not json' > "$TMP/garbage"
run "$TMP/garbage"
assert_eq "garbage on stdin: exit 0, nothing written" "$RC$(test -e "$CLAUDE_STATUSLINE_FILE" && echo yes || echo no)" "0no"

section "3 · The wrapped status line command still gets the payload"
cat > "$TMP/line.sh" <<'LINE'
#!/usr/bin/env bash
echo "model: $(jq -r .model.display_name)"
LINE
chmod +x "$TMP/line.sh"
run "$FX/statusline-payload.json" "$TMP/line.sh"
assert_eq "its output is the status line" "$OUT" "model: Haiku"
assert_eq "the payload was saved as well" "$(test -f "$CLAUDE_STATUSLINE_FILE" && echo yes)" "yes"
run "$FX/statusline-payload-null.json" "$TMP/line.sh"
assert_eq "a null payload still reaches it" "$OUT" "model: null"
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 3\n' > "$TMP/fail.sh"; chmod +x "$TMP/fail.sh"
run "$FX/statusline-payload.json" "$TMP/fail.sh"
assert_eq "its exit status is passed on" "$RC" "3"

section "4 · A save that cannot happen never breaks the status line"
export CLAUDE_STATUSLINE_FILE="/proc/no/such/dir/saved.json"
run "$FX/statusline-payload.json" "$TMP/line.sh"
assert_eq "the status line is still drawn" "$OUT" "model: Haiku"
assert_eq "exit 0" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
