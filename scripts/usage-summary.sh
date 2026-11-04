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
# --by picks the groupings to print, and can be repeated: harness, handler, task, role, model,
# adapters. The default is all of them. "adapters" is the cross-adapter view: every attempt
# that has an estimate, reported cost or not, on the price table's one basis, with the number
# of attempts that have none.
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
        harness|handler|task|role|model|adapters) BY="$BY${BY:+,}$2"; shift 2 ;;
        *) echo "usage-summary.sh: --by takes harness, handler, task, role, model or adapters" >&2; exit 1 ;;
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
    map(select($since == "" or .ts >= $since)) as $all
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
      def groups(f): $all | group_by(f // "-") | map({key: (.[0] | f // "-"), a: agg(.)}) | sort_by(-(.a.reported + .a.estimated), .key);
      if ($all | length) == 0 then "empty"
      else
        ("meta\tfirst\t" + ($all | map(.ts) | min)),
        ("meta\tlast\t" + ($all | map(.ts) | max)),
        ("meta\tevents\t" + ($all | map(.event) | unique | length | tostring)),
        row("total"; "-"; agg($all)),
        row("unfinished"; "-"; agg($all | map(select(.outcome != "finished")))),
        (if want("harness") then (groups(.harness) | .[] | row("harness"; .key; .a)) else empty end),
        (if want("handler") then (groups(.handler) | .[] | row("handler"; .key; .a)) else empty end),
        (if want("task")    then (groups(.task)    | .[] | row("task";    .key; .a)) else empty end),
        (if want("role")    then (groups(.role)    | .[] | row("role";    .key; .a)) else empty end),
        (if want("model")   then (groups(.model)   | .[] | row("model";   .key; .a)) else empty end),
        (if want("adapters") then (groups(.harness) | sort_by(.key) | .[] | row("adapters"; .key; .a)) else empty end)
      end' \
  | awk -F'\t' -v file="$FILE" -v since="$SINCE" '
    function money(x) { return sprintf("$%.4f", x) }
    function section(title) { printf "\n%-28s %8s %11s %11s %8s %11s %9s\n", title, "attempts", "reported", "estimated", "unknown", "in", "out" }
    $1 == "empty" { print "No usage lines" (since != "" ? " since " since : "") " in " file "."; empty = 1; next }
    $1 == "meta"  { meta[$2] = $3; next }
    $1 == "total" {
      total = $3
      printf "Usage log : %s%s\n", file, (since != "" ? "  (since " since ")" : "")
      printf "Period    : %s  to  %s   (%d attempts, %d events)\n", meta["first"], meta["last"], $3, meta["events"]
      printf "Known cost: %s over %d attempts with a reported cost\n", money($4), $11
      printf "Estimated : %s over %d attempts with only an estimate\n", money($5), $12
      printf "Unknown   : %d attempt(s) with neither a reported cost nor an estimate\n", $6
      printf "Tokens    : in %d, out %d, cache read %d, cache write %d\n", $7, $8, $9, $10
      next
    }
    $1 == "unfinished" {
      printf "Unfinished: %s reported%s over %d attempts that did not finish (%d of them with no cost)\n", money($4), ($5 > 0 ? " and " money($5) " estimated" : ""), $3, $6
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
      printf "%-28s %8d %11s %11s %8d %11d %9d\n", key, $3, money($4), money($5), $6, $7, $8
    }
    END {
      if (empty) exit
      if (adapters_shown)
        printf "\n%d of the %d attempts have no estimate (an unpriced model, or no record). They are not counted as free.\n", unpriced_all, total
      print "\nThe known cost is a floor: attempts with unknown cost are not in it, and estimated cost is shown apart from reported."
    }'
