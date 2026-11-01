#!/usr/bin/env bash
# What every adapter_dispatch reports back, in one place.
#
# Sourced (not executed), together with dispatch-prompt.sh. The three adapters
# (claude-code, codex, pi) read very different results, so how each one finds an error
# stays in the adapter. What they share is the shape of the usage record and the check
# on the model's last line, and those are defined here so they cannot drift apart.
#
#   dispatch_write_usage <harness> <model> <input> <output> <cache_read> <cache_write> <cost> <turns>
#     Writes the usage record, one JSON line, to $DISPATCH_USAGE_FILE (nothing if it is
#     unset). The fields are harness, model, input_tokens, output_tokens,
#     cache_read_tokens, cache_write_tokens, cost_usd and turns. Pass "-" or "" for a
#     value the harness does not report: model, cost and turns become null, token counts
#     become 0. input_tokens counts input that was neither read from nor written to a
#     cache, so a harness that reports a total has to subtract the cached part first.
#
#   dispatch_finish <harness> <answer>
#     Writes the answer's last non-empty line to $DISPATCH_ANSWER_FILE if that is set, so the
#     loop can show what the model said it did (it is written before the check below, so a
#     HANDLER-FAILED line is kept too). Returns 1, with a message, if the last non-empty line of the model's answer starts
#     with HANDLER-FAILED:. Returns 0 otherwise. Needs dispatch_final_exit from
#     dispatch-prompt.sh.

dispatch_write_usage() {
  [[ -n "${DISPATCH_USAGE_FILE:-}" ]] || return 0
  jq -nc --arg harness "$1" --arg model "$2" --arg inp "$3" --arg out "$4" \
    --arg cr "$5" --arg cw "$6" --arg cost "$7" --arg turns "$8" '
    def num: if . == "" or . == "-" then null else (tonumber? // null) end;
    { harness: $harness,
      model: (if $model == "" or $model == "-" then null else $model end),
      input_tokens: ($inp | num // 0),
      output_tokens: ($out | num // 0),
      cache_read_tokens: ($cr | num // 0),
      cache_write_tokens: ($cw | num // 0),
      cost_usd: ($cost | num),
      turns: ($turns | num) }' > "$DISPATCH_USAGE_FILE"
}

dispatch_finish() {
  local harness="${1:?Usage: dispatch_finish <harness> <answer>}" answer="${2-}"
  if [[ -n "${DISPATCH_ANSWER_FILE:-}" ]]; then
    { printf '%s\n' "$answer" | awk 'NF{l=$0} END{if (l != "") print substr(l, 1, 300)}' > "$DISPATCH_ANSWER_FILE"; } 2> /dev/null || true
  fi
  dispatch_final_exit "$answer" && return 0
  echo "$harness: handler reported failure: $(printf '%s\n' "$answer" | awk 'NF{l=$0} END{print l}')" >&2
  return 1
}
