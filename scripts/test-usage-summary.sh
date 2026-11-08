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
has 'Known cost: \$0.3345 over 3 attempts with a reported cost' "known cost adds only the attempts that have one"
has 'Unknown   : 2 attempt(s) with neither' "attempts with no cost are counted as unknown"
has 'Tokens    : in 5846, out 3760, cache read 192785, cache write 15783' "tokens"
has 'Unfinished: \$0.0900 reported over 2 attempts that did not finish (1 of them with no cost)' "spend on attempts that did not finish"
has 'The known cost is a floor' "and it says the known cost is a floor"

section "2 · By harness"
run --file "$LOG"
has '^claude-code  *3  *\$0.3345  *\$0.0000  *0 ' "claude-code: three attempts, all with a cost"
has '^codex  *2  *\$0.0000  *\$0.0000  *2 ' "codex: its attempts are shown as unknown, not hidden behind a zero"

section "3 · By handler and by task"
has '^conductor/reconcile  *1  *\$0.1945' "the reconcile is a handler like the others"
has '^conductor/on-signal-complete  *2  *\$0.1400' "a retried event's attempts add up"
has '^(no task)  *1  *\$0.1945' "the reconcile has no task"
has '^0001  *2  *\$0.1400' "task 0001"
has '^0002  *2  *\$0.0000  *\$0.0000  *2' "task 0002: unknown, twice"
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

section "5b · Lines with role and cost_source read the same as lines without"
# Every line gets the two fields (role "conductor", cost_source from whether a cost was reported),
# or only every other one does: the totals must not move, since the summary still goes by cost_usd.
add_fields='. + {role: "conductor", cost_source: (if .cost_usd != null then "reported" else "unknown" end)}'
# the log has one line that is not JSON; it is dropped here, as the summary does
jq -Rc 'fromjson? // empty' "$LOG" > "$TMP/old.jsonl"
jq -c "$add_fields" "$TMP/old.jsonl" > "$TMP/new.jsonl"
awk 'NR % 2' "$TMP/old.jsonl" > "$TMP/mixed.jsonl"
jq -c "$add_fields" <(awk 'NR % 2 == 0' "$TMP/old.jsonl") >> "$TMP/mixed.jsonl"
for variant in new mixed; do
  run --file "$TMP/$variant.jsonl"
  has 'Known cost: \$0.3345 over 3 attempts with a reported cost' "$variant: the same known cost"
  has 'Unknown   : 2 attempt(s) with neither' "$variant: the same unknown count"
  has 'Tokens    : in 5846, out 3760, cache read 192785, cache write 15783' "$variant: the same tokens"
done

