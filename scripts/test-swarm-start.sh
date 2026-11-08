#!/usr/bin/env bash
# Tests how scripts/swarm-start.sh starts the conductor, with no real tmux and no AI: stub
# tmux, claude and node on the PATH record what they were asked to do. Covers the default
# (the interactive conductor, unchanged), --headless-conductor with an adapter that has
# adapter_dispatch, the fallback for one that has not, the restart warning, and preflight.
#
# Usage: scripts/test-swarm-start.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

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
has() { if grep -q -- "$1" "$2"; then ok "$3"; else fail "$3 (in $2: $(tr '\n' '|' < "$2" | cut -c1-400))"; fi; }
lacks() { if grep -q -- "$1" "$2"; then fail "$3 (found in $2)"; else ok "$3"; fi; }

# --- stubs ----------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
cmd="$1"; shift
printf '%s' "$cmd" >> "$TMUX_LOG"
for a in "$@"; do printf ' [%s]' "$a" >> "$TMUX_LOG"; done; echo >> "$TMUX_LOG"
case "$cmd" in
  has-session)  [[ -f "$TMUX_STATE" ]] ;;
  new-session)  : > "$TMUX_STATE"; printf '%s' "${*: -1}" > "$TMUX_CMD" ;;
esac
TMUX_EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/npm"      # the default language, typescript, asks for node and npm
chmod +x "$STUB"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# What Codex has on this machine must not decide these tests: no sign-in file and no sessions, unless a section says so.
export CODEX_AUTH_FILE="$TMP/no-auth.json" CODEX_SESSIONS_DIR="$TMP/no-codex-sessions"
export TMUX_LOG="$TMP/tmux.log" TMUX_STATE="$TMP/tmux.state" TMUX_CMD="$TMP/tmux.cmd"

# A copy of the tool with one more adapter that has no adapter_dispatch, and a workforce
# that uses it. swarm-start.sh finds its adapters next to itself.
FAKE="$TMP/tool"; mkdir -p "$FAKE"
cp -r "$ROOT_DIR/scripts" "$ROOT_DIR/adapters" "$ROOT_DIR/integrations" "$ROOT_DIR/workforces" \
  "$ROOT_DIR/topologies" "$ROOT_DIR/prompts" "$ROOT_DIR/skills" "$FAKE/"
python3 - "$FAKE/adapters/claude-code.sh" "$FAKE/adapters/interactive-only.sh" << 'PYEOF'
import sys
s = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(s[:s.index("# --- Headless dispatch")])
PYEOF
printf '{"members":[{"role":"conductor","adapter":"interactive-only"},{"role":"architect","adapter":"interactive-only"},{"role":"coder","adapter":"claude-code"},{"role":"validator","adapter":"claude-code"},{"role":"reviewer","adapter":"claude-code"},{"role":"merger","adapter":"claude-code"}]}' > "$FAKE/workforces/interactive-only.json"

# start [--tool <dir>] [--env K=V]... -- <swarm-start args>
# Runs swarm-start.sh in a fresh target dir. Sets TARGET, OUT, ERR and RC.
start() {
  local tool="$ROOT_DIR" envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      --tool) tool="$2"; shift 2 ;;
      --env)  envs+=("$2"); shift 2 ;;
    esac
  done
  shift
  rm -rf "$TMP/target"; mkdir -p "$TMP/target"
  [[ -n "${PREPARE:-}" ]] && "$PREPARE"
  : > "$TMUX_LOG"; rm -f "$TMUX_STATE"
  RC=0
  TARGET="$TMP/target"
  ( cd "$TMP" && env PATH="${START_PATH:-$STUB:$PATH}" "${envs[@]}" bash "$tool/scripts/swarm-start.sh" "$TARGET" "$@" ) \
    > "$TMP/out" 2> "$TMP/err" || RC=$?
}
new_session() { grep '^new-session' "$TMUX_LOG" | head -1; }

