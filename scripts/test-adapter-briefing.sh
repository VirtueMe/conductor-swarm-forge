#!/usr/bin/env bash
# Tests that every adapter's adapter_write_briefing resolves the conductor dir
# correctly — no tmux, no AI. CONDUCTOR_DIR may be absolute or relative to the
# project root; prefixing the root onto an absolute path used to double it
# (".../proj//abs/path/.conductor") in the briefing.
#
# Usage: scripts/test-adapter-briefing.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

PROJECT="$WORK/proj"
mkdir -p "$PROJECT"

# Writes a briefing with the given adapter and CONDUCTOR_DIR; prints the briefing
# file's path. Each call sources the adapter in a subshell so the identically
# named functions of the different adapters never collide.
write_briefing() {
  local adapter="$1" conductor_dir="$2" out="$3"
  (
    export CONDUCTOR_DIR="$conductor_dir"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/adapters/$adapter.sh"
    # shellcheck disable=SC2016  # the literal placeholder is what the adapter expands
    adapter_write_briefing "$out" t1 'conductor=$CONDUCTOR_DIR' 'do the thing' \
      /scripts "$PROJECT" feature/t1 "" ""
  )
}

# Every adapter writes the same briefing file (#56).
briefing_file() { echo "$1/AGENTS.md"; }

for adapter_file in "$ROOT_DIR"/adapters/*.sh; do
  adapter="$(basename "$adapter_file" .sh)"
  echo "── $adapter"

  ABS="$WORK/abs/.conductor"
  OUT="$WORK/out-$adapter-abs"; mkdir -p "$OUT"
  write_briefing "$adapter" "$ABS" "$OUT"
  B="$(briefing_file "$OUT")"
  assert_eq "absolute: Environment line"  "$(grep '^- Conductor dir:' "$B")" "- Conductor dir: $ABS"
  assert_eq "absolute: skill placeholder" "$(grep '^conductor=' "$B" | sed 's|^conductor=||; s|^CONDUCTOR_DIR=[^ ]* ||')" "$ABS"
  if grep -q "$PROJECT/$WORK" "$B" 2>/dev/null; then fail "absolute: path not doubled"; else ok "absolute: path not doubled"; fi

  OUT="$WORK/out-$adapter-rel"; mkdir -p "$OUT"
  write_briefing "$adapter" ".conductor" "$OUT"
  B="$(briefing_file "$OUT")"
  assert_eq "relative: Environment line"  "$(grep '^- Conductor dir:' "$B")" "- Conductor dir: $PROJECT/.conductor"
  assert_eq "relative: skill placeholder" "$(grep '^conductor=' "$B" | sed 's|^conductor=||; s|^CONDUCTOR_DIR=[^ ]* ||')" "$PROJECT/.conductor"
done

echo ""
if (( FAILS > 0 )); then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "All checks passed"
