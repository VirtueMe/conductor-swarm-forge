#!/usr/bin/env bash
# Tests scripts/worker-usage.sh against the trimmed real sessions in tests/worker-usage/ (see
# docs/worker-usage-sources.md): a spawn record, a line per harness with role, task, model and
# tokens, an explicit unknown line when nothing can be read, early and hard-killed workers, and
# a sweep of workers whose window is gone. Needs no model, and no real tmux.
#
# Usage: scripts/test-worker-usage.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WU="$SCRIPTS_DIR/worker-usage.sh"
FX="$SCRIPTS_DIR/../tests/worker-usage"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Claude Code's sign-in and state are the test's own, never ~/.claude: no test reaches the usage endpoint.
export CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json" CLAUDE_JSON_FILE="$TMP/no-claude.json" CLAUDE_STATUSLINE_FILE="$TMP/no-claude-statusline.json"

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }

export CONDUCTOR_DIR="$TMP/c"
export CLAUDE_PROJECTS_DIR="$TMP/claude" CODEX_SESSIONS_DIR="$TMP/codex" PI_SESSIONS_DIR="$TMP/pi"
export CODEX_USAGE_NOW=1793780000   # before the five-hour window of the Codex fixture resets (1793788907)
LOG="$CONDUCTOR_DIR/usage.jsonl"

# tmux is a stub that lists the windows named in $STUB_WINDOWS
mkdir -p "$TMP/bin" "$CONDUCTOR_DIR"
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [[ "$1" == "list-windows" ]]; then
  [[ -z "${STUB_TMUX_FAIL:-}" ]] || exit 1
  printf '%s\n' ${STUB_WINDOWS:-}
fi
STUB
chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH"

# The fixtures were taken in this worktree; a spawn record names the same directory
CWD="$(jq -rn 'first(inputs | select(.type == "session") | .cwd)' "$FX/pi/session.jsonl")"

put() { # <adapter> <fixture> <name> : place a session file where the harness keeps it
  local dir
  case "$1" in
    claude-code) dir="$CLAUDE_PROJECTS_DIR/proj" ;;
    codex)       dir="$CODEX_SESSIONS_DIR/2026/11/04" ;;
    pi)          dir="$PI_SESSIONS_DIR/--proj--" ;;
  esac
  mkdir -p "$dir"; cp "$2" "$dir/$3"; echo "$dir/$3"
}
reset() { rm -rf "$CONDUCTOR_DIR/workers" "$CONDUCTOR_DIR/allowance" "$LOG" "$CLAUDE_PROJECTS_DIR" "$CODEX_SESSIONS_DIR" "$PI_SESSIONS_DIR"; }
spawn() { "$WU" spawned "$1" "$2" "$3" "$CWD" '{"model":"m"}'; }
last() { jq -r "select(.record == null) | $1" "$LOG" | tail -1; }   # the last attempt, not a record about one
lines() { { jq -c 'select(.record == null)' "$LOG" 2> /dev/null || true; } | wc -l | tr -d ' '; }

section "1 · The spawn record"
reset
spawn 0001 coder pi
REC="$CONDUCTOR_DIR/workers/coder-0001.json"
assert_eq "one record per role and task" "$(find "$CONDUCTOR_DIR/workers" -type f -printf "%f\n")" "coder-0001.json"
assert_eq "it names the role, the harness and the worktree" \
  "$(jq -r '[.task, .role, .adapter, .cwd] | join(" ")' "$REC")" "0001 coder pi $CWD"
assert_eq "and when it started, in UTC and as a number" \
  "$(jq -r '(.started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.started_epoch | type == "number")' "$REC")" "true"
assert_eq "and the params, kept as they came" "$(jq -c .params "$REC")" '{"model":"m"}'