section "1 · Without the flag nothing changes"
start --
assert_eq "exit 0" "$RC" "0"
has "Conductor initialized" "$TMP/out" "the briefing is written as before"
assert_eq "AGENTS.md exists" "$([[ -f "$TARGET/AGENTS.md" ]] && echo yes || echo no)" "yes"
new_session > "$TMP/ns"
has "&& claude " "$TMP/ns" "the conductor window runs the adapter's interactive command"
lacks "conductor-loop" "$TMUX_LOG" "no loop anywhere"
lacks "Warning" "$TMP/err" "no warning"
assert_eq "tmux was attached last" "$(sed -n '$p' "$TMUX_LOG" | cut -d' ' -f1)" "attach-session"

section "2 · --headless-conductor with an adapter that has adapter_dispatch"
start -- --headless-conductor
assert_eq "exit 0" "$RC" "0"
has "Conductor: headless loop" "$TMP/out" "says so"
assert_eq "no briefing for the conductor" "$([[ -f "$TARGET/AGENTS.md" ]] && echo yes || echo no)" "no"
new_session > "$TMP/ns"
has "\[-n\] \[conductor\]" "$TMP/ns" "the window is still named conductor"
has "conductor-loop.sh" "$TMP/ns" "its command is the loop"
has "exec" "$TMP/ns" "and it leaves a shell behind when the loop exits"
has "CONDUCTOR_DIR=.conductor" "$TMP/ns" "with the conductor dir set"
lacks "&& claude " "$TMUX_LOG" "no interactive claude"
has "^notify-channel: none" "$TARGET/.conductor/config.md" "notify-channel is in config.md"
has "^poll-interval:" "$TARGET/.conductor/config.md" "next to the poll interval"
start -- -hc
assert_eq "-hc is the same flag" "$(new_session | grep -c 'conductor-loop.sh' || true)" "1"

section "3 · The loop's settings reach the window"
start --env CONDUCTOR_MAX_ATTEMPTS=5 --env CONDUCTOR_CODEX_SANDBOX=workspace-write --env PI_ABORT_GRACE=7 --env UNRELATED=1 -- -hc
new_session > "$TMP/ns"
has "CONDUCTOR_MAX_ATTEMPTS=5" "$TMP/ns" "CONDUCTOR_MAX_ATTEMPTS"
has "CONDUCTOR_CODEX_SANDBOX=workspace-write" "$TMP/ns" "CONDUCTOR_CODEX_SANDBOX"
has "PI_ABORT_GRACE=7" "$TMP/ns" "PI_ABORT_GRACE"
lacks "UNRELATED" "$TMP/ns" "nothing else is passed on"
lacks "HOME=" "$TMP/ns" "not the whole environment"

section "4 · An adapter without adapter_dispatch falls back"
start --tool "$FAKE" -- --workforce interactive-only --headless-conductor
assert_eq "exit 0" "$RC" "0"
has "needs an adapter with adapter_dispatch" "$TMP/err" "warns"
has "Falling back to the interactive conductor" "$TMP/err" "and says what happens"
has "Conductor initialized" "$TMP/out" "the briefing is written"
assert_eq "AGENTS.md exists" "$([[ -f "$TARGET/AGENTS.md" ]] && echo yes || echo no)" "yes"
lacks "conductor-loop" "$TMUX_LOG" "no loop"
start --tool "$FAKE" -- --workforce interactive-only
lacks "Warning" "$TMP/err" "without the flag the same adapter gives no warning"

section "5 · A restart with work in flight starts the loop without a warning"
# The loop runs the startup reconcile itself (#89), so there is nothing to warn about.
# shellcheck disable=SC2329  # called through $PREPARE
prepare_in_flight() {
  mkdir -p "$TMP/target/.conductor/kanban/in-progress"
  : > "$TMP/target/.conductor/kanban/in-progress/0001.md"
}
PREPARE=prepare_in_flight start -- -hc
assert_eq "exit 0" "$RC" "0"
lacks "in flight" "$TMP/err" "no warning"
assert_eq "the loop is launched" "$(new_session | grep -c 'conductor-loop.sh' || true)" "1"

