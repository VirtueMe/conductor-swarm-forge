#!/usr/bin/env bash
# Tests scripts/budget.sh: budgets per pool (and per role, adapter or model within a pool), the brief
# that may only tighten them, spent measured against them from the usage log, and the warning that is
# written once. Report only: nothing here pauses or refuses anything. Needs no harness and no account.
#
# Usage: scripts/test-budget.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
B="$SCRIPTS_DIR/budget.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { echo ""; echo "── $1"; }

NOW="2026-11-06T12:00:00Z"
LOG="$TMP/usage.jsonl"
BUDGETS="$TMP/budgets.json"

# line <ts> <pool> <role> <harness> <cost|-> <weekly points|->
line() {
  jq -nc --arg ts "$1" --arg pool "$2" --arg role "$3" --arg h "$4" --arg cost "$5" --arg pts "$6" '
    { ts: $ts, pool: $pool, billing: ($pool | split(":")[0]), role: $role, harness: $h, model: "m",
      cost_usd: (if $cost == "-" then null else ($cost | tonumber) end),
      estimated_cost_usd: null,
      allowance: (if $pts == "-" then null else {pool: $pool, weekly: {points: ($pts | tonumber)}} end) }' >> "$LOG"
}
status() { "$B" status --file "$LOG" --budgets "$BUDGETS" --now "$NOW"; }
# row <jq filter on the row for this pool and scope> : pick a field
field() { status | jq -r --arg p "$1" --arg s "$2" ".[] | select(.pool == \$p and .scope == \$s) | $3"; }

section "1 · Spent against a dollar budget on an API pool"
: > "$LOG"
cat > "$BUDGETS" <<'EOF'
[{"pool":"api:anthropic","usd":10,"period":"run","warn_at":80,
  "caps":[{"role":"coder","usd":4}]}]
EOF
line 2026-11-06T09:00:00Z api:anthropic coder claude-code 3.00 -
line 2026-11-06T09:30:00Z api:anthropic reviewer claude-code 2.50 -
line 2026-11-06T10:00:00Z api:anthropic coder claude-code - -
assert_eq "pool spent is the sum of the costs" "$(field api:anthropic pool .spent)" "5.5"
assert_eq "pool percent of the budget" "$(field api:anthropic pool .percent)" "55"
assert_eq "pool state ok under the threshold" "$(field api:anthropic pool .state)" "ok"
assert_eq "a line with no cost is counted, not called free" "$(field api:anthropic pool .unmeasured)" "1"
assert_eq "a per-role cap is its own row" "$(field api:anthropic role=coder .spent)" "3"
assert_eq "the cap row has its own budget" "$(field api:anthropic role=coder .budget)" "4"
assert_eq "the cap row's state: 75 percent is ok" "$(field api:anthropic role=coder .state)" "ok"

section "2 · Thresholds"
line 2026-11-06T10:30:00Z api:anthropic coder claude-code 0.30 -
assert_eq "80 percent of a cap: warn" "$(field api:anthropic role=coder .state)" "warn"
line 2026-11-06T10:40:00Z api:anthropic reviewer claude-code 4.50 -
assert_eq "at or over the budget: over" "$(field api:anthropic pool .state)" "over"

section "3 · Other pools are not mixed in"
line 2026-11-06T10:50:00Z subscription:anthropic coder claude-code 9.00 -
line 2026-11-06T10:55:00Z api:openai coder codex 9.00 -
assert_eq "a dollar budget ignores other pools' lines" "$(field api:anthropic pool .spent)" "10.3"

section "4 · A subscription budget is allowance percent, from the runs' own points"
: > "$LOG"
cat > "$BUDGETS" <<'EOF'
[{"pool":"subscription:anthropic","percent":30,"period":"run"}]
EOF
line 2026-11-06T09:00:00Z subscription:anthropic coder claude-code 0.50 10
line 2026-11-06T09:30:00Z subscription:anthropic coder claude-code 0.40 8
line 2026-11-06T10:00:00Z subscription:anthropic coder claude-code 0.30 -
assert_eq "spent is the weekly points the runs used" "$(field subscription:anthropic pool .spent)" "18"
assert_eq "unit is percent" "$(field subscription:anthropic pool .unit)" "percent"
assert_eq "60 percent of the budget is ok" "$(field subscription:anthropic pool .state)" "ok"
assert_eq "a run whose points could not be attributed is counted" "$(field subscription:anthropic pool .unmeasured)" "1"

section "5 · A weekly period only counts the last seven days"
: > "$LOG"
cat > "$BUDGETS" <<'EOF'
[{"pool":"api:openai","usd":10,"period":"week"}]
EOF
line 2026-10-20T09:00:00Z api:openai coder codex 7.00 -
line 2026-11-03T09:00:00Z api:openai coder codex 2.00 -
assert_eq "an old line is outside the week" "$(field api:openai pool .spent)" "2"