section "2 · pi: role, task, model, tokens and its own cost"
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
"$WU" read 0001
assert_eq "one line" "$(lines)" "1"
assert_eq "the event names the task and the worker" "$(last .event)" "0001/worker-coder"
assert_eq "the task" "$(last .task)" "0001"
assert_eq "the role" "$(last .role)" "coder"
assert_eq "the harness" "$(last .harness)" "pi"
assert_eq "the model that answered" "$(last .model)" "claude-haiku-4-5"
assert_eq "tokens: input" "$(last .input_tokens)" "2288"
assert_eq "tokens: output" "$(last .output_tokens)" "55"
assert_eq "tokens: cache read and write" "$(last '[.cache_read_tokens, .cache_write_tokens] | join(",")')" "0,0"
assert_eq "Pi's own cost is the reported cost" "$(last .cost_usd)" "0.002563"
assert_eq "and the source says so" "$(last .cost_source)" "reported"
assert_eq "the estimate from the price table sits beside it" "$(last .estimated_cost_usd)" "0.002563"
assert_eq "usage was reported" "$(last .usage)" "reported"
assert_eq "it finished" "$(last .outcome)" "finished"
assert_eq "a worker has no exit status or attempt" "$(last '[.rc, .attempt] | map(tostring) | join(",")')" "null,null"
assert_eq "the time is in the line" "$(last '.duration_s | type')" "number"
assert_eq "the record is gone once read" "$(find "$CONDUCTOR_DIR/workers" -type f | wc -l | tr -d ' ')" "0"
assert_eq "a worker on another harness has no allowance" "$(last '.allowance | tostring')" "null"

section "3 · claude-code: the cost the process wrote on exit"
reset; spawn 0002 reviewer claude-code
put claude-code "$FX/claude-code/exited.jsonl" a.jsonl > /dev/null
"$WU" read 0002
assert_eq "the role is the worker's" "$(last .role)" "reviewer"
assert_eq "the model" "$(last .model)" "claude-haiku-4-5-20251001"
assert_eq "the duplicated message is counted once (input, output)" "$(last '[.input_tokens, .output_tokens] | join(",")')" "10,54"
assert_eq "cache read and write" "$(last '[.cache_read_tokens, .cache_write_tokens] | join(",")')" "27430,10056"
assert_eq "the cost the process reported" "$(last .cost_usd)" "0.023135"
assert_eq "reported" "$(last .cost_source)" "reported"
assert_eq "the write was at the 1-hour rate" "$(last .cache_write_1h_tokens)" "10056"
assert_eq "so the table's estimate is the reported cost" "$(last '.estimated_cost_usd == .cost_usd')" "true"

section "4 · claude-code killed with SIGKILL: tokens, but no cost to report"
reset; spawn 0003 coder claude-code
put claude-code "$FX/claude-code/sigkilled.jsonl" a.jsonl > /dev/null
"$WU" read 0003 --outcome interrupted
assert_eq "the tokens of the run are there" "$(last '[.input_tokens, .output_tokens, .cache_write_tokens] | join(",")')" "10,47,5950"
assert_eq "no cost_usd is invented" "$(last .cost_usd)" "null"
assert_eq "the estimate stands in, and says so" "$(last .cost_source)" "estimated"
assert_eq "the outcome is what was asked for" "$(last .outcome)" "interrupted"

section "5 · codex: tokens, and a model the price table does not know"
reset; spawn 0004 validator codex
put codex "$FX/codex/rollout.jsonl" rollout-a.jsonl > /dev/null
"$WU" read 0004
assert_eq "the model comes from turn_context" "$(last .model)" "gpt-6.1-sol"
assert_eq "input without the cached part" "$(last .input_tokens)" "3317"
assert_eq "cache read" "$(last .cache_read_tokens)" "12032"
assert_eq "output" "$(last .output_tokens)" "5"
assert_eq "no cost" "$(last .cost_usd)" "null"
assert_eq "gpt-6.1-sol is priced: 3317*2 + 12032*0.1 + 5*10 per million" "$(last .estimated_cost_usd)" "0.0078872"
assert_eq "so the cost is estimated, not reported" "$(last .cost_source)" "estimated"
assert_eq "but the tokens were read" "$(last .usage)" "reported"

