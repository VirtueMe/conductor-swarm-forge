#!/usr/bin/env bash
# Tests scripts/window-watch.sh: a worker window that waits for a person is noticed once. A stub
# tmux serves the windows and their panes from files; no real tmux, no AI.
#
# Usage: scripts/test-window-watch.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH="$SCRIPTS_DIR/window-watch.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TMUX_TMPDIR="$TMP/tmux"; mkdir -p "$TMUX_TMPDIR"

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { echo ""; echo "── $1"; }

# The stub: list-windows prints $PANES/windows; capture-pane prints $PANES/<window>; the rest is logged.
mkdir -p "$TMP/bin" "$TMP/panes"
cat > "$TMP/bin/tmux" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  list-windows) cat "$PANES/windows" ;;
  capture-pane) t=""; while [[ $# -gt 0 ]]; do [[ "$1" == -t ]] && t="${2#*:}"; shift; done; cat "$PANES/$t" ;;
  *) echo "$*" >> "$PANES/tmux.log" ;;
esac
STUB
chmod +x "$TMP/bin/tmux"
export PANES="$TMP/panes" PATH="$TMP/bin:$PATH"

new_swarm() {
  rm -rf "$TMP/c" "$TMP/panes"; mkdir -p "$TMP/c/tasks" "$TMP/c/work" "$TMP/panes"
  export CONDUCTOR_DIR="$TMP/c"
  : > "$PANES/windows"; : > "$PANES/tmux.log"
}
add_window() { # <window> <pane text>
  echo "$1" >> "$PANES/windows"; printf '%s\n' "$2" > "$PANES/$1"
  local id="${1##*-}"
  [[ -f "$CONDUCTOR_DIR/tasks/$id.md" ]] || printf -- '---\nid: %s\n---\n' "$id" > "$CONDUCTOR_DIR/tasks/$id.md"
  mkdir -p "$CONDUCTOR_DIR/work/$id"; echo x > "$CONDUCTOR_DIR/work/$id/assigned.md"
}
inbox() { find "$CONDUCTOR_DIR/human-inbox" -name 'window-*.md' 2> /dev/null | wc -l | tr -d ' '; }

PERMISSION=$'● Bash(npm test)\n\n╭────────────────────────────╮\n│ Bash command               │\n│   npm test                 │\n│ Do you want to proceed?    │\n│ ❯ 1. Yes                   │\n│   2. Yes, and don'"'"'t ask again │\n│   3. No (esc)              │\n╰────────────────────────────╯'

section "1 · A numbered question is reported once, with its text"
new_swarm
add_window coder-0001 "$PERMISSION"
OUT="$("$WATCH")"
assert_eq "one finding" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
assert_eq "it names the window, the task and the kind" "$(printf '%s' "$OUT" | cut -f1-3)" $'coder-0001\t0001\twaiting'
if grep -q 'Do you want to proceed?' <<< "$OUT"; then ok "it says what the prompt asks"; else fail "no question text: $OUT"; fi
assert_eq "a notice for the person" "$(inbox)" "1"
if grep -q 'tmux select-window -t swarm:coder-0001' "$CONDUCTOR_DIR"/human-inbox/window-*.md; then ok "the notice says how to get there"; else fail "no way to the window"; fi
if grep -q 'set-option -w -t swarm:coder-0001 window-status-style' "$PANES/tmux.log"; then ok "the window is coloured in the status bar"; else fail "no status colour"; fi
OUT="$("$WATCH")"
assert_eq "the second look says nothing" "$OUT" ""
assert_eq "and leaves no second notice" "$(inbox)" "1"

section "2 · A window that moved on is forgotten, and its next stop is reported again"
echo '● Writing code...' > "$PANES/coder-0001"
OUT="$("$WATCH")"
assert_eq "nothing while it works" "$OUT" ""
if grep -q 'set-option -w -u -t swarm:coder-0001 window-status-style' "$PANES/tmux.log"; then ok "the colour is cleared"; else fail "colour not cleared"; fi
printf '%s\n' "$PERMISSION" > "$PANES/coder-0001"
OUT="$("$WATCH")"
assert_eq "reported again" "$(printf '%s' "$OUT" | cut -f3)" "waiting"

section "3 · A different question in the same window is a new finding"
new_swarm
add_window coder-0001 "$PERMISSION"
"$WATCH" > /dev/null
printf 'Do you trust the files in this folder?\n❯ 1. Yes, proceed\n  2. No, exit\n' > "$PANES/coder-0001"
OUT="$("$WATCH")"
if grep -q 'trust the files' <<< "$OUT"; then ok "the new question is reported"; else fail "not reported: $OUT"; fi

section "4 · A y/n question counts; a pane that looks like work does not"
new_swarm
add_window tester-0002 $'Overwrite file? (y/n)'
add_window coder-0003 $'Reading files\n✻ Thinking… (12s · esc to interrupt)'
OUT="$("$WATCH")"
assert_eq "only the y/n window" "$(printf '%s\n' "$OUT" | cut -f1)" "tester-0002"

section "5 · A quiet window is reported by the time limit, and an unknown shape is not guessed at"
new_swarm
add_window coder-0001 $'something no reader knows about'
touch -d '2 hours ago' "$CONDUCTOR_DIR/work/0001/assigned.md"
OUT="$(CONDUCTOR_QUIET_AFTER=20 "$WATCH")"
assert_eq "quiet" "$(printf '%s' "$OUT" | cut -f3)" "quiet"
if grep -q 'nothing for 20 minutes' <<< "$OUT" && grep -q 'something no reader knows about' <<< "$OUT"; then ok "it says how long and what the pane ends with"; else fail "text: $OUT"; fi
assert_eq "asked only once" "$(CONDUCTOR_QUIET_AFTER=20 "$WATCH")" ""
new_swarm
add_window coder-0001 $'something no reader knows about'
touch -d '2 hours ago' "$CONDUCTOR_DIR/work/0001/assigned.md"
assert_eq "CONDUCTOR_QUIET_AFTER=0 turns the time limit off" "$(CONDUCTOR_QUIET_AFTER=0 "$WATCH")" ""
new_swarm
add_window coder-0001 $'something no reader knows about'
assert_eq "a fresh artifact is not quiet" "$(CONDUCTOR_QUIET_AFTER=20 "$WATCH")" ""

section "6 · Other windows, no session, and off"
new_swarm
echo conductor >> "$PANES/windows"; printf 'Do you want to proceed?\n❯ 1. Yes\n' > "$PANES/conductor"
add_window coder-0009 "plain"
rm "$CONDUCTOR_DIR/tasks/0009.md"
assert_eq "windows that are not a worker of a task are left alone" "$("$WATCH")" ""
new_swarm
add_window coder-0001 "$PERMISSION"
assert_eq "off does nothing" "$(CONDUCTOR_WINDOW_WATCH=off "$WATCH")" ""
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/tmux.fail"; mkdir -p "$TMP/nobin"
cp "$TMP/bin/tmux.fail" "$TMP/nobin/tmux"; chmod +x "$TMP/nobin/tmux"
RC=0; OUT="$(PATH="$TMP/nobin:$PATH" "$WATCH")" || RC=$?
assert_eq "no session: no output, exit 0" "$OUT:$RC" ":0"

section "7 · Values cannot break the notice"
new_swarm
add_window coder-0001 $'Run `touch '"$TMP"$'/ran` $(touch '"$TMP"$'/ran)?\n❯ 1. Yes'
"$WATCH" > /dev/null
if [[ -e "$TMP/ran" ]]; then fail "the pane text was executed"; else ok "the pane text was not executed"; fi

echo ""
if (( FAILS > 0 )); then echo "$FAILS failure(s)" >&2; exit 1; fi
echo "all passed"
