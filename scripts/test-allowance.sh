#!/usr/bin/env bash
# Tests scripts/allowance.sh: the reading record, the difference a Codex or a Claude run made to the
# windows, and above all that a difference is null, with a reason, whenever it cannot be trusted:
# nothing new written by Codex, a window that reset, an unknown reading, a stale Claude copy, or runs
# that overlapped. Needs no Codex, no Claude Code and no allowance: a Codex run is played by writing
# the event Codex would have written, a Claude run by a stub curl that serves the usage endpoint.
#
# Usage: scripts/test-allowance.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
AL="$SCRIPTS_DIR/allowance.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

export CONDUCTOR_DIR="$TMP/c"
export CODEX_SESSIONS_DIR="$TMP/sessions"
export CODEX_AUTH_FILE="$TMP/auth.json"   # the test's own sign-in, never ~/.codex
printf '{"auth_mode":"chatgpt"}\n' > "$CODEX_AUTH_FILE"
export CODEX_USAGE_NOW=1793790000        # between the five-hour window opening (1793782000) and its reset
# Claude's own sign-in and state are the test's, never ~/.claude, and no API key is in the environment.
export CLAUDE_CREDENTIALS_FILE="$SCRIPTS_DIR/../tests/claude-usage/credentials.json"
export CLAUDE_JSON_FILE="$TMP/no-claude.json"
export CLAUDE_STATUSLINE_FILE="$TMP/no-claude-statusline.json"
export CLAUDE_USAGE_NOW=1793865600       # 2026-11-05 08:00 UTC, before the Claude windows reset (09:10, and 11-07 04:00)
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
LOG="$CONDUCTOR_DIR/usage.jsonl"
RUNS="$CONDUCTOR_DIR/allowance"
P5=1793800000; P7=1794059735

mkdir -p "$TMP/bin" "$CONDUCTOR_DIR"
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "list-windows" ]]; then
  [[ -z "${STUB_TMUX_FAIL:-}" ]] || exit 1
  printf '%s\n' ${STUB_WINDOWS:-}
fi
STUB
chmod +x "$TMP/bin/tmux"
# A curl that never reaches a network: it answers the usage endpoint with $TMP/claude-body.json.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
[[ "${STUB_CURL_CODE:-200}" != 000 ]] || exit 7
[[ -z "$out" ]] || cp "$STUB_CLAUDE_BODY" "$out"
printf '%s' "${STUB_CURL_CODE:-200}"
STUB
chmod +x "$TMP/bin/curl"
export STUB_CLAUDE_BODY="$TMP/claude-body.json"
cp "$SCRIPTS_DIR/../tests/claude-usage/endpoint.json" "$STUB_CLAUDE_BODY"   # until a section serves its own
export PATH="$TMP/bin:$PATH"

SEQ=0
# codex_wrote <used 5h> <used weekly> [resets 5h] [resets weekly]: what Codex writes at the end of a
# turn, in a new session file, so it is the newest
codex_wrote() {
  SEQ=$(( SEQ + 1 ))
  local d="$CODEX_SESSIONS_DIR/2026/11/04" f ts
  mkdir -p "$d"; f="$d/rollout-$SEQ.jsonl"
  ts="2026-11-04T05:$(printf '%02d' "$SEQ"):00.000Z"
  jq -nc '{timestamp: "2026-11-04T05:00:00.000Z", type: "session_meta", payload: {cwd: "/x", cli_version: "0.166.0"}}' > "$f"
  jq -nc --arg ts "$ts" --argjson p "$1" --argjson s "$2" --argjson pr "${3:-$P5}" --argjson sr "${4:-$P7}" '
    { timestamp: $ts, type: "event_msg", payload: { type: "token_count", info: {},
      rate_limits: { limit_id: "codex", plan_type: "plus",
        primary:   { used_percent: $p, window_minutes: 300,   resets_at: $pr },
        secondary: { used_percent: $s, window_minutes: 10080, resets_at: $sr } } } }' >> "$f"
  touch -d "@$(( 1793700000 + SEQ ))" "$f"
}
reset() { rm -rf "$CONDUCTOR_DIR/usage.jsonl" "$RUNS" "$CODEX_SESSIONS_DIR"; SEQ=0; }
lines() { wc -l < "$LOG" 2> /dev/null | tr -d ' ' || echo 0; }
j() { jq -r "$1" <<< "$OUT"; }
end_run() { OUT="$("$AL" end "$1")"; }
files() { find "$RUNS" -type f -name '*.json' 2> /dev/null | wc -l | tr -d ' '; }