section "6 · Nothing readable is an explicit unknown, never zero"
reset; spawn 0005 coder pi
"$WU" read 0005
assert_eq "a line is still written" "$(lines)" "1"
assert_eq "usage none" "$(last .usage)" "none"
assert_eq "tokens are null" "$(last '[.input_tokens, .output_tokens, .model] | map(tostring) | join(",")')" "null,null,null"
assert_eq "cost_source unknown" "$(last .cost_source)" "unknown"
assert_eq "the role and harness are still there" "$(last '[.role, .harness] | join(",")')" "coder,pi"
reset; spawn 0006 coder mystery-harness
"$WU" read 0006
assert_eq "a harness with no reader gets the same line" "$(last '[.harness, .usage, .cost_source, (.input_tokens | tostring)] | join(",")')" "mystery-harness,none,unknown,null"
reset; spawn 0007 coder pi
put pi <(printf '{"type":"session","cwd":"%s"}\n{"type":"message","message":{"role":"user"}}\n' "$CWD") a.jsonl > /dev/null
"$WU" read 0007 --outcome interrupted
assert_eq "a worker closed before the model replied is unknown, not zero" "$(last '[.usage, (.input_tokens | tostring), .cost_source] | join(",")')" "none,null,unknown"

section "7 · Which sessions count"
reset; spawn 0008 coder pi
old="$(put pi "$FX/pi/session.jsonl" old.jsonl)"; touch -d '2 days ago' "$old"
"$WU" read 0008
assert_eq "a session older than the spawn is not this worker's" "$(last .usage)" "none"
reset; spawn 0009 coder pi
sed 's#"cwd":"[^"]*"#"cwd":"/some/other/worktree"#' "$FX/pi/session.jsonl" > "$TMP/other.jsonl"
put pi "$TMP/other.jsonl" other.jsonl > /dev/null
"$WU" read 0009
assert_eq "another worktree's session is not either" "$(last .usage)" "none"
reset; spawn 0010 coder pi
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
put pi "$FX/pi/session.jsonl" b.jsonl > /dev/null
"$WU" read 0010
assert_eq "two sessions in one worktree are added up (input)" "$(last .input_tokens)" "4576"
assert_eq "and so is the cost" "$(last .cost_usd)" "0.005126"
reset; spawn 0011 coder claude-code
put claude-code "$FX/claude-code/exited.jsonl" a.jsonl > /dev/null
put claude-code "$FX/claude-code/sigkilled.jsonl" b.jsonl > /dev/null
"$WU" read 0011
assert_eq "a cost is only reported if every session has one" "$(last .cost_usd)" "null"
assert_eq "while the tokens are all counted" "$(last .output_tokens)" "101"

section "7b · Codex sessions are looked for where Codex keeps them"
reset; spawn 0016 validator codex
mkdir -p "$TMP/home/sessions/2026/11/04"; cp "$FX/codex/rollout.jsonl" "$TMP/home/sessions/2026/11/04/rollout-a.jsonl"
( unset CODEX_SESSIONS_DIR; CODEX_HOME="$TMP/home" "$WU" read 0016 )
assert_eq "CODEX_HOME locates the sessions, as codex-usage.sh does" "$(last .usage)" "reported"

section "7c · A Codex worker's line carries what it used of the allowance"
reset
old="$(put codex "$FX/codex/rollout.jsonl" rollout-old.jsonl)"; touch -d '2 hours ago' "$old"
spawn 0040 validator codex
assert_eq "the spawn took the reading the run is measured from" "$(jq -r 'select(.record == "allowance") | .moment' "$LOG")" "run-begin:worker:validator-0040"
# Codex then writes the worker's session, with the five-hour window 3 points further on
put codex <(jq -c 'if .payload.type == "token_count" then .timestamp = "2026-11-04T07:00:00.000Z" | .payload.rate_limits.primary.used_percent = 3.0 else . end' "$FX/codex/rollout.jsonl") rollout-new.jsonl > /dev/null
STUB_WINDOWS="" "$WU" read 0040
assert_eq "the tokens are read as before" "$(last '[.harness, .input_tokens, .usage] | map(tostring) | join(",")')" "codex,3317,reported"
assert_eq "the five-hour window rose by 3 points, attributed to the run" "$(last '.allowance | [(.five_hour.points | tostring), .attributed_to] | join(" ")')" "3 run"
assert_eq "the weekly window did not move, which is a number, not an unknown" "$(last '.allowance.weekly.points | tostring')" "0"
assert_eq "both readings are in the log, apart from the attempt" "$(jq -r 'select(.record == "allowance") | .moment' "$LOG" | tr '\n' ' ')" "run-begin:worker:validator-0040 run-end:worker:validator-0040 "
assert_eq "and the run is forgotten" "$(find "$CONDUCTOR_DIR/allowance" -type f | wc -l | tr -d ' ')" "0"
reset
old="$(put codex "$FX/codex/rollout.jsonl" rollout-old.jsonl)"; touch -d '2 hours ago' "$old"
STUB_WINDOWS="coder-0041 reviewer-0042" spawn 0041 coder codex
STUB_WINDOWS="coder-0041 reviewer-0042" spawn 0042 reviewer codex
put codex <(jq -c 'if .payload.type == "token_count" then .timestamp = "2026-11-04T07:00:00.000Z" | .payload.rate_limits.primary.used_percent = 3.0 else . end' "$FX/codex/rollout.jsonl") rollout-new.jsonl > /dev/null
STUB_WINDOWS="reviewer-0042" "$WU" read 0041
assert_eq "two Codex workers at once: the difference belongs to the batch" "$(last '.allowance | [.attributed_to, (.five_hour.points | tostring)] | join(" ")')" "batch null"

