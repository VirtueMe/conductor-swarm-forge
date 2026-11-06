#!/usr/bin/env bash
set -euo pipefail
# Summarise the headless conductor loop's usage log: what the dispatches cost, by harness, by
# handler, by task, by role and by model, how the harnesses compare on estimated cost, and how
# much is not known or was spent on attempts that did not finish.
#
# Usage: usage-summary.sh [--file <usage.jsonl>] [--since <timestamp>] [--by <grouping>]...
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# The log has one JSON line per dispatch attempt (see conductor-loop.sh; the fields are listed in
# docs/event-driven-conductor.md, "Usage log"). Cost comes in three kinds, kept apart:
#   reported   the harness gave a cost (cost_usd)
#   estimated  no reported cost, but the price table priced the tokens (estimated_cost_usd)
#   unknown    neither: a harness with no cost on a model the table lacks, or an attempt that
#              left no record. Never counted as free.
# The kind is read from the two cost fields, so a line from before cost_source, role or
# estimated_cost_usd existed reads as it always did. The reported and estimated totals do not
# include the unknown attempts, so together they are a floor, not the bill.
#
# Dollars are not all the same kind. A line's billing (api, subscription or unknown, from the pool it was
# billed to) says whether its cost is real spend or notional: what a plan was used for, not a bill.
# Once any line has a billing, the headline totals are split by billing and are never added across it,
# and "pool" lists each pool apart (subscription pools marked notional). A line from before pools
# existed has no billing and reads as unknown, never as api. The other groupings can span billing
# within a group, and say so.
#
# --by picks the groupings to print, and can be repeated: harness, handler, task, role, model, pool,
# adapters, allowance. The default is all of them. "adapters" is the cross-adapter view: every attempt
# that has an estimate, reported cost or not, on the price table's one basis, with the number
# of attempts that have none.
#
# "allowance" is the subscription pools (Codex, subscription:openai, and Claude Code,
# subscription:anthropic), kept apart from tokens and dollars because it is a percentage of a window,
# not a cost. With more than one pool it starts with the runs metered in each (a count: points are
# per pool and never added across pools). Each pool then has its own block: the latest reading of the
# five-hour and the weekly window, how far each has moved since the first reading in the same window,
# for Claude the week per model and the credits (dollars), and the percentage points that runs used
# (the allowance on their lines), by role. A run whose points could not be
# attributed (runs overlapped, or a reading was unknown) is counted, not guessed. The readings are
# records of their own in the log ("record": "allowance") and are not attempts, and neither is any
# other line with a "record" field. A run on a model other than the one asked for is its own record
# ("record": "model_mismatch"); the section lists them by the pair of names, with a count.
#
# --since takes a UTC timestamp as written in the log (2026-11-01T12:00:00Z), or a prefix of one
# (2026-11-01).

FILE="${CONDUCTOR_DIR:-.conductor}/usage.jsonl"
SINCE=""
BY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)  FILE="${2:?--file needs a path}";  shift 2 ;;
    --since) SINCE="${2:?--since needs a timestamp}"; shift 2 ;;
    --by)
      case "${2:-}" in
        harness|handler|task|role|model|pool|adapters|allowance) BY="$BY${BY:+,}$2"; shift 2 ;;
        *) echo "usage-summary.sh: --by takes harness, handler, task, role, model, pool, adapters or allowance" >&2; exit 1 ;;
      esac ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Usage: usage-summary.sh [--file <usage.jsonl>] [--since <timestamp>] [--by <grouping>]..." >&2; exit 1 ;;
  esac
done

command -v jq > /dev/null 2>&1 || { echo "usage-summary.sh needs jq" >&2; exit 3; }
if [[ ! -s "$FILE" ]]; then
  echo "No usage recorded yet: $FILE is missing or empty."
  echo "The headless conductor loop writes it, one line per dispatch."
  exit 0
fi

