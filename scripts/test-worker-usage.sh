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
last() { jq -r "$1" "$LOG" | tail -1; }
lines() { wc -l < "$LOG" 2> /dev/null | tr -d ' ' || echo 0; }

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
assert_eq "the table's estimate is lower: it prices a 5-minute cache write" "$(last '.estimated_cost_usd < .cost_usd')" "true"

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
assert_eq "an unpriced model has no estimate" "$(last .estimated_cost_usd)" "null"
assert_eq "so the cost is unknown, and visibly so" "$(last .cost_source)" "unknown"
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
  "$(lines 2> /dev/null || echo 0)/$(find "$CONDUCTOR_DIR/workers" -type f | wc -l | tr -d ' ')" "0/1"

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
assert_eq "no line is made up for a task that never had a worker" "$(lines 2> /dev/null || echo 0)" "0"
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

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
