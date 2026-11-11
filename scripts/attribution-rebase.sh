#!/usr/bin/env bash
# The merger's rebase, which also stamps each of the task's commits with trailer lines (#130,
# docs/commit-attribution.md).
#
# Usage: attribution-rebase.sh <base-sha> [<trailer-line>...]
#        run from the task's worktree, on the task's branch.
#
# Rebases the branch onto <base-sha>. With trailer lines, every commit that lands on <base-sha>
# ends up with each of them in its message. With none it is the plain `git rebase <base-sha>`.
#
# The stamp only ever adds. A line is added to a commit only when that exact line is not one of
# the commit's trailers: a second run changes nothing (the merger retries a failed fast-forward up to
# three times), and a trailer the commit already has, a human's Co-Authored-By among them, is kept.
# Git's own trailer.ifexists options do not give this: the default doubles the lines when several are
# added, and `replace` removes every trailer with the same key.
#
# A conflict stops the rebase, which this script leaves in progress and reports with git's exit code:
# the merger aborts it and signals, as before.
#
# Exit: 0 rebased (and stamped); 2 no base given; anything else is git's.

set -euo pipefail

# Add each given line to HEAD's message unless that exact line is already one of its trailers.
# Called by `git rebase --exec` once per commit, so HEAD is the commit just replayed.
#
# --no-verify: the amend changes a trailer and nothing else, so it must not depend on the project's own
# commit rules. A commit-msg hook that lints messages, or a signing prompt, would fail the rebase here
# and the merger would read that as a conflict.
stamp_head() {
  local line args=()
  for line in "$@"; do
    git log -1 --format=%B | git interpret-trailers --parse | grep -qxF -- "$line" \
      || args+=(--trailer "$line")
  done
  [[ ${#args[@]} -eq 0 ]] || git commit -q --amend --no-edit --no-verify "${args[@]}"
}

# --stamp is not for people: it is the command `git rebase --exec` runs for each replayed commit (see the
# end of this file, where the lines are quoted into one string with printf %q).
if [[ "${1:-}" == "--stamp" ]]; then
  shift
  stamp_head "$@"
  exit 0
fi

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  echo "usage: attribution-rebase.sh <base-sha> [<trailer-line>...]" >&2
  exit 2
fi
shift

if [[ $# -eq 0 ]]; then
  git rebase -q "$BASE"
else
  # --exec takes one shell string: this script again, in --stamp mode, with the lines quoted.
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  stamp="$(printf '%q ' "$me" --stamp "$@")"
  git rebase -q --exec "$stamp" "$BASE"
fi
