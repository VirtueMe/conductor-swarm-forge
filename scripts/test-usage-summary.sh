#!/usr/bin/env bash
# shellcheck disable=SC2016  # the dollar signs in the patterns below are regular-expression text
# Tests scripts/usage-summary.sh against a hand-written usage log: the totals, the split by
# harness, handler and task, the share spent on attempts that did not finish, and above all
# that an attempt with no cost is counted as unknown and never as free.
#
# Usage: scripts/test-usage-summary.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SUMMARY="$SCRIPTS_DIR/usage-summary.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
has() { if grep -q -- "$1" "$OUT"; then ok "$2"; else fail "$2 (in output: $(tr '\n' '|' < "$OUT" | cut -c1-500))"; fi; }
lacks() { if grep -q -- "$1" "$OUT"; then fail "$2"; else ok "$2"; fi; }

LOG="$TMP/usage.jsonl"
line() { # ts event task handler attempt outcome rc harness cost in out cr cw usage
  jq -nc --arg ts "$1" --arg event "$2" --arg task "$3" --arg handler "$4" --argjson attempt "$5" \
    --arg outcome "$6" --argjson rc "$7" --arg harness "$8" --argjson cost "$9" --argjson in "${10}" \
    --argjson out "${11}" --argjson cr "${12}" --argjson cw "${13}" --arg usage "${14}" '
    { ts: $ts, event: $event, task: (if $task == "" then null else $task end), handler: $handler,
      attempt: $attempt, outcome: $outcome, rc: $rc, duration_s: 10, harness: $harness, model: null,
      input_tokens: $in, output_tokens: $out, cache_read_tokens: $cr, cache_write_tokens: $cw,
      cost_usd: $cost, turns: 3, usage: $usage }'
}
{
  line 2026-11-01T10:00:00Z startup ""   conductor/reconcile            1 finished 0   claude-code 0.1945 20 2806 72785 8783 reported
  line 2026-11-01T10:05:00Z 0001/signal-1.md 0001 conductor/on-signal-complete 1 failed   1   claude-code 0.09   8  300   20000 7000 reported
  line 2026-11-01T10:05:20Z 0001/signal-1.md 0001 conductor/on-signal-complete 2 finished 0   claude-code 0.05   8  310   20000 0    reported
  line 2026-11-01T11:00:00Z 0002/review-1.md 0002 conductor/on-review-approved 1 finished 0   codex       null   5810 344 80000 0    reported
  line 2026-11-01T11:10:00Z 0002/merge-1.md  0002 conductor/on-merge-success   1 timeout  124 codex       null   null null null null none
  echo 'this line is not json'
} > "$LOG"
OUT="$TMP/out"
run() { RC=0; "$SUMMARY" "$@" > "$OUT" 2> "$TMP/err" || RC=$?; }

section "1 · The totals"
run --file "$LOG"
assert_eq "exit 0" "$RC" "0"
has 'Period    : 2026-11-01T10:00:00Z  to  2026-11-01T11:10:00Z   (5 attempts, 4 events)' "period, attempts and events (the broken line is skipped)"
has 'Known cost: \$0.3345 over 3 attempts with a cost' "known cost adds only the attempts that have one"
has 'Unknown   : 2 attempts reported no cost' "attempts with no cost are counted as unknown"
has 'Tokens    : in 5846, out 3760, cache read 192785, cache write 15783' "tokens"
has 'Unfinished: \$0.0900 over 2 attempts that did not finish (1 of them with no cost)' "spend on attempts that did not finish"
has 'The known cost is a floor' "and it says the known cost is a floor"

section "2 · By harness"
run --file "$LOG"
has '^claude-code  *3  *\$0.3345  *0 ' "claude-code: three attempts, all with a cost"
has '^codex  *2  *\$0.0000  *2 ' "codex: its attempts are shown as unknown, not hidden behind a zero"

section "3 · By handler and by task"
has '^conductor/reconcile  *1  *\$0.1945' "the reconcile is a handler like the others"
has '^conductor/on-signal-complete  *2  *\$0.1400' "a retried event's attempts add up"
has '^(no task)  *1  *\$0.1945' "the reconcile has no task"
has '^0001  *2  *\$0.1400' "task 0001"
has '^0002  *2  *\$0.0000  *2' "task 0002: unknown, twice"
first="$(grep -E '^conductor/' "$OUT" | head -1 | cut -d' ' -f1)"
assert_eq "the most expensive handler comes first" "$first" "conductor/reconcile"

section "4 · --since"
run --file "$LOG" --since 2026-11-01T11
has '(2 attempts, 2 events)' "only the later attempts"
has '(since 2026-11-01T11)' "says what it is filtered by"
lacks 'conductor/reconcile' "the earlier handler is gone"
run --file "$LOG" --since 2027-01-01
has 'No usage lines since 2027-01-01' "a filter that matches nothing says so"

section "5 · No log"
run --file "$TMP/none.jsonl"
assert_eq "exit 0" "$RC" "0"
has 'No usage recorded yet' "says there is nothing yet"
: > "$TMP/empty.jsonl"
run --file "$TMP/empty.jsonl"
has 'No usage recorded yet' "an empty file is the same"
mkdir -p "$TMP/c"
cp "$LOG" "$TMP/c/usage.jsonl"
RC=0; CONDUCTOR_DIR="$TMP/c" "$SUMMARY" > "$OUT" 2>&1 || RC=$?
has '5 attempts' "the default is \$CONDUCTOR_DIR/usage.jsonl"

section "6 · Arguments"
run --bogus
assert_eq "an unknown flag: exit 1" "$RC" "1"
run --help
assert_eq "--help: exit 0" "$RC" "0"
has 'Summarise the headless conductor' "and it prints the description"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
