#!/usr/bin/env bash
# Tests adapter_dispatch in adapters/pi.sh and scripts/pi-rpc-run.py with no AI and no
# network: a fake `pi` on the PATH speaks the RPC protocol and plays a scenario chosen by
# FAKE_PI (finished, error, hang, ...). The event shapes follow real `pi --mode rpc` runs.
#
# Usage: scripts/test-pi-dispatch.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
ADAPTER="$ROOT_DIR/adapters/pi.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else fail "$msg"; fi; }

# --- the fake pi ------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pi" << 'FAKEPI_EOF'
#!/usr/bin/env python3
import json, os, subprocess, sys, time
scenario = os.environ.get("FAKE_PI", "finished")
open(os.environ["FAKE_PI_ARGS"], "w").write("\n".join(sys.argv[1:]) + "\n")
if os.environ.get("FAKE_PI_PID"):
    open(os.environ["FAKE_PI_PID"], "w").write(str(os.getpid()))
log = open(os.environ["FAKE_PI_LOG"], "a")
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def assistant(text="", stop="stop", err=None):
    m = {"role": "assistant", "content": [{"type": "thinking", "thinking": "hm"}] + ([{"type": "text", "text": text}] if text else []), "stopReason": stop}
    if err: m["errorMessage"] = err
    return m
def finish(msg, aborted=False, extra=None):
    out({"type": "message_end", "message": msg})
    out({"type": "agent_end", "messages": [{"role": "system"}, {"role": "user"}, msg], "willRetry": False})
    for e in (extra or []): out(e)
    out({"type": "agent_settled", "aborted": aborted})
STATS = {"tokens": {"input": 100, "output": 20, "cacheRead": 300, "cacheWrite": 50, "total": 470},
         "cost": 0.0123, "assistantMessages": 3, "toolCalls": 2}
if scenario == "exit-early":
    out({"type": "agent_start"}); sys.stderr.write("pi: something broke at startup\n"); sys.exit(1)
for line in sys.stdin:
    cmd = json.loads(line); t = cmd.get("type"); log.write(t + "\n"); log.flush()
    if t == "get_state":
        out({"id": cmd["id"], "type": "response", "command": "get_state", "success": True, "data": {"model": {"id": "fake-model", "provider": "fake"}}})
    elif t == "prompt":
        if scenario == "reject":
            out({"id": cmd["id"], "type": "response", "command": "prompt", "success": False, "error": "nope"}); continue
        out({"id": cmd["id"], "type": "response", "command": "prompt", "success": True, "data": {"disposition": "started"}})
        out({"type": "agent_start"})
        if scenario == "finished":
            finish(assistant("Moved 0001 to merging."))
        elif scenario == "handler-failed":
            finish(assistant("task-locks.sh failed.\nHANDLER-FAILED: task-locks.sh exited 1"))
        elif scenario == "err404":
            finish(assistant("", "error", '404 {"type":"error","error":{"message":"model: no-such-model"}}'))
        elif scenario == "err529":
            finish(assistant("", "error", "529 overloaded"), extra=[{"type": "auto_retry_end", "success": False, "finalError": "529 overloaded"}])
        elif scenario == "repeat-step":
            for _ in range(2):
                subprocess.run(os.environ["FAKE_PI_CMD"], shell=True, check=False)
            finish(assistant("Started the merger."))
        # hang / hang-noabort: say nothing more
    elif t == "abort":
        log.write("abort-handled\n"); log.flush()
        if scenario == "hang":
            finish(assistant("", "error", "This operation was aborted"), aborted=True)
            out({"type": "response", "command": "abort", "success": True})
    elif t == "get_session_stats":
        out({"id": cmd["id"], "type": "response", "command": "get_session_stats", "success": True, "data": STATS})
FAKEPI_EOF
chmod +x "$TMP/bin/pi"
export FAKE_PI_ARGS="$TMP/pi.args" FAKE_PI_LOG="$TMP/pi.log"

# --- a conductor dir to dispatch in -------------------------------------------------
export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR/prompts"
cp "$ROOT_DIR/prompts/conductor.prompt" "$CONDUCTOR_DIR/prompts/"
printf '{"members":[{"role":"conductor","adapter":"pi","params":{"model":"anthropic/claude-opus-4-8","effort":"high"}}]}' > "$CONDUCTOR_DIR/workforce.json"
export SCRIPTS_DIR TASK_ID=0001
export DISPATCH_USAGE_FILE="$TMP/usage.json"

