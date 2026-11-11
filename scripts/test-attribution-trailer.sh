#!/usr/bin/env bash
# Tests attribution-trailer.sh with no tmux and no AI: the trailer lines the conductor stamps on a task's
# commits (#130), from config.md's `attribution`, the workforce's coder and the task's strategy.
#
# Usage: scripts/test-attribution-trailer.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TRAILER="$SCRIPTS_DIR/attribution-trailer.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

# A conductor dir whose workforce has a coder on adapter $1 with params $2 (JSON), and a config.md with
# the lines of $3 (none for no config.md key). Echoes the dir.
new_cd() {
  local adapter="$1" params="$2" cfg="${3:-}" d
  d="$(mktemp -d "$WORK/cd.XXXXXX")"
  jq -n --arg a "$adapter" --argjson p "$params" \
    '{name: "t", members: [{role: "conductor", adapter: "claude-code"}, {role: "coder", adapter: $a, params: $p}]}' > "$d/workforce.json"
  printf -- '---\nlang: bash\n%s---\n' "$cfg" > "$d/config.md"
  echo "$d"
}

# Runs the resolver; $OUT is stdout, $ERR stderr, $RC the exit code.
run() {
  local rc=0
  CONDUCTOR_DIR="$1" "$TRAILER" "${@:2}" > "$WORK/out" 2> "$WORK/err" || rc=$?
  OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"; RC=$rc
}

echo "── the default is trailer"
D="$(new_cd codex '{"model":"gpt-6.1-sol"}')"
run "$D" 0001
assert_eq "exit 0" "$RC" "0"
assert_eq "the agent line, then the model line" "$OUT" \
"Co-Authored-By: Codex <https://openai.com/codex>
Assisted-by: codex:gpt-6.1-sol"

echo "── each adapter names itself"
D="$(new_cd claude-code '{"model":"claude-sonnet-4-6"}' 'attribution: trailer
')"
run "$D" 0001
assert_eq "claude-code" "$OUT" \
"Co-Authored-By: Claude Code <https://claude.com/claude-code>
Assisted-by: claude-code:claude-sonnet-4-6"
D="$(new_cd pi '{"model":"some-model"}')"
run "$D" 0001
assert_eq "pi" "$OUT" \
"Co-Authored-By: Pi <https://pi.dev>
Assisted-by: pi:some-model"

echo "── none adds nothing"
D="$(new_cd codex '{"model":"gpt-6.1-sol"}' 'attribution: none
')"
run "$D" 0001
assert_eq "exit 0" "$RC" "0"
assert_eq "no lines" "$OUT" ""

echo "── a value that is neither is an error, not a guess"
D="$(new_cd codex '{"model":"gpt-6.1-sol"}' 'attribution: banana
')"
run "$D" 0001
assert_eq "exit 1" "$RC" "1"
assert_eq "no lines" "$OUT" ""
if [[ "$ERR" == *banana* ]]; then ok "and the message names the value"; else fail "and the message names the value ($ERR)"; fi

echo "── the task's own strategy picks the model"
D="$(new_cd codex '{"model":"gpt-6.1-sol"}')"
mkdir -p "$D/strategy"
echo '{"workers":{"coder":{"model":"gpt-6.1-luna"}}}' > "$D/strategy/0002.json"
run "$D" 0002
assert_eq "the strategy's model" "$(sed -n 2p <<< "$OUT")" "Assisted-by: codex:gpt-6.1-luna"
run "$D" 0001
assert_eq "another task keeps the workforce's" "$(sed -n 2p <<< "$OUT")" "Assisted-by: codex:gpt-6.1-sol"

echo "── a coder with no model"
D="$(new_cd codex '{}')"
run "$D" 0001
assert_eq "the adapter alone" "$(sed -n 2p <<< "$OUT")" "Assisted-by: codex"
assert_eq "and the agent line is still there" "$(sed -n 1p <<< "$OUT")" "Co-Authored-By: Codex <https://openai.com/codex>"

echo "── what is missing costs lines, with a warning, never the merge"
D="$(mktemp -d "$WORK/cd.XXXXXX")"
run "$D" 0001
assert_eq "no workforce: exit 0" "$RC" "0"
assert_eq "no workforce: no lines" "$OUT" ""
if [[ "$ERR" == *workforce* ]]; then ok "no workforce: says so on stderr"; else fail "no workforce: says so on stderr ($ERR)"; fi
D="$(mktemp -d "$WORK/cd.XXXXXX")"
echo '{"name":"t","members":[{"role":"conductor","adapter":"claude-code"}]}' > "$D/workforce.json"
run "$D" 0001
assert_eq "no coder: exit 0" "$RC" "0"
assert_eq "no coder: no lines" "$OUT" ""
if [[ "$ERR" == *coder* ]]; then ok "no coder: says so on stderr"; else fail "no coder: says so on stderr ($ERR)"; fi
D="$(new_cd mystery '{"model":"m"}')"
run "$D" 0001
assert_eq "an adapter with no file: exit 0" "$RC" "0"
assert_eq "an adapter with no file: no lines" "$OUT" ""
if [[ "$ERR" == *mystery* ]]; then ok "an adapter with no file: names it on stderr"; else fail "an adapter with no file: names it on stderr ($ERR)"; fi

echo "── usage"
D="$(new_cd codex '{}')"
run "$D"
assert_eq "no task: exit 2" "$RC" "2"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
