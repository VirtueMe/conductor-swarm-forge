#!/usr/bin/env bash
# Tests scripts/codex-allowance-run.sh with a stand-in for codex that writes the session event a
# real run would: the guards (billing, the confirmation, the arguments), the lines it writes with
# the allowance difference per run, and that it never runs ephemeral. Spends no allowance.
#
# Usage: scripts/test-codex-allowance-run.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$SCRIPTS_DIR/codex-allowance-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
has() { if grep -q -- "$1" "$TMP/out"; then ok "$2"; else fail "$2 (in output: $(tr '\n' '|' < "$TMP/out" | cut -c1-300))"; fi; }

mkdir -p "$TMP/bin" "$TMP/sessions/2026/11/03"
export TMPDIR="$TMP"
export CODEX_SESSIONS_DIR="$TMP/sessions" CODEX_USAGE_NOW=1793790000
export CODEX_AUTH_FILE="$TMP/auth.json"
export STUB_LOG="$TMP/codex.log" STUB_COUNT="$TMP/count"
printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}\n' > "$CODEX_AUTH_FILE"

# What Codex has written before the first run: five-hour window at 10 %, weekly at 20 %
rl() { printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":%s,"window_minutes":300,"resets_at":1793800000},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1794059735}}}}\n' "$1" "$2"; }
{ printf '{"timestamp":"2026-11-03T05:00:00.000Z","type":"session_meta","payload":{"cwd":"/elsewhere","cli_version":"0.166.0"}}\n'; rl 2026-11-03T05:00:01.000Z 10.0; } > "$TMP/sessions/2026/11/03/rollout-0.jsonl"
touch -d '2 hours ago' "$TMP/sessions/2026/11/03/rollout-0.jsonl"

# codex: for `exec`, write the session a real run leaves (the five-hour window 2 points further on,
# in the directory it was run in) and print its events; otherwise do nothing
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex $*" >> "$STUB_LOG"
[[ "${1:-}" == exec ]] || exit 0
if [[ -n "${STUB_FAIL:-}" ]]; then echo "stub: failed" >&2; exit 3; fi
n=$(( $(cat "$STUB_COUNT" 2> /dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
d="$CODEX_SESSIONS_DIR/2026/11/04"; mkdir -p "$d"; f="$d/rollout-$n.jsonl"
cwd="$(pwd -P)"
jq -nc --arg cwd "$cwd" '{timestamp: "2026-11-04T05:00:00.000Z", type: "session_meta", payload: {cwd: $cwd, cli_version: "0.166.0"}}' > "$f"
jq -nc --arg cwd "$cwd" '{timestamp: "2026-11-04T05:00:01.000Z", type: "turn_context", payload: {model: "gpt-6.1-sol", cwd: $cwd}}' >> "$f"
pct="$(( 10 + ${STUB_STEP:-2} * n ))"
printf '{"timestamp":"2026-11-04T05:0%s:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":1050}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":%s.0,"window_minutes":300,"resets_at":1793800000},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1794059735}}}}\n' "$n" "$pct" >> "$f"
touch -d "@$(( $(date +%s) + n ))" "$f"
echo '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50}}'
STUB
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

reset() { : > "$STUB_LOG"; rm -f "$STUB_COUNT"; rm -rf "$TMP/sessions/2026/11/04"; }
go() { RC=0; "$RUN" "$@" > "$TMP/out" 2> "$TMP/err" < /dev/null || RC=$?; }
execs() { grep -c '^codex exec' "$STUB_LOG" || true; }
scratch() { sed -n 's/^Scratch directory: //p' "$TMP/out" | head -1; }
alines() { jq -c 'select(.record == null)' "$(scratch)/conductor/usage.jsonl"; }

section "1 · A dry run spends nothing"
reset
go --dry-run
assert_eq "exit 0" "$RC" "0"
assert_eq "codex was not run" "$(execs)" "0"
has '^Allowance now:' "it shows the allowance now"
has 'Dry run: would run 1 real Codex run' "and what it would run"

section "2 · Two runs, each with its own difference"
reset
go --yes --runs 2
assert_eq "exit 0" "$RC" "0"
assert_eq "codex ran twice" "$(execs)" "2"
assert_eq "read-only, in a scratch directory with no git check" "$(grep '^codex exec' "$STUB_LOG" | head -1 | grep -c -- '-s read-only.*--skip-git-repo-check')" "1"
assert_eq "and never ephemeral, which would leave nothing to read" "$(grep -c -- '--ephemeral' "$STUB_LOG" || true)" "0"
assert_eq "two lines, for the role check" "$(alines | jq -s -r 'map(.role) | join(" ")')" "check check"
assert_eq "the five-hour window rose 2 points on each run" "$(alines | jq -s -r 'map(.allowance.five_hour.points | tostring) | join(" ")')" "2 2"
assert_eq "the weekly window did not move: a number, not an unknown" "$(alines | jq -s -r 'map(.allowance.weekly.points | tostring) | join(" ")')" "0 0"
assert_eq "attributed to the run" "$(alines | jq -s -r 'map(.allowance.attributed_to) | unique | join(" ")')" "run"
assert_eq "tokens, with the cached part taken out of the input" "$(alines | head -1 | jq -r '[.input_tokens, .output_tokens, .cache_read_tokens] | join(" ")')" "800 50 200"
assert_eq "the model that answered" "$(alines | head -1 | jq -r .answered_model)" "gpt-6.1-sol"
assert_eq "an estimate, which the price table cannot make for that model" "$(alines | head -1 | jq -r '.estimated_cost_usd | tostring')" "null"
has '5-hour: +2 points' "it says so as it goes"
has '^Codex allowance (subscription:openai)' "and prints the summary's allowance section"
has '^  5-hour  *14% used' "with the window where the last run left it"
assert_eq "the swarm's own conductor directory is untouched" "$([[ -e .conductor ]] && echo touched || echo untouched)" "untouched"

section "2b · A run that moves nothing says so in words"
reset
STUB_STEP=0 go --yes
assert_eq "exit 0" "$RC" "0"
has '5-hour: +0 points (under one step)' "a measured zero is under one step"
has '^  check  *1  *+0 (<1)  *+0 (<1)' "and the summary does not show it as nothing"

section "3 · It does not run on an API key"
reset
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$CODEX_AUTH_FILE"
go --yes
assert_eq "exit 2" "$RC" "2"
assert_eq "codex was not run" "$(execs)" "0"
case "$(cat "$TMP/err")" in *"API key"*) ok "and it says why" ;; *) fail "stderr: $(cat "$TMP/err")" ;; esac
assert_eq "the key is not printed" "$(cat "$TMP/out" "$TMP/err" | grep -c 'sk-test-not-real' || true)" "0"
printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}\n' > "$CODEX_AUTH_FILE"

section "4 · It asks before it spends"
reset
go
assert_eq "no terminal and no --yes: exit 1" "$RC" "1"
case "$(cat "$TMP/err")" in *"--yes"*) ok "and says how to go ahead" ;; *) fail "stderr: $(cat "$TMP/err")" ;; esac
assert_eq "codex was not run" "$(execs)" "0"

section "5 · A run that fails is recorded as failed, with the difference unknown"
reset
STUB_FAIL=1 go --yes
assert_eq "the script still finishes" "$RC" "0"
assert_eq "the line says the run failed" "$(alines | jq -r '[.outcome, .rc, .usage] | map(tostring) | join(" ")')" "failed 3 none"
assert_eq "and the difference is null, never zero" "$(alines | jq -r '.allowance.five_hour.points | tostring')" "null"
case "$(cat "$TMP/err")" in *"codex exited with 3"*) ok "and it says so on stderr" ;; *) fail "stderr: $(cat "$TMP/err")" ;; esac

section "6 · Arguments"
for bad in "--runs 0" "--runs 11" "--runs abc" "--bogus"; do
  # shellcheck disable=SC2086  # the words are split on purpose
  go $bad
  assert_eq "$bad: exit 1" "$RC" "1"
done
go --help
assert_eq "--help: exit 0" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
