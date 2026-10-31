#!/usr/bin/env bash
# Tests that same-second artifacts of one type no longer overwrite each other.
# A stub `date` returns a frozen timestamp for its first calls and the real time
# afterwards, so the collision is forced instead of left to timing. Runs the real
# task-signal.sh and task-move.sh; no tmux, no AI.
#
# Usage: scripts/test-artifact-name.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

# --- stub date: frozen for the first N timestamp calls, real afterwards ------
REAL_DATE="$(command -v date)"
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/date" << 'STUB_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%Y%m%d-%H%M%S" && -s "${FREEZE_FILE:-/nonexistent}" ]]; then
  n=$(cat "$FREEZE_FILE")
  if (( n > 0 )); then echo $(( n - 1 )) > "$FREEZE_FILE"; echo "20261031-120000"; exit 0; fi
fi
exec "$REAL_DATE" "$@"
STUB_EOF
export REAL_DATE
chmod +x "$STUB/date"
export FREEZE_FILE="$TMP/freeze"
freeze() { echo "$1" > "$FREEZE_FILE"; }

# --- an isolated conductor dir with one task ---------------------------------
export CONDUCTOR_DIR="$TMP/.conductor"
mkdir -p "$CONDUCTOR_DIR"/{tasks,work}
while IFS= read -r stage; do
  mkdir -p "$CONDUCTOR_DIR/kanban/$stage"
done < <("$SCRIPTS_DIR/topology-load.sh" stages software-dev)
cp "$("$SCRIPTS_DIR/topology-load.sh" resolve software-dev)" "$CONDUCTOR_DIR/topology.json"
"$SCRIPTS_DIR/task-create.sh" --title "Collide" --type chore --description "x" > /dev/null
ID=0001
W="$CONDUCTOR_DIR/work/$ID"

signal() { PATH="$STUB:$PATH" "$SCRIPTS_DIR/task-signal.sh" --task "$ID" --type "$1" --notes "$2" > /dev/null; }
move()   { PATH="$STUB:$PATH" "$SCRIPTS_DIR/task-move.sh" "$ID" "$1" > /dev/null; }
count()  { find "$W" -name "$1-*.md" | wc -l | tr -d ' '; }

echo "── two signals in one second both survive"
freeze 2
signal progress first
signal progress second
assert_eq "two progress artifacts"        "$(count progress)" "2"
FIRST="$(grep -l '^first$'  "$W"/progress-*.md)"
SECOND="$(grep -l '^second$' "$W"/progress-*.md)"
if [[ "$FIRST" != "$SECOND" ]]; then ok "distinct names"; else fail "distinct names"; fi
assert_eq "first keeps the frozen second" "$(basename "$FIRST")" "progress-20261031-120000.md"

echo "── names sort in arrival order"
assert_eq "second sorts after first"      "$(printf '%s\n%s\n' "$SECOND" "$FIRST" | sort | tail -1)" "$SECOND"

echo "── the timestamp field matches the file name"
for f in "$FIRST" "$SECOND"; do
  ts="$(awk -F': ' '/^timestamp: /{print $2; exit}' "$f")"
  base="$(basename "$f" .md)"
  assert_eq "$(basename "$f")" "$ts" "${base#progress-}"
done

echo "── three in a row, and a different type is unaffected"
freeze 3
signal merge m1; signal merge m2; signal merge m3
assert_eq "three merge artifacts"         "$(count merge)" "3"
last_of() { local f=("$W"/"$1"-*.md); echo "${f[${#f[@]}-1]}"; }   # glob order = name order
LATEST="$(last_of merge)"
assert_eq "last by name is the last written" "$(grep -c '^m3$' "$LATEST")" "1"
freeze 1
signal review r1
assert_eq "one review artifact"           "$(count review)" "1"

echo "── two moves in one second both survive"
MOVED_BEFORE="$(count moved)"   # task-create writes one
freeze 2
move ready
move in-progress
assert_eq "two new moved artifacts"       "$(( $(count moved) - MOVED_BEFORE ))" "2"
LAST_MOVE="$(last_of moved)"
assert_eq "last by name is the last move" "$(awk -F': ' '/^to: /{print $2}' "$LAST_MOVE")" "in-progress"

echo "── a missing directory fails instead of looping"
# shellcheck source=scripts/artifact-name.sh
source "$SCRIPTS_DIR/artifact-name.sh"
if artifact_claim "$TMP/does-not-exist" signal 2>/dev/null; then
  fail "claimed in a missing dir"
else
  ok "returns 1 for a missing dir"
fi

echo "── a clock that is stuck behind gives up instead of hanging"
mkdir -p "$TMP/stuck"
freeze 100
touch "$TMP/stuck/signal-20261031-120000.md"
if OUT="$(PATH="$STUB:$PATH" ARTIFACT_CLAIM_TRIES=2 artifact_claim "$TMP/stuck" signal 2>&1)"; then
  fail "claimed although every name was taken"
else
  ok "returns 1 after the cap"
fi
case "$OUT" in *"is the clock behind"*) ok "says why" ;; *) fail "says why ($OUT)" ;; esac
freeze 0

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
