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

# --- record mode -----------------------------------------------------------------
# Recording runs the SKILL through the real conductor-loop.sh, in the gate's scratch setup, and
# writes `expect` from what it did. Here the adapter is a stub that makes known moves, so no model
# is called; the live run is the user's.
STUB_ADAPTER="$TMP/stub-adapter.sh"
cat > "$STUB_ADAPTER" << 'S'
adapter_dispatch() {
  local skill="$1" event="$2"
  if [[ "$event" == startup ]]; then echo startup >> "$STUB_STARTUPS"; return 0; fi
  { echo "event $(basename "$event")"; printf '%s\n' "$skill" | head -1; } >> "$STUB_EVENTS"
  pwd >> "$STUB_PWDS"
  cat "$CONDUCTOR_DIR/config.md" >> "$STUB_CONFIGS" 2> /dev/null || true
  [[ -n "${STUB_FAIL:-}" ]] && return 1
  [[ -n "${STUB_NOOP:-}" ]] && return 0
  task-move.sh "$TASK_ID" merging
  stage-start.sh "$TASK_ID" merging
}
S
export STUB_STARTUPS="$TMP/startups" STUB_EVENTS="$TMP/events" STUB_PWDS="$TMP/pwds" STUB_CONFIGS="$TMP/configs"
record() { # <fixture dir> [more args] -> sets RC and OUT
  local dir="$1"; shift
  : > "$STUB_STARTUPS"; : > "$STUB_EVENTS"; : > "$STUB_PWDS"; : > "$STUB_CONFIGS"
  RC=0; OUT="$("$GATE" --record "$dir" --adapter-file "$STUB_ADAPTER" "$@" 2>&1)" || RC=$?
}
fresh_fixture() { # <name>: a copy of the locks-free fixture with no expect
  rm -rf "${TMP:?}/${1:?}"; cp -r "$FIX/review-approved-locks-free" "$TMP/$1"; rm -f "$TMP/$1/expect"
}

section "12 · Recording writes expect from what the skill did"
fresh_fixture rec1
record "$TMP/rec1"
assert_eq "exit 0" "$RC" "0"
assert_eq "expect is written from the moves, the spawn and the stage" "$(cat "$TMP/rec1/expect" 2>/dev/null)" "$(printf 'move 0001 merging\nspawn 0001 merger\nstage 0001 merging')"
assert_eq "the event was dispatched once" "$(grep -c '^event ' "$STUB_EVENTS" || true)" "1"
assert_eq "it was the fixture's event" "$(sed -n 1p "$STUB_EVENTS")" "event review-20261102-102000.md"
assert_eq "the skill went to the model" "$(sed -n 2p "$STUB_EVENTS")" "# Skill: On Review Approved"
assert_eq "the startup reconcile was not run" "$(wc -l < "$STUB_STARTUPS" | tr -d ' ')" "0"

section "13 · A recorded expect is what the gate then checks"
reference
RC=0; OUT="$("$GATE" "$TMP/rec1" --handlers-dir "$H" 2>&1)" || RC=$?
assert_eq "the right handler passes against it" "$RC" "0"

section "14 · Recording never replaces an expect unless asked"
printf 'move 0001 elsewhere\n' > "$TMP/rec1/expect"
record "$TMP/rec1"
assert_eq "exit 2" "$RC" "2"
assert_eq "expect is as it was" "$(cat "$TMP/rec1/expect")" "move 0001 elsewhere"
assert_eq "and the skill was not run" "$(grep -c '^event ' "$STUB_EVENTS" || true)" "0"
record "$TMP/rec1" --force
assert_eq "--force: exit 0" "$RC" "0"
assert_eq "--force: expect is replaced" "$(head -1 "$TMP/rec1/expect")" "move 0001 merging"

section "15 · A failed skill records nothing"
fresh_fixture rec2
STUB_FAIL=1 record "$TMP/rec2"
assert_eq "exit 1" "$RC" "1"
assert_eq "no expect is written" "$([[ -e "$TMP/rec2/expect" ]] && echo yes || echo no)" "no"

section "16 · Recording runs the skill even when a script handler exists"
fresh_fixture rec3
MARK="$TMP/script-ran"; rm -f "$MARK"; export MARK
handler on-review-approved << 'S'
#!/usr/bin/env bash
echo ran >> "$MARK"
S
record "$TMP/rec3" --handlers-dir "$H"
assert_eq "exit 0" "$RC" "0"
assert_eq "the script handler did not run" "$([[ -e "$MARK" ]] && echo yes || echo no)" "no"
assert_eq "the skill did" "$(grep -c '^event ' "$STUB_EVENTS" || true)" "1"

section "17 · Recording does not modify the rest of the fixture"
fresh_fixture rec4
before="$(cd "$TMP/rec4" && find . -type f -print0 | sort -z | xargs -0 cksum)"
record "$TMP/rec4"
after="$(cd "$TMP/rec4" && find . -type f ! -name expect -print0 | sort -z | xargs -0 cksum)"
assert_eq "everything but expect is untouched" "$after" "$before"

