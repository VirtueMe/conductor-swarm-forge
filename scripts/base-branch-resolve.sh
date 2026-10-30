#!/usr/bin/env bash
# Resolves the swarm's base branch in the current git repo and checks it out.
#
# Usage: base-branch-resolve.sh <branch> [<start-point>]
#        base-branch-resolve.sh --default
#
# A missing branch is created from <start-point>; when omitted, from the repo's
# default branch: origin/HEAD if set, else main, else master. With --default,
# prints that default branch name and changes nothing.
#
# Prints one line naming the case that applied:
#   reused   <branch>   already exists locally
#   tracking <branch>   exists only as origin/<branch> — local tracking branch created
#   created  <branch>   did not exist — created from the start point
set -euo pipefail

[[ $# -ge 1 ]] || { echo "Usage: base-branch-resolve.sh <branch> [<start-point>] | --default" >&2; exit 1; }

default_branch() {
  local head
  if head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${head#origin/}"; return 0
  fi
  local b
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then echo "$b"; return 0; fi
  done
  return 1
}

if [[ "$1" == "--default" ]]; then
  default_branch
  exit
fi

BRANCH="$1"
START="${2:-}"

git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || {
  echo "Invalid branch name: $BRANCH" >&2; exit 1; }

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  CASE="reused"
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git branch --track "$BRANCH" "origin/$BRANCH" >/dev/null
  CASE="tracking"
else
  START="${START:-$(default_branch)}" || {
    echo "Cannot create base branch '$BRANCH': no default branch found (origin/HEAD, main, master)" >&2; exit 1; }
  git rev-parse --verify --quiet "$START^{commit}" >/dev/null || {
    echo "Cannot create base branch '$BRANCH': start point '$START' does not exist" >&2; exit 1; }
  git branch "$BRANCH" "$START"
  CASE="created"
fi

git checkout -q "$BRANCH"
echo "$CASE $BRANCH"
