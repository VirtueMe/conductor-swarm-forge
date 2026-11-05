#!/usr/bin/env bash
# The one place a usage line is written, so the conductor loop and the workers cannot drift apart.
#
# Sourced (not executed). Needs jq and usage-price.sh next to it.
#
#   usage_append <file> <record>
#     Appends one line to <file> (the usage log). <record> is a JSON object with the facts the
#     writer knows: event, task, handler, role, attempt, outcome, rc, duration_s, harness, model,
#     input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cache_write_1h_tokens (the part of the write at the 1-hour rate), cost_usd, turns, usage
#     allowance (what a Codex run used of the subscription, from allowance.sh end), and, for a Codex
#     run, requested_model and answered_model (what the workforce asked for, and what Codex said it
#     used), and declared_pool (the pool the workforce gave the member, if it did), pool (a pool the
#     writer has already settled) or pool_check (the whole decision, as billing-mode.sh pool --json
#     prints it, for a writer that settled it earlier). Anything missing is null. This adds what is
#     the same for every writer: ts, the cost estimated from the price table (null when it cannot be
#     priced), cost_source, which is reported when the record has a cost_usd, estimated when only the
#     estimate exists and unknown when neither does, and pool and billing: what the line was billed
#     to (the harness's sign-in, else the declared pool, else "unknown") and the api, subscription or
#     unknown that pool implies. A sign-in that disagrees with the declared pool wins, and a
#     declaration that is not a pool is set aside; either leaves a record of its own,
#     {"record": "pool_mismatch", ...}, just before the line. Field names and meanings are in
#     docs/event-driven-conductor.md, "Usage log". Always returns 0: the log is a convenience, and a
#     line that cannot be written must not change what the caller does.

# usage_pool_check <scripts dir> <record>: what was decided about the pool a line is billed to, as the object
# billing-mode.sh pool --json prints: {pool, declared, mismatch, rejected}. Pure: it writes nothing.
#   - a pool_check in the record is a decision a writer already made (worker-spawn settles it when the
#     worker starts, so the line says what the worker was billed to and not what the closing process can
#     see), and is taken as it is;
#   - a pool in the record is taken as it is, with nothing to say about it;
#   - otherwise it is decided now from the record's harness and declared_pool.
# Anything it cannot settle is "unknown"; it never fails.
usage_pool_check() {
  local here="$1" record="$2" check harness declared
  check="$(jq -c 'select((.pool_check | type) == "object" and (.pool_check.pool | type) == "string") | .pool_check' <<< "$record" 2> /dev/null)" || check=""
  if [[ -z "$check" ]]; then
    check="$(jq -c 'select((.pool | type) == "string" and .pool != "") | {pool: .pool, declared: null, mismatch: false, rejected: false}' <<< "$record" 2> /dev/null)" || check=""
  fi
  if [[ -z "$check" ]]; then
    harness="$(jq -r '.harness // empty' <<< "$record" 2> /dev/null)" || harness=""
    declared="$(jq -r '.declared_pool // empty' <<< "$record" 2> /dev/null)" || declared=""
    if [[ -n "$harness" ]]; then
      check="$("$here/billing-mode.sh" pool "$harness" ${declared:+--declared "$declared"} --json 2> /dev/null)" || check=""
    fi
  fi
  if ! jq -e 'type == "object" and (.pool | type) == "string"' <<< "$check" > /dev/null 2>&1; then
    check='{"pool":"unknown","declared":null,"mismatch":false,"rejected":false}'
  fi
  printf '%s\n' "$check"
}

usage_append() {
  local file="${1:?usage_append <file> <record>}" record="${2:?usage_append <file> <record>}"
  local here estimate pool billing check
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  check="$(usage_pool_check "$here" "$record")"
  pool="$(jq -r .pool <<< "$check")"
  billing="${pool%%:*}"
  case "$billing" in api|subscription) ;; *) billing=unknown ;; esac
  # A sign-in that overrode the workforce, or a declaration that was not a pool: a record of its own,
  # just before the line it is about.
  if [[ "$(jq -r '(.mismatch or .rejected) | tostring' <<< "$check")" == true ]]; then
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$record" --argjson c "$check" '
      { record: "pool_mismatch", ts: $ts, role: ($r.role // null), task: ($r.task // null), event: ($r.event // null),
        harness: ($r.harness // null), declared: $c.declared, detected: $c.pool, rejected: $c.rejected }' >> "$file" 2> /dev/null || true
  fi
  # Priced from the table; null when it cannot be, and the line is written either way.
  estimate="$("$here/usage-price.sh" estimate <<< "$record" 2> /dev/null)" || estimate=null
  jq -e 'type == "number" or . == null' <<< "$estimate" > /dev/null 2>&1 || estimate=null
  jq -nc --argjson r "$record" --argjson est "$estimate" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pool "$pool" --arg billing "$billing" '
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
      cache_write_1h_tokens: ($r.cache_write_1h_tokens // null),
      cost_usd: ($r.cost_usd // null),
      estimated_cost_usd: $est,
      cost_source: (if ($r.cost_usd // null) != null then "reported" elif $est != null then "estimated" else "unknown" end),
      pool: $pool,
      billing: $billing,
      turns: ($r.turns // null),
      usage: ($r.usage // null),
      allowance: ($r.allowance // null),
      requested_model: ($r.requested_model // null),
      answered_model: ($r.answered_model // null) }' >> "$file" 2> /dev/null || true
  return 0
}

#   usage_model_check <file> <role> <task> <event> <harness> <requested> <answered>
#     Appends a record of its own, {"record": "model_mismatch", ...}, if a run was asked for one model
#     and another answered. Nothing if either is empty (no model was asked for, or the session did not
#     name one) or if the two names are the same: a doubt is not a mismatch. The names are compared as
#     they are, so an alias that Codex reports under another id shows up as a mismatch with both
#     names in it, for a person to judge. Always returns 0, like usage_append.
usage_model_check() {
  local file="${1:?usage_model_check <file> <role> <task> <event> <harness> <requested> <answered>}"
  local role="${2-}" task="${3-}" event="${4-}" harness="${5-}" requested="${6-}" answered="${7-}"
  [[ -n "$requested" && -n "$answered" && "$requested" != "$answered" ]] || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg role "$role" --arg task "$task" --arg event "$event" \
    --arg harness "$harness" --arg requested "$requested" --arg answered "$answered" '
    { record: "model_mismatch", ts: $ts, role: $role, task: (if $task == "" then null else $task end), event: $event,
      harness: $harness, requested: $requested, answered: $answered }' >> "$file" 2> /dev/null || true
  return 0
}
