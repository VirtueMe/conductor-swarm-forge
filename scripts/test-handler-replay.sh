#!/usr/bin/env bash
# Tests the replay gate (scripts/handler-replay.sh): it must pass a handler that does what the
# fixture expects and fail one that does not. The handlers here are throwaway scripts written
# for the test (a right one and several wrong ones); the fixtures are the real ones in
# tests/handler-replay/. The gate runs a handler against a scratch copy of the fixture with
# worker-spawn.sh, task-notify.sh, task-locks.sh and tmux stubbed, so there is no model and no
# tmux server.
#
# Usage: scripts/test-handler-replay.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
GATE="$SCRIPTS_DIR/handler-replay.sh"
FIX="$ROOT_DIR/tests/handler-replay"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

H="$TMP/handlers"; mkdir -p "$H"
gate() { # <fixture> -> sets RC and OUT
  RC=0; OUT="$("$GATE" "$FIX/$1" --handlers-dir "$H" 2>&1)" || RC=$?
}
handler() { # <name>: the handler script is read from stdin
  cat > "$H/$1.sh"; chmod +x "$H/$1.sh"
}

# A handler that does what on-review-approved does, on the shared steps.
reference() {
  handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPTS_DIR/handler-steps.sh"
close_worker_window "$TASK_ID"
guard="$(locks_guard "$TASK_ID")"
route_task "$TASK_ID" review-approved "locks=$guard"
S
}

section "1 · A handler that does what the fixture expects passes"
reference
gate review-approved-locks-free
assert_eq "locks free: exit 0" "$RC" "0"
gate review-approved-locks-held
assert_eq "locks held: exit 0" "$RC" "0"

section "2 · A wrong destination fails"
handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPTS_DIR/handler-steps.sh"
route_task "$TASK_ID" review-approved locks=free      # ignores the lock check
S
gate review-approved-locks-free
assert_eq "right where the guard allows it" "$RC" "0"
gate review-approved-locks-held
assert_eq "wrong when the files are locked: exit 1" "$RC" "1"
if grep -q 'merge-pending' <<< "$OUT" && grep -q 'merging' <<< "$OUT"; then ok "and the difference names both stages"; else fail "and the difference names both stages ($OUT)"; fi

section "3 · A missing spawn fails"
handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
task-move.sh "$TASK_ID" merging                       # moves it, never starts the stage
S
gate review-approved-locks-free
assert_eq "exit 1" "$RC" "1"
if grep -q 'spawn 0001 merger' <<< "$OUT"; then ok "and the difference shows the spawn that did not happen"; else fail "and the difference shows the missing spawn ($OUT)"; fi

section "4 · An extra spawn fails"
handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPTS_DIR/handler-steps.sh"
guard="$(locks_guard "$TASK_ID")"
route_task "$TASK_ID" review-approved "locks=$guard"
stage-start.sh "$TASK_ID" merging                     # starts it a second time
S
gate review-approved-locks-free
assert_eq "exit 1" "$RC" "1"

section "5 · A handler that fails is a failure, with its message"
handler on-review-approved << 'S'
#!/usr/bin/env bash
echo "no lock check" >&2
exit 1
S
gate review-approved-locks-free
assert_eq "exit 1" "$RC" "1"
if grep -q 'no lock check' <<< "$OUT"; then ok "and the handler's own message is shown"; else fail "and the handler's message is shown ($OUT)"; fi

section "6 · No script handler is reported as such"
rm -f "$H"/*.sh
gate review-approved-locks-free
assert_eq "exit 3" "$RC" "3"
if grep -q 'on-review-approved' <<< "$OUT"; then ok "and the missing script is named"; else fail "and the missing script is named ($OUT)"; fi

section "7 · The fixture is never modified"
reference
before="$(cd "$FIX" && find . -type f -print0 | sort -z | xargs -0 cksum)"
gate review-approved-locks-free
gate review-approved-locks-held
after="$(cd "$FIX" && find . -type f -print0 | sort -z | xargs -0 cksum)"
assert_eq "same files, same contents" "$after" "$before"

section "8 · A bad fixture is a usage error"
RC=0; OUT="$("$GATE" "$TMP/nope" --handlers-dir "$H" 2>&1)" || RC=$?
assert_eq "exit 2" "$RC" "2"

section "9 · No handlers directory at all is 'no script handler', not a bad fixture"
RC=0; OUT="$("$GATE" "$FIX/review-approved-locks-free" --handlers-dir "$TMP/none" 2>&1)" || RC=$?
assert_eq "exit 3" "$RC" "3"
if grep -q "$TMP/none" <<< "$OUT"; then ok "and the path is named"; else fail "and the path is named ($OUT)"; fi

section "10 · A manual stage is notified, not spawned"
reference
gate review-approved-manual-merge
assert_eq "the right handler passes: exit 0" "$RC" "0"
handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
task-move.sh "$TASK_ID" merging                       # moves it, never tells the human
S
gate review-approved-manual-merge
assert_eq "no notification fails: exit 1" "$RC" "1"
if grep -q 'notify 0001 merging' <<< "$OUT"; then ok "and the difference shows the missing notification"; else fail "and the difference shows the missing notification ($OUT)"; fi

section "11 · The loop and the gate find a handler the same way"
# shellcheck source=scripts/handler-resolve.sh
source "$SCRIPTS_DIR/handler-resolve.sh"
assert_eq "a skill name maps to its script" "$(handler_script /h conductor/on-review-approved)" "/h/on-review-approved.sh"
assert_eq "the directory part of the skill name is dropped" "$(handler_script /h a/b/on-x)" "/h/on-x.sh"
if grep -q 'handler-resolve.sh' "$SCRIPTS_DIR/conductor-loop.sh" && grep -q 'handler-resolve.sh' "$GATE"; then
  ok "both scripts use it"
else
  fail "both scripts use it"
fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