section "1 · A reading is a record, not an attempt"
reset; codex_wrote 10 20
OUT="$("$AL" reading swarm-start)"
assert_eq "it prints the reading" "$(j '[.five_hour.used_percent, .weekly.used_percent] | join(" ")')" "10 20"
assert_eq "and appends one line" "$(lines)" "1"
L="$(tail -1 "$LOG")"
assert_eq "the record kind, the pool and the moment" "$(jq -r '[.record, .pool, .moment] | join(" ")' <<< "$L")" "allowance subscription:openai swarm-start"
assert_eq "when it was taken" "$(jq -r '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <<< "$L")" "true"
assert_eq "what the reader found" "$(jq -r '[.plan_type, .five_hour.used_percent, .weekly.resets_at] | join(" ")' <<< "$L")" "plus 10 $P7"
assert_eq "without the path of the session file" "$(jq -r 'has("source")' <<< "$L")" "false"
reset
OUT="$("$AL" reading swarm-start)"
assert_eq "with nothing to read, still a record, and both windows unknown" "$(jq -r '[.record, .five_hour.state, .weekly.state] | join(" ")' "$LOG")" "allowance unknown unknown"

section "2 · One run, alone: its difference is its own"
reset; codex_wrote 10 20
"$AL" begin run1 --kind dispatch --pid $$
assert_eq "the run is noted" "$(files)" "1"
codex_wrote 12.5 20.5
end_run run1
assert_eq "the five-hour window rose by" "$(j .five_hour.points)" "2.5"
assert_eq "the weekly window rose by" "$(j .weekly.points)" "0.5"
assert_eq "no reason, because nothing is missing" "$(j '[.five_hour.reason, .weekly.reason] | map(tostring) | join(" ")')" "null null"
assert_eq "attributed to the run" "$(j '[.overlap, .attributed_to] | map(tostring) | join(" ")')" "false run"
assert_eq "the pool" "$(j .pool)" "subscription:openai"
assert_eq "both snapshots are in it" "$(j '[.before_snapshot_at, .after_snapshot_at] | join(" ")')" "2026-11-04T05:01:00.000Z 2026-11-04T05:02:00.000Z"
assert_eq "the run is forgotten" "$(files)" "0"
assert_eq "both readings were appended" "$(jq -r 'select(.record == "allowance") | .moment' "$LOG" | tr '\n' ' ')" "run-begin:run1 run-end:run1 "

section "3 · A difference that cannot be trusted is null, with a reason"
reset; codex_wrote 10 20
"$AL" begin run2 --kind dispatch --pid $$
end_run run2
assert_eq "Codex wrote nothing new: null, not zero" "$(j '.five_hour.points | tostring')" "null"
assert_eq "and says why" "$(j .five_hour.reason)" "Codex wrote nothing new since the run began"
reset; codex_wrote 10 20
"$AL" begin run3 --kind dispatch --pid $$
codex_wrote 1 20.5 $(( P5 + 18000 ))
end_run run3
assert_eq "the five-hour window reset during the run: null" "$(j '.five_hour | [(.points | tostring), .reason] | join(" / ")')" "null / the window reset during the run"
assert_eq "the weekly window is still worked out" "$(j .weekly.points)" "0.5"
reset; codex_wrote 10 20
"$AL" begin run4 --kind dispatch --pid $$
codex_wrote 11 20 $(( P5 + 3 ))
end_run run4
assert_eq "resets_at moving by a few seconds is the same window" "$(j .five_hour.points)" "1"
reset; codex_wrote 10 20
"$AL" begin run5 --kind dispatch --pid $$
codex_wrote 4 20
end_run run5
assert_eq "a percentage that fell is not a negative difference" "$(j '.five_hour | [(.points | tostring), .reason] | join(" / ")')" "null / the percentage fell"
reset
"$AL" begin run6 --kind dispatch --pid $$
codex_wrote 4 20
end_run run6
assert_eq "no reading before the run: null" "$(j '.five_hour.points | tostring')" "null"
case "$(j .five_hour.reason)" in "the reading before the run was unknown: "*) ok "and says it was the reading before" ;; *) fail "reason: $(j .five_hour.reason)" ;; esac
reset; codex_wrote 10 20
"$AL" begin run7 --kind dispatch --pid $$
rm -rf "$CODEX_SESSIONS_DIR"
end_run run7
case "$(j .weekly.reason)" in "the reading after the run was unknown: "*) ok "no reading after the run says it was the one after" ;; *) fail "reason: $(j .weekly.reason)" ;; esac
reset; codex_wrote 10 20
OUT="$("$AL" end never-began)"
assert_eq "an end with no begin: null" "$OUT" "null"
assert_eq "but the reading is still taken" "$(jq -r 'select(.record == "allowance") | .moment' "$LOG")" "run-end:never-began"

