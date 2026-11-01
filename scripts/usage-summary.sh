#!/usr/bin/env bash
set -euo pipefail
# Summarise the headless conductor loop's usage log: what the dispatches cost, by harness, by
# handler and by task, and how much of it is not known or was spent on attempts that did not
# finish.
#
# Usage: usage-summary.sh [--file <usage.jsonl>] [--since <timestamp>]
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# The log has one JSON line per dispatch attempt (see conductor-loop.sh). A cost of null means
# the harness did not report one: Codex never does, and a run that was killed or failed before
# it answered leaves no record. Those attempts are counted as "unknown", never as free, so the
# known total is a floor, not the bill.
#
# --since takes a UTC timestamp as written in the log (2026-11-01T12:00:00Z), or a prefix of one
# (2026-11-01).

FILE="${CONDUCTOR_DIR:-.conductor}/usage.jsonl"
SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)  FILE="${2:?--file needs a path}";  shift 2 ;;
    --since) SINCE="${2:?--since needs a timestamp}"; shift 2 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Usage: usage-summary.sh [--file <usage.jsonl>] [--since <timestamp>]" >&2; exit 1 ;;
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
  | jq -rs --arg since "$SINCE" '
    map(select($since == "" or .ts >= $since)) as $all
    | def agg(rows): {
        attempts: (rows | length),
        cost: (rows | map(.cost_usd // 0) | add // 0),
        unknown: (rows | map(select(.cost_usd == null)) | length),
        input: (rows | map(.input_tokens // 0) | add // 0),
        output: (rows | map(.output_tokens // 0) | add // 0),
        cache_read: (rows | map(.cache_read_tokens // 0) | add // 0),
        cache_write: (rows | map(.cache_write_tokens // 0) | add // 0) };
      def row(section; key; a): [section, key, a.attempts, a.cost, a.unknown, a.input, a.output, a.cache_read, a.cache_write] | @tsv;
      def groups(f): $all | group_by(f // "-") | map({key: (.[0] | f // "-"), a: agg(.)}) | sort_by(-.a.cost, .key);
      if ($all | length) == 0 then "empty"
      else
        ("meta\tfirst\t" + ($all | map(.ts) | min)),
        ("meta\tlast\t" + ($all | map(.ts) | max)),
        ("meta\tevents\t" + ($all | map(.event) | unique | length | tostring)),
        row("total"; "-"; agg($all)),
        row("unfinished"; "-"; agg($all | map(select(.outcome != "finished")))),
        (groups(.harness)  | .[] | row("harness"; .key; .a)),
        (groups(.handler)  | .[] | row("handler"; .key; .a)),
        (groups(.task)     | .[] | row("task";    .key; .a))
      end' \
  | awk -F'\t' -v file="$FILE" -v since="$SINCE" '
    function money(x) { return sprintf("$%.4f", x) }
    function section(title) { printf "\n%-28s %8s %11s %8s %11s %9s\n", title, "attempts", "cost", "unknown", "in", "out" }
    $1 == "empty" { print "No usage lines" (since != "" ? " since " since : "") " in " file "."; empty = 1; next }
    $1 == "meta"  { meta[$2] = $3; next }
    $1 == "total" {
      printf "Usage log : %s%s\n", file, (since != "" ? "  (since " since ")" : "")
      printf "Period    : %s  to  %s   (%d attempts, %d events)\n", meta["first"], meta["last"], $3, meta["events"]
      printf "Known cost: %s over %d attempts with a cost\n", money($4), $3 - $5
      printf "Unknown   : %d attempts reported no cost (no record, or a harness that has none)\n", $5
      printf "Tokens    : in %d, out %d, cache read %d, cache write %d\n", $6, $7, $8, $9
      next
    }
    $1 == "unfinished" {
      printf "Unfinished: %s over %d attempts that did not finish (%d of them with no cost)\n", money($4), $3, $5
      next
    }
    $1 == "harness" || $1 == "handler" || $1 == "task" {
      if (shown != $1) { section("By " $1); shown = $1 }
      key = ($1 == "task" && $2 == "-") ? "(no task)" : $2
      printf "%-28s %8d %11s %8d %11d %9d\n", key, $3, money($4), $5, $6, $7
    }
    END { if (!empty) print "\nThe known cost is a floor: attempts with unknown cost are not in it." }'