# dispatch [scenario]: runs adapter_dispatch; sets RC, ERR and SECS
dispatch() {
  FAKE_PI="${1:-finished}" RC=0
  export FAKE_PI
  : > "$FAKE_PI_LOG"; rm -f "$DISPATCH_USAGE_FILE" "$FAKE_PI_ARGS"
  local start=$SECONDS
  # shellcheck disable=SC2016  # $1 belongs to the child shell
  ERR="$(PATH="$TMP/bin:$PATH" bash -c 'source "$1"; adapter_dispatch "# Skill: Example
1. do the thing" "/x/work/0001/review-1.md"' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
  SECS=$(( SECONDS - start ))
}
usage_field() { jq -r ".$1" "$DISPATCH_USAGE_FILE"; }
sent() { grep -c "^$1\$" "$FAKE_PI_LOG" || true; }

section "1 · A finished run"
dispatch finished
assert_eq "exit 0" "$RC" "0"
assert_eq "rpc mode" "$(head -2 "$FAKE_PI_ARGS" | tr '\n' ' ')" "--mode rpc "
for flag in --no-session --no-context-files; do
  check "$flag" grep -qxF -- "$flag" "$FAKE_PI_ARGS"
done
assert_eq "tools limited to what handlers use" "$(grep -xA1 -- '--tools' "$FAKE_PI_ARGS" | tail -1)" "bash,read"
assert_eq "model from the workforce" "$(grep -xA1 -- '--model' "$FAKE_PI_ARGS" | tail -1)" "anthropic/claude-opus-4-8"
assert_eq "thinking level from the workforce" "$(grep -xA1 -- '--thinking' "$FAKE_PI_ARGS" | tail -1)" "high"
assert_eq "state, prompt, then stats were requested" "$(tr '\n' ' ' < "$FAKE_PI_LOG")" "get_state prompt get_session_stats "
check "the prompt carries the skill" grep -q '^1. do the thing' "$CONDUCTOR_DIR/dispatch-prompt.txt"

section "2 · The usage record"
assert_eq "harness" "$(usage_field harness)" "pi"
assert_eq "model" "$(usage_field model)" "fake-model"
assert_eq "input tokens" "$(usage_field input_tokens)" "100"
assert_eq "output tokens" "$(usage_field output_tokens)" "20"
assert_eq "cache read tokens" "$(usage_field cache_read_tokens)" "300"
assert_eq "cache write tokens" "$(usage_field cache_write_tokens)" "50"
assert_eq "cost" "$(usage_field cost_usd)" "0.0123"
assert_eq "turns" "$(usage_field turns)" "3"
assert_eq "one line" "$(wc -l < "$DISPATCH_USAGE_FILE" | tr -d ' ')" "1"

section "3 · No params in the workforce"
printf '{"members":[{"role":"conductor","adapter":"pi"}]}' > "$CONDUCTOR_DIR/workforce.json"
dispatch finished
assert_eq "exit 0" "$RC" "0"
if grep -qxF -- '--model' "$FAKE_PI_ARGS"; then fail "passed a model nobody asked for"; else ok "no model flag"; fi
printf '{"members":[{"role":"conductor","adapter":"pi","params":{"model":"anthropic/claude-opus-4-8","effort":"high"}}]}' > "$CONDUCTOR_DIR/workforce.json"

section "4 · A rejected request is not retried"
dispatch err404
assert_eq "exit 2" "$RC" "2"
case "$ERR" in *"rejected"*"404"*) ok "says why" ;; *) fail "message: $ERR" ;; esac
assert_eq "the cost is still recorded" "$(usage_field cost_usd)" "0.0123"

section "5 · A failed model call that is worth a retry"
dispatch err529
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"529"*) ok "names the status" ;; *) fail "message: $ERR" ;; esac

section "6 · The model reports a failed guard"
dispatch handler-failed
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"HANDLER-FAILED: task-locks.sh exited 1"*) ok "quotes the reason" ;; *) fail "message: $ERR" ;; esac

section "7 · The deadline sends abort"
DISPATCH_DEADLINE=1 PI_ABORT_GRACE=3 dispatch hang
assert_eq "exit 1" "$RC" "1"
assert_eq "abort was sent once" "$(sent abort)" "1"
assert_eq "and the fake handled it" "$(sent abort-handled)" "1"
if [[ "$SECS" -le 5 ]]; then ok "stopped after ${SECS}s"; else fail "took ${SECS}s"; fi
case "$ERR" in *"deadline"*"aborted"*) ok "says why" ;; *) fail "message: $ERR" ;; esac
assert_eq "usage is still recorded after an abort" "$(usage_field cost_usd)" "0.0123"

