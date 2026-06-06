#!/usr/bin/env bash
# Tests the cursor-file + batch-drain mechanics used by the conductor's main loop.
# No AI, no tmux, no swarm — just the find/touch primitives.
#
# Usage: scripts/test-drain.sh

set -euo pipefail

# ── Colour helpers (match test-flow.sh) ───────────────────────────────────────

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[0;36m'
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[0;33m'
C_MAGENTA='\033[0;35m'

step()    { echo ""; echo -e "${C_CYAN}${C_BOLD}── $1${C_RESET}"; }
info()    { echo -e "   ${C_GREEN}✓${C_RESET}  $1"; }
fail_()   { echo -e "   ${C_RED}✗${C_RESET}  $1"; FAILURES=$(( FAILURES + 1 )); }
note()    { echo -e "   ${C_YELLOW}→${C_RESET}  $1"; }
section() { echo -e "\n${C_MAGENTA}${C_BOLD}$1${C_RESET}"; }

batch_size() {
  local b="$1"
  if [[ -z "$b" ]]; then echo 0; else echo "$b" | wc -l | tr -d ' '; fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    info "$label — $actual file(s) (expected $expected)"
  else
    fail_ "$label — got $actual file(s), expected $expected"
  fi
}

FAILURES=0
WORK_DIR=""
# shellcheck disable=SC2317,SC2329  # invoked via trap, not a direct call
cleanup() {
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup EXIT

# ── Bootstrap ─────────────────────────────────────────────────────────────────

section "BATCH-DRAIN MECHANICS — cursor + find -newer"
WORK_DIR="$(mktemp -d)"
CURSOR="$WORK_DIR/last-poll"
WORK="$WORK_DIR/work"
mkdir -p "$WORK/task-001" "$WORK/task-002" "$WORK/task-003"
touch "$CURSOR"
echo "   Temp dir: $WORK_DIR"

# ── Scenario 1: Normal flow ───────────────────────────────────────────────────

section "1 · Normal flow"
note "artifact appears → find detects it → cursor advances → gone next scan"

step "Create one artifact after cursor"
sleep 0.1
echo "type: signal" > "$WORK/task-001/signal-001.md"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "batch before advance" 1 "$(batch_size "$BATCH")"

step "Process artifact — advance cursor to artifact mtime (touch -r)"
touch -r "$WORK/task-001/signal-001.md" "$CURSOR"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "batch after advance" 0 "$(batch_size "$BATCH")"

# ── Scenario 2: Crash recovery ────────────────────────────────────────────────

section "2 · Crash recovery"
note "cursor not advanced (crash mid-skill) → artifact reappears on restart"

step "Create artifact, do NOT advance cursor (simulate crash)"
sleep 0.1
echo "type: review" > "$WORK/task-001/review-001.md"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "first poll after crash" 1 "$(batch_size "$BATCH")"

step "Simulate restart — same find, same result"
BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "second poll (replay on restart)" 1 "$(batch_size "$BATCH")"

step "Process and advance cursor"
touch -r "$WORK/task-001/review-001.md" "$CURSOR"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "after recovery advance" 0 "$(batch_size "$BATCH")"

# ── Scenario 3: Full batch collected then drained one by one ──────────────────

section "3 · Batch collection then drain"
note "full batch snapped at start — each file processed, cursor advances after each"

step "Create three artifacts with distinct timestamps"
sleep 0.1; echo "type: signal"     > "$WORK/task-001/signal-002.md"
sleep 0.1; echo "type: validation" > "$WORK/task-002/validation-001.md"
sleep 0.1; echo "type: review"     > "$WORK/task-003/review-001.md"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "full batch size" 3 "$(batch_size "$BATCH")"

step "Drain batch one file at a time, advancing cursor after each"
while IFS= read -r f; do
  note "Processing $(basename "$f")"
  touch -r "$f" "$CURSOR"
done <<< "$BATCH"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "after full drain" 0 "$(batch_size "$BATCH")"

# ── Scenario 4: File arrives during drain — cursor-to-mtime prevents loss ─────

section "4 · File arrives during drain"
note "using touch -r (cursor = artifact mtime) ensures late arrivals are caught"
note "touch (cursor = now) would permanently lose files arriving in the drain window"

step "Create file-A, collect batch"
sleep 0.1
echo "type: signal" > "$WORK/task-001/signal-003.md"
ARTIFACT_A="$WORK/task-001/signal-003.md"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "batch contains file-A" 1 "$(batch_size "$BATCH")"

step "File-C arrives WHILE processing file-A (before cursor is advanced)"
sleep 0.1
echo "type: merge" > "$WORK/task-003/merge-001.md"
ARTIFACT_C="$WORK/task-003/merge-001.md"

step "Advance cursor to file-A mtime (not to 'now')"
touch -r "$ARTIFACT_A" "$CURSOR"
CURSOR_TS=$(stat -f '%m' "$CURSOR" 2>/dev/null || stat -c '%Y' "$CURSOR" 2>/dev/null)
FILE_C_TS=$(stat -f '%m' "$ARTIFACT_C" 2>/dev/null || stat -c '%Y' "$ARTIFACT_C" 2>/dev/null)
note "cursor mtime = $CURSOR_TS  |  file-C mtime = $FILE_C_TS"
if [[ "$CURSOR_TS" -eq "$FILE_C_TS" ]]; then
  note "⚠  same 1-second bucket — filesystem mtime resolution is 1s here; sub-second sleep was not enough."
  note "   On 1s-resolution filesystems, file-C and file-A share a mtime. find -newer (strictly >) will"
  note "   not find file-C in this case. This is the known edge case: use a processed ledger if 1s"
  note "   resolution is a concern. Skipping assertion — scenario not provable at this resolution."
else
  step "Immediate re-poll — file-C mtime > file-A mtime so it is caught"
  BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
  assert_eq "late arrival caught (touch -r)" 1 "$(batch_size "$BATCH")"
fi

step "Drain and advance to file-C mtime"
touch -r "$ARTIFACT_C" "$CURSOR"
BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "queue empty after draining late arrival" 0 "$(batch_size "$BATCH")"

# ── Scenario 5: Empty batch → sleep path ─────────────────────────────────────

section "5 · Empty batch"
note "no new files → find returns empty → conductor would sleep here"

step "No new artifacts written"
BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "empty queue" 0 "$(batch_size "$BATCH")"
info "Batch empty — sleep 3 path taken, then re-poll"

# ── Scenario 6: Multiple tasks in flight simultaneously ───────────────────────

section "6 · Multiple tasks in flight"
note "artifacts from several tasks land close together — all consumed in one batch"

step "Three workers signal complete in rapid succession"
sleep 0.1
echo "type: signal" > "$WORK/task-001/signal-004.md"
echo "type: signal" > "$WORK/task-002/signal-001.md"
echo "type: signal" > "$WORK/task-003/signal-001.md"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
COUNT="$(batch_size "$BATCH")"
assert_eq "all parallel signals in one batch" 3 "$COUNT"

step "Drain all, advancing cursor after each"
while IFS= read -r f; do
  note "Processing $(basename "$f") from $(basename "$(dirname "$f")")"
  touch -r "$f" "$CURSOR"
done <<< "$BATCH"

BATCH=$(find "$WORK" -name '*.md' -newer "$CURSOR" | sort)
assert_eq "queue empty after parallel drain" 0 "$(batch_size "$BATCH")"

# ── Summary ───────────────────────────────────────────────────────────────────

section "RESULTS"
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "  ${C_GREEN}${C_BOLD}All scenarios passed.${C_RESET}"
  echo ""
  exit 0
else
  echo -e "  ${C_RED}${C_BOLD}$FAILURES scenario(s) failed.${C_RESET}"
  echo ""
  exit 1
fi