section "7e · A pi worker on a ChatGPT plan is metered in the same window as Codex"
reset
old="$(put codex "$FX/codex/rollout.jsonl" rollout-old.jsonl)"; touch -d '2 hours ago' "$old"
STUB_WINDOWS="coder-0050" "$WU" spawned 0050 coder pi "$CWD" '{"model":"openai/gpt-5.5"}' subscription:openai
assert_eq "the spawn took the reading the run is measured from, in the OpenAI pool" "$(jq -r 'select(.record == "allowance") | [.pool, .moment] | join(" ")' "$LOG")" "subscription:openai run-begin:worker:coder-0050"
put codex <(jq -c 'if .payload.type == "token_count" then .timestamp = "2026-11-04T07:00:00.000Z" | .payload.rate_limits.primary.used_percent = 3.0 else . end' "$FX/codex/rollout.jsonl") rollout-new.jsonl > /dev/null
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
STUB_WINDOWS="" "$WU" read 0050
assert_eq "the tokens are Pi's own" "$(last '[.harness, .usage] | join(",")')" "pi,reported"
assert_eq "its line carries the window's rise, attributed to the run" "$(last '.allowance | [.pool, (.five_hour.points | tostring), .attributed_to] | join(" ")')" "subscription:openai 3 run"
reset
old="$(put codex "$FX/codex/rollout.jsonl" rollout-old.jsonl)"; touch -d '2 hours ago' "$old"
STUB_WINDOWS="coder-0051 validator-0052" "$WU" spawned 0051 coder pi "$CWD" '{"model":"m"}' subscription:openai
STUB_WINDOWS="coder-0051 validator-0052" spawn 0052 validator codex
put codex <(jq -c 'if .payload.type == "token_count" then .timestamp = "2026-11-04T07:00:00.000Z" | .payload.rate_limits.primary.used_percent = 3.0 else . end' "$FX/codex/rollout.jsonl") rollout-new.jsonl > /dev/null
STUB_WINDOWS="coder-0051" "$WU" read 0052
assert_eq "a Codex worker beside a pi worker on the plan: the rise belongs to the batch, not to the Codex worker" "$(last '.allowance | [.attributed_to, (.five_hour.points | tostring)] | join(" ")')" "batch null"
reset
STUB_WINDOWS="coder-0053" "$WU" spawned 0053 coder pi "$CWD" '{"model":"m"}' api:openai
assert_eq "pi on an API key is not metered: no reading at the spawn" "$(jq -r 'select(.record == "allowance") | 1' "$LOG" 2> /dev/null | wc -l | tr -d ' ')" "0"
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
"$WU" read 0053
assert_eq "and its line has no allowance" "$(last '.allowance | tostring')" "null"

