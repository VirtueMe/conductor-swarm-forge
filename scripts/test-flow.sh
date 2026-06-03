#!/usr/bin/env bash
# Simulates a full swarm lifecycle with no tmux, no AI, no fswatch.
# Run alongside kanban-board.js to watch cards move in real time.
#
# Usage:
#   scripts/test-flow.sh [target-dir]
#   STEP_DELAY=2 scripts/test-flow.sh /tmp/my-test    # slower, custom dir

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
STEP_DELAY="${STEP_DELAY:-1}"
TARGET_DIR=""
KANBAN_SERVER=false

for arg in "$@"; do
  case "$arg" in
    --kanban-server|-cbs) KANBAN_SERVER=true ;;
    *) [[ -z "$TARGET_DIR" ]] && TARGET_DIR="$arg" ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[0;36m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_MAGENTA='\033[0;35m'

step()    { echo ""; echo -e "${C_CYAN}${C_BOLD}── $1${C_RESET}"; sleep "$STEP_DELAY"; }
info()    { echo -e "   ${C_GREEN}✓${C_RESET}  $1"; }
note()    { echo -e "   ${C_YELLOW}→${C_RESET}  $1"; }
section() { echo -e "\n${C_MAGENTA}${C_BOLD}$1${C_RESET}"; }

# ── Init ─────────────────────────────────────────────────────────────────────

section "SWARM FORGE — test flow"
FLOW_START=$(date +%s)

# Resolve or create target dir
if [[ -n "$TARGET_DIR" ]]; then
  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  REPO_DIR="$(cd "$TARGET_DIR" && pwd)"
else
  REPO_DIR="$(mktemp -d)"
fi

CONDUCTOR_DIR=".conductor"

echo "   Target dir    : $REPO_DIR"
echo "   Step delay    : ${STEP_DELAY}s"
echo "   Board         : CONDUCTOR_DIR=$REPO_DIR/$CONDUCTOR_DIR node kanban-board.js"

# Init git repo in target dir
cd "$REPO_DIR"
git init -q
git config user.email "swarm@test"
git config user.name "Swarm Test"
echo "# Hunt the Wumpus" > README.md
git add README.md
git commit -q -m "chore: initial commit"

mkdir -p \
  "$CONDUCTOR_DIR/tasks" \
  "$CONDUCTOR_DIR/work" \
  "$CONDUCTOR_DIR/architect-inbox" \
  "$CONDUCTOR_DIR/kanban/backlog" \
  "$CONDUCTOR_DIR/kanban/ready" \
  "$CONDUCTOR_DIR/kanban/in-progress" \
  "$CONDUCTOR_DIR/kanban/review" \
  "$CONDUCTOR_DIR/kanban/merge-pending" \
  "$CONDUCTOR_DIR/kanban/merging" \
  "$CONDUCTOR_DIR/kanban/done"

info "Git repo + conductor dir initialized at $REPO_DIR"

# Start kanban server if requested — register EXIT trap to stop it
KANBAN_PID=""
if [[ "$KANBAN_SERVER" == true ]]; then
  # Find a free port starting from PORT env var or 3000
  KANBAN_PORT="${PORT:-3000}"
  while nc -z localhost "$KANBAN_PORT" 2>/dev/null; do
    KANBAN_PORT=$(( KANBAN_PORT + 1 ))
  done

  CONDUCTOR_DIR="$REPO_DIR/$CONDUCTOR_DIR" PORT="$KANBAN_PORT" \
    node "$ROOT_DIR/kanban-board.js" >> "$REPO_DIR/$CONDUCTOR_DIR/kanban-server.log" 2>&1 &
  KANBAN_PID=$!
  echo "$KANBAN_PORT" > "$REPO_DIR/$CONDUCTOR_DIR/kanban-server.port"
  info "Kanban board → http://localhost:${KANBAN_PORT} (pid $KANBAN_PID)"
fi

cleanup() {
  [[ -n "$KANBAN_PID" ]] && kill "$KANBAN_PID" 2>/dev/null && echo "Kanban server stopped"
  [[ -z "${TARGET_DIR:-}" ]] && [[ -n "${REPO_DIR:-}" ]] && rm -rf "$REPO_DIR"
}
trap cleanup EXIT

# All script helpers run from inside the repo with CONDUCTOR_DIR set
sig() { (cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-signal.sh" "$@") > /dev/null; }
mov() { (cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-move.sh"   "$@") > /dev/null; }
lst() { (cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-list.sh"); }
lck() { (cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-locks.sh"); }

# Helper: simulate a coder committing real files in a worktree
coder_commit() {
  local worktree="$1" file="$2" msg="$3"
  mkdir -p "$REPO_DIR/$worktree/$(dirname "$file")"
  echo "$(date) — $msg" > "$REPO_DIR/$worktree/$file"
  git -C "$REPO_DIR/$worktree" add "$file"
  git -C "$REPO_DIR/$worktree" commit -q -m "$msg"
}

# Helper: simulate a merger rebasing onto main
merger_rebase() {
  local worktree="$1"
  if git -C "$REPO_DIR/$worktree" rebase origin/main -q >/dev/null 2>&1 || \
     git -C "$REPO_DIR/$worktree" rebase main -q >/dev/null 2>&1; then
    echo "success"
  else
    git -C "$REPO_DIR/$worktree" rebase --abort >/dev/null 2>&1 || true
    echo "conflict"
  fi
}

# ── Architect: decompose brief ────────────────────────────────────────────────

section "ARCHITECT — decomposing brief"
note "Project: Hunt the Wumpus (mini)"

step "Creating foundational design task (no dependencies)"
T1=$(cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-create.sh" \
  --title "Define game model" --type design \
  --description "Define Room (id, connections[3]), Player (room, arrows=5), Wumpus (room). Adjacency is bidirectional.")
info "Created $T1 — Define game model"

step "Creating parallel implementation tasks (all depend on $T1)"
T2=$(cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-create.sh" \
  --title "Implement room graph" --type feature --depends-on "$T1" \
  --description "Build 20-room dodecahedron. Implement adjacency lookup.")
info "Created $T2 — Implement room graph"

T3=$(cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-create.sh" \
  --title "Implement player state" --type feature --depends-on "$T1" \
  --description "Player position, arrow count, move and shoot actions.")
info "Created $T3 — Implement player state"

T4=$(cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-create.sh" \
  --title "Implement Wumpus behaviour" --type feature --depends-on "$T1" \
  --description "Wumpus random start, moves on missed shot.")
info "Created $T4 — Implement Wumpus behaviour"

step "Creating integration task (depends on $T2, $T3, $T4)"
T5=$(cd "$REPO_DIR" && CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-create.sh" \
  --title "Implement game loop" --type feature --depends-on "$T2,$T3,$T4" \
  --description "Turn sequence: sense hazards, prompt action, resolve outcome, check win/lose.")
info "Created $T5 — Implement game loop"

lst

# ── Conductor: unblock ready tasks ────────────────────────────────────────────

section "CONDUCTOR — unblocking ready tasks"
note "$T1 has no dependencies → move to ready"

step "Moving $T1 (design) to ready — no coder needed, architect writes content"
mov "$T1" ready
info "$T1 moved to ready"

step "Design task is self-contained — architect signals it complete directly"
sig --task "$T1" --type signal --outcome complete \
  --notes "Game model defined. Room, Player, Wumpus structs documented in task."
mov "$T1" done
info "$T1 done — unblocks $T2, $T3, $T4"

step "Conductor sees $T1 is done — moves all dependents to ready"
mov "$T2" ready && mov "$T3" ready && mov "$T4" ready
info "$T2, $T3, $T4 all moved to ready (can run in parallel)"

lst

# ── Coders: parallel work ─────────────────────────────────────────────────────

section "CODERS — three parallel workers"

step "Conductor spawns coder for $T2, $T3, $T4 — creates real git worktrees"
git -C "$REPO_DIR" worktree add -q ".worktrees/coder-$T2" -b "feature/$T2-room-graph"
git -C "$REPO_DIR" worktree add -q ".worktrees/coder-$T3" -b "feature/$T3-player-state"
git -C "$REPO_DIR" worktree add -q ".worktrees/coder-$T4" -b "feature/$T4-wumpus"
sig --task "$T2" --type assigned --worker-type coder --branch "feature/$T2-room-graph" --worktree ".worktrees/coder-$T2"
sig --task "$T3" --type assigned --worker-type coder --branch "feature/$T3-player-state" --worktree ".worktrees/coder-$T3"
sig --task "$T4" --type assigned --worker-type coder --branch "feature/$T4-wumpus" --worktree ".worktrees/coder-$T4"
mov "$T2" in-progress && mov "$T3" in-progress && mov "$T4" in-progress
info "Three git worktrees created, coders working in parallel"

step "Coder $T2 commits work"
coder_commit ".worktrees/coder-$T2" "src/rooms.clj" "feat: implement room graph"
sig --task "$T2" --type progress --notes "Room struct and adjacency map done."
info "$T2 committed src/rooms.clj"

step "Coder $T3 commits work and signals complete"
coder_commit ".worktrees/coder-$T3" "src/player.clj" "feat: implement player state"
sig --task "$T3" --type signal --outcome complete --files "src/player.clj" \
  --notes "Player state with move/shoot actions implemented."
mov "$T3" review
info "$T3 committed src/player.clj → review"

step "Coder $T2 signals complete"
sig --task "$T2" --type signal --outcome complete --files "src/rooms.clj" \
  --notes "20-room dodecahedron built. Adjacency lookup O(1)."
mov "$T2" review
info "$T2 → review"

step "Coder $T4 commits work — touches src/player.clj (overlap with $T3!)"
coder_commit ".worktrees/coder-$T4" "src/wumpus.clj"  "feat: implement wumpus behaviour"
coder_commit ".worktrees/coder-$T4" "src/player.clj"  "feat: extend player for wumpus shoot"
sig --task "$T4" --type signal --outcome complete --files "src/wumpus.clj,src/player.clj" \
  --notes "Wumpus behaviour implemented. Extended player.clj for shoot interaction."
mov "$T4" review
info "$T4 committed src/wumpus.clj + src/player.clj → review"

lst

# ── Reviewers ─────────────────────────────────────────────────────────────────

section "VALIDATORS — running test suite in each worktree"

step "Validator runs tests for $T3 — passes"
sig --task "$T3" --type validation --outcome passed \
  --notes "All tests passed. (lein test: 12 assertions, 0 failures)"
mov "$T3" review
info "$T3 validation passed → review"

step "Validator runs tests for $T2 — fails (missing guard not tested)"
sig --task "$T2" --type validation --outcome failed \
  --notes "FAIL in rooms-test: (adjacency-test) expected 3 connections, got nil for room 18"
mov "$T2" in-progress
info "$T2 validation failed → back to coder"

step "Coder $T2 fixes the failing test + adds guard"
coder_commit ".worktrees/coder-$T2" "src/rooms.clj" "fix: add guard + fix test for sparse rooms"
sig --task "$T2" --type signal --outcome complete --files "src/rooms.clj" \
  --notes "Guard added, test now passes."
mov "$T2" validation

step "Validator re-runs tests for $T2 — now passes"
sig --task "$T2" --type validation --outcome passed \
  --notes "All tests passed. (lein test: 14 assertions, 0 failures)"
mov "$T2" review
info "$T2 validation passed → review"

step "Validator runs tests for $T4 — passes"
sig --task "$T4" --type validation --outcome passed \
  --notes "All tests passed. (lein test: 8 assertions, 0 failures)"
mov "$T4" review
info "$T4 validation passed → review"

section "REVIEWERS"

step "Reviewer approves $T3, $T2, $T4"
sig --task "$T3" --type review --outcome approved --notes "Clean implementation."
sig --task "$T2" --type review --outcome approved --notes "Fix looks good."
sig --task "$T4" --type review --outcome approved --notes "Wumpus logic correct."
info "$T3, $T2, $T4 all approved"

# ── Merge queue with file lock collision ──────────────────────────────────────

section "CONDUCTOR — merge queue + file lock collision"

note "src/player.clj is touched by both $T3 and $T4 — they cannot merge simultaneously"

step "Conductor checks locks and starts $T3 merge (no conflict yet)"
mov "$T3" merging
sig --task "$T3" --type assigned --worker-type merger \
  --branch "feature/$T3-player-state" --worktree ".worktrees/merger-$T3"
info "$T3 → merging"

step "Conductor checks locks for $T4 — src/player.clj is locked by $T3"
note "Locked files: $(lck | tr '\n' ' ' || echo "(none)")"
mov "$T4" merge-pending
info "$T4 → merge-pending (blocked on file lock)"

step "$T2 has no overlap — starts merging immediately"
mov "$T2" merging
info "$T2 → merging (no lock conflict)"

lst

# ── Merges ────────────────────────────────────────────────────────────────────

section "MERGERS"

step "Merger $T3 — real rebase onto main (reuses coder worktree)"
RESULT=$(merger_rebase ".worktrees/coder-$T3")
sig --task "$T3" --type merge --outcome "$RESULT" --files "src/player.clj" \
  --notes "Rebase result: $RESULT"
if [[ "$RESULT" == "success" ]]; then
  # Fast-forward main so subsequent rebases see this work
  git -C "$REPO_DIR" merge -q --ff-only "feature/$T3-player-state"
  mov "$T3" done
  info "$T3 merged cleanly onto main"
fi

step "Conductor re-checks merge-pending — $T4 is now clear"
note "Locked files: $(lck | tr '\n' ' ' || echo "(none)")"
mov "$T4" merging
info "$T4 → merging (lock released)"

step "Merger $T4 — rebase onto main (now includes src/player.clj from $T3)"
RESULT=$(merger_rebase ".worktrees/coder-$T4")
note "Rebase result: $RESULT (expected: conflict — $T3 and $T4 both modified src/player.clj)"
sig --task "$T4" --type merge --outcome "$RESULT" --files "src/wumpus.clj,src/player.clj" \
  --notes "Rebase result: $RESULT"
if [[ "$RESULT" == "conflict" ]]; then
  mov "$T4" in-progress
  info "$T4 conflict → back to coder"

  step "Coder resolves conflict with a real merge commit"
  # Simulate resolution: re-create the branch from main, apply both changes
  git -C "$REPO_DIR" worktree remove -f ".worktrees/coder-$T4" 2>/dev/null || true
  git -C "$REPO_DIR" branch -D "feature/$T4-wumpus" 2>/dev/null || true
  git -C "$REPO_DIR" worktree add -q ".worktrees/coder-$T4" -b "feature/$T4-wumpus"
  coder_commit ".worktrees/coder-$T4" "src/wumpus.clj"  "feat: wumpus behaviour"
  coder_commit ".worktrees/coder-$T4" "src/player.clj"  "fix: merge player extensions"
  sig --task "$T4" --type signal --outcome complete --files "src/wumpus.clj,src/player.clj" \
    --notes "Conflict resolved — merged both Player extensions."
  mov "$T4" review
  sig --task "$T4" --type review --outcome approved --notes "Resolution looks correct."
  mov "$T4" merging

  step "Merger $T4 retries — rebase should be clean now"
  RESULT=$(merger_rebase ".worktrees/coder-$T4")
  sig --task "$T4" --type merge --outcome "$RESULT" --files "src/wumpus.clj,src/player.clj" \
    --notes "Retry rebase result: $RESULT"
  if [[ "$RESULT" == "success" ]]; then
    git -C "$REPO_DIR" merge -q --ff-only "feature/$T4-wumpus"
    mov "$T4" done
    info "$T4 merged cleanly on retry"
  fi
fi

step "Merger $T2 — real rebase onto main (reuses coder worktree)"
RESULT=$(merger_rebase ".worktrees/coder-$T2")
sig --task "$T2" --type merge --outcome "$RESULT" --files "src/rooms.clj" \
  --notes "Rebase result: $RESULT"
if [[ "$RESULT" == "success" ]]; then
  git -C "$REPO_DIR" merge -q --ff-only "feature/$T2-room-graph"
  mov "$T2" done
  info "$T2 merged cleanly"
fi

# ── Conductor: unblock T5 ─────────────────────────────────────────────────────

section "CONDUCTOR — $T5 unblocked"

step "All dependencies of $T5 are done — conductor moves it to ready"
mov "$T5" ready
info "$T5 (game loop) → ready"

step "Coder implements game loop with a real commit"
git -C "$REPO_DIR" worktree add -q ".worktrees/coder-$T5" -b "feature/$T5-game-loop"
coder_commit ".worktrees/coder-$T5" "src/game.clj" "feat: implement game loop"
sig --task "$T5" --type assigned --worker-type coder \
  --branch "feature/$T5-game-loop" --worktree ".worktrees/coder-$T5"
mov "$T5" in-progress
sig --task "$T5" --type signal --outcome complete --files "src/game.clj" \
  --notes "Game loop implemented. Win/lose conditions working."
mov "$T5" validation
sig --task "$T5" --type validation --outcome passed \
  --notes "All tests passed. (lein test: 31 assertions, 0 failures)"
mov "$T5" review
sig --task "$T5" --type review --outcome approved --notes "Game loop clean. All criteria met."
mov "$T5" merging

step "Merger $T5 — real rebase onto main (reuses coder worktree)"
RESULT=$(merger_rebase ".worktrees/coder-$T5")
sig --task "$T5" --type merge --outcome "$RESULT" --files "src/game.clj" \
  --notes "Rebase result: $RESULT"
if [[ "$RESULT" == "success" ]]; then
  git -C "$REPO_DIR" merge -q --ff-only "feature/$T5-game-loop"
  mov "$T5" done
  info "$T5 merged cleanly — Hunt the Wumpus is built"
fi

# ── Final state ───────────────────────────────────────────────────────────────

section "COMPLETE"
lst
echo ""
echo "Git log:"
git -C "$REPO_DIR" log --oneline
echo ""
echo -e "${C_GREEN}${C_BOLD}All tasks done. Hunt the Wumpus is built.${C_RESET}"
echo ""

section "TIMING"
CONDUCTOR_DIR="$REPO_DIR/$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-timing.sh"

FLOW_END=$(date +%s)
FLOW_SECS=$(( FLOW_END - FLOW_START ))
echo -e "  ${C_BOLD}Script ran in    :${C_RESET}  ${FLOW_SECS}s total (including all sleeps)"

if [[ -z "$TARGET_DIR" ]]; then
  echo -e "\n  ${C_YELLOW}(temp dir cleaned up automatically)${C_RESET}"
else
  echo -e "\n  Project remains at: $REPO_DIR"
fi
echo ""