section "4 · Runs that overlap: the difference belongs to the batch"
reset; codex_wrote 10 20
"$AL" begin dispatch-a --kind dispatch --pid $$
STUB_WINDOWS="coder-0001" "$AL" begin worker-b --kind worker --window coder-0001
assert_eq "two live runs" "$(files)" "2"
assert_eq "both are marked" "$(jq -s -r 'map(.overlap) | join(" ")' "$RUNS"/*.json)" "true true"
codex_wrote 15 22
STUB_WINDOWS="coder-0001" end_run dispatch-a
assert_eq "the first to end: attributed to the batch" "$(j '[.overlap, .attributed_to, (.five_hour.points | tostring)] | join(" ")')" "true batch null"
assert_eq "and says why" "$(j .five_hour.reason)" "runs overlapped; the difference belongs to the batch"
STUB_WINDOWS="" end_run worker-b
assert_eq "the other too, although it is now alone and its window is gone" "$(j '[.overlap, .attributed_to] | join(" ")')" "true batch"
assert_eq "the batch change is in the readings the runs appended" \
  "$(jq -r 'select(.record == "allowance") | .five_hour.used_percent | tostring' "$LOG" | tr '\n' ' ')" "10 10 15 15 "
reset; codex_wrote 10 20
"$AL" begin run-c --kind dispatch --pid $$
codex_wrote 11 20
end_run run-c
"$AL" begin run-d --kind dispatch --pid $$
codex_wrote 12 20
end_run run-d
assert_eq "runs one after the other are not overlapping" "$(j '[.overlap, (.five_hour.points | tostring)] | join(" ")')" "false 1"

section "5 · A run that never ended does not make the next one overlap"
reset; codex_wrote 10 20
mkdir -p "$RUNS"
jq -nc '{run: "crashed", kind: "dispatch", pid: 999999, window: null, overlap: false, before: {}}' > "$RUNS/crashed.json"
"$AL" begin run-e --kind dispatch --pid $$
assert_eq "the dead dispatch is forgotten" "$(files)" "1"
codex_wrote 11 20
end_run run-e
assert_eq "and the run is attributed" "$(j '[.overlap, (.five_hour.points | tostring)] | join(" ")')" "false 1"
reset; codex_wrote 10 20
"$AL" begin w-old --kind worker --window coder-0009
STUB_WINDOWS="" "$AL" begin run-f --kind dispatch --pid $$
assert_eq "a worker whose window is gone is forgotten too" "$(files)" "1"
reset; codex_wrote 10 20
"$AL" begin w-doubt --kind worker --window coder-0009
STUB_TMUX_FAIL=1 "$AL" begin run-g --kind dispatch --pid $$
assert_eq "if tmux cannot say, the worker is taken as live, and the run is not attributed" "$(jq -s -r 'map(.overlap) | join(" ")' "$RUNS"/*.json)" "true true"

section "6 · A worker whose window has already closed can still end"
reset; codex_wrote 10 20
STUB_WINDOWS="coder-0002" "$AL" begin w1 --kind worker --window coder-0002
codex_wrote 13 21
STUB_WINDOWS="" end_run w1
assert_eq "its difference is worked out, though its window is gone" "$(j '[.overlap, (.five_hour.points | tostring)] | join(" ")')" "false 3"

section "6b · A reading at swarm start, if Codex is in the workforce"
reset; codex_wrote 10 20
printf '{"members":[{"role":"conductor","adapter":"claude-code"},{"role":"reviewer","adapter":"codex"}]}' > "$TMP/wf-codex.json"
printf '{"members":[{"role":"coder","adapter":"pi"}]}' > "$TMP/wf-other.json"
"$AL" start "$TMP/wf-other.json"
assert_eq "no Codex or Claude member: nothing is read" "$(lines 2> /dev/null || echo 0)" "0"
"$AL" start "$TMP/wf-codex.json" --vendor codex
assert_eq "a Codex member: one reading, taken at swarm start" "$(jq -r '[.record, .pool, .moment] | join(" ")' "$LOG")" "allowance subscription:openai swarm-start"
reset; codex_wrote 10 20
"$AL" start "$TMP/wf-codex.json"
assert_eq "with no --vendor, a reading for each vendor the workforce uses" "$(jq -r '.pool' "$LOG" | sort | tr '\n' ' ')" "subscription:anthropic subscription:openai "
RC=0; "$AL" start "$TMP/missing.json" || RC=$?
assert_eq "a workforce that cannot be read is not an error" "$RC" "0"

