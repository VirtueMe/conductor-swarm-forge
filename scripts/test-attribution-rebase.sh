#!/usr/bin/env bash
# Tests attribution-rebase.sh with no tmux and no AI: the merger's rebase that also stamps each of the
# task's commits with trailer lines (#130). Throwaway repos only.
#
# Usage: scripts/test-attribution-rebase.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$SCRIPTS_DIR/attribution-rebase.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

AGENT="Co-Authored-By: Codex <https://openai.com/codex>"
MODEL="Assisted-by: codex:gpt-6.1-sol"

# A repo with a base commit on main, and a task branch of $2 commits (c1, c2, ...) checked out. When
# $3 is set, every task commit carries that trailer line already.
new_task() {
  local dir="$1" n="$2" trailer="${3:-}" i
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "swarm@test"
  git -C "$dir" config user.name "Swarm Test"
  echo base > "$dir/base.txt"
  git -C "$dir" add base.txt
  git -C "$dir" commit -q -m "chore: base"
  git -C "$dir" switch -q -c task
  for (( i = 1; i <= n; i++ )); do
    echo "$i" > "$dir/f$i.txt"
    git -C "$dir" add "f$i.txt"
    if [[ -n "$trailer" ]]; then git -C "$dir" commit -q -m "feat: c$i" --trailer "$trailer"
    else git -C "$dir" commit -q -m "feat: c$i"; fi
  done
}

# The trailer lines of one commit, one per line.
trailers() { git -C "$1" log -1 --format=%B "$2" | git interpret-trailers --parse; }
# How many times $3 is a line of the trailers of commit $2 in repo $1.
count() { { trailers "$1" "$2" | grep -cxF -- "$3"; } || true; }

echo "── every commit of the task is stamped"
R="$WORK/stamp"; new_task "$R" 3
BASE="$(git -C "$R" rev-parse main)"
TREE_BEFORE="$(git -C "$R" rev-parse 'HEAD^{tree}')"
(cd "$R" && "$STAMP" "$BASE" "$AGENT" "$MODEL")
for c in HEAD HEAD~1 HEAD~2; do
  assert_eq "$c has the agent line" "$(count "$R" "$c" "$AGENT")" "1"
  assert_eq "$c has the model line" "$(count "$R" "$c" "$MODEL")" "1"
done
assert_eq "three task commits, no more" "$(git -C "$R" rev-list --count "$BASE..HEAD")" "3"
assert_eq "the base is not touched"     "$(git -C "$R" log -1 --format=%s main)" "chore: base"
assert_eq "the trees are unchanged"     "$(git -C "$R" rev-parse 'HEAD^{tree}')" "$TREE_BEFORE"
assert_eq "the subjects are unchanged"  "$(git -C "$R" log -1 --format=%s HEAD~1)" "feat: c2"

echo "── a second run changes nothing"
BEFORE="$(git -C "$R" rev-parse HEAD)"
(cd "$R" && "$STAMP" "$BASE" "$AGENT" "$MODEL")
assert_eq "same commits"          "$(git -C "$R" rev-parse HEAD)" "$BEFORE"
assert_eq "still one agent line"  "$(count "$R" HEAD "$AGENT")" "1"
assert_eq "still one model line"  "$(count "$R" HEAD "$MODEL")" "1"

echo "── a trailer already there is kept, and only the missing one is added"
HUMAN="Co-Authored-By: A Human <human@example.com>"
R="$WORK/human"; new_task "$R" 2 "$HUMAN"
BASE="$(git -C "$R" rev-parse main)"
(cd "$R" && "$STAMP" "$BASE" "$AGENT" "$MODEL")
for c in HEAD HEAD~1; do
  assert_eq "$c keeps the human"       "$(count "$R" "$c" "$HUMAN")" "1"
  assert_eq "$c has the agent line"    "$(count "$R" "$c" "$AGENT")" "1"
done
R="$WORK/partial"; new_task "$R" 2 "$AGENT"
BASE="$(git -C "$R" rev-parse main)"
(cd "$R" && "$STAMP" "$BASE" "$AGENT" "$MODEL")
assert_eq "the agent line is not doubled" "$(count "$R" HEAD "$AGENT")" "1"
assert_eq "the model line is added"       "$(count "$R" HEAD "$MODEL")" "1"

