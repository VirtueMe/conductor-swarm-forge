#!/usr/bin/env bash
# Tests that a worker's scripts find the project's .conductor wherever its window starts (#181): every
# adapter exports an absolute CONDUCTOR_DIR in the window's command, and task-create.sh and
# task-signal.sh refuse to invent a conductor directory in the working directory (the architect's
# cards once landed in .worktrees/architect/.conductor, which the loop never watches). A stub tmux
# records the command; no real claude, codex or pi, no tmux server.
#
# Usage: scripts/test-conductor-dir.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { echo ""; echo "── $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" << 'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" > "$TMUX_CMD_FILE"
[[ "$1" == has-session ]] && exit 1
exit 0
STUB_EOF
# a claude that only answers --help, so the permission mode resolves
cat > "$TMP/bin/claude" << 'STUB_EOF'
#!/usr/bin/env bash
echo '  --permission-mode <mode>   (choices: "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")'
STUB_EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/claude"
export TMUX_CMD_FILE="$TMP/tmux.cmd"

PROJECT="$TMP/proj with space"; mkdir -p "$PROJECT/.worktrees/architect" "$PROJECT/.conductor"
echo "briefing" > "$PROJECT/.worktrees/architect/AGENTS.md"

# launch <adapter> -> the command the window runs, with CONDUCTOR_DIR as given (or unset)
launch() {
  : > "$TMUX_CMD_FILE"
  ( PATH="$TMP/bin:$PATH"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/adapters/$1.sh"
    adapter_launch swarm architect .worktrees/architect "$PROJECT" '{}' 2> /dev/null )
  cat "$TMUX_CMD_FILE"
}

section "1 · Every adapter puts the project's absolute conductor dir in the window's environment"
for a in claude-code codex pi; do
  unset CONDUCTOR_DIR
  CMD="$(launch "$a")"
  case "$CMD" in *"export CONDUCTOR_DIR=$(printf '%q' "$PROJECT/.conductor") && "*) ok "$a: no CONDUCTOR_DIR set: the project's .conductor, absolute" ;; *) fail "$a: default ($CMD)" ;; esac
  # the export comes after the cd, before the harness
  case "$CMD" in "cd '$PROJECT/.worktrees/architect' && export CONDUCTOR_DIR="*) ok "$a: after the cd into the worktree" ;; *) fail "$a: order ($CMD)" ;; esac
  CMD="$(CONDUCTOR_DIR=/elsewhere/.conductor launch "$a")"
  case "$CMD" in *"export CONDUCTOR_DIR=/elsewhere/.conductor && "*) ok "$a: an absolute CONDUCTOR_DIR is kept" ;; *) fail "$a: kept ($CMD)" ;; esac
  CMD="$(CONDUCTOR_DIR=state launch "$a")"
  case "$CMD" in *"export CONDUCTOR_DIR=$(printf '%q' "$PROJECT/state") && "*) ok "$a: a relative one is made absolute against the project" ;; *) fail "$a: relative ($CMD)" ;; esac
done

section "2 · task-create.sh and task-signal.sh do not invent a conductor directory"
WT="$TMP/wt"; mkdir -p "$WT"
RC=0; ( cd "$WT" && unset CONDUCTOR_DIR && "$SCRIPTS_DIR/task-create.sh" --title T --type chore ) > "$TMP/out" 2> "$TMP/err" || RC=$?
assert_eq "task-create from a directory without .conductor: refused" "$RC" "1"
assert_eq "and says where it looked and what to set" "$(grep -c "no conductor directory at '.conductor'.*set CONDUCTOR_DIR" "$TMP/err" || true)" "1"
assert_eq "and nothing was created" "$(find "$WT" -mindepth 1 | wc -l | tr -d ' ')" "0"
RC=0; ( cd "$WT" && unset CONDUCTOR_DIR && "$SCRIPTS_DIR/task-signal.sh" --task 0001 --type progress ) > "$TMP/out" 2> "$TMP/err" || RC=$?
assert_eq "task-signal likewise" "$RC" "1"
assert_eq "and creates nothing" "$(find "$WT" -mindepth 1 | wc -l | tr -d ' ')" "0"
RC=0; ( cd "$WT" && CONDUCTOR_DIR="$PROJECT/.conductor" "$SCRIPTS_DIR/task-create.sh" --title T --type chore ) > "$TMP/out" 2> "$TMP/err" || RC=$?
assert_eq "with CONDUCTOR_DIR set to the project's, from the worktree: it works" "$RC" "0"
assert_eq "and the task is in the project's .conductor" "$(find "$PROJECT/.conductor/tasks" -type f -exec basename {} \;)" "0001.md"
assert_eq "not in the working directory" "$(find "$WT" -mindepth 1 | wc -l | tr -d ' ')" "0"
RC=0; ( cd "$PROJECT" && unset CONDUCTOR_DIR && "$SCRIPTS_DIR/task-signal.sh" --task 0001 --type progress ) > /dev/null 2>&1 || RC=$?
assert_eq "from the project root the default still works" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All conductor-dir checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