section "6c · On an API key there is no allowance to measure"
reset; codex_wrote 10 20
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$CODEX_AUTH_FILE"
"$AL" start "$TMP/wf-codex.json" --vendor codex
assert_eq "start takes no reading" "$(lines 2> /dev/null || echo 0)" "0"
"$AL" start "$TMP/wf-codex.json"
assert_eq "with no --vendor only the Claude reading is taken: the Codex one does not apply" "$(jq -r '.pool' "$LOG" | tr '\n' ' ')" "subscription:anthropic "
reset; codex_wrote 10 20
"$AL" begin k1 --kind worker --window k1 > /dev/null
assert_eq "begin holds no run" "$(files)" "0"
end_run k1
assert_eq "so end has nothing to match: null" "$OUT" "null"
assert_eq "and nothing was written to the log" "$(lines 2> /dev/null || echo 0)" "0"
printf '{"auth_mode":"chatgpt"}\n' > "$CODEX_AUTH_FILE"
reset; codex_wrote 10 20
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$CODEX_AUTH_FILE"
"$AL" begin k0 --kind worker --window k0 > /dev/null
printf '{"auth_mode":"chatgpt"}\n' > "$CODEX_AUTH_FILE"   # the sign-in changes before the run ends
end_run k0
assert_eq "the decision made at begin stands: null, though the sign-in has changed" "$OUT" "null"
assert_eq "no reading was taken for it" "$(lines 2> /dev/null || echo 0)" "0"
assert_eq "and the decision's marker is gone" "$(find "$RUNS" -type f 2> /dev/null | wc -l | tr -d ' ')" "0"
"$AL" begin k2 --kind worker --window k2 > /dev/null
assert_eq "back on a subscription, begin holds a run" "$(files)" "1"
rm -f "$CODEX_AUTH_FILE"
"$AL" begin k3 --kind worker --window k3 > /dev/null
assert_eq "when the sign-in cannot be read, doubt is not a reason to skip: it holds a run" "$([[ -e "$RUNS/k3.json" ]] && echo held || echo none)" "held"
printf '{"auth_mode":"chatgpt"}\n' > "$CODEX_AUTH_FILE"

section "6d · A Claude run: the endpoint, before and after"
# claude_serves <five %> <week %> <Fable %> <spent, minor units> [five-hour reset] [week reset]: what the
# usage endpoint answers from now on
C5="2026-11-05T09:10:00.240293+00:00"; C7="2026-11-07T04:00:00.240316+00:00"
claude_serves() {
  jq -nc --argjson f "$1" --argjson w "$2" --argjson m "$3" --argjson spent "$4" --arg r5 "${5:-$C5}" --arg r7 "${6:-$C7}" '
    { five_hour: { utilization: $f, resets_at: $r5 }, seven_day: { utilization: $w, resets_at: $r7 },
      limits: [ { kind: "weekly_scoped", percent: $m, scope: { model: { display_name: "Fable" } } } ],
      extra_usage: { is_enabled: true, currency: "USD", decimal_places: 2 },
      spend: { used: { amount_minor: $spent }, limit: { amount_minor: 10000 } } }' > "$STUB_CLAUDE_BODY"
}
reset; claude_serves 10 20 5 0
OUT="$("$AL" reading swarm-start --vendor claude)"
assert_eq "a reading from the Claude reader" "$(j '[.source, .five_hour.used_percent, .weekly.used_percent] | join(" ")')" "endpoint 10 20"
L="$(tail -1 "$LOG")"
assert_eq "the record is in the Anthropic pool" "$(jq -r '[.record, .pool, .moment] | join(" ")' <<< "$L")" "allowance subscription:anthropic swarm-start"
assert_eq "it keeps the source, which is a word and not a path" "$(jq -r '.source' <<< "$L")" "endpoint"
reset; claude_serves 10 20 5 0
"$AL" begin c1 --kind dispatch --pid $$ --vendor claude
assert_eq "the run is noted, with its vendor" "$(jq -r '.vendor' "$RUNS/c1.json")" "claude"
claude_serves 12.5 20.5 7 425
end_run c1
assert_eq "no --vendor on end: the run's own is used, so the pool" "$(j .pool)" "subscription:anthropic"
assert_eq "five-hour points" "$(j .five_hour.points)" "2.5"
assert_eq "weekly points" "$(j .weekly.points)" "0.5"
assert_eq "per-model points, by name" "$(j '.weekly_by_model.models[0] | [.model, (.points | tostring)] | join(" ")')" "Fable 2"
assert_eq "credits drawn, in dollars" "$(j '.credits.dollars')" "4.25"
assert_eq "attributed to the run" "$(j '[.overlap, .attributed_to] | map(tostring) | join(" ")')" "false run"
assert_eq "both readings were appended, in the Anthropic pool" "$(jq -r 'select(.record == "allowance") | "\(.pool) \(.moment)"' "$LOG" | tr '\n' ',')" "subscription:anthropic run-begin:c1,subscription:anthropic run-end:c1,"
assert_eq "the run is forgotten" "$(files)" "0"

