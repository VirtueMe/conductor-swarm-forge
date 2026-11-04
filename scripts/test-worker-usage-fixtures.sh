#!/usr/bin/env bash
# Tests the reading recipes in docs/worker-usage-sources.md against the trimmed real sessions in
# tests/worker-usage/: the numbers each harness leaves behind for a worker, reduced to the
# four disjoint token counts of a usage record (see usage-prices.json, "basis"), the model that
# answered, and the cost where the harness leaves one. Needs no model.
#
# Usage: scripts/test-worker-usage-fixtures.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FX="$SCRIPTS_DIR/../tests/worker-usage"

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

# Each recipe prints one JSON record: model, the four counts, cost_usd (null when the harness
# left none) and the cwd that links the session to a worker's worktree.

claude_record() { # claude-code: the assistant lines (one API message can be written twice, so
  # deduplicate on message.id) and, when the process exited normally, the cost-state line
  jq -cs '
    ([.[] | select(.type == "assistant")] | unique_by(.message.id)) as $a
    | { model: $a[0].message.model,
        input_tokens: ($a | map(.message.usage.input_tokens) | add),
        output_tokens: ($a | map(.message.usage.output_tokens) | add),
        cache_read_tokens: ($a | map(.message.usage.cache_read_input_tokens) | add),
        cache_write_tokens: ($a | map(.message.usage.cache_creation_input_tokens) | add),
        cost_usd: ([.[] | select(.type == "cost-state")] | last | .totalCostUSD // null | if . == null then null else (. * 1e8 | round) / 1e8 end),
        cwd: $a[0].cwd }' "$1"
}

codex_record() { # codex: token counts are cumulative, so the last token_count is the total;
  # input_tokens includes the cached part, which has to come out of it
  jq -cs '
    ([.[] | select(.payload.type == "token_count")] | last | .payload.info.total_token_usage) as $u
    | { model: ([.[] | select(.type == "turn_context")] | last | .payload.model),
        input_tokens: ($u.input_tokens - $u.cached_input_tokens),
        output_tokens: $u.output_tokens,
        cache_read_tokens: $u.cached_input_tokens,
        cache_write_tokens: ($u.cache_write_input_tokens // 0),
        cost_usd: null,
        cwd: (.[] | select(.type == "session_meta") | .payload.cwd) }' "$1"
}

pi_record() { # pi: every assistant message carries its own usage and cost, so sum them
  jq -cs '
    ([.[] | select(.type == "message" and .message.role == "assistant") | .message]) as $m
    | { model: $m[0].model,
        input_tokens: ($m | map(.usage.input) | add),
        output_tokens: ($m | map(.usage.output) | add),
        cache_read_tokens: ($m | map(.usage.cacheRead) | add),
        cache_write_tokens: ($m | map(.usage.cacheWrite) | add),
        cost_usd: ($m | map(.usage.cost.total) | add),
        cwd: (.[] | select(.type == "session") | .cwd) }' "$1"
}
field() { jq -r ".$2" <<< "$1"; }

section "1 · claude-code, the process exited (kill-window sends SIGHUP)"
R="$(claude_record "$FX/claude-code/exited.jsonl")"
assert_eq "model" "$(field "$R" model)" "claude-haiku-4-5-20251001"
assert_eq "input tokens, the duplicated message counted once" "$(field "$R" input_tokens)" "10"
assert_eq "output tokens" "$(field "$R" output_tokens)" "54"
assert_eq "cache read tokens" "$(field "$R" cache_read_tokens)" "27430"
assert_eq "cache write tokens" "$(field "$R" cache_write_tokens)" "10056"
assert_eq "cost from the cost-state line" "$(field "$R" cost_usd)" "0.023135"
assert_eq "the session names its worktree" "$(field "$R" cwd | grep -c '/.worktrees/')" "1"
assert_eq "and carries the window name from -n" \
  "$(jq -r 'select(.type == "custom-title") | .customTitle' "$FX/claude-code/exited.jsonl")" "claude-0001"

section "2 · claude-code, killed with SIGKILL: the tokens survive, the cost does not"
R="$(claude_record "$FX/claude-code/sigkilled.jsonl")"
assert_eq "the tokens of its own run are there" "$(field "$R" output_tokens)/$(field "$R" cache_write_tokens)" "47/5950"
assert_eq "no cost-state, so no reported cost" "$(field "$R" cost_usd)" "null"

section "3 · codex"
R="$(codex_record "$FX/codex/rollout.jsonl")"
assert_eq "model comes from turn_context" "$(field "$R" model)" "gpt-6.1-sol"
assert_eq "input minus the cached part (15349 - 12032)" "$(field "$R" input_tokens)" "3317"
assert_eq "cache read is the cached input" "$(field "$R" cache_read_tokens)" "12032"
assert_eq "output tokens" "$(field "$R" output_tokens)" "5"
assert_eq "no cost is left behind" "$(field "$R" cost_usd)" "null"
assert_eq "the session names its worktree" "$(field "$R" cwd | grep -c '/.worktrees/')" "1"
assert_eq "the allowance is in the token_count event (for the Codex subscription slice)" \
  "$(jq -r 'select(.payload.type == "token_count") | .payload.rate_limits.primary.window_minutes' "$FX/codex/rollout.jsonl")" "300"

section "4 · pi"
R="$(pi_record "$FX/pi/session.jsonl")"
assert_eq "model" "$(field "$R" model)" "claude-haiku-4-5"
assert_eq "input tokens" "$(field "$R" input_tokens)" "2288"
assert_eq "output tokens" "$(field "$R" output_tokens)" "55"
assert_eq "cost is pi's own" "$(field "$R" cost_usd)" "0.002563"
assert_eq "the session names its worktree" "$(field "$R" cwd | grep -c '/.worktrees/')" "1"

section "5 · Against the price table"
price() { "$SCRIPTS_DIR/usage-price.sh" estimate <<< "$1"; }
assert_eq "pi: the table agrees with pi's own cost" "$(price "$(pi_record "$FX/pi/session.jsonl")")" "0.002563"
# Claude Code billed the cache write at the 1-hour rate (cacheCreationEphemeral1hInputTokens), and the
# table holds the 5-minute rate, so the estimate is lower than the reported cost.
CLAUDE="$(claude_record "$FX/claude-code/exited.jsonl")"
assert_eq "claude-code: the estimate is below the reported cost (1-hour cache write)" \
  "$(jq -n --argjson e "$(price "$CLAUDE")" --argjson r "$(field "$CLAUDE" cost_usd)" '$e < $r')" "true"
assert_eq "codex: the model is not in the table, so no estimate" "$(price "$(codex_record "$FX/codex/rollout.jsonl")")" "null"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
