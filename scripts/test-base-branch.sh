#!/usr/bin/env bash
# Tests the --base-branch mechanics with no tmux and no AI: base-branch-resolve.sh
# (created / reused / tracking cases), the integration adapter forking task
# branches from the base, and a merge landing on the base with main untouched.
#
# Usage: scripts/test-base-branch.sh

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
assert_file() {
  if [[ -f "$2" ]]; then ok "$1"; else fail "$1 ($2 missing)"; fi
}

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "swarm@test"
  git -C "$dir" config user.name "Swarm Test"
  echo "base" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "chore: initial commit"
}

# Spawns a task workspace the way worker-spawn.sh does, commits, and merges it
# the way the merger skill lands work: rebase onto $BASE, then fast-forward $BASE
# in the main working tree (git refuses to fetch into a checked-out branch).
run_task() {
  local repo="$1" base="$2" task="$3"
  (
    cd "$repo"
    # shellcheck source=integrations/git.sh
    source "$ROOT_DIR/integrations/git.sh"
    IFS=$'\t' read -r wt branch < <(integration_prepare_workspace "$task" coder "Add $task" "$base")
    echo "$task" > "$wt/$task.txt"
    git -C "$wt" add "$task.txt"
    git -C "$wt" commit -q -m "feat: $task"
    git -C "$wt" rebase -q "$base"
    git -C "$repo" merge -q --ff-only "$branch"
  )
}

echo "── base branch created from main"
R1="$WORK/fresh"; new_repo "$R1"
MAIN_BEFORE=$(git -C "$R1" rev-parse main)
OUT=$(cd "$R1" && "$SCRIPTS_DIR/base-branch-resolve.sh" build)
assert_eq "reports created"            "$OUT" "created build"
assert_eq "build forks from main"      "$(git -C "$R1" rev-parse build)" "$MAIN_BEFORE"
assert_eq "build is checked out"       "$(git -C "$R1" symbolic-ref --short HEAD)" "build"
run_task "$R1" build t1
assert_eq "task branch forked from build" \
  "$(git -C "$R1" rev-parse feature/t1-add-t1~1)" "$MAIN_BEFORE"
assert_eq "merge landed on build" "$(git -C "$R1" rev-parse build)" "$(git -C "$R1" rev-parse feature/t1-add-t1)"
assert_eq "main untouched"             "$(git -C "$R1" rev-parse main)" "$MAIN_BEFORE"

echo "── base branch already exists"
R2="$WORK/existing"; new_repo "$R2"
git -C "$R2" checkout -q -b build
echo "phase1" > "$R2/phase1.txt"; git -C "$R2" add phase1.txt; git -C "$R2" commit -q -m "feat: phase 1"
BUILD_TIP=$(git -C "$R2" rev-parse build)
MAIN_BEFORE=$(git -C "$R2" rev-parse main)
git -C "$R2" checkout -q main
OUT=$(cd "$R2" && "$SCRIPTS_DIR/base-branch-resolve.sh" build)
assert_eq "reports reused"             "$OUT" "reused build"
assert_eq "build tip preserved"        "$(git -C "$R2" rev-parse build)" "$BUILD_TIP"
run_task "$R2" build t2
assert_eq "task branch forked from build tip" \
  "$(git -C "$R2" rev-parse feature/t2-add-t2~1)" "$BUILD_TIP"
assert_eq "merge landed on build" "$(git -C "$R2" rev-parse build)" "$(git -C "$R2" rev-parse feature/t2-add-t2)"
assert_file "build keeps earlier work" "$R2/phase1.txt"
assert_eq "main untouched"             "$(git -C "$R2" rev-parse main)" "$MAIN_BEFORE"

echo "── base branch only on origin"
R3="$WORK/origin-src"; new_repo "$R3"
git -C "$R3" checkout -q -b build
echo "remote" > "$R3/remote.txt"; git -C "$R3" add remote.txt; git -C "$R3" commit -q -m "feat: remote work"
git -C "$R3" checkout -q main
git clone -q "$R3" "$WORK/clone"
OUT=$(cd "$WORK/clone" && "$SCRIPTS_DIR/base-branch-resolve.sh" build)
assert_eq "reports tracking"           "$OUT" "tracking build"
assert_eq "local build matches origin" \
  "$(git -C "$WORK/clone" rev-parse build)" "$(git -C "$WORK/clone" rev-parse origin/build)"

echo "── failure modes"
R4="$WORK/bad"; new_repo "$R4"
if (cd "$R4" && "$SCRIPTS_DIR/base-branch-resolve.sh" "bad..name" >/dev/null 2>&1); then
  fail "invalid branch name rejected"; else ok "invalid branch name rejected"; fi
git -C "$R4" branch -m main trunk
if (cd "$R4" && "$SCRIPTS_DIR/base-branch-resolve.sh" build >/dev/null 2>&1); then
  fail "no default branch rejected"; else ok "no default branch rejected"; fi

