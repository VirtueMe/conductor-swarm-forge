#!/usr/bin/env bash
# Tests the prompt an adapter_dispatch builds, and how a HANDLER-FAILED answer is read.
#
# Usage: scripts/test-dispatch-prompt.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
# shellcheck source=scripts/dispatch-prompt.sh
source "$SCRIPTS_DIR/dispatch-prompt.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR/prompts"
cp "$ROOT_DIR/prompts/conductor.prompt" "$CONDUCTOR_DIR/prompts/"
export TASK_ID=0007

echo "── the prompt"
P="$(dispatch_prompt "# Skill: Example
1. do the thing" "/x/work/0007/review-1.md")"
# has <pattern> <message>: pass if the pattern is in the prompt
has() { if printf '%s\n' "$P" | grep -q -- "$1"; then ok "$2"; else fail "$2"; fi; }
assert_eq "starts with the static briefing" "$(printf '%s\n' "$P" | head -1)" "$(head -1 "$CONDUCTOR_DIR/prompts/conductor.prompt")"
L_BRIEF="$(printf '%s\n' "$P" | grep -n '^## Scripts API' | head -1 | cut -d: -f1)"
L_RULES="$(printf '%s\n' "$P" | grep -n '^## This is one dispatched event' | cut -d: -f1)"
L_SKILL="$(printf '%s\n' "$P" | grep -n '^## Skill to run' | cut -d: -f1)"
L_EVENT="$(printf '%s\n' "$P" | grep -n '^## The event' | cut -d: -f1)"
if [[ "$L_BRIEF" -lt "$L_RULES" && "$L_RULES" -lt "$L_SKILL" && "$L_SKILL" -lt "$L_EVENT" ]]; then
  ok "order: briefing, rules, skill, event (the static part first)"
else
  fail "order: $L_BRIEF $L_RULES $L_SKILL $L_EVENT"
fi
has '^1. do the thing' "the skill text is included"
has 'Artifact: /x/work/0007/review-1.md' "the artifact is named"
has "^$DISPATCH_FAILED_MARKER" "the failure line is spelled out"
has 'Ignore the Startup and' "the interactive sections are ruled out"
has 'Watch loop sections' "by the names the prompt uses"

echo "── the startup reconcile has no artifact or task"
P="$(TASK_ID='' dispatch_prompt "# Skill: Reconcile" "startup")"
has 'Startup reconcile. There is no artifact and no task.' "the event says so"
if printf '%s\n' "$P" | grep -q 'Artifact:'; then fail "an artifact line for the reconcile"; else ok "no artifact line"; fi
if printf '%s\n' "$P" | grep -q 'TASK_ID, TASK_FILE and ARTIFACT'; then fail "it claims per-event variables"; else ok "and does not claim per-event variables"; fi
has 'CONDUCTOR_DIR is set' "it names only what is set"

echo "── a missing briefing"
if (CONDUCTOR_DIR="$TMP/none" dispatch_prompt "s" "a" > /dev/null 2>&1); then
  fail "built a prompt without a briefing"
else
  ok "returns 1"
fi

echo "── reading the answer"
if dispatch_final_exit "Moved the card to merging."; then ok "a normal answer passes"; else fail "normal answer failed"; fi
if dispatch_final_exit "task-locks.sh failed.
HANDLER-FAILED: task-locks.sh exited 1"; then fail "the marker on the last line passed"; else ok "the marker on the last line fails"; fi
if dispatch_final_exit "HANDLER-FAILED: x

"; then fail "trailing blank lines hid the marker"; else ok "trailing blank lines are ignored"; fi
if dispatch_final_exit "HANDLER-FAILED: x
Then I carried on anyway."; then ok "a marker that is not last does not count"; else fail "a mid-answer marker failed the dispatch"; fi
if dispatch_final_exit ""; then ok "an empty answer passes (the exit code decides)"; else fail "empty answer failed"; fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