reset; claude_serves 10 20 5 0
"$AL" begin c2 --kind dispatch --pid $$ --vendor claude
end_run c2
assert_eq "an unchanged endpoint is a real zero, not unknown" "$(j '[(.five_hour.points | tostring), (.credits.dollars | tostring)] | join(" ")')" "0 0"

section "6e · A Claude difference that cannot be trusted is null, with a reason"
reset; claude_serves 10 20 5 0
"$AL" begin c3 --kind dispatch --pid $$ --vendor claude
claude_serves 3 20 5 0 "2026-11-05T14:10:00.1+00:00"
end_run c3
assert_eq "the five-hour window reset during the run: null" "$(j '.five_hour | [(.points | tostring), .reason] | join(" / ")')" "null / the window reset during the run"
assert_eq "the weekly window is still worked out" "$(j .weekly.points)" "0"
reset; claude_serves 10 20 5 0
"$AL" begin c4 --kind dispatch --pid $$ --vendor claude
claude_serves 10 20 5 0 "$C5" "2026-11-14T04:00:00.1+00:00"
end_run c4
assert_eq "the week reset during the run: the per-model difference is null too" "$(j '.weekly_by_model | [.reason, (.models | length | tostring)] | join(" / ")')" "the window reset during the run / 0"
reset; claude_serves 10 20 5 300
"$AL" begin c5 --kind dispatch --pid $$ --vendor claude
claude_serves 10 20 5 100
end_run c5
assert_eq "credits that fell (a new month): null" "$(j '.credits | [(.dollars | tostring), .reason] | join(" / ")')" "null / the amount fell"
reset; claude_serves 10 20 5 0
"$AL" begin c6 --kind dispatch --pid $$ --vendor claude
claude_serves 10 20 5 0
STUB_CURL_CODE=401 end_run c6
assert_eq "the reading after the run was unknown: null, and the reason carries why" \
  "$(j '.five_hour | [(.points | tostring), (.reason | startswith("the reading after the run was unknown: the endpoint refused the token (401)") | tostring)] | join(" / ")')" "null / true"
assert_eq "so is every other figure" "$(j '[(.weekly.points | tostring), (.weekly_by_model.models | length | tostring), (.credits.dollars | tostring)] | join(" ")')" "null 0 null"
reset
STUB_CURL_CODE=401 "$AL" begin c7 --kind dispatch --pid $$ --vendor claude
claude_serves 12 21 5 0
end_run c7
assert_eq "no reading before the run: null, and says so" "$(j '.five_hour.reason | startswith("the reading before the run was unknown: ")')" "true"
reset; claude_serves 10 20 5 0
"$AL" begin c8 --kind dispatch --pid $$ --vendor claude
claude_serves 11 21 6 100
rm -f "$CLAUDE_JSON_FILE"
cp "$SCRIPTS_DIR/../tests/claude-usage/claude.json" "$CLAUDE_JSON_FILE"
STUB_CURL_CODE=401 end_run c8
rm -f "$CLAUDE_JSON_FILE"
assert_eq "an end read from the stale copy is not subtracted: it is not an endpoint reading" "$(j '.five_hour.points | tostring')" "null"

