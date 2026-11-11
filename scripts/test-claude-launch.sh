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

# The values of every --settings in a launch command, one per line: JSON as is, a path as is.
settings_args() { python3 - "$1" << 'PYEOF'
import shlex, sys
t = shlex.split(sys.argv[1])
for i, w in enumerate(t):
    if w == "--settings" and i + 1 < len(t):
        print(t[i + 1])
PYEOF
}
set_attribution() { mkdir -p "$PROJECT/.conductor"; printf -- '---\nlang: bash\nattribution: %s\n---\n' "$1" > "$PROJECT/.conductor/config.md"; }
OFF='{"commit":"","pr":""}'

section "4 · The project's allow list reaches every window"
printf '{"permissions":{"allow":["Bash(git *)"]}}\n' > "$PROJECT/.claude/settings.json"
set_attribution none
CMD="$(launch '{}')"
case "$CMD" in *"--settings '$PROJECT/.claude/settings.json'"*) ok "attribution none: passed with --settings, so a worker in a worktree does not depend on finding it" ;; *) fail "attribution none: passed with --settings ($CMD)" ;; esac
rm -f "$PROJECT/.claude/settings.json"
CMD="$(launch '{}')"
case "$CMD" in *"--settings"*) fail "attribution none, no project settings file: no --settings" ;; *) ok "attribution none, no project settings file: no --settings" ;; esac

section "4b · With attribution on, the swarm's windows do not add their own trailer (#130)"
# claude-code adds Co-Authored-By to its commits. The conductor stamps the task's commits itself (docs/commit-attribution.md),
# so the window is launched with Claude's own attribution off, in the same single --settings that carries the allow list. Whether
# repeated --settings flags merge is not documented, so there is one, and the project's file is merged into it. The merge is
# written to a file in the state dir and passed by path: the project's settings can hold env entries and helpers, which do not
# belong on a command line that ps shows.
MERGED="$PROJECT/.conductor/claude-settings.json"
printf '{"permissions":{"allow":["Bash(git *)","Bash(echo '"'"'x'"'"')"]},"attribution":{"commit":"custom"}}\n' > "$PROJECT/.claude/settings.json"
rm -f "$PROJECT/.conductor/config.md" "$MERGED"
CMD="$(launch '{}')"
ARGS="$(settings_args "$CMD")"
assert_eq "no attribution key in config.md means trailer: one --settings" "$(printf '%s\n' "$ARGS" | grep -c .)" "1"
assert_eq "it is the merged file in the state dir" "$ARGS" "$MERGED"
case "$CMD" in *"Bash(git"*|*'"permissions"'*) fail "and none of the settings is on the command line" ;; *) ok "and none of the settings is on the command line" ;; esac
assert_eq "the allow list is in the file, quotes and all" "$(jq -c '.permissions.allow' "$MERGED")" '["Bash(git *)","Bash(echo '"'"'x'"'"')"]'
assert_eq "Claude's own attribution is off in it, over the project's own" "$(jq -c '.attribution' "$MERGED")" "$OFF"
assert_eq "only its owner can read it" "$(stat -c %a "$MERGED")" "600"
assert_eq "the project's own file is untouched" "$(jq -c '.attribution' "$PROJECT/.claude/settings.json")" '{"commit":"custom"}'
set_attribution trailer
rm -f "$MERGED"
ARGS="$(settings_args "$(launch '{}')")"
assert_eq "attribution: trailer: the same file" "$ARGS" "$MERGED"
assert_eq "and the same attribution" "$(jq -c '.attribution' "$MERGED")" "$OFF"
launch '{}' > /dev/null
assert_eq "a second launch rewrites it the same" "$(jq -c '.attribution' "$MERGED")" "$OFF"
rm -f "$PROJECT/.claude/settings.json" "$MERGED"
ARGS="$(settings_args "$(launch '{}')")"
assert_eq "trailer, no project file: one --settings, the file" "$ARGS" "$MERGED"
assert_eq "carrying only the attribution" "$(jq -c . "$MERGED")" "{\"attribution\":$OFF}"
rm -f "$MERGED"
set_attribution none
CMD="$(launch '{}')"
case "$CMD" in *"--settings"*) fail "attribution none, no project file: Claude's own attribution is left alone" ;; *) ok "attribution none, no project file: Claude's own attribution is left alone" ;; esac
assert_eq "and no merged file is written" "$([[ -e "$MERGED" ]] && echo yes || echo no)" "no"
set_attribution trailer
echo '{ not json' > "$PROJECT/.claude/settings.json"
CMD="$(launch '{}')"
case "$CMD" in *"--settings '$PROJECT/.claude/settings.json'"*) ok "a project file that is not JSON is passed as it is" ;; *) fail "a project file that is not JSON is passed as it is ($CMD)" ;; esac
assert_eq "and the launch says attribution is not turned off" "$(grep -c 'attribution is not turned off' "$TMP/launch.err" || true)" "1"
printf '{"permissions":{"allow":["Bash(git *)"]}}\n' > "$PROJECT/.claude/settings.json"
rm -rf "$PROJECT/.conductor"; : > "$PROJECT/.conductor"      # a file where the state dir should be: nothing can be written there
CMD="$(launch '{}')"
case "$CMD" in *"--settings '$PROJECT/.claude/settings.json'"*) ok "a state dir that cannot be written: the project's file is passed as it is" ;; *) fail "a state dir that cannot be written ($CMD)" ;; esac
assert_eq "and the launch says attribution is not turned off" "$(grep -c 'attribution is not turned off' "$TMP/launch.err" || true)" "1"
rm -f "$PROJECT/.conductor" "$PROJECT/.claude/settings.json"; mkdir -p "$PROJECT/.conductor"

