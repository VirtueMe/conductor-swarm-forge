#!/usr/bin/env bash
# Tests the duplicate-worker guard in worker-spawn.sh with no real tmux and no AI:
# a stub tmux keeps a window list, so the guard sees the windows earlier spawns
# created. A replayed spawn for the same task must be a quiet no-op — no second
# `assigned` artifact, no briefing rewrite, no second window.
#
# Usage: scripts/test-worker-spawn.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Claude Code's sign-in and state are the test's own, never ~/.claude: no test reaches the usage endpoint.
export CLAUDE_CREDENTIALS_FILE="$WORK/no-claude-login.json" CLAUDE_JSON_FILE="$WORK/no-claude.json"

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

# --- stub tmux: a window list in a file, one name per line -------------------
STUB="$WORK/stub"; mkdir -p "$STUB"
WINDOWS="$STUB/windows"; : > "$WINDOWS"
cat > "$STUB/tmux" << 'EOF'
#!/usr/bin/env bash
# Minimal tmux: has-session, new-session, new-window, list-windows, kill-window.
W="$STUB_DIR/windows"
cmd="$1"; shift
name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) name="$2"; shift 2 ;;
    -t|-s|-F) shift 2 ;;
    -d) shift ;;
    *) shift ;;
  esac
done
case "$cmd" in
  has-session)   [[ -f "$STUB_DIR/session" ]] ;;
  new-session)   : > "$STUB_DIR/session"; echo "$name" >> "$W" ;;
  new-window)    echo "$name" >> "$W" ;;
  list-windows)  [[ -f "$STUB_DIR/session" ]] || exit 1; cat "$W" ;;
  kill-window)   ;;
  *) ;;
esac
EOF
chmod +x "$STUB/tmux"
export STUB_DIR="$STUB"
export PATH="$STUB:$PATH"

# --- a scratch project the way swarm-start.sh lays it out --------------------
PROJECT="$WORK/proj"; mkdir -p "$PROJECT"
cd "$PROJECT"
git init -q -b main
git config user.email "swarm@test"; git config user.name "Swarm Test"
echo base > README.md; git add README.md; git commit -q -m "chore: init"

export CONDUCTOR_DIR="$PROJECT/.conductor"
TOPO="$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work}
while IFS= read -r stage; do
  [[ -n "$stage" ]] && mkdir -p "$CONDUCTOR_DIR/kanban/$stage"
done < <("$SCRIPTS_DIR/topology-load.sh" stages "$TOPO")
cp -r "$ROOT_DIR/skills"  "$CONDUCTOR_DIR/skills"
cp -r "$ROOT_DIR/prompts" "$CONDUCTOR_DIR/prompts"
cp "$TOPO" "$CONDUCTOR_DIR/topology.json"
cp "$ROOT_DIR/workforces/default.json" "$CONDUCTOR_DIR/workforce.json"
printf 'lang: bash\nbase-branch: main\n' > "$CONDUCTOR_DIR/config.md"

for t in one two three; do
  "$SCRIPTS_DIR/task-create.sh" --title "Task $t" --type chore --description "x" > /dev/null
done

spawn() { "$SCRIPTS_DIR/worker-spawn.sh" "$@" 2>&1; }
assigned_count() { find "$CONDUCTOR_DIR/work/$1" -name 'assigned-*.md' 2>/dev/null | wc -l | tr -d ' '; }
window_count()   { grep -c -- "-$1\$" "$WINDOWS" || true; }

echo "── first spawn creates the worker"
OUT=$(spawn 0001 coder)
assert_eq "one assigned artifact"        "$(assigned_count 0001)" "1"
assert_eq "one window"                   "$(window_count 0001)"   "1"
BRIEFING="$(ls "$PROJECT"/.worktrees/coder-0001/AGENTS.md)"
SUM_BEFORE="$(cksum < "$BRIEFING")"
case "$OUT" in *"Spawned coder"*) ok "reports the spawn" ;; *) fail "reports the spawn ($OUT)" ;; esac
REC="$CONDUCTOR_DIR/workers/coder-0001.json"
assert_eq "the spawn is noted for the usage log: task, role and worktree" \
  "$(jq -r '[.task, .role, (.cwd | endswith("/.worktrees/coder-0001"))] | map(tostring) | join(" ")' "$REC" 2>/dev/null || true)" "0001 coder true"