section "7f · A Claude Code worker's line carries what it used of the Claude allowance"
# The usage endpoint is a stub curl that answers with $STUB_CLAUDE_BODY; the account uses more while the worker runs.
cat > "$TMP/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
[[ -z "$out" ]] || cp "$STUB_CLAUDE_BODY" "$out"
printf '200'
CURL_EOF
chmod +x "$TMP/bin/curl"
export STUB_CLAUDE_BODY="$TMP/claude-body.json" CLAUDE_USAGE_NOW=1793865600
export CLAUDE_CREDENTIALS_FILE="$FX/../claude-usage/credentials.json"
# The endpoint's state is the test's own (never ~/.claude) and nothing is reused: every read asks the stub (#173).
export CLAUDE_USAGE_STATE_FILE="$TMP/endpoint-state.json" CLAUDE_USAGE_FRESH_SECONDS=0
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
reset
cp "$FX/../claude-usage/endpoint.json" "$STUB_CLAUDE_BODY"
spawn 0044 reviewer claude-code
assert_eq "the spawn took the reading, in the Anthropic pool" "$(jq -r 'select(.record == "allowance") | [.pool, .moment] | join(" ")' "$LOG")" "subscription:anthropic run-begin:worker:reviewer-0044"
put claude-code "$FX/claude-code/exited.jsonl" a.jsonl > /dev/null
cp "$FX/../claude-usage/endpoint-extra.json" "$STUB_CLAUDE_BODY"
STUB_WINDOWS="" "$WU" read 0044
assert_eq "the tokens are read as before" "$(last '[.harness, .model, .usage] | map(tostring) | join(",")')" "claude-code,claude-haiku-4-5-20251001,reported"
assert_eq "the five-hour window and the week, attributed to the run" "$(last '.allowance | [(.five_hour.points | tostring), (.weekly.points | tostring), .attributed_to] | join(" ")')" "27.5 41 run"
assert_eq "a model, and the credits in dollars" "$(last '.allowance | [(.weekly_by_model.models[0].points | tostring), (.credits.dollars | tostring)] | join(" ")')" "12 4.25"
assert_eq "both readings are in the log" "$(jq -r 'select(.record == "allowance") | .moment' "$LOG" | tr '\n' ' ')" "run-begin:worker:reviewer-0044 run-end:worker:reviewer-0044 "
assert_eq "and the run is forgotten" "$(find "$CONDUCTOR_DIR/allowance" -type f | wc -l | tr -d ' ')" "0"
rm -f "$TMP/bin/curl"
unset STUB_CLAUDE_BODY CLAUDE_USAGE_NOW
export CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json"

section "7d · A Codex worker on another model than asked for"
codex_worker() { # <task> <params-json>
  reset
  "$WU" spawned "$1" validator codex "$CWD" "$2"
  put codex "$FX/codex/rollout.jsonl" rollout-a.jsonl > /dev/null
  STUB_WINDOWS="" "$WU" read "$1"
}
mismatches() { jq -r 'select(.record == "model_mismatch") | [.role, .task, .harness, .requested, .answered] | join(" ")' "$LOG"; }
codex_worker 0050 '{"model":"gpt-5"}'
assert_eq "asked for gpt-5, gpt-6.1-sol answered: both on the line" "$(last '[.requested_model, .answered_model] | join(" ")')" "gpt-5 gpt-6.1-sol"
assert_eq "and a mismatch record of its own" "$(mismatches)" "validator 0050 codex gpt-5 gpt-6.1-sol"
codex_worker 0051 '{"model":"gpt-6.1-sol"}'
assert_eq "the model asked for answered: no mismatch" "$(mismatches)" ""
codex_worker 0052 '{}'
assert_eq "no model asked for: the answer is recorded" "$(last '[(.requested_model | tostring), .answered_model] | join(" ")')" "null gpt-6.1-sol"
assert_eq "and a default is not a mismatch" "$(mismatches)" ""
reset; spawn 0053 coder pi
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
"$WU" read 0053
assert_eq "another harness's line has neither field" "$(last '[(.requested_model | tostring), (.answered_model | tostring)] | join(" ")')" "null null"

section "7e · Which model answered in a directory's sessions"
reset
old="$(put codex "$FX/codex/rollout.jsonl" rollout-old.jsonl)"; touch -d '2 days ago' "$old"
assert_eq "a session older than the time asked about is not looked at" "$("$WU" model codex "$CWD" $(( $(date +%s) - 3600 )))" ""
put codex "$FX/codex/rollout.jsonl" rollout-new.jsonl > /dev/null
assert_eq "a session since then names its model" "$("$WU" model codex "$CWD" $(( $(date +%s) - 3600 )))" "gpt-6.1-sol"
assert_eq "another directory's does not" "$("$WU" model codex /some/other/dir $(( $(date +%s) - 3600 )))" ""
assert_eq "a harness with no reader prints nothing" "$("$WU" model mystery "$CWD" 0)" ""
RC=0; "$WU" model codex "$CWD" abc 2> /dev/null || RC=$?
assert_eq "a since that is not a time: exit 1" "$RC" "1"

