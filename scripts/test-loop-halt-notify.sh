#!/usr/bin/env bash
# Tests scripts/loop-halt-notify.sh: the notice a halted conductor loop leaves for the human
# and for the architect. No tmux, no AI; a stub osascript stands in for the desktop
# notification.
#
# Usage: scripts/test-loop-halt-notify.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="$SCRIPTS_DIR/loop-halt-notify.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
has() { if grep -q -- "$1" "$2"; then ok "$3"; else fail "$3 (in $2: $(tr '\n' '|' < "$2" | cut -c1-300))"; fi; }

new_dir() { rm -rf "$TMP/c"; mkdir -p "$TMP/c"; export CONDUCTOR_DIR="$TMP/c"; : > "$TMP/osascript.log"; }
count() { find "$1" -maxdepth 1 -name 'loop-halt-*.md' 2> /dev/null | wc -l | tr -d ' '; }
human() { find "$CONDUCTOR_DIR/human-inbox" -name 'loop-halt-*.md' | head -1; }
architect() { find "$CONDUCTOR_DIR/architect-inbox" -name 'loop-halt-*.md' | head -1; }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s"\n' "$TMP/osascript.log" > "$TMP/bin/osascript"
chmod +x "$TMP/bin/osascript"

section "1 · A halt leaves one notice for the human and one for the architect"
new_dir
OUT="$("$NOTIFY" --kind failed --artifact 0001/signal-20261101-120000.md --handler conductor/on-signal-complete \
  --detail "the handler failed 3 time(s); last exit 1" --last-error "claude-code: budget reached")"
assert_eq "one human notice" "$(count "$CONDUCTOR_DIR/human-inbox")" "1"
assert_eq "one architect notice" "$(count "$CONDUCTOR_DIR/architect-inbox")" "1"
has '^type: loop-halt$' "$(human)" "the human's notice is typed loop-halt"
has '^type: halt$' "$(architect)" "the architect's is typed halt, which on-halt.md handles"
for f in "$(human)" "$(architect)"; do
  has '^kind: failed$' "$f" "kind in $(basename "$(dirname "$f")")"
  has '^artifact: 0001/signal-20261101-120000.md$' "$f" "artifact in $(basename "$(dirname "$f")")"
  has '^handler: conductor/on-signal-complete$' "$f" "handler in $(basename "$(dirname "$f")")"
  has 'Last error: claude-code: budget reached' "$f" "last error in $(basename "$(dirname "$f")")"
done
has 'scripts/conductor-loop.sh' "$(human)" "says how to start again"
has 'still waiting' "$(human)" "says the event was not skipped"
has 'CONDUCTOR LOOP HALTED' <(printf '%s\n' "$OUT") "a banner on stdout (the conductor window)"
has 'Why:       the handler failed 3 time' <(printf '%s\n' "$OUT") "the banner says why"

section "2 · Values cannot break the notice or run anything"
new_dir
MARK="$TMP/ran"
"$NOTIFY" --kind "failed" --artifact "0001/a.md" --handler "h" \
  --detail "line one
line two	with a tab" --last-error "\`touch $MARK\` and \$(touch $MARK) and \"quotes\"" > /dev/null
assert_eq "a newline or tab does not add lines to a field" "$(grep -c '^detail\|^Why' "$(human)")" "1"
has 'Why:       line one line two with a tab' "$(human)" "the value is on one line"
assert_eq "no command in a value was run" "$([[ -e "$MARK" ]] && echo ran || echo not-run)" "not-run"
has 'touch' "$(human)" "the text itself is kept"
"$NOTIFY" --kind failed --artifact a --handler h --detail "$(printf 'x%.0s' $(seq 1 500))" > /dev/null
assert_eq "a long value is cut" "$(grep '^Why:' "$(find "$CONDUCTOR_DIR/human-inbox" -name 'loop-halt-*.md' | sort | tail -1)" | wc -c | tr -d ' ')" "$((11 + 300 + 1))"

section "3 · Desktop notification only when asked for"
new_dir
PATH="$TMP/bin:$PATH" "$NOTIFY" --kind failed --artifact a --handler h --detail d > /dev/null
assert_eq "no config: no notification" "$(wc -l < "$TMP/osascript.log" | tr -d ' ')" "0"
printf -- '---\nnotify-channel: none\n---\n' > "$CONDUCTOR_DIR/config.md"
PATH="$TMP/bin:$PATH" "$NOTIFY" --kind failed --artifact a --handler h --detail d > /dev/null
assert_eq "channel none: no notification" "$(wc -l < "$TMP/osascript.log" | tr -d ' ')" "0"
printf -- '---\nnotify-channel: push\n---\n' > "$CONDUCTOR_DIR/config.md"
PATH="$TMP/bin:$PATH" "$NOTIFY" --kind failed --artifact a --handler h --detail 'said "hi" and \ more' > /dev/null
assert_eq "channel push: one notification" "$(grep -c 'display notification' "$TMP/osascript.log")" "1"
if grep 'display notification' "$TMP/osascript.log" | grep -q 'said "hi"'; then fail "double quotes reached AppleScript"; else ok "double quotes were stripped"; fi
if grep 'display notification' "$TMP/osascript.log" | grep -q 'more' && ! grep 'display notification' "$TMP/osascript.log" | grep -q '\\ more'; then ok "backslashes were stripped"; else fail "backslash reached AppleScript: $(grep 'display notification' "$TMP/osascript.log")"; fi
: > "$TMP/osascript.log"
RC=0
# shellcheck disable=SC2016  # the command is for the child shell
PATH="/usr/bin:/bin" "$BASH" -c 'command -v osascript > /dev/null && exit 0; "$1" --kind failed --artifact a --handler h --detail d' _ "$NOTIFY" > /dev/null 2>&1 || RC=$?
assert_eq "push without osascript (not macOS): still exit 0" "$RC" "0"

section "4 · A notice that cannot be written never changes the outcome"
new_dir
touch "$CONDUCTOR_DIR/human-inbox"          # a file where the directory should be
RC=0
"$NOTIFY" --kind failed --artifact a --handler h --detail d > /dev/null 2>&1 || RC=$?
assert_eq "exit 0" "$RC" "0"
assert_eq "the architect still gets theirs" "$(count "$CONDUCTOR_DIR/architect-inbox")" "1"
new_dir
RC=0
"$NOTIFY" > /dev/null 2>&1 || RC=$?
assert_eq "no arguments: exit 0" "$RC" "0"
has '^handler: none$' "$(human)" "an unknown handler is written as none"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