section "5c · By role and by model, with reported and estimated cost apart"
# Three roles, two models, three harnesses. Reported cost is what a harness charged; estimated
# is the price table's figure on a line with no reported cost; unknown has neither.
RL="$TMP/roles.jsonl"
rline() { # role harness model cost estimate outcome
  jq -nc --arg role "$1" --arg harness "$2" --arg model "$3" --argjson cost "$4" --argjson est "$5" --arg outcome "$6" '
    { ts: "2026-11-02T10:00:00Z", event: "0001/x.md", task: "0001", handler: "h", role: $role, attempt: 1,
      outcome: $outcome, rc: 0, duration_s: 5, harness: $harness, model: (if $model == "" then null else $model end),
      input_tokens: 100, output_tokens: 10, cache_read_tokens: 1000, cache_write_tokens: 0,
      cost_usd: $cost, estimated_cost_usd: $est, turns: 2, usage: "reported",
      cost_source: (if $cost != null then "reported" elif $est != null then "estimated" else "unknown" end) }'
}
{
  rline conductor claude-code opus   0.50 0.40 finished
  rline conductor claude-code opus   0.30 0.25 finished
  rline coder     claude-code sonnet 0.20 0.15 finished
  rline coder     codex       gpt-5  null 0.10 finished
  rline coder     codex       gpt-5  null 0.30 interrupted
  rline reviewer  codex       gpt-5  null 0.20 finished
  rline reviewer  codex       ""     null null timeout
  # an old line: no role, no estimate, no cost_source
  echo '{"ts":"2026-11-02T10:00:00Z","event":"0001/y.md","task":"0001","handler":"h","attempt":1,"outcome":"finished","rc":0,"duration_s":5,"harness":"claude-code","model":"opus","input_tokens":100,"output_tokens":10,"cache_read_tokens":1000,"cache_write_tokens":0,"cost_usd":0.10,"turns":2,"usage":"reported"}'
} > "$RL"
run --file "$RL"
has 'Known cost: \$1.1000 over 4 attempts with a reported cost' "reported cost is its own total"
has 'Estimated : \$0.6000 over 3 attempts with only an estimate' "and estimated cost is apart from it"
has 'Unknown   : 1 attempt(s) with neither' "unknown is the line with neither"
has '^By role' "a role section"
has '^conductor  *2  *\$0.8000  *\$0.0000  *0 ' "conductor: reported only"
has '^coder  *3  *\$0.2000  *\$0.4000  *0 ' "coder: a reported line and two estimated"
has '^reviewer  *2  *\$0.0000  *\$0.2000  *1 ' "reviewer: one estimated, one unknown"
has '^(no role)  *1  *\$0.1000  *\$0.0000  *0 ' "a line from before roles existed"
has '^By model' "a model section"
has '^opus  *3  *\$0.9000 ' "opus: two lines plus the old one"
has '^gpt-5  *3  *\$0.0000  *\$0.6000  *0 ' "gpt-5: no reported cost, all estimated"
has '^(no model)  *1  *\$0.0000  *\$0.0000  *1 ' "a line with no model is its own row, unknown"

section "5d · The cross-adapter view is on estimated cost, and unknown is not zero"
has '^Across harnesses' "the view is there"
has '^codex  *4  *\$0.6000  *3  *1  *\$0.2000$' "codex: four attempts, three priced, one not; the estimate over the priced ones"
has '^claude-code  *4  *\$0.8000  *3  *1  *\$0.2667$' "claude-code: the old line has no estimate and is counted unpriced"
has '2 of the 8 attempts have no estimate' "it says how many attempts are not in the estimate"

section "5e · --by picks the groupings"
run --file "$RL" --by role
has '^By role' "role is shown"
lacks '^By model' "model is not"
lacks '^By harness' "nor the others"
lacks '^Across harnesses' "nor the cross-adapter view"
run --file "$RL" --by model --by adapters
has '^By model' "--by repeats"
has '^Across harnesses' "and takes adapters"
run --file "$RL" --by nonsense
assert_eq "an unknown grouping: exit 1" "$RC" "1"

section "5f · Worker lines read with the existing groupings"
# What worker-usage.sh writes: a role and a task, but no handler, attempt or exit status.
WL="$TMP/workers.jsonl"
wline() { # role task harness model cost estimate outcome
  jq -nc --arg role "$1" --arg task "$2" --arg harness "$3" --arg model "$4" --argjson cost "$5" --argjson est "$6" --arg outcome "$7" '
    { ts: "2026-11-03T10:00:00Z", event: ($task + "/worker-" + $role), task: $task, handler: null, role: $role,
      attempt: null, outcome: $outcome, rc: null, duration_s: 600, harness: $harness, model: $model,
      input_tokens: 100, output_tokens: 10, cache_read_tokens: 1000, cache_write_tokens: 0,
      cost_usd: $cost, estimated_cost_usd: $est, turns: 3, usage: "reported",
      cost_source: (if $cost != null then "reported" elif $est != null then "estimated" else "unknown" end) }'
}
{
  wline coder    0001 claude-code claude-sonnet-4-6 0.40 0.30 finished
  wline reviewer 0001 pi          claude-opus-4-8   0.20 0.20 finished
  wline coder    0002 codex       gpt-5             null 0.10 interrupted
  # and one of the conductor's own, from the loop
  line 2026-11-03T10:00:00Z 0001/signal-1.md 0001 conductor/on-signal-complete 1 finished 0 claude-code 0.05 8 310 20000 0 reported | jq -c '. + {role: "conductor"}'
} > "$WL"
run --file "$WL"
assert_eq "exit 0" "$RC" "0"
has '^coder  *2  *\$0.4000  *\$0.1000  *0 ' "by role: the coder's two lines, one reported and one estimated"
has '^reviewer  *1  *\$0.2000  *\$0.0000  *0 ' "the reviewer"
has '^conductor  *1  *\$0.0500 ' "the conductor's own line is a role like the others"
has '^(no handler)  *3 ' "by handler: the worker lines have none"
has '^0001  *3 ' "by task: the worker lines belong to their task"
has '^Unfinished: .* 1 attempts that did not finish' "an interrupted worker counts as unfinished"
has '^claude-sonnet-4-6  *1 ' "by model"