echo "── the project's commit hooks do not stand in the way"
R="$WORK/hook"; new_task "$R" 2
printf '#!/bin/sh\necho "rejected by the project hook" >&2\nexit 1\n' > "$R/.git/hooks/commit-msg"
chmod +x "$R/.git/hooks/commit-msg"
BASE="$(git -C "$R" rev-parse main)"
set +e; (cd "$R" && "$STAMP" "$BASE" "$AGENT") >/dev/null 2>&1; RC=$?; set -e
assert_eq "a rejecting commit-msg hook does not fail the stamp" "$RC" "0"
assert_eq "and the tip is stamped" "$(count "$R" HEAD "$AGENT")" "1"
assert_eq "and so is the first commit" "$(count "$R" HEAD~1 "$AGENT")" "1"

echo "── no trailer lines: a plain rebase"
R="$WORK/plain"; new_task "$R" 2
git -C "$R" switch -q main
echo more > "$R/more.txt"; git -C "$R" add more.txt; git -C "$R" commit -q -m "chore: base moved"
git -C "$R" switch -q task
NEWBASE="$(git -C "$R" rev-parse main)"
(cd "$R" && "$STAMP" "$NEWBASE")
assert_eq "the task sits on the moved base" "$(git -C "$R" merge-base HEAD main)" "$NEWBASE"
assert_eq "no trailer was added"            "$(trailers "$R" HEAD | wc -l | tr -d ' ')" "0"
assert_eq "two commits on the new base"     "$(git -C "$R" rev-list --count "$NEWBASE..HEAD")" "2"

echo "── the rebase still happens when it stamps"
R="$WORK/moved"; new_task "$R" 2
git -C "$R" switch -q main
echo more > "$R/more.txt"; git -C "$R" add more.txt; git -C "$R" commit -q -m "chore: base moved"
git -C "$R" switch -q task
NEWBASE="$(git -C "$R" rev-parse main)"
(cd "$R" && "$STAMP" "$NEWBASE" "$AGENT")
assert_eq "the task sits on the moved base" "$(git -C "$R" merge-base HEAD main)" "$NEWBASE"
assert_eq "and its tip is stamped"          "$(count "$R" HEAD "$AGENT")" "1"
assert_eq "and so is the first commit"      "$(count "$R" HEAD~1 "$AGENT")" "1"

echo "── a conflict is left for the caller"
R="$WORK/conflict"; new_task "$R" 1
git -C "$R" switch -q main
echo other > "$R/f1.txt"; git -C "$R" add f1.txt; git -C "$R" commit -q -m "chore: clash"
git -C "$R" switch -q task
set +e; (cd "$R" && "$STAMP" "$(git -C "$R" rev-parse main)" "$AGENT") >/dev/null 2>&1; RC=$?; set -e
if [[ "$RC" -ne 0 ]]; then ok "exits non-zero on a conflict"; else fail "exits non-zero on a conflict (got 0)"; fi
if [[ -d "$R/.git/rebase-merge" || -d "$R/.git/rebase-apply" ]]; then ok "the rebase is left in progress, for the merger to abort"
else fail "the rebase is left in progress, for the merger to abort"; fi

echo "── --task: the lines come from the resolver (#130)"
# A conductor dir whose coder is on codex with a model, and a config.md with $1 (an attribution line, or none).
new_cd() {
  local d; d="$(mktemp -d "$WORK/cd.XXXXXX")"
  echo '{"name":"t","members":[{"role":"coder","adapter":"codex","params":{"model":"gpt-6.1-sol"}}]}' > "$d/workforce.json"
  printf -- '---\nlang: bash\n%s---\n' "${1:+$1
}" > "$d/config.md"
  echo "$d"
}
RESOLVED_AGENT="Co-Authored-By: Codex <https://openai.com/codex>"
RESOLVED_MODEL="Assisted-by: codex:gpt-6.1-sol"
R="$WORK/task"; new_task "$R" 2
BASE="$(git -C "$R" rev-parse main)"; CD="$(new_cd)"
(cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --task 0001)
for c in HEAD HEAD~1; do
  assert_eq "$c has the resolved agent line" "$(count "$R" "$c" "$RESOLVED_AGENT")" "1"
  assert_eq "$c has the resolved model line" "$(count "$R" "$c" "$RESOLVED_MODEL")" "1"
