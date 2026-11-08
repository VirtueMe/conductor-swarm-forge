#!/usr/bin/env bash
# Guards what the validator skill says about a task with no tests (#185). The skill is prose for a
# model, so this can only check that the rules are written down, not that a model follows them; it
# exists because the rule was once the opposite (report "no tests ran" as a failure), which sent a
# task round the rework loop for hours when its tests were a later task.
#
# Usage: scripts/test-validator-skill.sh

set -euo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/validator/validate.md"

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
has()  { if grep -qF -- "$1" "$SKILL"; then ok "$2"; else fail "$2 (missing: $1)"; fi; }
lacks() { if grep -qF -- "$1" "$SKILL"; then fail "$2 (still has: $1)"; else ok "$2"; fi; }

has 'There are no test files here at all' "no test files at all is a case of its own"
has 'nothing was validated' "and it passes with a note that says nothing ran"
has 'report it as **passed**' "...as passed, not failed"
has 'There are test files, but none ran' "test files that did not run are the other case"
has 'real fault' "...and that one is still a failure"
has 'only in your own working directory' "the check stays in the validator's own directory"
lacks 'report it as a failure in step 3 with exactly that as the note' "the old rule (no tests = failure) is gone"

echo ""
if (( FAILS > 0 )); then echo "$FAILS failure(s)" >&2; exit 1; fi
echo "all passed"
