#!/usr/bin/env bash
# Tests how adapters/claude-code.sh launches an interactive window, with no real claude and no tmux
# server: the permission mode (a workforce param, auto by default, acceptEdits when this claude has no
# auto), that the project's allow list is passed to every window whatever worktree it runs in, and that
# none of this leaks into the headless dispatch's flags. A stub claude answers --help only.
#
# Usage: scripts/test-claude-launch.sh

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

# A claude that only answers --help, with or without the auto permission mode in its choices.
mkdir -p "$TMP/with-auto" "$TMP/no-auto" "$TMP/bin"
cat > "$TMP/with-auto/claude" << 'STUB_EOF'
#!/usr/bin/env bash
echo '  --permission-mode <mode>   (choices: "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")'
STUB_EOF
cat > "$TMP/no-auto/claude" << 'STUB_EOF'
#!/usr/bin/env bash
echo '  --permission-mode <mode>   (choices: "acceptEdits", "bypassPermissions", "manual", "dontAsk", "plan")'
STUB_EOF
chmod +x "$TMP/with-auto/claude" "$TMP/no-auto/claude"
# tmux records the command a window was started with
cat > "$TMP/bin/tmux" << 'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" > "$TMUX_CMD_FILE"
[[ "$1" == has-session ]] && exit 1
exit 0
STUB_EOF
chmod +x "$TMP/bin/tmux"
export TMUX_CMD_FILE="$TMP/tmux.cmd"

# shellcheck source=adapters/claude-code.sh
source "$ROOT_DIR/adapters/claude-code.sh"

with_claude() { local which="$1"; shift; PATH="$TMP/$which:$TMP/bin:$PATH" "$@"; }

PROJECT="$TMP/proj"; mkdir -p "$PROJECT/.worktrees/coder-0001" "$PROJECT/.claude"
echo "briefing" > "$PROJECT/.worktrees/coder-0001/AGENTS.md"
launch() { # <params json> -> the command the window runs
  : > "$TMUX_CMD_FILE"
  with_claude with-auto adapter_launch swarm coder-0001 .worktrees/coder-0001 "$PROJECT" "${1:-}" 2> "$TMP/launch.err"
  cat "$TMUX_CMD_FILE"
}

section "1 · The permission mode is auto unless the workforce says otherwise"
CMD="$(launch '{"model":"m"}')"
case "$CMD" in *"--permission-mode auto"*) ok "default: auto" ;; *) fail "default: auto ($CMD)" ;; esac
case "$CMD" in *"--permission-mode acceptEdits"*) fail "and not acceptEdits" ;; *) ok "and not acceptEdits" ;; esac
CMD="$(launch '')"
case "$CMD" in *"--permission-mode auto"*) ok "no params at all: auto" ;; *) fail "no params at all: auto ($CMD)" ;; esac
CMD="$(launch '{"permission_mode":"acceptEdits"}')"
case "$CMD" in *"--permission-mode acceptEdits"*) ok "a workforce can set acceptEdits" ;; *) fail "a workforce can set acceptEdits ($CMD)" ;; esac
CMD="$(launch '{"permission_mode":"dontAsk"}')"
case "$CMD" in *"--permission-mode dontAsk"*) ok "or dontAsk (anything not allowed is denied, nothing stops to ask)" ;; *) fail "or dontAsk ($CMD)" ;; esac
CMD="$(launch '{"model":"m","effort":"high"}')"
case "$CMD" in *"--model m"*"--effort high"*) ok "model and effort still reach the command" ;; *) fail "model and effort still reach the command ($CMD)" ;; esac

section "2 · A claude without auto falls back to acceptEdits and says so"
: > "$TMUX_CMD_FILE"
with_claude no-auto adapter_launch swarm coder-0001 .worktrees/coder-0001 "$PROJECT" '{}' 2> "$TMP/launch.err"
CMD="$(cat "$TMUX_CMD_FILE")"
case "$CMD" in *"--permission-mode acceptEdits"*) ok "falls back" ;; *) fail "falls back ($CMD)" ;; esac
assert_eq "and says why on stderr" "$(grep -c 'no auto permission mode' "$TMP/launch.err" || true)" "1"
: > "$TMUX_CMD_FILE"
with_claude no-auto adapter_launch swarm coder-0001 .worktrees/coder-0001 "$PROJECT" '{"permission_mode":"acceptEdits"}' 2> "$TMP/launch.err"
assert_eq "an explicit acceptEdits says nothing" "$(wc -c < "$TMP/launch.err" | tr -d ' ')" "0"

section "3 · A mode that is not allowed fails before anything is launched"
for m in bypassPermissions bananas; do
  : > "$TMUX_CMD_FILE"; RC=0
  with_claude with-auto adapter_launch swarm coder-0001 .worktrees/coder-0001 "$PROJECT" "{\"permission_mode\":\"$m\"}" 2> "$TMP/launch.err" || RC=$?
  assert_eq "$m: refused" "$([[ "$RC" != 0 ]] && echo refused || echo launched)" "refused"
  assert_eq "$m: nothing was launched" "$(wc -c < "$TMUX_CMD_FILE" | tr -d ' ')" "0"
  assert_eq "$m: and the reason is on stderr" "$(grep -c 'permission_mode' "$TMP/launch.err" || true)" "1"
done

section "4 · The project's allow list reaches every window"
printf '{"permissions":{"allow":["Bash(git *)"]}}\n' > "$PROJECT/.claude/settings.json"
CMD="$(launch '{}')"
case "$CMD" in *"--settings '$PROJECT/.claude/settings.json'"*) ok "passed with --settings, so a worker in a worktree does not depend on finding it" ;; *) fail "passed with --settings ($CMD)" ;; esac
rm -f "$PROJECT/.claude/settings.json"
CMD="$(launch '{}')"
case "$CMD" in *"--settings"*) fail "no project settings file: no --settings" ;; *) ok "no project settings file: no --settings" ;; esac

section "5 · None of it reaches the headless dispatch"
FLAGS="$(adapter_params_to_flags '{"model":"m","permission_mode":"auto"}')"
assert_eq "the dispatch's flags are model and effort only" "$FLAGS" "--model m"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All claude-launch checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