# Lines that are not JSON are skipped, so a half-written last line cannot break the summary.
jq -R 'fromjson? // empty' "$FILE" \
  | jq -rs --arg since "$SINCE" --arg by "$BY" '
    map(select($since == "" or .ts >= $since)) as $inrange
    | ($inrange | map(select(.record == "allowance"))) as $readings
    | ($inrange | map(select(.record == "model_mismatch"))) as $mismatches
    | ($inrange | map(select(.record == "pool_mismatch"))) as $poolmm
    | ($inrange | map(select(.record == null))) as $all
    | ($all | map(select(.billing == "api" or .billing == "subscription")) | length > 0) as $billed
    | ($all | map(select(.pool != null and .pool != "unknown")) | length > 0) as $pooled
    | def want(k): $by == "" or ($by | split(",") | index(k) != null);
      def reported: select(.cost_usd != null);
      def estimated: select(.cost_usd == null and .estimated_cost_usd != null);
      def unknown: select(.cost_usd == null and .estimated_cost_usd == null);
      def priced: select(.estimated_cost_usd != null);
      def sum(f): map(f) | add // 0;
      def agg(rows): {
        attempts: (rows | length),
        reported: (rows | sum(reported | .cost_usd)),
        reported_n: (rows | map(reported) | length),
        estimated: (rows | sum(estimated | .estimated_cost_usd)),
        estimated_n: (rows | map(estimated) | length),
        unknown: (rows | map(unknown) | length),
        priced: (rows | sum(priced | .estimated_cost_usd)),
        priced_n: (rows | map(priced) | length),
        input: (rows | sum(.input_tokens // 0)),
        output: (rows | sum(.output_tokens // 0)),
        cache_read: (rows | sum(.cache_read_tokens // 0)),
        cache_write: (rows | sum(.cache_write_tokens // 0)) };
      def row(section; key; a): [section, key, a.attempts, a.reported, a.estimated, a.unknown, a.input, a.output, a.cache_read, a.cache_write, a.reported_n, a.estimated_n, a.priced, a.priced_n] | @tsv;
      def billing_of: .billing // "unknown";
      def poolkey: (.pool // "unknown") | if startswith("subscription:") then . + " (notional)" else . end;
      def by_billing(rows): ["api", "subscription", "unknown"] | map(. as $m | {mode: $m, a: agg(rows | map(select(billing_of == $m)))}) | map(select(.a.attempts > 0));
      def groups(f): $all | group_by(f // "-") | map({key: (.[0] | f // "-"), a: agg(.)}) | sort_by(-(.a.reported + .a.estimated), .key);
      def same_window($a; $b): ($a.resets_at != null and $b.resets_at != null and (($a.resets_at - $b.resets_at) | fabs) <= 120);
      def pool_of: .pool // "subscription:openai";
      def claude_pool: "subscription:anthropic";
      def label_of($p): if $p == claude_pool then "Claude" else "Codex" end;
      def window_rows($rs; $w; $label):
        ($rs | last) as $l
        | ([$rs[] | select(.[$w].state == "known" and same_window(.[$w]; $l[$w]))] | first) as $f
        | ["allow_win", $label, $l[$w].state, ($l[$w].used_percent // "-"),
           (if $l[$w].resets_at != null then ($l[$w].resets_at | todate) else "-" end),
           ($l[$w].reason // "-"),
           (if $l[$w].state == "known" and $f != null then $f[$w].used_percent else "-" end),
           (if $l[$w].state == "known" and $f != null then ($f.snapshot_at // "-") else "-" end)] | @tsv;
      def run_counts($runs):
        { runs: ($runs | length),
          attributed: ($runs | map(select(.allowance.attributed_to == "run" and .allowance.five_hour.points != null)) | length),
          batch: ($runs | map(select(.allowance.attributed_to == "batch")) | length),
          unknown: ($runs | map(select(.allowance.attributed_to != "batch" and .allowance.five_hour.points == null)) | length) };
      def pool_rows($p):
        ([$readings[] | select(pool_of == $p)]) as $rs
        | ($all | map(select(.allowance != null and (.allowance | pool_of) == $p))) as $runs
        | ($rs | last) as $l
        | (if ($rs | length) > 0 then
             (["allow_head", label_of($p), $p, ($l.snapshot_at // "-"),
               (if $p == claude_pool
                then "from " + ($l.source // "unknown") + (if $l.source == "cache" then ", " + ((($l.age_seconds // 0) / 3600) | floor | tostring) + " h old"
                                           elif $l.source == "statusline" then ", " + ((($l.age_seconds // 0) / 60) | floor | tostring) + " min old" else "" end)
                else "plan " + ($l.plan_type // "-") + ", Codex " + ($l.codex_version // "-") end)] | @tsv),
             window_rows($rs; "five_hour"; "5-hour"), window_rows($rs; "weekly"; "weekly"),
             (if $p == claude_pool then
                (if $l.weekly_by_model.state == "known"
                 then ($l.weekly_by_model.models[] | ["allow_model", .model, "known", .used_percent, "-", "-"] | @tsv)
                 else (["allow_model", "per model", "unknown", "-", "-", ($l.weekly_by_model.reason // "-")] | @tsv) end),
                (["allow_credits", $l.credits.state, ($l.credits.used // "-"), ($l.credits.limit // "-"), ($l.credits.currency // "-"), ($l.credits.reason // "-")] | @tsv)
              else empty end)
           else (["allow_head", label_of($p), $p, "-", "-"] | @tsv) end),
          ($runs | group_by(.role // "-")
           | map({role: (.[0].role // "-"), runs: length,
                  five: (map(.allowance.five_hour.points // 0) | add), weekly: (map(.allowance.weekly.points // 0) | add),
                  lost: (map(select(.allowance.five_hour.points == null)) | length),
                  batch: (map(select(.allowance.attributed_to == "batch")) | length),
                  five_n: (map(select(.allowance.five_hour.points != null)) | length),
                  weekly_n: (map(select(.allowance.weekly.points != null)) | length),
                  credits: (map(.allowance.credits.dollars // 0) | add),
                  credits_n: (map(select(.allowance.credits.dollars != null)) | length)})
           | sort_by(-.five, .role) | .[]
           | ["allow_role", .role, .runs, .five, .weekly, .lost, .batch, .five_n, .weekly_n, .credits, .credits_n] | @tsv),
          (if $p == claude_pool then
             ($runs | map(.allowance.weekly_by_model.models // []) | flatten | map(select(.points != null)) | group_by(.model)
              | map(["allow_use_model", .[0].model, length, (map(.points) | add)] | @tsv) | .[])
           else empty end);
      def allowance_rows:
        if want("allowance") and (($readings | length) > 0 or ($mismatches | length) > 0 or ($all | map(select(.allowance != null)) | length) > 0) then
          ([claude_pool, "subscription:openai"] | map(. as $p
             | select(($readings | map(select(pool_of == $p)) | length) > 0 or ($all | map(select(.allowance != null and (.allowance | pool_of) == $p)) | length) > 0))) as $pools
          | (if ($pools | length) == 0 then ["subscription:openai"] else ($pools | reverse) end) as $order
          | (if ($order | length) > 1 then
               (["allow_total", ($all | map(select(.allowance != null)) | length)] | @tsv),
               ($order[] | . as $p | run_counts($all | map(select(.allowance != null and (.allowance | pool_of) == $p))) as $c
                | ["allow_total_pool", label_of($p), $p, $c.runs, $c.attributed, $c.batch, $c.unknown] | @tsv)
             else empty end),
            ($order[] | pool_rows(.)),
            ($mismatches | group_by([.requested, .answered]) | map(["allow_mismatch", .[0].requested, .[0].answered, length]) | sort_by(-.[3]) | .[] | @tsv)
        else empty end;
      (if ($all | length) == 0 then "empty"
      else
        ("meta\tfirst\t" + ($all | map(.ts) | min)),
        ("meta\tlast\t" + ($all | map(.ts) | max)),
        ("meta\tevents\t" + ($all | map(.event) | unique | length | tostring)),
        ("meta\tbilling\t" + ($billed | tostring)),
        row("total"; "-"; agg($all)),
        (if $billed then (by_billing($all) | .[] | row("billing"; .mode; .a)) else empty end),
        row("unfinished"; "-"; agg($all | map(select(.outcome != "finished")))),
        (if $billed then (by_billing($all | map(select(.outcome != "finished"))) | .[] | row("unfin_billing"; .mode; .a)) else empty end),
        (if want("harness") then (groups(.harness) | .[] | row("harness"; .key; .a)) else empty end),
        (if want("handler") then (groups(.handler) | .[] | row("handler"; .key; .a)) else empty end),
        (if want("task")    then (groups(.task)    | .[] | row("task";    .key; .a)) else empty end),
        (if want("role")    then (groups(.role)    | .[] | row("role";    .key; .a)) else empty end),
        (if want("model")   then (groups(.model)   | .[] | row("model";   .key; .a)) else empty end),
        (if want("pool") and ($pooled or ($poolmm | length) > 0) then
           (groups(poolkey) | .[] | row("pool"; .key; .a)),
           ($poolmm | group_by([.declared, .detected]) | map(["pool_mismatch", .[0].declared, .[0].detected, length] | @tsv) | .[])
         else empty end),
        (if want("adapters") then (groups(.harness) | sort_by(.key) | .[] | row("adapters"; .key; .a)) else empty end)
      end),
      allowance_rows' \
  | awk -F'\t' -v file="$FILE" -v since="$SINCE" '
    function money(x) { return sprintf("$%.4f", x) }
    # percentage points a window rose over the runs of a role: "-" if none of them could be attributed,
    # "+0 (<1)" for a real measurement of less than one step of the log, otherwise "+n"
    function points(v, n) { return (n == 0) ? "-" : ((v == 0) ? "+0 (<1)" : "+" v) }
    function section(title) { printf "\n%-34s %8s %11s %11s %8s %11s %9s\n", title, "attempts", "reported", "estimated", "unknown", "in", "out" }
    $1 == "empty" { print "No usage lines" (since != "" ? " since " since : "") " in " file "."; empty = 1; next }
    $1 == "meta"  { meta[$2] = $3; next }
    $1 == "total" {
      total = $3
      printf "Usage log : %s%s\n", file, (since != "" ? "  (since " since ")" : "")
      printf "Period    : %s  to  %s   (%d attempts, %d events)\n", meta["first"], meta["last"], $3, meta["events"]
      if (meta["billing"] != "true") {
        printf "Known cost: %s over %d attempts with a reported cost\n", money($4), $11
        printf "Estimated : %s over %d attempts with only an estimate\n", money($5), $12
      }
      printf "Unknown   : %d attempt(s) with neither a reported cost nor an estimate\n", $6
      printf "Tokens    : in %d, out %d, cache read %d, cache write %d\n", $7, $8, $9, $10
      next
    }
    $1 == "unfinished" {
      if (meta["billing"] == "true") printf "Unfinished: %d attempts that did not finish (%d of them with no cost)\n", $3, $6
      else printf "Unfinished: %s reported%s over %d attempts that did not finish (%d of them with no cost)\n", money($4), ($5 > 0 ? " and " money($5) " estimated" : ""), $3, $6
      next
    }
    $1 == "billing" {
      if (!billing_head) { printf "Known cost by billing (real and notional dollars are not added together):\n"; billing_head = 1 }
      printf "  %-13s %s reported + %s estimated over %d attempts%s%s\n", $2, money($4), money($5), $3, ($2 == "subscription" ? "  (notional)" : ""), ($6 > 0 ? "  [" $6 " with no cost]" : "")
      next
    }
    $1 == "unfin_billing" {
      if (!unfin_head) { printf "  of the unfinished, by billing:\n"; unfin_head = 1 }
      printf "  %-13s %s reported + %s estimated over %d attempts%s\n", $2, money($4), money($5), $3, ($2 == "subscription" ? "  (notional)" : "")
      next
    }
    $1 == "pool_mismatch" {
      if (!pool_mm_head) { printf "\n  %-62s %6s\n", "Declared pool -> what the sign-in said (the sign-in was used)", "lines"; pool_mm_head = 1 }
      printf "  declared %s, sign-in said %s  %d\n", $2, $3, $4
      next
    }
    $1 == "allow_total" {
      printf "\nAllowance, all subscription pools: %d runs metered (runs only: points are per pool, and are not added across pools)\n", $2
      printf "  %-34s %6s %11s %10s %8s\n", "Pool", "runs", "attributed", "in a batch", "unknown"
      next
    }
    $1 == "allow_total_pool" {
      printf "  %-34s %6d %11d %10d %8d\n", $2 " (" $3 ")", $4, $5, $6, $7
      next
    }
    $1 == "allow_head" {
      cur_label = $2; role_head = 0; use_head = 0
      printf "\n%s allowance (%s)", $2, $3
      if ($4 == "-") printf ": %s\n", ($2 == "Codex" ? "no reading in any Codex session" : "no reading")
      else printf ", read %s, %s\n", $4, $5
      allowed = 1
      next
    }
    $1 == "allow_win" {
      if ($3 == "known") {
        printf "  %-8s %s%% used, resets %s", $2, $4, $5
        if ($7 != "-") printf "  (was %s%% at %s, first reading in this window)", $7, $8
        printf "\n"
      } else printf "  %-8s unknown (%s)\n", $2, $6
      next
    }
    $1 == "allow_model" {
      if ($3 == "known") printf "  %-8s %s%% used (this week)\n", $2, $4
      else printf "  %-8s unknown (%s)\n", $2, $6
      next
    }
    $1 == "allow_credits" {
      if ($2 == "known") printf "  %-8s $%.2f of $%.2f %s\n", "credits", $3, $4, $5
      else printf "  %-8s unknown (%s)\n", "credits", $6
      next
    }
    $1 == "allow_role" {
      claude = (cur_label == "Claude")
      if (!role_head) {
        printf "\n  %-38s %6s %8s %8s %s%16s\n", "Used by runs (percentage points)", "runs", "5-hour", "weekly", (claude ? sprintf("%9s ", "credits") : ""), "not attributed"
        role_head = 1; any_role_head = 1
      }
      printf "  %-38s %6d %8s %8s %s%16s\n", $2, $3, points($4, $8), points($5, $9), (claude ? sprintf("%9s ", ($11 == 0 ? "-" : sprintf("+$%.2f", $10))) : ""), $6 (($7 > 0) ? " (" $7 " in a batch)" : "")
      next
    }
    $1 == "allow_use_model" {
      if (!use_head) { printf "\n  %-38s %6s %8s\n", "Used by runs, per model (points)", "runs", "week"; use_head = 1 }
      printf "  %-38s %6d %8s\n", $2, $3, points($4, $3)
      next
    }
    $1 == "allow_mismatch" {
      if (!mismatch_head) {
        printf "\n  %-38s %6s\n", "Model asked for -> model that answered", "runs"
        mismatch_head = 1
      }
      printf "  %-38s %6d\n", $2 " -> " $3, $4
      next
    }
    $1 == "adapters" {
      if (shown != $1) {
        adapters_shown = 1
        printf "\n%-28s %8s %11s %8s %9s %12s\n", "Across harnesses, on estimate", "attempts", "estimate", "priced", "unpriced", "per priced"
        shown = $1
      }
      unpriced = $3 - $14; unpriced_all += unpriced
      printf "%-28s %8d %11s %8d %9d %12s\n", $2, $3, money($13), $14, unpriced, ($14 > 0 ? money($13 / $14) : "-")
      next
    }
    {
      if (shown != $1) { section("By " $1); shown = $1 }
      key = ($2 == "-") ? "(no " $1 ")" : $2
      printf "%-34s %8d %11s %11s %8d %11d %9d\n", key, $3, money($4), money($5), $6, $7, $8
    }
    END {
      if (any_role_head) printf "\nRuns whose points could not be attributed (overlapping runs, or a reading that was unknown) are counted, not guessed, and a - is a column with none attributed; the change over a batch is in the readings above. A +0 (<1) is under one step of the log, which reports whole percents: not nothing. Credits are dollars drawn, shown only for Claude, and are never added to points.\n"
      if (empty) exit
      if (adapters_shown)
        printf "\n%d of the %d attempts have no estimate (an unpriced model, or no record). They are not counted as free.\n", unpriced_all, total
      if (meta["billing"] == "true")
        printf "\nDollars in a harness, handler, task, role or model group can span api and subscription lines, so they are not comparable with each other; --by pool keeps them apart.\n"
      print "\nThe known cost is a floor: attempts with unknown cost are not in it, and estimated cost is shown apart from reported."
    }'
