#!/usr/bin/env bash
# Tests that the conductor skills reference scripts one way, and that the
# environment conductor-env.sh builds makes that way work.
#
# The one way: a bare script name (task-move.sh). Not a relative path
# (scripts/topology-load.sh), not through a variable ($SCRIPTS_DIR/x.sh): neither
# is substituted in a per-event dispatch, so neither would run.
#
# Usage: scripts/test-conductor-script-refs.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

FILES=("$ROOT_DIR"/skills/conductor/*.md "$ROOT_DIR/prompts/conductor.prompt")

echo "── the files under test exist"
if [[ "$(find "$ROOT_DIR/skills/conductor" -name '*.md' | wc -l)" -gt 0 ]]; then
  ok "conductor skills found"; else fail "conductor skills found"; fi
if [[ -f "$ROOT_DIR/prompts/conductor.prompt" ]]; then ok "conductor.prompt found"; else fail "conductor.prompt found"; fi

echo "── no relative script paths"
# scripts/<name>.sh not preceded by a path character, so skills/... and $X/scripts/... do not count
HITS="$(grep -nE '(^|[^A-Za-z0-9_./$-])scripts/[A-Za-z0-9_-]+\.sh' "${FILES[@]}" || true)"
assert_eq "no scripts/<name>.sh" "$HITS" ""

echo "── no scripts called through SCRIPTS_DIR"
HITS="$(grep -nE '\$\{?SCRIPTS_DIR\}?' "${FILES[@]}" || true)"
assert_eq "no \$SCRIPTS_DIR" "$HITS" ""

echo "── the checks can fail"
printf 'run scripts/topology-load.sh stages x\n' > "$TMP/bad1.md"
# shellcheck disable=SC2016  # the dollar sign is the point
printf 'run $SCRIPTS_DIR/task-move.sh 1 ready\n' > "$TMP/bad2.md"
printf 'run task-move.sh 1 ready; see skills/conductor/startup.md\n' > "$TMP/good.md"
if grep -qE '(^|[^A-Za-z0-9_./$-])scripts/[A-Za-z0-9_-]+\.sh' "$TMP/bad1.md"; then
  ok "relative path is caught"; else fail "relative path is caught"; fi
if grep -qE '\$\{?SCRIPTS_DIR\}?' "$TMP/bad2.md"; then
  ok "SCRIPTS_DIR is caught"; else fail "SCRIPTS_DIR is caught"; fi
if grep -qE '(^|[^A-Za-z0-9_./$-])scripts/[A-Za-z0-9_-]+\.sh|\$\{?SCRIPTS_DIR\}?' "$TMP/good.md"; then
  fail "a bare name is accepted"
else
  ok "a bare name is accepted"
fi

echo "── every bare script name in the skills is a real script"
NAMES="$(grep -ohE '\b[a-z]+(-[a-z]+)*\.sh\b' "${FILES[@]}" | sort -u)"
MISSING=""
for n in $NAMES; do
  [[ -f "$SCRIPTS_DIR/$n" ]] || MISSING+="$n "
done
assert_eq "all referenced scripts exist" "$MISSING" ""

echo "── conductor_env makes bare names run"
mkdir -p "$TMP/proj/.conductor"
FAILS_BEFORE="$FAILS"
(
  # shellcheck source=scripts/conductor-env.sh
  source "$SCRIPTS_DIR/conductor-env.sh"
  cd "$TMP/proj"
  conductor_env .conductor
  assert_eq "CONDUCTOR_DIR is absolute"      "$CONDUCTOR_DIR" "$TMP/proj/.conductor"
  assert_eq "SCRIPTS_DIR is this directory"  "$SCRIPTS_DIR"   "$(cd "$ROOT_DIR/scripts" && pwd)"
  assert_eq "bare name resolves"             "$(command -v task-list.sh)" "$SCRIPTS_DIR/task-list.sh"
  assert_eq "a skill's topology call works"  "$(topology-load.sh stages software-dev | head -1)" "backlog"
  P1="$PATH"
  conductor_env .conductor
  assert_eq "a second call leaves PATH alone" "$PATH" "$P1"
  if conductor_env "$TMP/does-not-exist" 2>/dev/null; then
    fail "missing conductor dir accepted"
  else
    ok "missing conductor dir rejected"
  fi
  [[ "$FAILS" -eq "$FAILS_BEFORE" ]]
) || FAILS=$(( FAILS_BEFORE + 1 ))

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