section "5g · The Codex allowance is its own section, in percent of a window"
AL="$TMP/allowance.jsonl"
reading() { # ts snapshot used5 resets5 used7
  jq -nc --arg ts "$1" --arg snap "$2" --argjson u5 "$3" --argjson r5 "$4" --argjson u7 "$5" '
    { record: "allowance", pool: "subscription:openai", moment: "x", ts: $ts, snapshot_at: $snap, plan_type: "plus", codex_version: "0.166.0",
      five_hour: { state: "known", reason: null, window_minutes: 300, used_percent: $u5, opened_at: ($r5 - 18000), resets_at: $r5 },
      weekly:    { state: "known", reason: null, window_minutes: 10080, used_percent: $u7, opened_at: 1793454935, resets_at: 1794059735 } }'
}
arun() { # role p5 p7 attributed_to (points null when the run was part of a batch)
  jq -nc --arg role "$1" --argjson p5 "$2" --argjson p7 "$3" --arg to "$4" '
    { ts: "2026-11-04T05:30:00Z", event: "0001/worker-\($role)", task: "0001", handler: null, role: $role, attempt: null, outcome: "finished",
      rc: null, duration_s: 60, harness: "codex", model: "gpt-5", input_tokens: 100, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0,
      cost_usd: null, estimated_cost_usd: 0.01, turns: 1, usage: "reported",
      allowance: { pool: "subscription:openai", overlap: ($to == "batch"), attributed_to: $to,
                   five_hour: { points: $p5, reason: null }, weekly: { points: $p7, reason: null } } }'
}
{
  reading 2026-11-04T05:00:00Z 2026-11-04T05:00:00.000Z 10 1793800000 20
  arun coder 2 0.5 run
  arun coder 1.5 0 run
  arun conductor 1 0 run
  arun reviewer null null batch
  # a Claude Code line has no allowance
  line 2026-11-04T05:35:00Z 0001/x.md 0001 conductor/h 1 finished 0 claude-code 0.05 8 310 20000 0 reported
  reading 2026-11-04T05:40:00Z 2026-11-04T05:40:00.000Z 14.5 1793800003 21
} > "$AL"
run --file "$AL"
assert_eq "exit 0" "$RC" "0"
has '(5 attempts, ' "the two readings are not attempts"
has '^Codex allowance (subscription:openai), read 2026-11-04T05:40:00.000Z, plan plus, Codex 0.166.0' "the latest reading, with its plan and version"
has '^  5-hour  *14.5% used, resets 2026-11-04T13:46:43Z  (was 10% at 2026-11-04T05:00:00.000Z, first reading in this window)' "the five-hour window, and where it stood at the first reading in the same window"
has '^  weekly  *21% used, resets 2026-11-07T13:55:35Z  (was 20% at ' "the weekly window"
has '^  coder  *2  *+3.5  *+0.5  *0$' "by role: the coder's two runs, in percentage points"
has '^  conductor  *1  *+1  *+0 (<1)  *0$' "the conductor's own dispatch is a role like the others, and a measured zero is under one step"
has '^  reviewer  *1  *-  *-  *1 (1 in a batch)$' "a run in a batch is not attributed, shown as -, never as zero points"
has 'A +0 (<1) is under one step' "and the section explains both"
lacks 'claude-code.*+' "a line with no allowance is not in it"
has 'could not be attributed' "and the section says what not attributed means"
run --file "$AL" --by allowance
has '^Codex allowance' "--by allowance shows it"
lacks '^By role' "and only it"
run --file "$AL" --by role
lacks '^Codex allowance' "--by role does not"
jq -c 'select(.record == "allowance")' "$AL" > "$TMP/only-readings.jsonl"
run --file "$TMP/only-readings.jsonl"
has 'No usage lines' "a log of readings alone has no attempts to summarise"
has '^Codex allowance (subscription:openai), read 2026-11-04T05:40' "but still shows the allowance"
run --file "$LOG"
lacks 'Codex allowance' "a log with no Codex lines or readings has no such section"
jq -c 'del(.five_hour.resets_at) | .five_hour.state = "unknown" | .five_hour.used_percent = null | .five_hour.reason = "the window reset after the last reading"' <(reading 2026-11-04T06:00:00Z 2026-11-04T06:00:00.000Z 1 1793800000 21) > "$TMP/stale.jsonl"
run --file "$TMP/stale.jsonl"
has '^  5-hour  *unknown (the window reset after the last reading)' "an unknown window is shown as unknown, not as a percentage"