section "18 · The recorded skill does not run in the caller's directory"
fresh_fixture rec5
record "$TMP/rec5"
assert_eq "exit 0" "$RC" "0"
ran_in="$(head -1 "$STUB_PWDS")"
if [[ -n "$ran_in" && "$ran_in" != "$PWD" ]]; then ok "it ran somewhere else than $PWD"; else fail "it ran in the caller's directory ($ran_in)"; fi
if [[ "$ran_in" == "${TMPDIR:-/tmp}"/* || "$ran_in" == /tmp/* ]]; then ok "in a scratch directory"; else fail "in a scratch directory ($ran_in)"; fi

section "19 · A run that changed nothing is not recorded"
fresh_fixture rec6
STUB_NOOP=1 record "$TMP/rec6"
assert_eq "exit 1" "$RC" "1"
assert_eq "no expect is written" "$([[ -e "$TMP/rec6/expect" ]] && echo yes || echo no)" "no"
if grep -q 'no move' <<< "$OUT"; then ok "and it says why"; else fail "and it says why ($OUT)"; fi
STUB_NOOP=1 record "$TMP/rec6" --allow-empty
assert_eq "--allow-empty: exit 0" "$RC" "0"
assert_eq "--allow-empty: records just where the card is" "$(cat "$TMP/rec6/expect")" "stage 0001 review"

section "20 · Recording says what it may cost"
fresh_fixture rec7
record "$TMP/rec7"
if grep -qF "up to \$1" <<< "$OUT"; then ok "the default cap is shown"; else fail "the default cap is shown ($OUT)"; fi
fresh_fixture rec8
CONDUCTOR_MAX_BUDGET_USD=0.25 record "$TMP/rec8"
if grep -qF "up to \$0.25" <<< "$OUT"; then ok "and so is a set one"; else fail "and so is a set one ($OUT)"; fi

section "21 · A fixture can carry the project config"
# A handler may read config.md (on-signal-complete reads test-cmd), so a fixture can supply one.
handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPTS_DIR/handler-steps.sh"
[[ "$(config_field test-cmd)" == "make check" ]] || exit 0     # acts only when test-cmd is set
close_worker_window "$TASK_ID"
route_task "$TASK_ID" review-approved locks=free
S
rm -rf "$TMP/cfg1"; cp -r "$FIX/review-approved-locks-free" "$TMP/cfg1"
printf 'lang: bash\ntest-cmd: make check\n' > "$TMP/cfg1/config.md"
RC=0; OUT="$("$GATE" "$TMP/cfg1" --handlers-dir "$H" 2>&1)" || RC=$?
assert_eq "with the fixture's config.md the handler sees test-cmd: exit 0" "$RC" "0"
rm "$TMP/cfg1/config.md"
RC=0; OUT="$("$GATE" "$TMP/cfg1" --handlers-dir "$H" 2>&1)" || RC=$?
assert_eq "without one it sees nothing configured: exit 1" "$RC" "1"
fresh_fixture rec9
printf 'lang: bash\ntest-cmd: make check\n' > "$TMP/rec9/config.md"
record "$TMP/rec9"
if grep -qx 'test-cmd: make check' "$STUB_CONFIGS"; then ok "recording runs the skill with the fixture's config.md"; else fail "recording runs the skill with the fixture's config.md ($(cat "$STUB_CONFIGS"))"; fi
fresh_fixture rec10
record "$TMP/rec10"
if grep -qx 'poll-interval: 1' "$STUB_CONFIGS" && ! grep -q 'test-cmd' "$STUB_CONFIGS"; then ok "and with the default config when the fixture has none"; else fail "and with the default config when the fixture has none ($(cat "$STUB_CONFIGS"))"; fi

section "22 · The stubbed locks follow the board, and a shutdown is recorded"
# task-locks.sh answers from the fixture's `locks` and from the cards in merging, as the real one
# does, so a handler that releases several tasks sees the lock each release takes. A shutdown is
# a world-changing call like a spawn, so the gate logs it instead of closing windows.
handler on-review-approved << 'S'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPTS_DIR/handler-steps.sh"
route_task "$TASK_ID" review-approved locks=free
[[ "$(task-locks.sh)" == *src/a.txt* ]] || { echo "the task now merging holds no lock" >&2; exit 1; }
conductor-shutdown.sh
S
rm -rf "$TMP/sd1"; cp -r "$FIX/review-approved-locks-free" "$TMP/sd1"
printf 'move 0001 merging\nspawn 0001 merger\nshutdown\nstage 0001 merging\n' > "$TMP/sd1/expect"
RC=0; OUT="$("$GATE" "$TMP/sd1" --handlers-dir "$H" 2>&1)" || RC=$?
assert_eq "locks include the card now in merging, and the shutdown is logged: exit 0" "$RC" "0"
printf 'move 0001 merging\nspawn 0001 merger\nstage 0001 merging\n' > "$TMP/sd1/expect"
RC=0; OUT="$("$GATE" "$TMP/sd1" --handlers-dir "$H" 2>&1)" || RC=$?
assert_eq "an expect without the shutdown does not match: exit 1" "$RC" "1"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