section "8 · A harness that writes its cost on exit is given time to"
reset; spawn 0012 coder claude-code
f="$(put claude-code "$FX/claude-code/sigkilled.jsonl" a.jsonl)"
( sleep 0.6; jq -c 'select(.type == "cost-state")' "$FX/claude-code/exited.jsonl" >> "$f" ) &
"$WU" read 0012 --wait 4
wait
assert_eq "the cost that arrived while waiting is read" "$(last .cost_usd)" "0.023135"
reset; spawn 0013 coder claude-code
put claude-code "$FX/claude-code/sigkilled.jsonl" a.jsonl > /dev/null
start=$SECONDS; "$WU" read 0013 --wait 1
assert_eq "a cost that never comes does not hold it up past the wait" "$(( SECONDS - start <= 3 ))" "1"
assert_eq "and it is null, not guessed" "$(last .cost_usd)" "null"

section "9 · No spawn record"
reset
"$WU" read 0014 --role merger
assert_eq "the window's role is used and the rest is unknown" \
  "$(last '[.role, (.harness | tostring), .usage, .cost_source] | join(",")')" "merger,null,none,unknown"
RC=0; "$WU" read 0015 2> /dev/null || RC=$?
assert_eq "no record and no role is an error" "$RC" "1"

section "10 · Sweep: workers whose window is gone"
reset
spawn 0020 coder pi; spawn 0021 reviewer pi
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
STUB_WINDOWS="reviewer-0021" "$WU" sweep
assert_eq "one worker was read" "$(lines)" "1"
assert_eq "the one without a window" "$(last .task)" "0020"
assert_eq "as interrupted" "$(last .outcome)" "interrupted"
assert_eq "the one with a window is left alone" "$(find "$CONDUCTOR_DIR/workers" -type f -printf "%f\n")" "reviewer-0021.json"
STUB_WINDOWS="" "$WU" sweep
assert_eq "once its window goes, it is read too" "$(last .task)" "0021"
STUB_WINDOWS="" "$WU" sweep
assert_eq "nothing is read twice" "$(lines)" "2"
reset
spawn 0022 coder pi
STUB_TMUX_FAIL=1 "$WU" sweep
assert_eq "if tmux cannot answer, nothing is read and no record is deleted" \
  "$(lines)/$(find "$CONDUCTOR_DIR/workers" -type f | wc -l | tr -d ' ')" "0/1"

section "11 · Arguments"
RC=0; "$WU" bogus 2> /dev/null || RC=$?
assert_eq "an unknown command: exit 1" "$RC" "1"
RC=0; "$WU" read 0001 --outcome nope 2> /dev/null || RC=$?
assert_eq "an outcome that is not finished or interrupted: exit 1" "$RC" "1"

section "12 · worker-close.sh: close the window, then read"
CLOSE="$SCRIPTS_DIR/worker-close.sh"
export STUB_LOG="$TMP/tmux.log"
reset; : > "$STUB_LOG"
spawn 0030 coder pi
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
STUB_WINDOWS="coder-0030 reviewer-0031" "$CLOSE" 0030
assert_eq "the window named for the task is closed" "$(grep -c '^tmux kill-window -t swarm:coder-0030$' "$STUB_LOG")" "1"
assert_eq "no other window is" "$(grep -c 'kill-window' "$STUB_LOG")" "1"
assert_eq "the worker's usage is recorded" "$(last '[.task, .role, .input_tokens, .outcome] | map(tostring) | join(",")')" "0030,coder,2288,finished"
assert_eq "once" "$(lines)" "1"
reset; : > "$STUB_LOG"
STUB_WINDOWS="coder-0031" "$CLOSE" 0031
assert_eq "a worker with no spawn record still leaves a line, with the role from its window" \
  "$(last '[.role, (.harness | tostring), .usage, .cost_source] | join(",")')" "coder,null,none,unknown"