section "5g2 · The Claude allowance sits beside the Codex one, with a total of runs"
creading() { # ts used5 usedweek usedFable spent
  jq -nc --arg ts "$1" --argjson f "$2" --argjson w "$3" --argjson m "$4" --argjson spent "$5" '
    { record: "allowance", pool: "subscription:anthropic", moment: "x", ts: $ts, snapshot_at: $ts, source: "endpoint", age_seconds: 0, checked_version: "2.1.318",
      five_hour: { state: "known", reason: null, window_minutes: 300, used_percent: $f, opened_at: 1793851800, resets_at: 1793869800 },
      weekly:    { state: "known", reason: null, window_minutes: 10080, used_percent: $w, opened_at: 1793419200, resets_at: 1794024000 },
      weekly_by_model: { state: "known", reason: null, models: [ { model: "Fable", used_percent: $m, opened_at: 1793419200, resets_at: 1794024000 } ] },
      credits: { state: "known", reason: null, currency: "USD", used: $spent, limit: 100 } }'
}
crun() { # role p5 p7 pFable dollars attributed_to
  jq -nc --arg role "$1" --argjson p5 "$2" --argjson p7 "$3" --argjson pm "$4" --argjson d "$5" --arg to "$6" '
    { ts: "2026-11-05T08:30:00Z", event: "0002/worker-\($role)", task: "0002", handler: null, role: $role, attempt: null, outcome: "finished", rc: null,
      duration_s: 60, harness: "claude-code", model: "claude-opus-4-8", input_tokens: 100, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0,
      cost_usd: 0.05, turns: 1, usage: "reported",
      allowance: { pool: "subscription:anthropic", overlap: ($to == "batch"), attributed_to: $to,
                   five_hour: { points: $p5, reason: null }, weekly: { points: $p7, reason: null },
                   weekly_by_model: { reason: null, models: (if $pm == null then [] else [ { model: "Fable", points: $pm, reason: null } ] end) },
                   credits: { dollars: $d, reason: null } } }'
}
CL="$TMP/claude-allowance.jsonl"
{ creading 2026-11-05T08:00:00Z 10 20 0 0
  crun coder 2.5 0.5 2 0.25 run
  crun coder 1 0 0 0 run
  crun reviewer null null null null batch
  creading 2026-11-05T09:00:00Z 14 21 2 0.25; } > "$CL"