REC_SUM="$(cksum < "$REC")"

echo "── a replayed spawn for the same task is a no-op"
echo "marker" >> "$BRIEFING"                                # a running worker's file
SUM_MARKED="$(cksum < "$BRIEFING")"
if OUT=$(spawn 0001 coder); then ok "exits 0"; else fail "exits 0 ($OUT)"; fi
case "$OUT" in *"already running"*) ok "says why" ;; *) fail "says why ($OUT)" ;; esac
assert_eq "still one assigned artifact"  "$(assigned_count 0001)" "1"
assert_eq "still one window"             "$(window_count 0001)"   "1"
assert_eq "briefing not rewritten"       "$(cksum < "$BRIEFING")" "$SUM_MARKED"
assert_eq "the worker's record is not rewritten"  "$(cksum < "$REC")" "$REC_SUM"
[[ "$SUM_BEFORE" != "$SUM_MARKED" ]] || fail "test sanity: marker changed the file"

echo "── any role's window for the task blocks a spawn"
echo "reviewer-0002" >> "$WINDOWS"
OUT=$(spawn 0002 coder)
assert_eq "no assigned artifact"         "$(assigned_count 0002)" "0"
assert_eq "no second window"             "$(window_count 0002)"   "1"

echo "── a different task is not blocked"
OUT=$(spawn 0003 coder)
assert_eq "assigned artifact written"    "$(assigned_count 0003)" "1"
assert_eq "window opened"                "$(window_count 0003)"   "1"

echo "── a longer id does not match a shorter one"
# Window coder-10001 belongs to task 10001; it must not stop task 0004's spawn.
"$SCRIPTS_DIR/task-create.sh" --title "Task four" --type chore --description "x" > /dev/null
echo "coder-10001" >> "$WINDOWS"
OUT=$(spawn 0004 coder)
assert_eq "task 0004 still spawns"       "$(assigned_count 0004)" "1"

echo "── a Codex worker on an API key spawns like any other, with no allowance to measure"
"$SCRIPTS_DIR/task-create.sh" --title "Task five" --type chore --description "x" > /dev/null
"$SCRIPTS_DIR/task-create.sh" --title "Task six" --type chore --description "x" > /dev/null
jq '(.members[] | select(.role == "coder") | .adapter) = "codex"' "$CONDUCTOR_DIR/workforce.json" > "$CONDUCTOR_DIR/workforce.new" \
  && mv "$CONDUCTOR_DIR/workforce.new" "$CONDUCTOR_DIR/workforce.json"
mkdir -p "$WORK/no-sessions"; export CODEX_SESSIONS_DIR="$WORK/no-sessions"
export CODEX_AUTH_FILE="$WORK/auth.json"
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$CODEX_AUTH_FILE"
RC=0; OUT=$(spawn 0005 coder) || RC=$?
assert_eq "the spawn succeeds"           "$RC" "0"
case "$OUT" in *"Spawned coder (codex)"*) ok "and reports it" ;; *) fail "reports the spawn ($OUT)" ;; esac
case "$OUT" in *"sk-test-not-real"*) fail "the key is not printed" ;; *) ok "the key is not printed" ;; esac
assert_eq "assigned artifact written"    "$(assigned_count 0005)" "1"
assert_eq "window opened"                "$(window_count 0005)"   "1"
assert_eq "a record of the worker"       "$([[ -e "$CONDUCTOR_DIR/workers/coder-0005.json" ]] && echo yes || echo no)" "yes"
assert_eq "but no allowance run is held for it" "$([[ -e "$CONDUCTOR_DIR/allowance/worker_coder-0005.json" ]] && echo held || echo none)" "none"
printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}\n' > "$CODEX_AUTH_FILE"
RC=0; OUT=$(spawn 0006 coder) || RC=$?
assert_eq "on a subscription it spawns"  "$RC" "0"
case "$OUT" in *"Spawned coder (codex)"*) ok "reports the spawn" ;; *) fail "reports the spawn ($OUT)" ;; esac
assert_eq "with its window"              "$(window_count 0006)" "1"
unset CODEX_SESSIONS_DIR CODEX_AUTH_FILE

echo ""
if (( FAILS > 0 )); then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "All checks passed"
