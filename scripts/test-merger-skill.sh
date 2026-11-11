#!/usr/bin/env bash
# Tests that the merger skill runs the stamping rebase and tells its outcomes apart (#130): it is text a
# model follows, so the check is that the text says the right command and handles each exit.
#
# Usage: scripts/test-merger-skill.sh

# The patterns below are regular expressions for grep, so they hold $ in single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
SKILL="$ROOT_DIR/skills/merger/merge.md"

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
has()   { if grep -qE -- "$1" "$SKILL"; then ok "$2"; else fail "$2"; fi; }
lacks() { if grep -qE -- "$1" "$SKILL"; then fail "$2"; else ok "$2"; fi; }

echo "── the rebase is the stamping one"
has   'attribution-rebase\.sh "\$BASE_SHA" --task \$TASK_ID' "step 2 runs attribution-rebase.sh with the base and the task"
lacks '^[[:space:]]*git rebase "\$BASE_SHA"' "and no longer runs a plain git rebase on the base"
has   'BASE_SHA=\$\(git rev-parse' "BASE_SHA is still taken first"

# The text of step 2, from its number to step 3's; and the text of one bullet in it, from the line that has
# $1 to the line before the next bullet. Checks inside these say which outcome goes with which action,
# which a match anywhere in the file would not.
step2() { awk '/^2\. /{f=1} /^3\. /{f=0} f' "$SKILL"; }
bullet() { step2 | awk -v pat="$1" 'index($0, pat) {f=1; print; next} /^   - \*\*/ {f=0} f'; }
in_bullet()     { if bullet "$1" | grep -qE -- "$2"; then ok "$3"; else fail "$3"; fi; }
not_in_bullet() { if bullet "$1" | grep -qE -- "$2"; then fail "$3"; else ok "$3"; fi; }

echo "── each outcome of that command goes with its own action"
in_bullet     '**0**' 'step 3' "0: go on to step 3"
in_bullet     '**4**' '--outcome blocked' "4: signalled as blocked"
not_in_bullet '**4**' '--outcome conflict|git rebase --abort' "4: not a conflict, nothing to abort"
in_bullet     '**anything else**' 'rebase is in progress' "anything else: looks at whether a rebase is in progress"
in_bullet     '**anything else**' 'step 4' "a rebase in progress is a conflict: step 4"
in_bullet     '**anything else**' 'signal blocked' "none in progress: blocked, as for 4"
in_bullet     '**anything else**' 'git.s message|stderr message' "with git's message in the notes"
if step2 | grep -q 'git rev-parse --git-path rebase-merge'; then ok "the probe is spelled out"; else fail "the probe is spelled out"; fi
has   'git rebase --abort' "step 4 still aborts a conflict"
has   '--outcome conflict' "and still signals it as a conflict"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