run --file "$CL"
assert_eq "exit 0" "$RC" "0"
lacks '^Allowance, all subscription pools' "one pool needs no total"
has '^Claude allowance (subscription:anthropic), read 2026-11-05T09:00:00Z, from endpoint' "the Claude block, with where the reading came from"
lacks '^Codex allowance' "and no Codex block when there is nothing from Codex"
has 'from endpoint, 2 of 2 readings live' "and how many readings were live"
# a swarm whose endpoint answered 429: the stale readings show instead of looking like a quiet run
{ head -1 "$CL"; tail -n +2 "$CL" | sed 's/"source":"endpoint"/"source":"cache"/'; } > "$TMP/stale.jsonl"
run --file "$TMP/stale.jsonl"
has 'from cache, [0-9]* h old, 1 of 2 readings live' "a mostly stale run says so"
has '^  5-hour  *14% used, resets 2026-11-05T09:10:00Z  (was 10% at 2026-11-05T08:00:00Z, first reading in this window)' "its windows, as for Codex"
has '^  Fable  *2% used' "the week per model"
has '^  credits  *\$0.25 of \$100.00 USD' "the credits, in dollars"
has '^  coder  *2  *+3.5  *+0.5  *+\$0.25  *0$' "by role: points, and the credits as dollars in a column of their own"
has '^  reviewer  *1  *-  *-  *-  *1 (1 in a batch)$' "a run in a batch is not attributed, in every column"
has '^  Fable  *2  *+2$' "points per model across the runs"
# both pools: a total of runs on top, points kept per pool
{ cat "$CL"; cat "$AL"; } > "$TMP/both.jsonl"
run --file "$TMP/both.jsonl"
has '^Allowance, all subscription pools: 7 runs metered' "with both pools a total of runs comes first"
has 'points are per pool, and are not added across pools' "and says points are not added across pools"
has '^  Codex (subscription:openai)  *4  *3  *1  *0$' "the Codex line of it: runs, attributed, in a batch, unknown"
has '^  Claude (subscription:anthropic)  *3  *2  *1  *0$' "and the Claude line"
has '^Codex allowance (subscription:openai), read ' "each pool keeps its own block"
has '^Claude allowance (subscription:anthropic), read ' "so does Claude"
has '^  coder  *2  *+3.5  *+0.5  *0$' "Codex points are not mixed with Claude's"
assert_eq "the total is one section, ahead of both blocks" "$(grep '^Allowance, all\|^Codex allowance\|^Claude allowance' "$OUT" | cut -c1-9 | tr '\n' ' ')" "Allowance Codex all Claude al "
run --file "$TMP/both.jsonl" --by role
lacks 'allowance' "--by role leaves the allowance out"
jq -c 'select(.record == "allowance" and .pool == "subscription:anthropic") | .weekly_by_model.state = "unknown" | .weekly_by_model.reason = "the weekly window is unknown" | .credits.state = "unknown" | .credits.reason = "extra usage is not enabled"' "$CL" > "$TMP/claude-unknown.jsonl"
run --file "$TMP/claude-unknown.jsonl"
has '^  per model  *unknown (the weekly window is unknown)' "a per-model figure that is unknown says so"
has '^  credits  *unknown (extra usage is not enabled)' "so do the credits"