section "8 · A run that ignores abort is given up on"
export FAKE_PI_PID="$TMP/pi.pid"
DISPATCH_DEADLINE=1 PI_ABORT_GRACE=1 dispatch hang-noabort
assert_eq "exit 1" "$RC" "1"
if [[ "$SECS" -le 5 ]]; then ok "gave up after ${SECS}s"; else fail "took ${SECS}s"; fi
sleep 0.3
if kill -0 "$(cat "$FAKE_PI_PID")" 2>/dev/null; then fail "the pi process is still running"; else ok "and the pi process was stopped"; fi
unset FAKE_PI_PID

section "9 · pi exits before the run settles"
dispatch exit-early
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"something broke at startup"*) ok "passes on pi's own message" ;; *) fail "message: $ERR" ;; esac

section "10 · The prompt is rejected"
dispatch reject
assert_eq "exit 1" "$RC" "1"
case "$ERR" in *"prompt was rejected"*) ok "says so" ;; *) fail "message: $ERR" ;; esac

section "11 · Missing tools"
RC=0
# shellcheck disable=SC2016  # $1 belongs to the child shell
ERR="$(PATH="$TMP/nowhere" "$BASH" -c 'source "$1"; adapter_dispatch s a' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
assert_eq "no pi: exit 2" "$RC" "2"
case "$ERR" in *"needs pi"*) ok "names pi" ;; *) fail "message: $ERR" ;; esac
mkdir -p "$TMP/bin-nojq"; cp "$TMP/bin/pi" "$TMP/bin-nojq/pi"; ln -sf "$(command -v python3)" "$TMP/bin-nojq/python3"
RC=0
# shellcheck disable=SC2016  # $1 belongs to the child shell
ERR="$(PATH="$TMP/bin-nojq" "$BASH" -c 'source "$1"; adapter_dispatch s a' _ "$ADAPTER" 2>&1 > /dev/null)" || RC=$?
assert_eq "no jq: exit 2" "$RC" "2"
case "$ERR" in *"needs jq"*) ok "names jq" ;; *) fail "message: $ERR" ;; esac

section "12 · A repeated step is absorbed by the spawn guard"
# The fake pi plays a model that runs the spawn twice, as Pi did in the spike. The real
# worker-spawn.sh must start one worker.
STUB="$TMP/stub"; mkdir -p "$STUB"; : > "$STUB/windows"
cat > "$STUB/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
W="$STUB_DIR/windows"; cmd="$1"; shift; name=""
while [[ $# -gt 0 ]]; do case "$1" in -n) name="$2"; shift 2 ;; -t|-s|-F) shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  has-session)  [[ -f "$STUB_DIR/session" ]] ;;
  new-session)  : > "$STUB_DIR/session"; echo "$name" >> "$W" ;;
  new-window)   echo "$name" >> "$W" ;;
  list-windows) [[ -f "$STUB_DIR/session" ]] || exit 1; cat "$W" ;;
esac
TMUX_EOF
chmod +x "$STUB/tmux"; export STUB_DIR="$STUB"
PROJECT="$TMP/proj"; mkdir -p "$PROJECT"
(cd "$PROJECT" && git init -q -b main && git config user.email s@t && git config user.name s \
  && echo base > README.md && git add . && git commit -q -m init)
export CONDUCTOR_DIR="$PROJECT/.conductor"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work}
topo="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
while IFS= read -r st; do mkdir -p "$CONDUCTOR_DIR/kanban/$st"; done < <("$SCRIPTS_DIR/topology-load.sh" stages "$topo")
cp -r "$ROOT_DIR/skills" "$CONDUCTOR_DIR/skills"; cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
cp "$topo" "$CONDUCTOR_DIR/topology.json"; cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"
printf 'lang: bash\nbase-branch: main\n' > "$CONDUCTOR_DIR/config.md"
(cd "$PROJECT" && "$SCRIPTS_DIR/task-create.sh" --title T --type chore --description x > /dev/null)
export FAKE_PI_CMD="cd '$PROJECT' && PATH='$STUB':\$PATH '$SCRIPTS_DIR/worker-spawn.sh' 0001 coder"
# The default roster has a coder for worker-spawn.sh; the dispatch needs only the conductor entry.
dispatch repeat-step
assert_eq "exit 0" "$RC" "0"
assert_eq "one worker window" "$(grep -c -- '-0001$' "$STUB/windows" || true)" "1"
assert_eq "one assigned artifact" "$(find "$CONDUCTOR_DIR/work/0001" -name 'assigned-*.md' | wc -l | tr -d ' ')" "1"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
