#!/usr/bin/env bash
# Tests scripts/artifact-ledger.sh with no tmux, no AI, no swarm: just files.
# Covers recording, idempotence, listing order, path forms, the one-second mtime
# edge that find -newer misses, and replay after a crash before `mark`.
#
# Usage: scripts/test-artifact-ledger.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LEDGER_SH="$SCRIPTS_DIR/artifact-ledger.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

export CONDUCTOR_DIR="$TMP/.conductor"
WORK="$CONDUCTOR_DIR/work"
mkdir -p "$WORK/task-001" "$WORK/task-002" "$WORK/task-003"
unprocessed() { "$LEDGER_SH" unprocessed; }

section "1 · Nothing recorded yet"
assert_eq "empty work dir lists nothing" "$(unprocessed)" ""
echo x > "$WORK/task-001/signal-20261031-170000.md"
assert_eq "new artifact is unprocessed" "$(unprocessed)" "task-001/signal-20261031-170000.md"
if "$LEDGER_SH" check "$WORK/task-001/signal-20261031-170000.md"; then
  fail "check says yes for an unrecorded artifact"; else ok "check says no for an unrecorded artifact"; fi

section "2 · mark and check"
"$LEDGER_SH" mark "$WORK/task-001/signal-20261031-170000.md"
assert_eq "marked artifact leaves the list" "$(unprocessed)" ""
if "$LEDGER_SH" check "$WORK/task-001/signal-20261031-170000.md"; then
  ok "check says yes after mark"; else fail "check says no after mark"; fi

section "3 · Repeated marks are harmless"
"$LEDGER_SH" mark "$WORK/task-001/signal-20261031-170000.md"
"$LEDGER_SH" mark "$WORK/task-001/signal-20261031-170000.md"
assert_eq "artifact still processed after three marks" "$(unprocessed)" ""
if "$LEDGER_SH" check "$WORK/task-001/signal-20261031-170000.md"; then
  ok "check still says yes after repeated marks"; else fail "check broke after repeated marks"; fi

section "4 · Path forms"
echo x > "$WORK/task-002/review-20261031-170100.md"
(cd "$TMP" && "$LEDGER_SH" mark ".conductor/work/task-002/review-20261031-170100.md")
assert_eq "relative-to-cwd path accepted" "$(unprocessed)" ""
echo x > "$WORK/task-003/merge-20261031-170200.md"
"$LEDGER_SH" mark "task-003/merge-20261031-170200.md"
assert_eq "relative-to-work path accepted" "$(unprocessed)" ""
assert_eq "ledger stores work-relative paths" "$(grep -c '^task-002/review-20261031-170100.md$' "$CONDUCTOR_DIR/processed.log")" "1"
if "$LEDGER_SH" mark "$WORK/task-001/nope.md" 2>/dev/null; then
  fail "mark accepted a missing file"; else ok "mark rejects a missing file"; fi

section "5 · Order is by file name timestamp, not path or mtime"
# task-001 sorts first by path but its artifact is the newest by name; mtimes are
# deliberately reversed.
echo x > "$WORK/task-001/signal-20261031-180003.md"
echo x > "$WORK/task-002/signal-20261031-180001.md"
echo x > "$WORK/task-003/signal-20261031-180002.md"
touch -d '2026-01-01 00:00:03' "$WORK/task-002/signal-20261031-180001.md"
touch -d '2026-01-01 00:00:02' "$WORK/task-003/signal-20261031-180002.md"
touch -d '2026-01-01 00:00:01' "$WORK/task-001/signal-20261031-180003.md"
assert_eq "oldest name first" "$(unprocessed | tr '\n' ' ')" \
  "task-002/signal-20261031-180001.md task-003/signal-20261031-180002.md task-001/signal-20261031-180003.md "

section "6 · Same-second mtime: find -newer skips a file the ledger still lists"
CURSOR="$CONDUCTOR_DIR/last-poll"
A="$WORK/task-001/signal-20261031-190000.md"
B="$WORK/task-002/signal-20261031-190000.md"
echo x > "$A"; echo x > "$B"
touch -d '2026-01-01 00:00:10' "$A" "$B"
touch -r "$A" "$CURSOR"   # cursor advanced to A's mtime after handling A
"$LEDGER_SH" mark "$A"
NEWER="$(find "$WORK" -name '*.md' -newer "$CURSOR" | grep -c 'task-002/signal-20261031-190000' || true)"
# unprocessed does not consult the cursor; this shows the ledger reads the stream
# without the edge, not how a loop would combine the two.
assert_eq "find -newer misses B (same mtime as the cursor)" "$NEWER" "0"
if unprocessed | grep -qx 'task-002/signal-20261031-190000.md'; then
  ok "ledger still lists B"; else fail "ledger lost B"; fi

section "7 · Replay after a crash before mark"
C="$WORK/task-003/validation-20261031-200000.md"
echo x > "$C"
# handler ran, process died before `mark`: nothing recorded
assert_eq "C is still unprocessed after the crash" \
  "$(unprocessed | grep -c 'validation-20261031-200000' || true)" "1"
"$LEDGER_SH" mark "$C"
assert_eq "C is gone after mark" \
  "$(unprocessed | grep -c 'validation-20261031-200000' || true)" "0"

section "8 · Ledger is separate from last-poll"
BEFORE="$(stat -c '%Y' "$CURSOR" 2>/dev/null || stat -f '%m' "$CURSOR")"
"$LEDGER_SH" mark "$B"
AFTER="$(stat -c '%Y' "$CURSOR" 2>/dev/null || stat -f '%m' "$CURSOR")"
assert_eq "mark leaves last-poll untouched" "$AFTER" "$BEFORE"

section "9 · Usage errors"
if "$LEDGER_SH" bogus 2>/dev/null; then fail "unknown command accepted"; else ok "unknown command rejected"; fi
if "$LEDGER_SH" mark 2>/dev/null; then fail "mark without a path accepted"; else ok "mark without a path rejected"; fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