section "5h · A run on another model than the one asked for"
cp "$AL" "$TMP/mismatch.jsonl"
mismatch() { jq -nc --arg req "$1" --arg ans "$2" '{ record: "model_mismatch", ts: "2026-11-04T05:31:00Z", role: "coder", task: "0001", event: "0001/worker-coder", harness: "codex", requested: $req, answered: $ans }'; }
{ mismatch gpt-5 gpt-6.1-sol; mismatch gpt-5 gpt-6.1-sol; mismatch gpt-6.1-sol gpt-5; } >> "$TMP/mismatch.jsonl"
run --file "$TMP/mismatch.jsonl"
has '(5 attempts, ' "a mismatch record is not an attempt"
has '^  Model asked for -> model that answered  *runs' "the section lists them"
has '^  gpt-5 -> gpt-6.1-sol  *2$' "by the pair of names, counted, the commonest first"
has '^  gpt-6.1-sol -> gpt-5  *1$' "and the other direction apart"
run --file "$TMP/mismatch.jsonl" --by role
lacks 'Model asked for' "--by role leaves them out"
{ mismatch gpt-5 gpt-6.1-sol; } > "$TMP/only-mismatch.jsonl"
run --file "$TMP/only-mismatch.jsonl"
has '^  gpt-5 -> gpt-6.1-sol  *1$' "a log of nothing but a mismatch still shows it"

section "5i · Pools: real and notional dollars are never added together"
# Two subscription lines (notional dollars), an API line with a reported cost, an API line with only an
# estimate, and an old line from before pools existed. One of the API lines was declared against a
# sign-in that disagreed, which is a record of its own.
PL="$TMP/pools.jsonl"
pline() { # harness pool billing cost estimate outcome
  jq -nc --arg harness "$1" --arg pool "$2" --arg billing "$3" --argjson cost "$4" --argjson est "$5" --arg outcome "$6" '
    { ts: "2026-11-02T10:00:00Z", event: "0001/x", task: "0001", handler: null, role: "coder", attempt: null, outcome: $outcome,
      rc: null, duration_s: 5, harness: $harness, model: null, input_tokens: 10, output_tokens: 5, cache_read_tokens: 0,
      cache_write_tokens: 0, cost_usd: $cost, estimated_cost_usd: $est, turns: 1, usage: "reported", pool: $pool, billing: $billing }'
}
{
  pline claude-code subscription:anthropic subscription 0.30 0.30 finished
  pline claude-code subscription:anthropic subscription 0.20 0.20 interrupted
  pline pi          api:anthropic          api          0.10 0.10 finished
  pline codex       api:openai             api          null 0.05 finished
  line 2026-11-02T09:00:00Z 0001/old.md 0001 conductor/old 1 finished 0 claude-code 0.40 5 5 0 0 reported
  jq -nc '{record: "pool_mismatch", ts: "2026-11-02T10:00:00Z", role: "coder", harness: "claude-code", declared: "api:anthropic", detected: "subscription:anthropic"}'
} > "$PL"
run --file "$PL"
assert_eq "exit 0" "$RC" "0"
lacks '^Known cost: \$1' "no single known-cost figure adds real and notional dollars"
has '^Known cost by billing' "the headline is split by billing"
has '^  api  *\$0.1000 reported + \$0.0500 estimated over 2 attempts' "api: its reported cost and its estimate, apart"
has '^  subscription  *\$0.5000 reported + \$0.0000 estimated over 2 attempts  *(notional)' "subscription: labelled notional"
has '^  unknown  *\$0.4000 reported + \$0.0000 estimated over 1 attempts' "an old line with no pool is unknown billing, not api"
has '^Unfinished: 1 attempts' "the unfinished line counts attempts"
has '^  subscription  *\$0.2000 reported' "and splits its dollars by billing too"
has '^By pool' "the pool section is there by default"
has '^subscription:anthropic (notional)  *2  *\$0.5000' "a subscription pool is labelled notional"
has '^api:anthropic  *1  *\$0.1000' "an api pool is not"
has '^api:openai  *1  *\$0.0000  *\$0.0500' "a pool with only an estimate shows it apart from reported"
has '^unknown  *1  *\$0.4000' "a line with no pool is in unknown"
has 'declared api:anthropic, sign-in said subscription:anthropic  *1' "a pool mismatch is listed, with a count"
has 'not comparable' "and the other groupings say their dollars can span billing"
run --file "$PL" --by pool
has '^By pool' "--by pool shows it"
lacks '^By harness' "and only it"
run --file "$PL" --by role
lacks '^By pool' "--by role does not show pools"
run --file "$RL"
lacks '^Known cost by billing' "a log with no pool information keeps the old headline"
has '^Known cost: ' "the old headline"
lacks '^By pool' "and no pool section, there is nothing to show"

