#!/usr/bin/env bash
set -euo pipefail
# Price a usage record from the price table, and check a usage log against it.
#
# Usage: usage-price.sh estimate                    a usage record (JSON) on stdin
#        usage-price.sh unknown [--file <usage.jsonl>]
#        usage-price.sh compare [--file <usage.jsonl>]
# Env:   CONDUCTOR_DIR (default: .conductor), CONDUCTOR_PRICES (default: usage-prices.json
#        next to this script)
#
# estimate  prints the cost of the record in US dollars, or null. It is null, never a guess and
#           never zero, when the model is missing from the table, the record has no model
#           (Codex without --model), the model is a "+" joined list (Claude Code run on several
#           models) or the record has no token counts. Prices are per million tokens on the
#           basis in the table's header: input, cache_read, cache_write and output tokens, which
#           do not overlap.
# unknown   lists the models in a log that the table does not price, and how many attempts used
#           each, so a gap shows up before it is a hole in the totals.
# compare   lists the attempts that have both a reported and an estimated cost, with the
#           difference, so the table can be checked against what a harness charged.

PRICES="${CONDUCTOR_PRICES:-$(cd "$(dirname "$0")" && pwd)/usage-prices.json}"
LOG="${CONDUCTOR_DIR:-.conductor}/usage.jsonl"

command -v jq > /dev/null 2>&1 || { echo "usage-price.sh needs jq" >&2; exit 3; }
cmd="${1:-}"; [[ -n "$cmd" ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) LOG="${2:?--file needs a path}"; shift 2 ;;
    *) echo "Usage: usage-price.sh estimate | unknown [--file F] | compare [--file F]" >&2; exit 1 ;;
  esac
done

# The estimate as a jq program over one record, with the table as $prices.
# shellcheck disable=SC2016  # jq code, not shell
ESTIMATE='
  def estimate($prices):
    ($prices[.model // ""]) as $p
    | if $p == null or ([.input_tokens, .output_tokens, .cache_read_tokens, .cache_write_tokens] | any(. == null)) then null
      else ((.input_tokens * $p.input + .cache_read_tokens * $p.cache_read
             + .cache_write_tokens * $p.cache_write + .output_tokens * $p.output) / 1e6
            | . * 1e8 | round / 1e8)
      end;'

# A table that is missing or broken prices nothing: every estimate is null, and the caller's
# line is still written.
table() { jq -c '.models // {}' "$PRICES" 2> /dev/null || echo '{}'; }

case "$cmd" in
  estimate)
    jq -c --argjson prices "$(table)" "$ESTIMATE"' estimate($prices)' 2> /dev/null || echo null ;;
  unknown)
    [[ -s "$LOG" ]] || { echo "No usage recorded yet: $LOG is missing or empty."; exit 0; }
    out="$(jq -R 'fromjson? // empty' "$LOG" | jq -rs --argjson prices "$(table)" '
      map(select(.record != "allowance")) |
      ( map(select(.model != null and ($prices[.model] == null))) | group_by(.model)
        | map("\(.[0].model)\t\(length)") | .[] ),
      ( (map(select(.model == null)) | length) as $n | if $n > 0 then "(no model)\t\($n)" else empty end )')"
    if [[ -z "$out" ]]; then echo "Every attempt in $LOG used a model the price table knows."
    else
      echo "Not in the price table (attempts):"
      printf '%s\n' "$out" | awk -F'\t' '{ printf "  %-40s %s\n", $1, $2 }'
    fi ;;
  compare)
    [[ -s "$LOG" ]] || { echo "No usage recorded yet: $LOG is missing or empty."; exit 0; }
    out="$(jq -R 'fromjson? // empty' "$LOG" | jq -r 'select(.cost_usd != null and .estimated_cost_usd != null)
      | [.event, .model, .cost_usd, .estimated_cost_usd, (.estimated_cost_usd - .cost_usd)] | @tsv')"
    if [[ -z "$out" ]]; then echo "No attempt in $LOG has both a reported and an estimated cost."
    else
      printf '%s\n' "$out" | awk -F'\t' 'BEGIN { printf "%-28s %-26s %10s %10s %10s\n", "event", "model", "reported", "estimated", "diff" }
        { printf "%-28s %-26s %10.4f %10.4f %+10.4f\n", $1, $2, $3, $4, $5 }'
    fi ;;
  *) echo "Usage: usage-price.sh estimate | unknown [--file F] | compare [--file F]" >&2; exit 1 ;;
esac
