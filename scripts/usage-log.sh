#!/usr/bin/env bash
# The one place a usage line is written, so the conductor loop and the workers cannot drift apart.
#
# Sourced (not executed). Needs jq and usage-price.sh next to it.
#
#   usage_append <file> <record>
#     Appends one line to <file> (the usage log). <record> is a JSON object with the facts the
#     writer knows: event, task, handler, role, attempt, outcome, rc, duration_s, harness, model,
#     input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, turns, usage
#     and allowance (what a Codex run used of the subscription, from allowance.sh end). Anything
#     missing is null. This adds what is the same for every writer: ts, the cost
#     estimated from the price table (null when it cannot be priced), and cost_source, which is
#     reported when the record has a cost_usd, estimated when only the estimate exists and unknown
#     when neither does. Field names and meanings are in docs/event-driven-conductor.md, "Usage
#     log". Always returns 0: the log is a convenience, and a line that cannot be written must not
#     change what the caller does.

usage_append() {
  local file="${1:?usage_append <file> <record>}" record="${2:?usage_append <file> <record>}"
  local here estimate
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Priced from the table; null when it cannot be, and the line is written either way.
  estimate="$("$here/usage-price.sh" estimate <<< "$record" 2> /dev/null)" || estimate=null
  jq -e 'type == "number" or . == null' <<< "$estimate" > /dev/null 2>&1 || estimate=null
  jq -nc --argjson r "$record" --argjson est "$estimate" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    { ts: $ts,
      event: ($r.event // null),
      task: ($r.task // null),
      handler: ($r.handler // null),
      role: ($r.role // null),
      attempt: ($r.attempt // null),
      outcome: ($r.outcome // null),
      rc: ($r.rc // null),
      duration_s: ($r.duration_s // null),
      harness: ($r.harness // null),
      model: ($r.model // null),
      input_tokens: ($r.input_tokens // null),
      output_tokens: ($r.output_tokens // null),
      cache_read_tokens: ($r.cache_read_tokens // null),
      cache_write_tokens: ($r.cache_write_tokens // null),
      cost_usd: ($r.cost_usd // null),
      estimated_cost_usd: $est,
      cost_source: (if ($r.cost_usd // null) != null then "reported" elif $est != null then "estimated" else "unknown" end),
      turns: ($r.turns // null),
      usage: ($r.usage // null),
      allowance: ($r.allowance // null) }' >> "$file" 2> /dev/null || true
  return 0
}