section "6 · Budgets, spent against budget"
BL="$TMP/budget-usage.jsonl"
{
  jq -nc '{ts:"2026-11-06T09:00:00Z",event:"e",role:"coder",harness:"claude-code",model:"m",pool:"api:anthropic",billing:"api",cost_usd:6.0,outcome:"finished"}'
  jq -nc '{ts:"2026-11-06T09:30:00Z",event:"e",role:"reviewer",harness:"claude-code",model:"m",pool:"api:anthropic",billing:"api",cost_usd:null,estimated_cost_usd:null,outcome:"finished"}'
  jq -nc '{ts:"2026-11-06T10:00:00Z",event:"e",role:"coder",harness:"claude-code",model:"m",pool:"subscription:anthropic",billing:"subscription",cost_usd:1.0,allowance:{pool:"subscription:anthropic",weekly:{points:12}},outcome:"finished"}'
} > "$BL"
BB="$TMP/budgets.json"
printf '[{"pool":"api:anthropic","usd":10,"period":"run","caps":[{"role":"coder","usd":5}]},{"pool":"subscription:anthropic","percent":40,"period":"week"}]\n' > "$BB"
run --file "$BL" --budgets "$BB" --by budget
has '^Budgets ' "a budgets section"
has 'api:anthropic  *run  *\$6.00 of \$10.00  *60%  *ok' "the dollar pool: spent of budget, percent, state"
has '  role=coder  *run  *\$6.00 of \$5.00  *120%  *over' "a cap under its pool, over"
has 'subscription:anthropic  *week  *12% of 40%  *30%  *ok' "the subscription pool is in allowance percent"
has '1 with no cost' "lines with no cost are counted, not called free"
has 'the points of the runs, a floor: fewer than two live weekly readings in the period' "no readings: the row says it is the runs' floor, and why"
# with two live readings of one window the pool is measured by its rise, and says what that includes
{ cat "$BL"
  jq -nc '{record:"allowance",pool:"subscription:anthropic",moment:"x",ts:"2026-11-06T09:00:00Z",snapshot_at:"2026-11-06T09:00:00Z",source:"endpoint",weekly:{state:"known",used_percent:2,resets_at:1794024000}}'
  jq -nc '{record:"allowance",pool:"subscription:anthropic",moment:"x",ts:"2026-11-06T11:00:00Z",snapshot_at:"2026-11-06T11:00:00Z",source:"endpoint",weekly:{state:"known",used_percent:9,resets_at:1794024000}}'
} > "$BL.rise"
run --file "$BL.rise" --budgets "$BB" --by budget
has 'subscription:anthropic  *week  *7% of 40%  *18%  *ok' "the pool is measured by the rise of the window"
has 'the weekly window rose 2% to 9%; includes use by hand' "and says what the figure includes"
lacks '^By ' "--by budget shows nothing else"
run --file "$BL"
lacks '^Budgets ' "no budgets file: no section"
export CONDUCTOR_DIR="$TMP/cd"; mkdir -p "$CONDUCTOR_DIR"; cp "$BB" "$CONDUCTOR_DIR/budgets.json"
run --file "$BL"
has '^Budgets ' "the conductor dir's budgets.json is found, and shown with everything else"
unset CONDUCTOR_DIR

section "7 · Arguments"
run --bogus
assert_eq "an unknown flag: exit 1" "$RC" "1"
run --help
assert_eq "--help: exit 0" "$RC" "0"
has 'Summarise the headless conductor' "and it prints the description"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