section "6 · An existing tmux session is left alone"
start --
: > "$TMUX_LOG"; : > "$TMUX_STATE"
( cd "$TMP" && env PATH="$STUB:$PATH" bash "$ROOT_DIR/scripts/swarm-start.sh" "$TARGET" --headless-conductor ) > "$TMP/out" 2> "$TMP/err" || true
has "Attaching to existing tmux session" "$TMP/out" "says so"
lacks "^new-session" "$TMUX_LOG" "starts no window"

section "7 · Preflight asks for what the loop needs"
MIN="$TMP/min"; mkdir -p "$MIN"
for t in bash sh env cat sed awk grep tr cut head tail sort uniq mkdir cp rm mv ls find wc date git python3 touch printf \
         basename dirname readlink tee mktemp diff xargs chmod sleep kill timeout; do
  p="$(command -v "$t" 2> /dev/null || true)"; [[ -n "$p" ]] && ln -sf "$p" "$MIN/$t"
done
cp "$STUB"/* "$MIN"/
START_PATH="$MIN" start --
if [[ "$RC" -ne 0 ]]; then
  echo "   (skipped: the minimal PATH could not run swarm-start.sh at all here: $(head -c 200 "$TMP/err"))"
else
  assert_eq "the default start needs no jq" "$RC" "0"
  START_PATH="$MIN" start -- --headless-conductor
  assert_eq "the headless start fails without jq" "$RC" "1"
  has "jq" "$TMP/err" "and names jq"
  assert_eq "nothing was started" "$([[ -s "$TMUX_LOG" ]] && echo started || echo nothing)" "nothing"
fi

section "8 · The window command really runs"
# The command handed to tmux, run the way tmux would run it. CONDUCTOR_TIMEOUT_CMD names a
# command that does not exist, so the loop exits at once (status 3) and the window must
# turn into a shell instead of closing; SHELL=/bin/true stands in for that shell.
start --env CONDUCTOR_TIMEOUT_CMD=no-such-timeout -- -hc
RC=0
( cd "$TMP" && SHELL=/bin/true PATH="$STUB:$PATH" bash -c "$(cat "$TMUX_CMD")" ) > "$TMP/win.out" 2>&1 || RC=$?
assert_eq "the window command exits 0 through the shell it hands over to" "$RC" "0"
has "needs GNU timeout" "$TMP/win.out" "the loop ran, with the settings it was given"
has "conductor-loop exited with status 3" "$TMP/win.out" "the window reports the loop's status"
has "Restart the loop with" "$TMP/win.out" "and how to start it again"
has "^  cd .* && env CONDUCTOR_DIR=.*CONDUCTOR_TIMEOUT_CMD=no-such-timeout .*scripts/conductor-loop.sh\$" "$TMP/win.out" "as a command to paste, in the project, with the settings the loop was given"

section "9 · A setting reaches the loop exactly as written"
# A stand-in loop reports the variable it received. The value has spaces, quotes, a dollar
# sign, a backtick, a semicolon, a pipe, an ampersand, a backslash and a glob, and each
# layer of quoting between swarm-start.sh and the loop has to leave it alone.
# shellcheck disable=SC2016  # the dollar signs are for the stand-in and the test value, not for here
printf '#!/usr/bin/env bash\nprintf "%%s" "$CONDUCTOR_TEST_VAL"\n' > "$FAKE/scripts/conductor-loop.sh"
# shellcheck disable=SC2016  # the dollar sign is part of the value
VAL='two words $HOME "q" '"'"'s'"'"' `x`;|&\ *?(y)'
start --tool "$FAKE" --env "CONDUCTOR_TEST_VAL=$VAL" -- -hc
GOT="$( cd "$TMP" && SHELL=/bin/true PATH="$STUB:$PATH" bash -c "$(cat "$TMUX_CMD")" 2>&1 | head -1 )"
assert_eq "the value arrives unchanged" "${GOT:0:${#VAL}}" "$VAL"

section "10 · The window shows where the last run left off"
# shellcheck disable=SC2016  # the stand-in is a program for another shell
printf '#!/usr/bin/env bash\necho "THE LOOP RAN"\n' > "$FAKE/scripts/conductor-loop.sh"
# shellcheck disable=SC2329  # called through $PREPARE
prepare_log() {
  mkdir -p "$TMP/target/.conductor"
  for n in $(seq 1 30); do echo "2026-11-01 10:00:$(printf '%02d' "$n")  earlier line $n"; done > "$TMP/target/.conductor/conductor.log"
}
PREPARE=prepare_log start --tool "$FAKE" -- -hc
RC=0
( cd "$TMP" && SHELL=/bin/true PATH="$STUB:$PATH" bash -c "$(cat "$TMUX_CMD")" ) > "$TMP/win.out" 2>&1 || RC=$?
assert_eq "the window command exits 0" "$RC" "0"
assert_eq "it opens with the header" "$(sed -n 1p "$TMP/win.out")" "--- earlier in conductor.log:"
assert_eq "then the last 20 lines, not the first" "$(sed -n 2p "$TMP/win.out" | sed 's/.*earlier line //')" "11"
assert_eq "up to the newest" "$(sed -n 21p "$TMP/win.out" | sed 's/.*earlier line //')" "30"
assert_eq "then a marker" "$(sed -n 22p "$TMP/win.out")" "--- now:"
assert_eq "and then the loop" "$(sed -n 23p "$TMP/win.out")" "THE LOOP RAN"
start --tool "$FAKE" -- -hc
RC=0
( cd "$TMP" && SHELL=/bin/true PATH="$STUB:$PATH" bash -c "$(cat "$TMUX_CMD")" ) > "$TMP/win.out" 2>&1 || RC=$?
assert_eq "with no log yet, the window starts with the loop" "$(sed -n 1p "$TMP/win.out")" "THE LOOP RAN"

section "11 · Each role is launched by its own adapter"
# The conductor and the architect use different adapters. Each window must start with the command of
# its own role's adapter, and each briefing must be written by it (pi and claude-code prefix the
# scripts dir with CONDUCTOR_DIR=..., codex does not).
printf 'a brief\n' > "$TMP/brief.md"
mixed() { # <conductor adapter> <architect adapter>
  printf '{"members":[{"role":"conductor","adapter":"%s"},{"role":"architect","adapter":"%s"},{"role":"coder","adapter":"claude-code"},{"role":"validator","adapter":"claude-code"},{"role":"reviewer","adapter":"claude-code"},{"role":"merger","adapter":"claude-code"}]}' "$1" "$2" > "$FAKE/workforces/mixed.json"
}
window() { grep "\[$1\]" "$TMUX_LOG" | head -1; }

# The briefing check below reads how the scripts dir is written in the architect's prompt. If that
# prompt stops referring to it, the check would pass without proving anything, so say so.
# shellcheck disable=SC2016  # a literal $SCRIPTS_DIR is what the prompt contains
if grep -q '\$SCRIPTS_DIR/watch-dir.sh' "$ROOT_DIR/prompts/architect.prompt"; then
  ok "the architect prompt still has a \$SCRIPTS_DIR reference for the briefing check to read"
else
  fail "prompts/architect.prompt no longer uses \$SCRIPTS_DIR/watch-dir.sh: the briefing check in this section proves nothing"
fi

mixed pi codex
start --tool "$FAKE" -- --workforce mixed --brief "$TMP/brief.md"
assert_eq "exit 0" "$RC" "0"
case "$(window conductor)" in *"&& pi "*) ok "pi conductor: the conductor window starts pi" ;; *) fail "conductor window: $(window conductor | cut -c1-200)" ;; esac
case "$(window architect)" in *"&& codex"*) ok "codex architect: the architect window starts codex" ;; *) fail "architect window: $(window architect | cut -c1-200)" ;; esac
if grep -q 'CONDUCTOR_DIR=[^ ]* [^ ]*watch-dir.sh' "$TARGET/.worktrees/architect/AGENTS.md"; then
  fail "the architect's briefing was written by pi's adapter, not codex's"
else
  ok "the architect's briefing was written by the codex adapter"
fi

mixed codex pi
start --tool "$FAKE" -- --workforce mixed --brief "$TMP/brief.md"
case "$(window conductor)" in *"&& codex"*) ok "swapped: the conductor window starts codex" ;; *) fail "conductor window: $(window conductor | cut -c1-200)" ;; esac
case "$(window architect)" in *"&& pi "*) ok "swapped: the architect window starts pi" ;; *) fail "architect window: $(window architect | cut -c1-200)" ;; esac
if grep -q 'CONDUCTOR_DIR=[^ ]* [^ ]*watch-dir.sh' "$TARGET/.worktrees/architect/AGENTS.md"; then
  ok "swapped: the architect's briefing was written by pi's adapter"
else
  fail "swapped: the architect's briefing was not written by pi's adapter"
fi

mixed claude-code pi
start --tool "$FAKE" -- --workforce mixed --brief "$TMP/brief.md"
case "$(window conductor)" in *"&& claude "*) ok "claude-code conductor with a pi architect: the conductor window starts claude" ;; *) fail "conductor window: $(window conductor | cut -c1-200)" ;; esac
case "$(window architect)" in *"&& pi "*) ok "and the architect window starts pi" ;; *) fail "architect window: $(window architect | cut -c1-200)" ;; esac

section "12 · node is needed for the kanban board only"
# A PATH like section 7's, without node or npm. A language that needs neither (bash), so the only
# thing that could ask for node is the kanban server.
if [[ -d "$MIN" ]]; then
  MIN2="$TMP/min-nonode"; rm -rf "$MIN2"; cp -a "$MIN" "$MIN2"; rm -f "$MIN2/node" "$MIN2/npm"
  START_PATH="$MIN2" start -- --lang bash
  assert_eq "a default start needs no node" "$RC" "0"
  if grep -qE 'missing tools|node —' "$TMP/err" "$TMP/out"; then fail "preflight complained: $(grep -hE 'missing tools|—' "$TMP/err" "$TMP/out" | head -3 | tr '\n' '|')"; else ok "and preflight reports nothing missing"; fi
  START_PATH="$MIN2" start -- --lang bash --kanban-server
  assert_eq "--kanban-server without node fails" "$RC" "1"
  has "node" "$TMP/err" "and names node"
  has "kanban board server" "$TMP/err" "as the kanban board's requirement"
  assert_eq "nothing was started" "$([[ -s "$TMUX_LOG" ]] && echo started || echo nothing)" "nothing"
else
  echo "   (skipped: section 7 could not build a minimal PATH here)"
fi

section "13 · A workforce with a role on Codex runs on a subscription or on an API key"
jq '(.members[] | select(.role == "conductor") | .adapter) = "codex"' "$ROOT_DIR/workforces/default.json" > "$FAKE/workforces/codex-conductor.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/codex"; chmod +x "$STUB/codex"
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$TMP/auth-apikey.json"
printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}\n' > "$TMP/auth-chatgpt.json"
mkdir -p "$TMP/codex-sessions/2026/11/04" "$TMP/codex-empty"
cp "$ROOT_DIR/tests/codex-usage/normal.jsonl" "$TMP/codex-sessions/2026/11/04/rollout-1.jsonl"
start --tool "$FAKE" --env "CODEX_AUTH_FILE=$TMP/auth-apikey.json" --env "CODEX_SESSIONS_DIR=$TMP/codex-empty" -- --workforce codex-conductor
assert_eq "on an API key the swarm starts: its dollars are real spend, billed outside the allowance" "$RC" "0"
assert_eq "with its session" "$([[ -n "$(new_session)" ]] && echo started || echo nothing)" "started"
case "$(cat "$TMP/err")" in *"Not starting"*) fail "no refusal: $(cat "$TMP/err")" ;; *) ok "and nothing refuses it" ;; esac
assert_eq "it takes no reading of an allowance that does not apply" "$(jq -r 'select(.record == "allowance" and .pool == "subscription:openai") | 1' "$TARGET/.conductor/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"
start --tool "$FAKE" --env "CODEX_AUTH_FILE=$TMP/auth-chatgpt.json" --env "CODEX_SESSIONS_DIR=$TMP/codex-sessions" -- --workforce codex-conductor
assert_eq "on a subscription it starts" "$RC" "0"
assert_eq "with its session" "$([[ -n "$(new_session)" ]] && echo started || echo nothing)" "started"
assert_eq "and takes a reading of the allowance as it starts" "$(jq -r 'select(.record == "allowance" and .pool == "subscription:openai") | .moment' "$TARGET/.conductor/usage.jsonl" 2> /dev/null)" "swarm-start"
start -- 
assert_eq "a workforce with no Codex role takes no Codex reading" "$(jq -r 'select(.pool == "subscription:openai") | 1' "$TARGET/.conductor/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"

section "14 · A workforce with a role on Claude Code takes a Claude reading at start, unless it is on an API key"
start --
assert_eq "the default workforce runs on Claude Code: one reading, in the Anthropic pool" "$(jq -r 'select(.record == "allowance") | [.pool, .moment] | join(" ")' "$TARGET/.conductor/usage.jsonl" 2> /dev/null)" "subscription:anthropic swarm-start"
start --env ANTHROPIC_API_KEY=sk-test-not-real --
assert_eq "on an API key it starts" "$RC" "0"
assert_eq "and takes no reading of an allowance that does not apply" "$(jq -r 'select(.record == "allowance") | 1' "$TARGET/.conductor/usage.jsonl" 2> /dev/null | wc -l | tr -d ' ')" "0"

section "15 · Budgets: the workforce's, tightened by the brief, reach the conductor dir"
jq '.budgets = [{"pool":"api:anthropic","usd":50,"period":"week"},{"pool":"subscription:anthropic","percent":40}]' "$ROOT_DIR/workforces/default.json" > "$FAKE/workforces/budgeted.json"
printf -- '---\nbudget:\n  - api:anthropic 20\n  - subscription:anthropic 90\n---\n# Brief\n' > "$TMP/budget-brief.md"
start --tool "$FAKE" -- --workforce budgeted
assert_eq "a workforce with budgets and no brief: the budgets as declared" "$(jq -r 'map(.pool + "=" + ((.usd // .percent) | tostring)) | join(" ")' "$TARGET/.conductor/budgets.json")" "api:anthropic=50 subscription:anthropic=40"
start --tool "$FAKE" -- --workforce budgeted --brief "$TMP/budget-brief.md"
assert_eq "a brief lowers one and cannot raise the other" "$(jq -r 'map(.pool + "=" + ((.usd // .percent) | tostring)) | join(" ")' "$TARGET/.conductor/budgets.json")" "api:anthropic=20 subscription:anthropic=40"
start --
assert_eq "a workforce with no budgets leaves no budgets file" "$([[ -e "$TARGET/.conductor/budgets.json" ]] && echo yes || echo no)" "no"

section "16 · The allow list covers the project's test command and its language's runner"
allow() { jq -r '.permissions.allow[]' "$TARGET/.claude/settings.json"; }
start -- --lang python --test-cmd "python3 -m unittest discover"
assert_eq "exit 0" "$RC" "0"
assert_eq "the test command itself is allowed" "$(allow | grep -cxF 'Bash(python3 -m unittest discover)')" "1"
assert_eq "and so is the same module with other arguments" "$(allow | grep -cxF 'Bash(python3 -m unittest *)')" "1"
assert_eq "python's runners are allowed" "$(allow | grep -cxF -e 'Bash(python3 *)' -e 'Bash(python *)')" "2"
assert_eq "what was already allowed still is" "$(allow | grep -cxF 'Bash(git *)')" "1"
assert_eq "and the deny list is untouched" "$(jq -r '.permissions.deny | length' "$TARGET/.claude/settings.json")" "5"
start -- --lang typescript --test-cmd "npm test"
assert_eq "an npm test command: allowed as written" "$(allow | grep -cxF 'Bash(npm test)')" "1"
assert_eq "no python rules for another language" "$(allow | grep -c 'python')" "0"
start --
assert_eq "no test command: the settings file is the fixed list, and valid JSON" "$(jq -e '.permissions.allow | length > 5' "$TARGET/.claude/settings.json" > /dev/null && echo ok)" "ok"
start -- --lang bash --test-cmd 'make test "quoted arg"'
assert_eq "a test command with quotes still gives valid JSON" "$(jq -e . "$TARGET/.claude/settings.json" > /dev/null && echo ok)" "ok"
assert_eq "and is allowed as written" "$(allow | grep -cxF 'Bash(make test "quoted arg")')" "1"

section "16b · Workers can read the project and call scripts with a CONDUCTOR_DIR= prefix without asking (#182)"
start -- --lang python --test-cmd "python3 -m unittest discover"
SET="$TARGET/.claude/settings.json"
PROJ_REAL="$(cd "$TARGET" && pwd -P)"
assert_eq "the project root is an additional directory" "$(jq -r --arg d "$PROJ_REAL" '.permissions.additionalDirectories | index($d) != null' "$SET")" "true"
assert_eq "so is the tool's scripts directory" "$(jq -r --arg d "$ROOT_DIR/scripts" '.permissions.additionalDirectories | index($d) != null' "$SET")" "true"
assert_eq "a script called with this swarm's CONDUCTOR_DIR prefix is allowed" "$(allow | grep -cxF "Bash(CONDUCTOR_DIR=$PROJ_REAL/.conductor $ROOT_DIR/scripts/*)")" "1"
assert_eq "and so is the bash form" "$(allow | grep -cxF "Bash(CONDUCTOR_DIR=$PROJ_REAL/.conductor bash $ROOT_DIR/scripts/*)")" "1"
assert_eq "no rule lets any CONDUCTOR_DIR through" "$(allow | grep -c 'CONDUCTOR_DIR=\*')" "0"
assert_eq "a start again does not repeat the directories" "$(start -- --lang python --test-cmd "python3 -m unittest discover"; jq -r '.permissions.additionalDirectories | length - (unique | length)' "$SET")" "0"
assert_eq "the file is still valid JSON with the deny list" "$(jq -r '.permissions.deny | length' "$SET")" "5"

section "17 · Trust: a note by default, and --trust-project only when asked"
export CLAUDE_JSON_FILE="$TMP/claude-state.json"
printf '{"numStartups":1,"projects":{}}' > "$CLAUDE_JSON_FILE"
start --
assert_eq "exit 0" "$RC" "0"
has "will ask you to trust" "$TMP/out" "an untrusted project: said up front"
has "trust-project" "$TMP/out" "with the way to avoid it"
assert_eq "and nothing was written to Claude's file" "$(jq -c . "$CLAUDE_JSON_FILE")" '{"numStartups":1,"projects":{}}'
start -- --trust-project
assert_eq "--trust-project: exit 0" "$RC" "0"
assert_eq "it records the trust for the project directory" "$(jq -r --arg d "$(cd "$TARGET" && pwd -P)" '.projects[$d].hasTrustDialogAccepted' "$CLAUDE_JSON_FILE")" "true"
lacks "will ask you to trust" "$TMP/out" "and the note is gone"
start --
lacks "will ask you to trust" "$TMP/out" "a project that is already trusted needs no note"
printf '{"projects":{}}' > "$CLAUDE_JSON_FILE"
start --tool "$FAKE" -- --workforce interactive-only
has "will ask you to trust" "$TMP/out" "a workforce with claude-code windows: the note"
jq '(.members[] | .adapter) = "pi"' "$ROOT_DIR/workforces/default.json" > "$FAKE/workforces/no-claude.json"
start --tool "$FAKE" -- --workforce no-claude
lacks "will ask you to trust" "$TMP/out" "no claude-code member: nothing to say about Claude's trust"
rm -f "$CLAUDE_JSON_FILE"
start --
has "will ask you to trust" "$TMP/out" "no Claude state file: the dialog will come, so the note too"
start -- --trust-project
assert_eq "--trust-project with no state file: the start goes on" "$RC" "0"
has "claude once" "$TMP/err" "and says what to do"
export CLAUDE_JSON_FILE="$TMP/no-claude.json"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