reset; claude_serves 10 20 5 0
"$AL" begin c9 --kind dispatch --pid $$ --vendor claude
RC=0; "$AL" end c9 --vendor codex > /dev/null 2>&1 || RC=$?
assert_eq "an end whose --vendor disagrees with the run's: exit 1" "$RC" "1"
assert_eq "and the run is left as it was" "$(files)" "1"
assert_eq "an end that agrees, or says nothing, is fine" "$("$AL" end c9 --vendor claude | jq -r .pool)" "subscription:anthropic"

section "6f · Runs overlap within a vendor, not across vendors"
reset; codex_wrote 10 20; claude_serves 10 20 5 0
"$AL" begin x-codex --kind dispatch --pid $$
"$AL" begin x-claude --kind dispatch --pid $$ --vendor claude
assert_eq "a Codex run and a Claude run are two pools: neither is marked" "$(jq -s -r 'map(.overlap) | join(" ")' "$RUNS"/*.json)" "false false"
"$AL" begin x-claude2 --kind dispatch --pid $$ --vendor claude
assert_eq "a second Claude run: the two Claude runs overlap" "$(for r in x-claude x-claude2 x-codex; do jq -r '.overlap' "$RUNS/$r.json"; done | tr '\n' ' ')" "true true false "
claude_serves 15 25 8 0
end_run x-claude
assert_eq "an overlapping Claude run: batch, with every figure null" \
  "$(j '[.attributed_to, (.five_hour.points | tostring), (.weekly_by_model.models | length | tostring), (.credits.dollars | tostring)] | join(" ")')" "batch null 0 null"
assert_eq "and the reason" "$(j .credits.reason)" "runs overlapped; the difference belongs to the batch"

section "6g · Swarm start and the API key, for Claude"
reset
printf '{"members":[{"role":"conductor","adapter":"claude-code"},{"role":"reviewer","adapter":"codex"}]}' > "$TMP/wf-both.json"
printf '{"members":[{"role":"reviewer","adapter":"codex"},{"role":"coder","adapter":"pi"}]}' > "$TMP/wf-nocl.json"
claude_serves 10 20 5 0
"$AL" start "$TMP/wf-nocl.json" --vendor claude
assert_eq "no claude-code member: nothing is read" "$(lines 2> /dev/null || echo 0)" "0"
"$AL" start "$TMP/wf-both.json" --vendor claude
assert_eq "a claude-code member: one reading, in the Anthropic pool" "$(jq -r '[.pool, .moment] | join(" ")' "$LOG")" "subscription:anthropic swarm-start"
reset
ANTHROPIC_API_KEY=sk-test-not-real "$AL" start "$TMP/wf-both.json" --vendor claude
assert_eq "on an API key, start takes no Claude reading" "$(lines 2> /dev/null || echo 0)" "0"
ANTHROPIC_API_KEY=sk-test-not-real "$AL" begin k9 --kind worker --window k9 --vendor claude > /dev/null
assert_eq "begin holds no run" "$(files)" "0"
OUT="$(ANTHROPIC_API_KEY=sk-test-not-real "$AL" end k9)"
assert_eq "and end has nothing to match: null, with no reading" "$OUT $(lines 2> /dev/null || echo 0)" "null 0"

section "6h · Which adapter draws on which allowance"
assert_eq "codex" "$("$AL" vendor codex)" "codex"
assert_eq "claude-code is the claude vendor" "$("$AL" vendor claude-code)" "claude"
RC=0; OUT="$("$AL" vendor pi)" || RC=$?
assert_eq "pi has none: nothing printed, exit 1" "$RC ${OUT:-empty}" "1 empty"

section "7 · Arguments"
RC=0; "$AL" bogus > /dev/null 2>&1 || RC=$?
assert_eq "an unknown command: exit 1" "$RC" "1"
RC=0; "$AL" begin r --kind nonsense > /dev/null 2>&1 || RC=$?
assert_eq "a kind that is not dispatch or worker: exit 1" "$RC" "1"
RC=0; "$AL" begin r --kind dispatch > /dev/null 2>&1 || RC=$?
assert_eq "a dispatch with no pid: exit 1" "$RC" "1"
RC=0; "$AL" begin r --kind worker > /dev/null 2>&1 || RC=$?
assert_eq "a worker with no window: exit 1" "$RC" "1"
RC=0; "$AL" reading x --vendor gemini > /dev/null 2>&1 || RC=$?
assert_eq "a vendor that is not codex or claude: exit 1" "$RC" "1"
RC=0; "$AL" --help > /dev/null 2>&1 || RC=$?
assert_eq "--help: exit 0" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