section "4c · A bad attribution value is said so, and acts as trailer (#130)"
# attribution-trailer.sh refuses a value that is neither trailer nor none. The window cannot refuse a launch
# for it, so it says so on stderr and goes on as trailer, the default: Claude's own attribution off, as the
# stamp expects. swarm-start.sh already blocks the value, so this is only for a config.md edited by hand.
printf '{"permissions":{"allow":["Bash(git *)"]}}\n' > "$PROJECT/.claude/settings.json"
rm -f "$MERGED"
set_attribution banana
CMD="$(launch '{}')"
assert_eq "the launch names the value" "$(grep -c 'banana' "$TMP/launch.err" || true)" "1"
assert_eq "and what it does instead" "$(grep -c 'as trailer' "$TMP/launch.err" || true)" "1"
assert_eq "it acts as trailer: the merged file is passed" "$(settings_args "$CMD")" "$MERGED"
assert_eq "with Claude's own attribution off" "$(jq -c '.attribution' "$MERGED")" "$OFF"
for good in trailer none; do
  set_attribution "$good"; launch '{}' > /dev/null
  assert_eq "$good: no warning" "$(grep -c 'attribution' "$TMP/launch.err" || true)" "0"
done
rm -f "$PROJECT/.conductor/config.md"; launch '{}' > /dev/null
assert_eq "no attribution key: no warning" "$(grep -c 'attribution' "$TMP/launch.err" || true)" "0"
printf -- '---\nattribution:\n---\n' > "$PROJECT/.conductor/config.md"; launch '{}' > /dev/null
assert_eq "an empty value: the default, no warning" "$(grep -c 'attribution' "$TMP/launch.err" || true)" "0"
rm -f "$PROJECT/.claude/settings.json" "$PROJECT/.conductor/config.md" "$MERGED"

section "5 · None of it reaches the headless dispatch"
FLAGS="$(adapter_params_to_flags '{"model":"m","permission_mode":"auto"}')"
assert_eq "the dispatch's flags are model and effort only" "$FLAGS" "--model m"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All claude-launch checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
