#!/usr/bin/env bash
# Tests claude-settings-merge.py on its own, with no tmux and no claude: the merge of the attribution-off
# keys over a project's settings, and what it does when it cannot (#221, docs/commit-attribution.md).
#
# Usage: scripts/test-claude-settings-merge.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGE="$SCRIPTS_DIR/claude-settings-merge.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

run() { # <settings file> <state dir>: sets OUT, ERR and RC
  RC=0; OUT="$(python3 -I "$MERGE" "$1" "$2" 2> "$WORK/err")" || RC=$?; ERR="$(cat "$WORK/err")"
}

echo "── a project file is merged, not replaced"
S="$WORK/a/state"; mkdir -p "$WORK/a"
echo '{"permissions":{"allow":["Bash(ls)"]},"attribution":{"commit":"x"}}' > "$WORK/a/settings.json"
run "$WORK/a/settings.json" "$S"
assert_eq "exit 0" "$RC" "0"
assert_eq "prints the flag for the merged file" "$OUT" "--settings '$S/claude-settings.json'"
assert_eq "the project's keys stay" "$(jq -c .permissions "$S/claude-settings.json")" '{"allow":["Bash(ls)"]}'
assert_eq "attribution is turned off over the project's own" "$(jq -c .attribution "$S/claude-settings.json")" '{"commit":"","pr":""}'
assert_eq "readable only by its owner" "$(stat -c %a "$S/claude-settings.json")" "600"
assert_eq "no temp file is left behind" "$(find "$S" -name '.claude-settings.*' | wc -l | tr -d ' ')" "0"
assert_eq "the project's file is untouched" "$(jq -c .attribution "$WORK/a/settings.json")" '{"commit":"x"}'

echo "── no project file is an empty object"
S="$WORK/b/state"
run "$WORK/b/none.json" "$S"
assert_eq "exit 0" "$RC" "0"
assert_eq "only the attribution keys" "$(jq -c . "$S/claude-settings.json")" '{"attribution":{"commit":"","pr":""}}'

echo "── a second run replaces the file"
run "$WORK/b/none.json" "$S"
assert_eq "same result" "$(jq -c . "$S/claude-settings.json")" '{"attribution":{"commit":"","pr":""}}'

echo "── a file that is not a JSON object is passed as it is, with a warning"
mkdir -p "$WORK/c"; echo '[1,2]' > "$WORK/c/settings.json"
run "$WORK/c/settings.json" "$WORK/c/state"
assert_eq "exit 0" "$RC" "0"
assert_eq "the project's file is passed" "$OUT" "--settings '$WORK/c/settings.json'"
case "$ERR" in *"attribution is not turned off"*) ok "the warning says attribution stays on" ;; *) fail "warning ($ERR)" ;; esac
if [[ -e "$WORK/c/state/claude-settings.json" ]]; then fail "a merged file was written"; else ok "no merged file is written"; fi

echo "── invalid JSON is the same"
echo '{nope' > "$WORK/c/bad.json"
run "$WORK/c/bad.json" "$WORK/c/state"
assert_eq "the project's file is passed" "$OUT" "--settings '$WORK/c/bad.json'"

echo "── a state dir that cannot be written is passed as it is"
echo '{"a":1}' > "$WORK/d.json"; touch "$WORK/file"
run "$WORK/d.json" "$WORK/file/state"
assert_eq "exit 0" "$RC" "0"
assert_eq "the project's file is passed" "$OUT" "--settings '$WORK/d.json'"
case "$ERR" in *"cannot write"*) ok "the warning names the write" ;; *) fail "warning ($ERR)" ;; esac

echo "── unwritable and no project file: nothing is printed"
run "$WORK/b/none.json" "$WORK/file/state"
assert_eq "no flag" "$OUT" ""

echo "── wrong arguments"
RC=0; python3 -I "$MERGE" > /dev/null 2>&1 || RC=$?
assert_eq "no arguments: non-zero" "$([[ $RC -ne 0 ]] && echo yes)" "yes"

if (( FAILS > 0 )); then echo "$FAILS check(s) failed." >&2; exit 1; fi
echo; echo "All checks passed."