reset; : > "$STUB_LOG"
RC=0; STUB_WINDOWS="" "$CLOSE" 0032 || RC=$?
assert_eq "no window and no record: exit 0" "$RC" "0"
assert_eq "no line is made up for a task that never had a worker" "$(lines)" "0"
assert_eq "and nothing is killed" "$(grep -c 'kill-window' "$STUB_LOG" || true)" "0"
reset; : > "$STUB_LOG"
spawn 0033 coder pi; spawn 0034 reviewer pi
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
STUB_WINDOWS="coder-0033" "$CLOSE" 0033
assert_eq "closing one worker also reads the one whose window is gone, as interrupted" \
  "$(jq -r '[.task, .outcome] | join(":")' "$LOG" | sort | tr '\n' ' ')" "0033:finished 0034:interrupted "
reset; : > "$STUB_LOG"
spawn 0035 coder pi
mkdir -p "$TMP/ro"; chmod 555 "$TMP/ro"
RC=0; CONDUCTOR_DIR="$TMP/ro/none" STUB_WINDOWS="coder-0035" "$CLOSE" 0035 2> /dev/null || RC=$?
chmod 755 "$TMP/ro"
assert_eq "a log that cannot be written never fails the close" "$RC" "0"

section "9 · A line says what the worker was billed to"
# The sign-in files are the test's own, so nothing reads the real ones.
export CLAUDE_CREDENTIALS_FILE="$TMP/no-claude-login.json" CODEX_AUTH_FILE="$TMP/no-codex-login.json"
unset ANTHROPIC_API_KEY
reset
"$WU" spawned 0040 coder pi "$CWD" '{"model":"m"}'
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
"$WU" read 0040
assert_eq "nothing declared and nothing to detect: pool unknown" "$(last .pool)" "unknown"
assert_eq "and billing unknown" "$(last .billing)" "unknown"
reset
"$WU" spawned 0041 coder pi "$CWD" '{"model":"m"}' api:anthropic
assert_eq "the spawn record keeps the declared pool" "$(jq -r .declared_pool "$CONDUCTOR_DIR/workers/coder-0041.json")" "api:anthropic"
assert_eq "and the pool it settled on" "$(jq -r .pool_check.pool "$CONDUCTOR_DIR/workers/coder-0041.json")" "api:anthropic"
put pi "$FX/pi/session.jsonl" a.jsonl > /dev/null
"$WU" read 0041
assert_eq "a declared pool stands for pi, which has no sign-in to read" "$(last .pool)" "api:anthropic"
assert_eq "and its billing" "$(last .billing)" "api"
reset
printf '%s\n' '{"claudeAiOauth":{"accessToken":"oauth-test-token"}}' > "$CLAUDE_CREDENTIALS_FILE"
"$WU" spawned 0042 reviewer claude-code "$CWD" '{"model":"m"}' api:anthropic
put claude-code "$FX/claude-code/exited.jsonl" a.jsonl > /dev/null
assert_eq "the pool is settled when the worker is spawned: the sign-in wins" "$(jq -r .pool_check.pool "$CONDUCTOR_DIR/workers/reviewer-0042.json")" "subscription:anthropic"
assert_eq "and the mismatch is noted in the record" "$(jq -r '.pool_check.mismatch | tostring' "$CONDUCTOR_DIR/workers/reviewer-0042.json")" "true"
rm -f "$CLAUDE_CREDENTIALS_FILE"   # the login is gone by the time the window closes
"$WU" read 0042
assert_eq "so the line is what the worker was billed to, not what the closing process can see" "$(last .pool)" "subscription:anthropic"
assert_eq "and the mismatch is in the log" "$(jq -r 'select(.record == "pool_mismatch") | [.declared, .detected] | join(",")' "$LOG")" "api:anthropic,subscription:anthropic"
reset
"$WU" spawned 0043 coder claude-code "$CWD" '{"model":"m"}'
assert_eq "a spawn with no declared pool records none" "$(jq -r '.declared_pool | tostring' "$CONDUCTOR_DIR/workers/coder-0043.json")" "null"
assert_eq "and with no sign-in either, settles on unknown" "$(jq -r .pool_check.pool "$CONDUCTOR_DIR/workers/coder-0043.json")" "unknown"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