done
BEFORE="$(git -C "$R" rev-parse HEAD)"
(cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --task 0001)
assert_eq "a second run changes nothing" "$(git -C "$R" rev-parse HEAD)" "$BEFORE"

R="$WORK/task-extra"; new_task "$R" 1
BASE="$(git -C "$R" rev-parse main)"; CD="$(new_cd)"
(cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --task 0001 "$MODEL")
assert_eq "lines given as well are added too" "$(count "$R" HEAD "$MODEL")" "1"
assert_eq "beside the resolved ones"          "$(count "$R" HEAD "$RESOLVED_AGENT")" "1"

echo "── --task with attribution: none is the plain rebase"
R="$WORK/task-none"; new_task "$R" 2
BASE="$(git -C "$R" rev-parse main)"; CD="$(new_cd 'attribution: none')"
BEFORE="$(git -C "$R" rev-parse HEAD)"
(cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --task 0001)
assert_eq "no trailer was added" "$(trailers "$R" HEAD | wc -l | tr -d ' ')" "0"
assert_eq "the commits are as they were" "$(git -C "$R" rev-parse HEAD)" "$BEFORE"

echo "── --task with a bad setting stops before anything is rewritten"
R="$WORK/task-bad"; new_task "$R" 2
BASE="$(git -C "$R" rev-parse main)"; CD="$(new_cd 'attribution: banana')"
BEFORE="$(git -C "$R" rev-parse HEAD)"
set +e; (cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --task 0001) >/dev/null 2>"$WORK/err"; RC=$?; set -e
assert_eq "exit 1" "$RC" "1"
assert_eq "the branch is untouched" "$(git -C "$R" rev-parse HEAD)" "$BEFORE"
if [[ -d "$R/.git/rebase-merge" || -d "$R/.git/rebase-apply" ]]; then fail "no rebase was started"; else ok "no rebase was started"; fi
if grep -q banana "$WORK/err"; then ok "and the message says why"; else fail "and the message says why ($(cat "$WORK/err"))"; fi

echo "── --task with nothing to resolve: a plain rebase, with the warning"
R="$WORK/task-nowf"; new_task "$R" 1
git -C "$R" switch -q main
echo more > "$R/more.txt"; git -C "$R" add more.txt; git -C "$R" commit -q -m "chore: base moved"
git -C "$R" switch -q task
NEWBASE="$(git -C "$R" rev-parse main)"; CD="$(mktemp -d "$WORK/cd.XXXXXX")"
set +e; (cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$NEWBASE" --task 0001) >/dev/null 2>"$WORK/err"; RC=$?; set -e
assert_eq "exit 0" "$RC" "0"
assert_eq "the task sits on the moved base" "$(git -C "$R" merge-base HEAD main)" "$NEWBASE"
assert_eq "no trailer was added" "$(trailers "$R" HEAD | wc -l | tr -d ' ')" "0"
if grep -q workforce "$WORK/err"; then ok "and the warning reaches stderr"; else fail "and the warning reaches stderr ($(cat "$WORK/err"))"; fi

echo "── a stray argument is refused before anything is rewritten"
R="$WORK/stray"; new_task "$R" 2
BASE="$(git -C "$R" rev-parse main)"; CD="$(new_cd)"
BEFORE="$(git -C "$R" rev-parse HEAD)"
for bad in "--taks" "0001" "not a trailer" "Key:novalue" ": nokey"; do
  set +e; (cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --task 0001 "$bad") >/dev/null 2>"$WORK/err"; RC=$?; set -e
  assert_eq "'$bad': exit 2" "$RC" "2"
  assert_eq "'$bad': the branch is untouched" "$(git -C "$R" rev-parse HEAD)" "$BEFORE"
done
if grep -q -- '--taks' <<< "$(cd "$R" && CONDUCTOR_DIR="$CD" "$STAMP" "$BASE" --taks 0001 2>&1 || true)"; then ok "and the message shows the line it refused"; else fail "and the message shows the line it refused"; fi

echo "── usage"
set +e; (cd "$WORK" && "$STAMP") >/dev/null 2>&1; RC=$?; set -e
assert_eq "no base: exit 2" "$RC" "2"
set +e; (cd "$WORK" && "$STAMP" abc123 --task) >/dev/null 2>&1; RC=$?; set -e
assert_eq "--task with no id: exit 2" "$RC" "2"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; else echo "$FAILS check(s) failed." >&2; exit 1; fi