section "6 · A cap can match adapter and model"
: > "$LOG"
cat > "$BUDGETS" <<'EOF'
[{"pool":"api:openai","usd":10,"caps":[{"adapter":"codex","usd":1},{"adapter":"pi","model":"m","usd":1}]}]
EOF
line 2026-11-06T09:00:00Z api:openai coder codex 0.90 -
line 2026-11-06T09:10:00Z api:openai coder pi 0.20 -
assert_eq "adapter cap scope is named" "$(field api:openai adapter=codex .state)" "warn"
assert_eq "adapter and model together" "$(field api:openai adapter=pi,model=m .spent)" "0.2"

section "7 · A budget on a pool with no lines yet reads zero"
: > "$LOG"
cat > "$BUDGETS" <<'EOF'
[{"pool":"api:openai","usd":10}]
EOF
assert_eq "nothing spent" "$(field api:openai pool .spent)" "0"
assert_eq "state ok" "$(field api:openai pool .state)" "ok"

section "8 · No budgets file: nothing to report"
rm -f "$BUDGETS"
assert_eq "status prints an empty list" "$(status)" "[]"

section "9 · The brief may tighten a budget and never raise it"
cat > "$TMP/wf.json" <<'EOF'
{"name":"t","members":[{"role":"coder","adapter":"codex"}],
 "budgets":[{"pool":"api:openai","usd":10,"period":"week","caps":[{"role":"coder","usd":4}]},
            {"pool":"subscription:anthropic","percent":50}]}
EOF
cat > "$TMP/brief.md" <<'EOF'
---
budget:
  - api:openai 6
  - subscription:anthropic 80
  - api:anthropic 5
---
# Build a thing
EOF
"$B" merge "$TMP/wf.json" "$TMP/brief.md" > "$TMP/eff.json" 2> "$TMP/merge.err"
assert_eq "a lower brief amount tightens" "$(jq -r '.[] | select(.pool=="api:openai") | .usd' "$TMP/eff.json")" "6"
assert_eq "a higher brief amount is not taken" "$(jq -r '.[] | select(.pool=="subscription:anthropic") | .percent' "$TMP/eff.json")" "50"
assert_eq "the workforce's period and caps survive" "$(jq -r '.[] | select(.pool=="api:openai") | .period + "/" + (.caps[0].usd | tostring)' "$TMP/eff.json")" "week/4"
assert_eq "a pool the workforce has no budget for is not added" "$(jq -r 'map(.pool) | join(",")' "$TMP/eff.json")" "api:openai,subscription:anthropic"
assert_eq "the raise is said on stderr" "$(grep -c 'subscription:anthropic.*not raised' "$TMP/merge.err")" "1"
assert_eq "the unbudgeted pool is said on stderr" "$(grep -c 'api:anthropic.*no budget' "$TMP/merge.err")" "1"
"$B" merge "$TMP/wf.json" > "$TMP/eff2.json" 2> /dev/null
assert_eq "no brief: the workforce's budgets as they are" "$(jq -r '.[0].usd' "$TMP/eff2.json")" "10"
cat > "$TMP/nobudget.json" <<'EOF'
{"name":"t","members":[{"role":"coder","adapter":"codex"}]}
EOF
assert_eq "a workforce with no budgets: an empty list" "$("$B" merge "$TMP/nobudget.json" "$TMP/brief.md" 2> /dev/null)" "[]"

section "10 · A warning is written once, as a record in the log"
: > "$LOG"
cat > "$BUDGETS" <<'EOF'
[{"pool":"api:openai","usd":10,"warn_at":80}]
EOF
line 2026-11-06T09:00:00Z api:openai coder codex 5.00 -
"$B" warn --file "$LOG" --budgets "$BUDGETS" --now "$NOW" > "$TMP/w1" 2>&1
assert_eq "under the threshold: silent" "$(wc -c < "$TMP/w1" | tr -d ' ')" "0"
line 2026-11-06T09:30:00Z api:openai coder codex 4.00 -
"$B" warn --file "$LOG" --budgets "$BUDGETS" --now "$NOW" > "$TMP/w2" 2>&1
assert_eq "crossing the threshold: one line, naming pool and amounts" "$(grep -c "api:openai.*[\$]9.00 of [\$]10.00" "$TMP/w2")" "1"
"$B" warn --file "$LOG" --budgets "$BUDGETS" --now "$NOW" > "$TMP/w3" 2>&1
assert_eq "the same state again: silent" "$(wc -c < "$TMP/w3" | tr -d ' ')" "0"
assert_eq "one budget_warning record in the log" "$(jq -c 'select(.record == "budget_warning")' "$LOG" | wc -l | tr -d ' ')" "1"
line 2026-11-06T10:00:00Z api:openai coder codex 2.00 -
"$B" warn --file "$LOG" --budgets "$BUDGETS" --now "$NOW" > "$TMP/w4" 2>&1
assert_eq "going over is a new state: warned again" "$(grep -c 'over' "$TMP/w4")" "1"
assert_eq "the log's usage lines are unchanged by records" "$(jq -c 'select(.record == null)' "$LOG" | wc -l | tr -d ' ')" "3"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All budget checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