echo "── default branch fallback chain"
R5="$WORK/master"; new_repo "$R5"
git -C "$R5" branch -m main master
OUT=$(cd "$R5" && "$SCRIPTS_DIR/base-branch-resolve.sh" build)
assert_eq "falls back to master"       "$OUT" "created build"
assert_eq "build forks from master"    "$(git -C "$R5" rev-parse build)" "$(git -C "$R5" rev-parse master)"

R6="$WORK/clone-trunk"; new_repo "$WORK/trunk-src"
git -C "$WORK/trunk-src" branch -m main trunk
git clone -q "$WORK/trunk-src" "$R6"
git -C "$R6" checkout -q -b main            # decoy: a main that is not the default
echo "decoy" > "$R6/decoy.txt"; git -C "$R6" add decoy.txt; git -C "$R6" commit -q -m "chore: decoy"
OUT=$(cd "$R6" && "$SCRIPTS_DIR/base-branch-resolve.sh" build)
assert_eq "origin/HEAD preferred over main" "$OUT" "created build"
assert_eq "build forks from trunk"     "$(git -C "$R6" rev-parse build)" "$(git -C "$R6" rev-parse trunk)"

HEAD_BEFORE=$(git -C "$R6" symbolic-ref --short HEAD)
assert_eq "--default reports master"   "$(cd "$R5" && "$SCRIPTS_DIR/base-branch-resolve.sh" --default)" "master"
assert_eq "--default reports trunk"    "$(cd "$R6" && "$SCRIPTS_DIR/base-branch-resolve.sh" --default)" "trunk"
assert_eq "--default changes nothing"  "$(git -C "$R6" symbolic-ref --short HEAD)" "$HEAD_BEFORE"

R7="$WORK/explicit"; new_repo "$R7"
git -C "$R7" branch other
OUT=$(cd "$R7" && "$SCRIPTS_DIR/base-branch-resolve.sh" build other)
assert_eq "explicit start point used"  "$OUT" "created build"

echo "── task branch from a missing base falls back to HEAD"
R8="$WORK/nobase"; new_repo "$R8"
(
  cd "$R8"
  # shellcheck source=integrations/git.sh
  source "$ROOT_DIR/integrations/git.sh"
  integration_prepare_workspace t8 coder "Add t8" "no-such-branch" >/dev/null
)
assert_eq "workspace created from HEAD" \
  "$(git -C "$R8" rev-parse feature/t8-add-t8)" "$(git -C "$R8" rev-parse main)"

echo "── concurrent merges on disjoint files race on the base"
# Mirrors the merger skill's steps 1-3: fetch/rebase, fast-forward, and on a
# failed fast-forward (base moved) retry from the rebase, at most 3 attempts.
# Prints the attempt count on success; returns 1 if every attempt lost the race.
land_with_retry() {
  local repo="$1" base="$2" wt="$3" branch="$4" attempt
  for attempt in 1 2 3; do
    git -C "$wt" rebase -q "$base"
    if git -C "$repo" merge -q --ff-only "$branch" 2>/dev/null; then
      echo "$attempt"; return 0
    fi
  done
  return 1
}

R9="$WORK/race"; new_repo "$R9"
(
  cd "$R9"
  # shellcheck source=integrations/git.sh
  source "$ROOT_DIR/integrations/git.sh"
  IFS=$'\t' read -r WT_A BR_A < <(integration_prepare_workspace t9a coder "Add t9a" main)
  IFS=$'\t' read -r WT_B BR_B < <(integration_prepare_workspace t9b coder "Add t9b" main)
  echo a > "$WT_A/a.txt"; git -C "$WT_A" add a.txt; git -C "$WT_A" commit -q -m "feat: t9a"
  echo b > "$WT_B/b.txt"; git -C "$WT_B" add b.txt; git -C "$WT_B" commit -q -m "feat: t9b"
  # both mergers rebase onto the same base tip, then race
  git -C "$WT_A" rebase -q main
  git -C "$WT_B" rebase -q main
  printf '%s\n%s\n%s\n%s\n' "$R9/$WT_A" "$BR_A" "$R9/$WT_B" "$BR_B" > "$WORK/race.env"
)
{ read -r WT_A; read -r BR_A; read -r WT_B; read -r BR_B; } < "$WORK/race.env"

git -C "$R9" merge -q --ff-only "$BR_A"
if git -C "$R9" merge -q --ff-only "$BR_B" 2>/dev/null; then
  fail "second fast-forward is rejected once the base moved"
else
  ok "second fast-forward is rejected once the base moved"
fi
ATTEMPTS=$(land_with_retry "$R9" main "$WT_B" "$BR_B")
assert_eq "retry lands the second merge on attempt 1 (re-rebase)" "$ATTEMPTS" "1"
assert_file "base has first merge"  "$R9/a.txt"
assert_file "base has second merge" "$R9/b.txt"
assert_eq "history stays linear (no merge commits)" \
  "$(git -C "$R9" rev-list --merges main | wc -l | tr -d ' ')" "0"

echo ""
if (( FAILS > 0 )); then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "All checks passed"
